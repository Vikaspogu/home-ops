# Design: Headroom `headroom_retrieve` Plugin Integration into Hermes

**Date:** 2026-06-18  
**Status:** Approved

## Problem

Hermes routes LLM traffic through the headroom compression proxy. When headroom compresses large tool outputs it replaces them with opaque CCR markers like `<<ccr:abc123>>` or `[1500 items compressed ... hash=abc123]`. Without the `headroom_retrieve` plugin, Hermes has no way to recover the original content — the model either re-runs the original command (wasting tokens/time) or treats the marker as a file path and errors.

The upstream headroom repo ships a `headroom_retrieve` Hermes plugin that closes this loop by calling the proxy's `POST /v1/retrieve` endpoint. This design describes how to integrate it into the custom Hermes image and cluster deployment.

## Architecture

```
[Hermes pod - ai namespace]              [Headroom pod - ai namespace]
  hermes-agent container                   headroom container
  - headroom_retrieve plugin  ---------->  POST /v1/retrieve
    reads HEADROOM_PROXY_URL               headroom.ai.svc.cluster.local:8787
```

Hermes calls `headroom_retrieve(hash="abc123")` whenever it encounters a CCR marker. The plugin POSTs to the headroom proxy via cluster-internal DNS and returns the original uncompressed content to the model.

## Repositories Affected

| Repo | Purpose |
|------|---------|
| `agent-platform-custom` | Custom Hermes image — plugin source + Containerfile |
| `home-ops` | GitOps manifests — env vars for hermes and headroom |

## Changes

### 1. `agent-platform-custom` — Containerfile

Add a build ARG pinning the headroom commit SHA, clone the repo in a dedicated `RUN` stage, apply the one-line `_PROXY_URL` patch via `sed`, then copy the plugin into place. A `# renovate:` comment enables automatic SHA bump PRs.

```dockerfile
# renovate: datasource=github-commits depName=chopratejas/headroom
ARG HEADROOM_PLUGIN_SHA=<current-main-sha>

RUN git clone --no-checkout https://github.com/chopratejas/headroom.git /tmp/headroom \
    && git -C /tmp/headroom checkout "${HEADROOM_PLUGIN_SHA}" -- plugins/hermes/headroom_retrieve \
    && sed -i 's|_PROXY_URL = "http://127.0.0.1:8787"|_PROXY_URL = os.environ.get("HEADROOM_PROXY_URL", "http://127.0.0.1:8787")|' \
         /tmp/headroom/plugins/hermes/headroom_retrieve/__init__.py \
    && cp -r /tmp/headroom/plugins/hermes/headroom_retrieve \
         /opt/hermes/plugins/headroom/headroom_retrieve \
    && rm -rf /tmp/headroom
```

- No plugin files live in the `agent-platform-custom` repo — they come entirely from upstream at build time.
- The pinned SHA makes builds fully reproducible. Renovate opens a PR to bump the SHA when a new commit lands on `main`.
- The `sed` patch is the only divergence from upstream: it makes `_PROXY_URL` read from the `HEADROOM_PROXY_URL` env var (falling back to localhost for dev contexts).

### 2. `agent-platform-custom` — `defaults/config.yaml`

### 3. `agent-platform-custom` — `defaults/config.yaml`

Add `headroom_retrieve` to the `plugins.enabled` list:

```yaml
plugins:
  enabled:
    - rtk-rewrite
    - headroom_retrieve   # add this
```

### 4. `home-ops` — `components/ai/hermes-agent/values.yaml`

Add to the `app` container's `env` block:

```yaml
HEADROOM_PROXY_URL: http://headroom.ai.svc.cluster.local:8787
```

### 5. `home-ops` — `components/ai/headroom/values.yaml`

Add to the headroom container's `env` block to prevent re-compression loops:

```yaml
HEADROOM_EXCLUDE_TOOLS: "read_file,headroom_retrieve"
```

- `read_file` — Hermes file reads are reference data the agent needs verbatim
- `headroom_retrieve` — prevents retrieved originals being re-compressed, which would create an endless marker→retrieve→marker loop

## Data Flow

1. Hermes sends LLM request through headroom proxy (`OPENAI_BASE_URL` → headroom)
2. Headroom compresses large tool outputs → injects CCR markers
3. LLM sees `<<ccr:abc123>>` in response
4. Hermes calls `headroom_retrieve(hash="abc123")`
5. Plugin normalizes the marker to bare hash `abc123` (handles all marker formats)
6. Plugin POSTs `{"hash": "abc123"}` to `http://headroom.ai.svc.cluster.local:8787/v1/retrieve`
7. Headroom returns `{"original_content": "...", "original_tokens": N, "tool_name": "..."}`
8. Plugin returns content to Hermes — this call itself is excluded from re-compression

## Error Handling

| Condition | Plugin behavior |
|-----------|----------------|
| Proxy unreachable | Returns actionable error: "re-run the original command" |
| Hash expired (TTL) | Returns actionable error: "re-run the original command" |
| HTTP error from proxy | Returns error with status code and truncated body |
| Malformed marker passed | Normalizes best-effort; empty hash returns validation error |

## What Is Not Changed

- Headroom ExternalSecret and HTTPRoute — no changes
- Hermes bootstrap process (`bootstrap.py`, `bootstrap-config.yaml`) — plugin is image-baked, not git-cloned at runtime
- No new Kubernetes resources (Services, ConfigMaps, Secrets, RBAC)
- Headroom's existing proxy behavior for all other tools is unaffected
- `rtk-rewrite` plugin remains enabled — it rewrites outgoing tool call arguments (correctness), which is independent of headroom's tool output compression (token reduction). The two do not conflict.

## Upgrade Path

Renovate monitors `chopratejas/headroom` commits and opens a PR bumping `HEADROOM_PLUGIN_SHA` in the Containerfile. The `sed` patch is re-applied automatically on each build — no manual intervention needed. Review the Renovate PR diff to check for upstream changes to `__init__.py` that might affect the patch line.

## Alternatives Rejected

- **Plugin files in repo (original approach)** — requires manual copy + re-apply of patch on each upstream update; replaced by Dockerfile clone with pinned SHA
- **Clone `main` HEAD in Dockerfile** — non-deterministic; two builds a week apart could produce different behavior with no repo change; rejected in favour of pinned SHA + Renovate
- **Runtime bootstrap clone** — adds git clone latency at pod startup; build-time is simpler and matches existing agentmemory pattern
- **PyPI package import** — couples image build to PyPI; inconsistent with existing plugin pattern; harder to audit
- **Hardcode cluster URL in plugin source** — works but loses portability; env var is cleaner
- **Disable `rtk-rewrite`** — not needed; RTK rewrites tool inputs, headroom compresses tool outputs; they operate at different points in the pipeline and do not conflict
