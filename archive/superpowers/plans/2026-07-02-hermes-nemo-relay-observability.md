# Hermes NeMo Relay Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `subagent-driven-development` (recommended) or `executing-plans`. Execute task-by-task, retaining the verification evidence listed in each task.

**Goal:** Export Hermes Agent OpenInference traces through Alloy to Tempo and Grafana using the published NeMo Relay-enabled image.

**Architecture:** Hermes enables its bundled `observability/nemo_relay` plugin from the existing persistent-home configuration. A ConfigMap-mounted NeMo Relay `plugins.toml` enables only the OpenInference exporter and sends OTLP HTTP to Alloy's in-cluster receiver. Alloy keeps ownership of trace forwarding to Tempo; no Relay gateway or new network resource is created.

**Tech Stack:** Kubernetes, Kustomize, bjw-s app-template 5.0.1, Hermes Agent, NeMo Relay 0.3.0, OpenInference OTLP HTTP, Grafana Alloy, Tempo, Bash, yq.

## Global Constraints

- Use image tag `20260702184336-85d48a6-oci` from verified `agent-platform-custom` commit `85d48a6` for every Hermes container.
- Enable only `observability/nemo_relay`; do not change Hermes model provider URLs or add a NeMo Relay proxy.
- Export only OpenInference OTLP HTTP to `http://alloy.observability.svc.cluster.local:4318/v1/traces`.
- Do not enable ATOF/ATIF local disk exporters, create network objects, or add secrets.
- Preserve the existing Hermes PVC, resource settings, security contexts, and ingress.

---

### Task 1: Add a failing rendered-manifest contract

**Files:**
- Create: `scripts/test-hermes-nemo-relay-rendered-manifest.sh`

**Interfaces:**
- Consumes: `components/ai/hermes-agent` Kustomization rendered with `kustomize build --enable-helm`.
- Produces: an executable zero-exit contract test that asserts the Hermes Deployment and `hermes-agent-config` ConfigMap integration contract.

- [ ] **Step 1: Write the failing test**

Create an executable Bash test matching `scripts/test-ntfy-rendered-manifest.sh` conventions. Render `components/ai/hermes-agent` into a `mktemp` manifest and use `yq ea` assertions to require:

```bash
[[ "$(yq ea -r '
  select(.kind == "ConfigMap" and .metadata.name == "hermes-agent-config")
  | .data["nemo-relay-plugins.toml"]
  | contains("kind = \"observability\"")
    and contains("[components.config.openinference]")
    and contains("endpoint = \"http://alloy.observability.svc.cluster.local:4318/v1/traces\"")
' "${manifest}")" == "true" ]] || fail "NeMo Relay OpenInference ConfigMap entry is missing or invalid"
```

Also assert exactly one rendered Hermes application container uses `gitea.a113.casa/vpogu/agent-platform-hermes-agent:20260702184336-85d48a6-oci`, has `HERMES_NEMO_RELAY_PLUGINS_TOML=/opt/data/nemo-relay-plugins.toml`, and mounts ConfigMap key `nemo-relay-plugins.toml` read-only at that same path.

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
bash scripts/test-hermes-nemo-relay-rendered-manifest.sh
```

Expected: failure because the current ConfigMap lacks `nemo-relay-plugins.toml` and the Deployment has no environment variable or mount.

- [ ] **Step 3: Commit test-only red state only if collaboration requires it**

Do not commit an intentionally failing test to the integration branch. Continue directly to Task 2 in the same working tree.

### Task 2: Enable NeMo Relay OpenInference export

**Files:**
- Modify: `components/ai/hermes-agent/configmap.yaml`
- Modify: `components/ai/hermes-agent/values.yaml`

**Interfaces:**
- Consumes: the `nemo-relay==0.3.0` runtime and `observability/nemo_relay` plugin verified in image commit `85d48a6`.
- Produces: an enabled Hermes plugin, a mounted NeMo Relay plugin document, and a Deployment that exports OpenInference OTLP directly to Alloy.

- [ ] **Step 1: Enable the Hermes plugin**

Add the plugin to the existing configuration list:

```yaml
plugins:
  enabled:
    - ivan-personal
    - disk-cleanup
    - rtk-rewrite
    - forge
    - web/ddgs
    - security-guidance
    - observability/nemo_relay
```

- [ ] **Step 2: Add the NeMo Relay plugin document**

Add `nemo-relay-plugins.toml` as a second key in `hermes-agent-config`:

```toml
version = 1

[[components]]
kind = "observability"
enabled = true

[components.config]
version = 1

[components.config.openinference]
enabled = true
transport = "http_binary"
endpoint = "http://alloy.observability.svc.cluster.local:4318/v1/traces"
service_name = "hermes-agent"
service_namespace = "ai"
instrumentation_scope = "hermes-nemo-relay"
timeout_millis = 3000

[components.config.openinference.resource_attributes]
"deployment.environment" = "talos"
```

- [ ] **Step 3: Wire the Deployment to the document and published image**

Replace all three Hermes image tags with `20260702184336-85d48a6-oci`. Under the app container environment, add:

```yaml
HERMES_NEMO_RELAY_PLUGINS_TOML: /opt/data/nemo-relay-plugins.toml
```

Under the existing `config.advancedMounts.app.app` list, add:

```yaml
- path: /opt/data/nemo-relay-plugins.toml
  subPath: nemo-relay-plugins.toml
  readOnly: true
```

This uses the existing ConfigMap reloader and its `config` volume; no new workload object is needed.

### Task 3: Verify rendered integration

**Files:**
- Test: `scripts/test-hermes-nemo-relay-rendered-manifest.sh`

**Interfaces:**
- Consumes: Task 2 manifest configuration.
- Produces: verified rendered ConfigMap and Deployment contract.

- [ ] **Step 1: Run the rendered-manifest contract**

Run:

```bash
bash scripts/test-hermes-nemo-relay-rendered-manifest.sh
```

Expected: `PASS` message naming the published image tag, enabled plugin, OTLP endpoint, environment variable, and ConfigMap mount.

- [ ] **Step 2: Validate script syntax and Kustomize/Helm rendering**

Run:

```bash
bash -n scripts/test-hermes-nemo-relay-rendered-manifest.sh
kustomize build --enable-helm components/ai/hermes-agent >/dev/null
```

Expected: both commands exit zero.

- [ ] **Step 3: Review the final diff**

Confirm only the Hermes ConfigMap, Helm values, rendered-manifest test, and this design/plan documentation changed. Confirm no secret values, new Gateway API resources, or changes to Alloy, Tempo, Grafana, VolSync, or model provider configuration.

- [ ] **Step 4: Commit**

```bash
git add \
  components/ai/hermes-agent/configmap.yaml \
  components/ai/hermes-agent/values.yaml \
  scripts/test-hermes-nemo-relay-rendered-manifest.sh \
  docs/superpowers/specs/2026-07-02-hermes-nemo-relay-observability-design.md \
  docs/superpowers/plans/2026-07-02-hermes-nemo-relay-observability.md
git commit -m "feat: export Hermes traces through NeMo Relay"
```
