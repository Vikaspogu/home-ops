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

### 1. `agent-platform-custom` — New plugin files

**`images/hermes-agent/plugins/headroom/headroom_retrieve/__init__.py`**

Copy verbatim from upstream (`chopratejas/headroom` `plugins/hermes/headroom_retrieve/__init__.py`) with one patch:

```python
# Before (upstream)
_PROXY_URL = "http://127.0.0.1:8787"

# After (patched)
_PROXY_URL = os.environ.get("HEADROOM_PROXY_URL", "http://127.0.0.1:8787")
```

This is the only divergence from upstream. The env var falls back to localhost so the plugin still works in local/dev contexts.

**`images/hermes-agent/plugins/headroom/headroom_retrieve/plugin.yaml`**

New plugin manifest (copy from upstream `plugins/hermes/headroom_retrieve/plugin.yaml`).

### 2. `agent-platform-custom` — Containerfile

Add one `COPY` line after the existing agentmemory plugin copy:

```dockerfile
COPY plugins/headroom/headroom_retrieve /opt/hermes/plugins/headroom/headroom_retrieve
```

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

## Upgrade Path

To update the plugin to a newer upstream version:
1. Copy the new `__init__.py` from upstream into `plugins/headroom/headroom_retrieve/`
2. Re-apply the one-line `os.environ.get("HEADROOM_PROXY_URL", ...)` patch
3. Rebuild and push the image; Renovate handles the tag bump in home-ops

## Alternatives Rejected

- **Runtime bootstrap clone** — adds git clone latency at pod startup; build-time is simpler and matches existing agentmemory pattern
- **PyPI package import** — couples image build to PyPI; inconsistent with existing plugin pattern; harder to audit
- **Hardcode cluster URL in plugin source** — works but loses portability and makes upgrading slightly more error-prone than an env var
