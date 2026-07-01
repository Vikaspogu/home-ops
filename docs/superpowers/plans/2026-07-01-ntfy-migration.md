# Self-Hosted ntfy Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the repository-managed Gotify/Slack notification transport with a secured, persistent self-hosted ntfy service, while preserving Telegram as Hermes's privileged interactive control plane.

**Architecture:** ntfy runs once in `default`, persists its SQLite cache and auth databases on the existing VolSync-managed PVC pattern, and is reached through the normal HTTPS Gateway API route. The 1Password `ntfy` item supplies only server identity material and producer tokens; declarative ntfy ACLs give each producer write access solely to its own topic. Alertmanager and Argo CD use supported native webhook mechanisms. Hermes receives a separate constrained ntfy platform with distinct inbound and outbound topics.

**Tech Stack:** Kubernetes, Argo CD, Kustomize, bjw-s app-template v5.0.1, Gateway API, External Secrets Operator with 1Password Connect, VolSync, ntfy v2.25.0, AlertmanagerConfig, Argo CD notifications.

## Global Constraints

- Deploy ntfy to the `default` namespace and register it in `clusters/talos/apps/20-applications.yaml` at sync wave `20` with the existing VolSync storage variables.
- Use an HTTPS `HTTPRoute` attached to `${GATEWAY_NAME}` in `${GATEWAY_NAMESPACE}`; never create an Ingress or use the media gateway.
- Use `binwiederhier/ntfy:v2.25.0`; never use a floating image tag.
- Set `NTFY_BASE_URL=https://ntfy.${CLUSTER_DOMAIN}`, `NTFY_BEHIND_PROXY=true`, and `NTFY_AUTH_DEFAULT_ACCESS=deny-all`.
- Persist `NTFY_CACHE_FILE` and `NTFY_AUTH_FILE` under `/var/lib/ntfy` on the VolSync PVC. Do not enable attachments, web push, metrics, or account self-service without a specified requirement.
- The 1Password item `ntfy` must provide `NTFY_AUTH_USERS`, `NTFY_AUTH_ACCESS`, and `NTFY_AUTH_TOKENS`. These values never appear in Git. User and token fields are comma-separated ntfy declarative records; ACL records grant each producer only its intended topic permission.
- Use separate topics: `infra-alerts`, `argocd-events`, `media-events`, `hermes-in`, and `hermes-out`. No producer may have a token granting access to another producer's topic.
- Preserve Alertmanager grouping, inhibition, Watchdog handling, and `sendResolved: true`.
- Keep Telegram fully configured for Hermes. `platform_toolsets.ntfy` may only expose `clarify`, `cronjob`, `delegation`, `memory`, `messaging`, `session_search`, `skills`, `todo`, `tts`, `vision`, and `web`; it must not expose `browser`, `code_execution`, `computer_use`, `terminal`, or `file`.
- Media-app notification destinations are runtime settings persisted on existing PVCs. Do not modify those databases, bootstrap unsupported app state, or put publisher tokens in Git. Document the supported post-sync bindings exactly.

---

### Task 1: Deploy the secure ntfy transport

**Files:**
- Create: `components/default/ntfy/kustomization.yaml`
- Create: `components/default/ntfy/values.yaml`
- Create: `components/default/ntfy/http-route.yaml`
- Create: `components/default/ntfy/externalsecret.yaml`
- Modify: `clusters/talos/apps/20-applications.yaml`

**Interfaces:**
- Consumes: 1Password item `ntfy` with `NTFY_AUTH_USERS`, `NTFY_AUTH_ACCESS`, and `NTFY_AUTH_TOKENS`.
- Produces: service `ntfy.default.svc.cluster.local`, external URL `https://ntfy.${CLUSTER_DOMAIN}`, and Secret `ntfy-secret`.

- [ ] **Step 1: Establish the negative validation case**

Run `kustomize build --enable-helm components/default/ntfy` before the component exists. The command must fail because the new component is absent.

- [ ] **Step 2: Create the app-template component**

Create an app-template v5.0.1 component matching the existing Gotify layout. The container runs `binwiederhier/ntfy:v2.25.0` with `args: ["serve"]`; mounts the `ntfy` PVC at `/var/lib/ntfy`; uses a single replica/Recreate strategy; has `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, and dropped capabilities; requests 10m CPU and 250Mi memory; limits memory to 500Mi. The component defines a ClusterSecretStore-backed ExternalSecret named `ntfy-secret` that imports the three ntfy auth variables from the `ntfy` 1Password item.

- [ ] **Step 3: Configure security and persistence**

Set the ntfy environment to the global constraints above and configure `/var/lib/ntfy/cache.db` plus `/var/lib/ntfy/auth.db`. Load the three provisioned auth variables exclusively through `envFrom: secretRef: ntfy-secret`; never duplicate secret fields in Values or a ConfigMap.

- [ ] **Step 4: Add normal-gateway routing and VolSync registration**

Publish `ntfy.${CLUSTER_DOMAIN}` through a standard HTTPS HTTPRoute and register `ntfy` at sync wave 20 with `ceph-block`, `csi-ceph-blockpool`, 2Gi capacity, and 8Gi cache capacity.

- [ ] **Step 5: Validate rendering and schema**

Run:

```bash
kustomize build --enable-helm components/default/ntfy
bash ./scripts/kubeconform.sh
```

Expected: ntfy renders and all repository schema checks pass.

### Task 2: Migrate infrastructure notifications to ntfy

**Files:**
- Modify: `components/observability/kube-prometheus-stack/alertmanagerconfig.yaml`
- Modify: `components/observability/kube-prometheus-stack/externalsecret.yaml`
- Modify: `components/argo-system/argo-cd/values.yaml`
- Modify: `components/argo-system/argo-cd/external-secret.yaml`
- Modify: `clusters/talos/apps/common-values.yaml`

**Interfaces:**
- Consumes: `ntfy` 1Password properties for the Alertmanager and Argo CD producer tokens and an ntfy ACL granting each producer write-only access to its individual topic.
- Produces: Alertmanager posts `?template=alertmanager` messages to `infra-alerts`; Argo CD publishes to `argocd-events` through the webhook notifier. HolmesGPT remains on its supported Slack-only destination until upstream supplies an ntfy or generic webhook destination.

- [ ] **Step 1: Establish the old-transport check**

Confirm the current Alertmanager receiver is `slack` and the Argo CD subscription annotations target `.slack`. This demonstrates that the migration is active only after the following edits.

- [ ] **Step 2: Replace Alertmanager's Slack receiver**

Replace the Slack receiver/secret with an Alertmanager `webhookConfigs` receiver that posts to the ntfy server’s `infra-alerts` topic with `?template=alertmanager`, bearer authentication sourced from its ExternalSecret, and `sendResolved: true`. Keep all routes, receiver names used by routes, group timing, inhibition, and heartbeat behavior intact, changing only the transport receiver name and its configuration.

- [ ] **Step 3: Replace Argo CD's Slack notifier**

- Configure `service.webhook.ntfy` using the ntfy base URL and a `Bearer $ntfy-publisher-token` header sourced through `argocd-notifications-secret`. Change each notification template to use webhook `ntfy` with an explicit POST path `/argocd-events`, title/tags/priority headers, and the existing application detail URL/body semantics. Change global subscription annotations from `.slack` to `.ntfy` with an empty target.

- [ ] **Step 4: Retain the supported HolmesGPT destination**

- Do not change HolmesGPT’s `type: slack` destination or its Slack credential mapping. HolmesGPT 0.34.0 and current upstream documentation support only Slack and PagerDuty alert destinations, so ntfy/webhook configuration would be invalid. Record this upstream prerequisite in the operations runbook.

- [ ] **Step 5: Validate manifests and retained routing behavior**

Run:

```bash
bash ./scripts/kubeconform.sh
```

- Expected: AlertmanagerConfig, ExternalSecrets, and Argo components remain schema-valid. Inspect the rendered AlertmanagerConfig to confirm the Watchdog route and `sendResolved: true` remain present.

### Task 3: Add constrained Hermes ntfy support

**Files:**
- Modify: `components/ai/hermes-agent/configmap.yaml`
- Modify: `components/ai/hermes-agent/externalsecret.yaml`
- Modify: `components/ai/mac/config.yaml`

**Interfaces:**
- Consumes: the `hermes` ntfy token, which has read access only to `hermes-in` and write access only to `hermes-out`.
- Produces: Hermes `ntfy` platform configuration using `hermes-in` for inbound messages and `hermes-out` for published responses; Telegram remains unchanged.

- [ ] **Step 1: Establish the privilege regression check**

Confirm the current Telegram toolset contains privileged tools and no `platform_toolsets.ntfy` entry exists. This distinguishes the new restricted ntfy ingress from the existing Telegram control surface.

- [ ] **Step 2: Configure ntfy platform identity and constrained tools**

Add `platforms.ntfy` and a `platform_toolsets.ntfy` list containing only the global-constraint tools. Do not add a `known_plugin_toolsets.ntfy` entry, because no Ivan plugin tool is permitted through ntfy.

- [ ] **Step 3: Inject ntfy adapter settings**

Add `NTFY_SERVER_URL`, `NTFY_TOPIC=hermes-in`, `NTFY_PUBLISH_TOPIC=hermes-out`, `NTFY_ALLOWED_USERS=hermes-in`, `NTFY_HOME_CHANNEL=hermes-out`, `NTFY_HOME_CHANNEL_NAME=Hermes notifications`, and the secret `NTFY_TOKEN` to both the ExternalSecret target and its mounted `.env` content. Leave all Telegram keys intact.

- [ ] **Step 4: Correct MAC channel metadata**

Update MAC’s notification channel description to say it reaches Hermes, without claiming a Telegram-only transport.

- [ ] **Step 5: Validate privilege and manifest invariants**

Run:

```bash
bash ./scripts/kubeconform.sh
```

Expected: Hermes ConfigMap/ExternalSecret are valid; the `ntfy` toolset contains none of the prohibited capabilities; Telegram remains configured.

### Task 4: Complete the media migration boundary and retire Gotify

**Files:**
- Modify: `components/default/homepage/externalsecret.yaml`
- Delete: `components/default/gotify/kustomization.yaml`
- Delete: `components/default/gotify/values.yaml`
- Delete: `components/default/gotify/http-route.yaml`
- Modify: `clusters/talos/apps/20-applications.yaml`
- Create: `docs/operations/ntfy.md`

**Interfaces:**
- Consumes: the `media` ntfy token, ACL-limited to `media-events` write access.
- Produces: no Gotify workload, registration, route, or Homepage secret remains. The operations runbook supplies exact direct notification bindings for each application whose destination configuration is PVC-backed runtime state.

- [ ] **Step 1: Establish the removal check**

Confirm Gotify has no in-repository publisher and Homepage is the only tracked Gotify token consumer. This prevents deleting runtime dependencies without evidence.

- [ ] **Step 2: Remove the superseded component and homepage token**

Delete the Gotify component and replace its Argo CD application entry with the ntfy registration from Task 1. Remove the Homepage Gotify ExternalSecret mapping; do not add an ntfy Homepage token because Homepage is not a publisher.

- [ ] **Step 3: Document media runtime bindings**

Write `docs/operations/ntfy.md` with the non-secret 1Password item contract, ordered bootstrap verification, direct native configuration for Radarr/Sonarr, Jellyseerr, Bazarr, and SABnzbd, and explicit exclusions for Jellyfin and qBittorrent until their runtime plugin/external-program setups are separately requested. Each configured producer uses the `media-events` topic and its distinct token. State that settings persist on PVCs and are not safely or declaratively managed by this repository.

- [ ] **Step 4: Validate deletion and full repository schemas**

Run:

```bash
bash ./scripts/kubeconform.sh
```

Expected: no Git-tracked Gotify reference remains; ntfy and the complete manifest corpus validate.

### Task 5: Perform end-to-end static validation and update the graph

**Files:**
- Modify: `graphify-out/` generated graph artifacts only through `graphify update .`.

- [ ] **Step 1: Render affected Kustomizations**

Run:

```bash
kustomize build --enable-helm components/default/ntfy
kustomize build --enable-helm components/observability/kube-prometheus-stack
kustomize build --enable-helm components/argo-system/argo-cd
kustomize build --enable-helm components/ai/hermes-agent
```

Expected: each command exits successfully and produces manifests.

- [ ] **Step 2: Run repository validation**

Run:

```bash
bash ./scripts/kubeconform.sh
```

Expected: `All Kubernetes manifest validation completed successfully!`.

- [ ] **Step 3: Update architecture graph**

Run:

```bash
graphify update .
```

Expected: graph artifacts reflect the ntfy component and removed Gotify component.

- [ ] **Step 4: Review the final diff**

Verify every changed file serves the migration, no plaintext secret was introduced, no privileged Hermes tool is available to ntfy, no Gotify reference remains, and the runbook lists the external 1Password/runtime prerequisites required before enabling producers.
