# ntfy operations cutover

This runbook is the operational boundary for the repository-controlled ntfy transport. It covers the out-of-repository secret and application-runtime work required to make the configured transport useful. It does **not** place credentials, token-bearing URLs, media application settings, a relay, a Kubernetes Job, or other automation in Git.

## Current transport contract

The ntfy service is deployed in the `default` namespace at `https://ntfy.${CLUSTER_DOMAIN}`. Its service maps port 80 to ntfy port 8080; its cache and authorization database persist under `/var/lib/ntfy`; and `NTFY_AUTH_DEFAULT_ACCESS=deny-all` makes every usable topic dependent on the explicit authorization data below.

Repository-managed publishers are intentionally narrow:

| Source | Topic | Transport behavior |
| --- | --- | --- |
| Alertmanager | `infra-alerts` | Webhook receiver, `sendResolved: true`, Alertmanager template |
| Argo CD notifications | `argocd-events` | Native generic webhook with Bearer authorization and `Content-Type: text/plain` |
| Media applications | `media-events` | Native application configuration performed after transport readiness |
| Hermes inbound | `hermes-in` | Restricted ntfy control/messages input |
| Hermes outbound/home notifications | `hermes-out` | Hermes notification output |

Do not deploy a generic relay. Alertmanager, Argo CD, Hermes, and the listed media applications can publish to ntfy using their native mechanisms. A relay would add an unnecessary credential-translation attack surface and another service to operate.

## Pre-sync: prepare 1Password and authorization

Before syncing the Argo applications, create or review the `ntfy` item in the 1Password vault used by the `onepassword-connect` ClusterSecretStore. The following fields are required; preserve their values as secrets and do not paste, decode, log, or commit them:

| Required `ntfy` item field | Consumer | Purpose |
| --- | --- | --- |
| `NTFY_AUTH_USERS` | ntfy server | Server-side user definitions |
| `NTFY_AUTH_ACCESS` | ntfy server | Topic access-control rules |
| `NTFY_AUTH_TOKENS` | ntfy server | Server-side token definitions |
| `ALERTMANAGER_PUBLISH_TOKEN` | Alertmanager ExternalSecret | Publish only to `infra-alerts` |
| `ARGOCD_PUBLISH_TOKEN` | Argo CD ExternalSecret | Publish only to `argocd-events` |
| `HERMES_PUBLISH_TOKEN` | Hermes ExternalSecret | Publish only to `hermes-out` |
| `MEDIA_PUBLISH_TOKEN` | Protected media application settings | Publish only to `media-events` |

Use ntfy's documented access-control syntax when composing the three server-side fields. The repository intentionally supplies only the field names; credentials and ACL values remain in 1Password. Validate the item has every listed field before the first sync, because a missing field prevents External Secrets from rendering its target Secret.

### Topic ACL model

Start from deny-by-default. Grant only the following capabilities, using distinct identities or tokens rather than sharing a broad operator credential:

| Topic | Read access | Write access | Required restriction |
| --- | --- | --- | --- |
| `infra-alerts` | Operators and alert subscribers | Alertmanager publisher only | The publisher is write-only and cannot read alerts or publish to another topic. |
| `argocd-events` | Operators and Argo CD event subscribers | Argo CD publisher only | The publisher is write-only and cannot read events or publish to another topic. |
| `media-events` | Operators and media-event subscribers | Media publisher only | The publisher is write-only and cannot read event history or publish elsewhere. |
| `hermes-in` | Hermes inbound-message subscriber and designated operators, only when required | Hermes input publisher only | Do not give a general subscriber or output publisher write access to this control boundary. |
| `hermes-out` | Operators and Hermes notification subscribers | Hermes publisher only | The Hermes publisher is write-only and cannot publish to `hermes-in` or other topics. |

An operator/subscriber identity should have read access only to the topics it needs. Each publishing identity must be least-privilege, write-only, and limited to its single topic. Do not give a publisher wildcard topic permissions, read permission, or administrative authority. Keep the credential material only in the 1Password item and protected application settings.

## Sync and transport verification

After the 1Password item is complete, sync the ntfy, Alertmanager, Argo CD, and Hermes applications through the normal Argo CD workflow. Do not proceed to media configuration until the following checks all pass.

1. Confirm the ntfy workload and its ExternalSecret have reconciled, without retrieving Secret data. Confirm the public HTTPS route answers the health endpoint:

   ```bash
   curl --fail --silent --show-error https://ntfy.${CLUSTER_DOMAIN}/v1/health
   ```

2. Confirm the authorization default is effective. From an unauthenticated client, attempt an intentionally unauthorized publish and record that the request is denied (HTTP 401 or 403 is acceptable). Do not turn off authentication, weaken the default ACL, or use a production publishing token in logs to make this pass.

3. Confirm authorized publishing for each configured publisher with a benign, uniquely identifiable test message. Supply the corresponding write-only credential from protected runtime state, use an `Authorization: Bearer` header, and set `Content-Type: text/plain`. Do not use a token in a URL, command history, ticket, or captured output.

4. While authenticated as the appropriate read-only subscriber, subscribe to each tested topic and confirm delivery of its matching message. Verify that a subscriber cannot publish and that each publisher cannot read. Treat the message body as operational data and remove test messages or use a dedicated non-production window according to local retention practice.

5. Verify the configured integrations individually:
   - Alertmanager: trigger or observe a safe test alert and its resolved transition on `infra-alerts`; the configured receiver uses the Alertmanager webhook template and sends resolved notifications.
   - Argo CD: cause or observe a non-disruptive notification condition and confirm its event reaches `argocd-events` through the native webhook notifier.
   - Hermes: send a benign, non-action message to `hermes-in` only through its designated inbound publisher, and verify the expected message-handling path. Confirm that Hermes continues to use Telegram as its privileged control surface. Its ntfy tool allowlist is limited to `clarify`, `cronjob`, `delegation`, `memory`, `messaging`, `session_search`, `skills`, `todo`, `tts`, `vision`, and `web`; it has no ntfy known-plugin toolset and no browser, code execution, computer-use, terminal, file, or Ivan tools on the ntfy surface. A successful ntfy test must never be interpreted as permission to perform privileged Hermes actions.

If a check fails, inspect Argo application health, ExternalSecret reconciliation status, route/TLS health, and the relevant ACL **without printing Secret values**. Correct the missing field or over-broad/insufficient permission in 1Password, then resync and repeat the complete authorization and delivery checks.

## Configure media publishers after transport readiness

Media notification configuration is PVC-backed application/runtime state, not a repository-managed Helm value. Configure it only after the transport verification above succeeds. Keep tokens in each application's protected runtime settings; never put them in this repository.

For direct webhook publishers, configure the endpoint exactly as `https://ntfy.${CLUSTER_DOMAIN}/media-events`, store the media publishing token in the application's protected authorization setting as a Bearer token, and set `Content-Type: text/plain`. Do not use or construct a token-bearing URL.

| Application | Native mechanism | Runtime action |
| --- | --- | --- |
| Radarr | Connect Webhook | Add an ntfy webhook notification using the direct endpoint, protected Bearer token, and `Content-Type: text/plain`; enable only the events that are operationally useful. |
| Sonarr | Connect Webhook | Add an ntfy webhook notification using the direct endpoint, protected Bearer token, and `Content-Type: text/plain`; enable only the events that are operationally useful. |
| Jellyseerr | Webhook | Add an ntfy webhook using the direct endpoint, protected Bearer token, and `Content-Type: text/plain`; send a benign application test event and confirm `media-events` delivery. |
| Bazarr | Apprise | Configure the runtime notification target with `ntfys://<MEDIA_PUBLISH_TOKEN>@ntfy.${CLUSTER_DOMAIN}/media-events`. This literal placeholder shows Apprise syntax only; the actual value remains in protected runtime state, never Git. |
| SABnzbd | Apprise | Configure the runtime notification target with `ntfys://<MEDIA_PUBLISH_TOKEN>@ntfy.${CLUSTER_DOMAIN}/media-events`. This literal placeholder shows Apprise syntax only; the actual value remains in protected runtime state, never Git. |

For every media application, publish a benign test notification and verify it arrives to a read-only `media-events` subscriber. Reconfirm that the media credential cannot read the topic or publish to any other topic.

### Explicit media exclusions

Do not configure Jellyfin or qBittorrent as part of this cutover. Their plugin/external-program notification configuration is absent from Git and has not been requested. Their documentation is included below for a separately requested, application-specific change; it is not approval to add runtime configuration now.

## HolmesGPT, Gotify, and retirement boundaries

HolmesGPT remains Slack-only. The deployed/current upstream destinations support Slack and PagerDuty, not ntfy; do not claim a HolmesGPT-to-ntfy integration or introduce an adapter to work around that limitation.

Gotify is not automatically removed by this cutover. Before any decommissioning, audit all publishers, user clients, and operational dependencies for Gotify, and preserve a rollback decision until ntfy delivery has been proven for every migrated use case. Homepage currently consumes a Gotify token through `HOMEPAGE_VAR_GOTIFY_API_TOKEN`; after the audit confirms that token is unused, remove that Homepage ExternalSecret mapping in a dedicated Git-reviewed change and rotate or retire the corresponding Gotify credential. Only then plan the separate Gotify service retirement. Do not remove the Homepage token mapping merely because ntfy is healthy.

## Primary documentation

- [ntfy configuration and access control](https://docs.ntfy.sh/config/)
- [ntfy publishing](https://docs.ntfy.sh/publish/)
- [External Secrets 1Password Connect provider](https://external-secrets.io/latest/provider/1password-automation/)
- [1Password Connect](https://www.1password.dev/connect)
- [Alertmanager webhook configuration](https://prometheus.io/docs/alerting/latest/configuration/#webhook_config)
- [Argo CD notification webhook service](https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/services/webhook/)
- [Hermes ntfy messaging](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/ntfy/)
- [Radarr Connect settings](https://wiki.servarr.com/radarr/settings#connect)
- [Sonarr Connect settings](https://wiki.servarr.com/sonarr/settings#connect)
- [Seerr webhook notifications](https://docs.seerr.dev/using-seerr/notifications/webhook/)
- [Bazarr notifications](https://wiki.bazarr.media/Additional-Configuration/Settings/#notifications)
- [Apprise ntfy service](https://appriseit.com/services/ntfy/)
- [SABnzbd notifications](https://sabnzbd.org/wiki/configuration/5.0/notifications)
- [HolmesGPT destinations](https://holmesgpt.dev/latest/operator/destinations/)
- [Gotify documentation](https://gotify.net/docs/)
- [Homepage Gotify widget](https://gethomepage.dev/widgets/services/gotify/)
- [Jellyfin notifications](https://jellyfin.org/docs/general/server/notifications/)
- [qBittorrent external programs](https://github.com/qbittorrent/qBittorrent/wiki/External-programs-How-to)
