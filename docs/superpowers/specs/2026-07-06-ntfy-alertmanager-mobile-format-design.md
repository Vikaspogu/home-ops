# ntfy Alertmanager Mobile Format Design

## Goal

Make Alertmanager notifications concise and actionable on the ntfy mobile client without relying on Markdown, while assigning ntfy notification priority from alert severity.

## Context

Alertmanager currently sends webhook JSON to `https://ntfy.${CLUSTER_DOMAIN}/infra-alerts?template=alertmanager`. The server-shipped `alertmanager` template renders a long fixed message and cannot be changed in Git.

ntfy runs as non-root with `readOnlyRootFilesystem: true`. Only `/var/lib/ntfy` is writable, so the template must be projected by Kubernetes rather than written at container startup.

## Chosen approach

Create a Kubernetes ConfigMap in `components/default/ntfy/` with one key, `infra-alerts.yml`. Mount it read-only at `/etc/ntfy/templates` through the bjw-s app-template persistence configuration. Set `NTFY_TEMPLATE_DIR=/etc/ntfy/templates` so ntfy loads the mounted directory.

Change the Alertmanager webhook URL to request `template=infra-alerts`.

The custom template uses only the ntfy-supported custom-template keys:

- `title`
- `message`
- `priority`

## Mobile notification contract

### Title

- Firing: `🚨 <alertname>`
- Resolved: `✅ <alertname>`

The first alert in the Alertmanager group supplies `<alertname>`.

### Message

Plain text only. It includes, when available:

1. Severity
2. Namespace
3. Pod
4. Container
5. Instance
6. Summary
7. Description
8. Source URL

The template must not use Markdown because the primary reading client is ntfy mobile and ntfy documents Markdown as web-app-only.

### Priority

- `critical`: `5` (urgent)
- `warning`: `4` (high)
- all other severities, including missing severity: `3` (default)

## Non-goals

- No `markdown=yes` webhook parameter.
- No template `tags`, `click`, or `actions` keys. ntfy custom template files do not support those keys; Alertmanager’s webhook configuration cannot produce dynamic ntfy headers for them.
- No changes to ntfy authorization, persistence, routes, alert grouping, or Alertmanager routing.

## Validation

Render both affected Kustomize trees with Helm enabled. Inspect the ntfy output for the ConfigMap mount and `NTFY_TEMPLATE_DIR`, and the observability output for the `template=infra-alerts` webhook URL. Confirm the ConfigMap template parses as YAML and has only `title`, `message`, and `priority` keys.
