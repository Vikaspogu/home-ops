# Hermes SearXNG Search Design

## Goal

Configure Hermes web search to use the existing in-cluster SearXNG service without changing secret management or web extraction behavior.

## Scope

- Configure the Hermes search backend explicitly as SearXNG.
- Supply the in-cluster SearXNG base URL as a non-secret environment variable.
- Preserve the existing `web/ddgs` plugin entry and all web extraction behavior.

## Configuration

Hermes receives the non-secret endpoint through `components/ai/hermes-agent/values.yaml`:

```yaml
SEARXNG_URL: http://searxng.ai.svc.cluster.local:8080
```

Hermes receives the explicit per-capability backend selection through the `config.yaml` data in `components/ai/hermes-agent/configmap.yaml`:

```yaml
web:
  search_backend: searxng
```

The endpoint resolves to the `searxng` ClusterIP Service in namespace `ai`, which exposes port `8080`. SearXNG has JSON output enabled and requires no API key for this internal request path.

## Constraints

- `SEARXNG_URL` is an internal URL, not a credential. It belongs in Helm `env:`, not the Hermes ExternalSecret.
- Do not set `web.backend: searxng`. SearXNG provides search only; a shared backend would also route `web_extract` to SearXNG and fail.
- Do not set `web.extract_backend`. Existing extract provider selection remains unchanged.
- Do not remove `web/ddgs` from `plugins.enabled`; it is separate from Hermes's web-tool backend selection.

## Data Flow

`web_search` in Hermes reads `SEARXNG_URL`, sends the search request to `http://searxng.ai.svc.cluster.local:8080`, and consumes the SearXNG JSON response. `web_extract` remains on its existing provider-selection path.

## Verification

Render the Hermes Kustomization and verify the output includes both `SEARXNG_URL` with the ClusterIP URL and `web.search_backend: searxng`. Confirm the rendered manifests remain valid Kubernetes YAML.

## Sources

- https://hermes-agent.nousresearch.com/docs/user-guide/features/web-search
- https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/environment-variables.md
- `components/ai/searxng/settings.yml`
- `components/ai/searxng/values.yaml`
