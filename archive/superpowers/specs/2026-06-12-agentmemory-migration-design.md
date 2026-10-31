# agentmemory Migration Design

**Date:** 2026-06-12  
**Status:** Approved  
**Repos affected:** `home-ops`, `agent-platform-custom`, `opencode-config`

---

## Goal

Replace the self-hosted mem0 memory backend with agentmemory across all agents. Both Hermes (in-cluster) and OpenCode (Mac) will share a single agentmemory server, giving cross-agent persistent memory with 95.2% retrieval accuracy (BM25 + vector + knowledge graph) versus mem0's manual `add()` model.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Talos cluster (ai namespace)                        │
│                                                      │
│  ┌──────────────┐      ┌────────────────────────┐   │
│  │ hermes-agent │─────▶│ agentmemory            │   │
│  │              │      │ :3111 (REST + MCP)     │   │
│  │  plugin:     │      │ :3113 (viewer UI)      │   │
│  │  agentmemory │      │                        │   │
│  │  (6 hooks)   │      │  SQLite state_store.db │   │
│  └──────────────┘      │  + vector index        │   │
│                        └────────────────────────┘   │
│                                 ▲                    │
│           HTTPRoutes:           │                    │
│   agentmemory.${CLUSTER_DOMAIN} → :3111 (API/MCP)  │
│   agentmemory-viewer.${CLUSTER_DOMAIN} → :3113 (UI) │
└─────────────────────────────────────────────────────┘
                          │ HTTPS (internal FQDN)
┌─────────────────────────▼───────────────────────────┐
│  Mac (OpenCode)                                      │
│                                                      │
│  ~/.config/opencode/opencode.json                    │
│    mcp: agentmemory (npx @agentmemory/mcp)           │
│    plugin: agentmemory-capture.ts                    │
│                                                      │
│  AGENTMEMORY_URL=https://agentmemory.${CLUSTER_DOMAIN}
└──────────────────────────────────────────────────────┘
```

**Removed:** mem0-api-server deployment, mem0-dashboard deployment, mem0_selfhosted Hermes plugin, all MEM0_* env vars.  
**Added:** agentmemory k8s component, agentmemory Hermes plugin, agentmemory-capture.ts OpenCode plugin.

---

## Deployment Phases

### Phase 1 — Deploy agentmemory alongside mem0 (both running)

- Create `components/ai/agentmemory/` in home-ops
- Wire OpenCode to agentmemory (`agentmemory-capture.ts` plugin + MCP)
- mem0 still running; Hermes still pointing at mem0
- Verify: `curl https://agentmemory.${CLUSTER_DOMAIN}/agentmemory/health`

### Phase 2 — Migrate mem0 data

- Run `scripts/migrate-mem0-to-agentmemory.sh` in agent-platform-custom
- Script: GET all memories from mem0 → POST each to agentmemory `/remember`
- Verify migrated memories searchable in viewer at `https://agentmemory-viewer.${CLUSTER_DOMAIN}`

### Phase 3 — Cut Hermes over

- Switch hermes-agent values: `AGENTMEMORY_URL`, remove `MEM0_*` vars
- Switch `memory.provider: agentmemory` in bootstrap config
- Deploy new Hermes image: replace `mem0_selfhosted` plugin with `agentmemory` plugin
- Verify Hermes using agentmemory via the viewer

### Phase 4 — Cleanup (after Hermes stable for a few days)

- Remove `components/ai/mem0/` from home-ops
- Remove mem0 from `clusters/talos/apps/20-applications.yaml`
- Remove `images/mem0-api-server/` and `images/mem0-dashboard/` from agent-platform-custom
- Delete mem0 VolSync PVC
- Remove mem0 1Password items and secrets

---

## Changes by Repository

### 1. home-ops — new `components/ai/agentmemory/`

**`kustomization.yaml`**
- bjw-s app-template v5.0.1
- namespace: ai
- resources: externalsecret.yaml, http-route.yaml
- components: volsync-replication (for SQLite persistence)
- plugin env vars: `STORAGE_CLASS=ceph-block`, `VOLUME_SNAPSHOT_CLASS=csi-ceph-blockpool`, `VOLSYNC_CAPACITY=5Gi`, `VOLSYNC_CACHE_CAPACITY=5Gi`
  - mem0's data volume was 2Gi (history SQLite only; memories lived in PostgreSQL). agentmemory stores everything in SQLite + vector index on disk, so 5Gi gives adequate headroom with room to grow.

**`values.yaml`**
- Single controller `app`, single container `app`
- Image: `node:22-slim` running `npx @agentmemory/agentmemory`
  - Uses latest npm release on first deploy; pin a specific version once confirmed stable (Renovate will track `@agentmemory/agentmemory` npm releases)
- Ports: `3111` (API/MCP), `3113` (viewer — ClusterIP only, not in Service for external)
- Persistence: `/data` mounted from VolSync claim (SQLite + vector index)
- Env: `PORT=3111`, `DATA_DIR=/data`, `AGENTMEMORY_SECRET` from ExternalSecret
- Resources: `requests: cpu 100m, memory 512Mi`, `limits: memory 1Gi`
- Probes: liveness/readiness on `GET /agentmemory/health` port 3111
- Security: `allowPrivilegeEscalation: false`, drop ALL capabilities
- `strategy: Recreate` (SQLite is single-writer)

**`http-route.yaml`**
- Single HTTPRoute with two hostnames / two rule sets:
  - `agentmemory.${CLUSTER_DOMAIN}` → service port 3111 (API + MCP — used by Hermes, OpenCode, migration script)
  - `agentmemory-viewer.${CLUSTER_DOMAIN}` → service port 3113 (browser viewer UI)
- Both use `${GATEWAY_NAME}` / `${GATEWAY_NAMESPACE}` / sectionName: https
- Homepage annotations on the viewer hostname rule

**`externalsecret.yaml`**
- Name: `agentmemory`
- Target secret: `agentmemory-secret`
- Key: `AGENTMEMORY_SECRET` pulled from 1Password item `agentmemory`
- ClusterSecretStore: `onepassword-connect`

**`clusters/talos/apps/20-applications.yaml`**
- Add agentmemory entry at sync-wave **"23"** (same as mem0 — must be running before hermes-agent at wave 24)
  - `VOLSYNC_CAPACITY=5Gi`, `VOLSYNC_CACHE_CAPACITY=5Gi`
- Remove mem0 entry (Phase 4)

### 2. home-ops — hermes-agent changes (Phase 3)

**`components/ai/hermes-agent/values.yaml`**
- Remove env vars: `MEM0_API_URL`, `MEM0_USER_ID`, `MEM0_AGENT_ID`, `MEM0_PIN_USER_ID`, `MEM0_TOP_K`
- Add env var: `AGENTMEMORY_URL: http://agentmemory.ai.svc.cluster.local:3111`
  - Hermes reaches agentmemory via in-cluster ClusterIP directly, not the HTTPRoute, so no `AGENTMEMORY_SECRET` needed for Hermes itself (loopback exemption in the agentmemory plugin). `AGENTMEMORY_SECRET` is still added to the ExternalSecret so Hermes can pass it to any MCP tool calls it makes externally.

**`components/ai/hermes-agent/externalsecret.yaml`**
- Remove `MEM0_API_KEY` from target data and `.env` block
- Remove `- extract: key: mem0` from dataFrom
- Add `AGENTMEMORY_SECRET` to target data and `.env` block, extracted from `agentmemory` 1Password item

**`components/ai/hermes-agent/bootstrap-config.yaml`**
- Update `memory.provider` from `mem0_selfhosted` to `agentmemory`

### 3. agent-platform-custom — Hermes image (Phase 3)

**`images/hermes-agent/plugins/memory/`**
- Remove `mem0_selfhosted/` directory entirely
- Add `agentmemory/` directory containing:
  - `__init__.py` — verbatim from `integrations/hermes/__init__.py` in rohitg00/agentmemory
  - `plugin.yaml` — verbatim from `integrations/hermes/plugin.yaml` in rohitg00/agentmemory

**`images/hermes-agent/Containerfile`**
- Change line 175:
  - From: `COPY plugins/memory/mem0_selfhosted /opt/hermes/plugins/memory/mem0_selfhosted`
  - To: `COPY plugins/memory/agentmemory /opt/hermes/plugins/memory/agentmemory`

**`images/hermes-agent/defaults/config.yaml`**
- Check whether `memory.provider` is set here; if so update to `agentmemory`. The authoritative source is `bootstrap-config.yaml` (home-ops) which seeds the Hermes home dir on startup — that is the file that must be updated.

**New: `scripts/migrate-mem0-to-agentmemory.sh`**
- Reads `MEM0_API_URL`, `MEM0_ADMIN_API_KEY`, `AGENTMEMORY_URL`, `AGENTMEMORY_SECRET` from environment
- `GET ${MEM0_API_URL}/memories?user_id=vikas` with `X-API-Key` header
- For each `memory` string in response:
  - `POST ${AGENTMEMORY_URL}/agentmemory/remember` with body:
    ```json
    { "content": "<memory>", "type": "fact", "project": "hermes-migration" }
    ```
  - Auth: `Authorization: Bearer ${AGENTMEMORY_SECRET}`
- Prints count of migrated memories
- Non-zero exit on any HTTP error

**Phase 4 cleanup:**
- Remove `images/mem0-api-server/` directory
- Remove `images/mem0-dashboard/` directory
- Remove `images/hermes-agent/plugins/memory/` if empty after agentmemory plugin moves to image-native

### 4. opencode-config (Phase 1)

**`opencode.json`**
- Add `mcp` block:
  ```json
  "mcp": {
    "agentmemory": {
      "type": "local",
      "command": ["npx", "-y", "@agentmemory/mcp"],
      "enabled": true,
      "env": {
        "AGENTMEMORY_URL": "{env:AGENTMEMORY_URL}",
        "AGENTMEMORY_SECRET": "{env:AGENTMEMORY_SECRET}"
      }
    }
  }
  ```
- Add `agentmemory-capture.ts` to `plugin` array alongside superpowers

**`.opencode/plugins/agentmemory-capture.ts`**
- Verbatim copy of upstream `plugin/opencode/agentmemory-capture.ts` from rohitg00/agentmemory

**`.opencode/commands/recall.md`** and **`.opencode/commands/remember.md`**
- Verbatim copies of upstream `plugin/opencode/commands/` from rohitg00/agentmemory

**`install.sh`**
- Extend commands copy to include `.opencode/commands/*.md` → `~/.config/opencode/commands/`
- Add `AGENTMEMORY_URL` and `AGENTMEMORY_SECRET` reads from 1Password inside the `opencode()` shell function block
- Create `~/.config/opencode/commands/` if it doesn't exist

---

## Data Migration Script

**Location:** `agent-platform-custom/scripts/migrate-mem0-to-agentmemory.sh`

**Logic:**
```
source: GET https://mem0.${CLUSTER_DOMAIN}/memories?user_id=vikas
        Header: X-API-Key: $MEM0_ADMIN_API_KEY

for each memory in response[]:
  POST https://agentmemory.${CLUSTER_DOMAIN}/agentmemory/remember
  Header: Authorization: Bearer $AGENTMEMORY_SECRET
  Body: { "content": memory.memory, "type": "fact", "project": "hermes-migration" }
```

**Data fidelity:** mem0 plain-text memory strings are preserved verbatim as agentmemory `fact` entries. Session history, vector embeddings, and metadata are not migrated (not available via mem0 REST API; agentmemory rebuilds embeddings on first search).

**Verification:** after script completes, `POST /agentmemory/smart-search` with `{"query": "vikas"}` should return migrated memories.

---

## 1Password Items Required

| Item | Field | Used by |
|------|-------|---------|
| `agentmemory` | `AGENTMEMORY_SECRET` | agentmemory ExternalSecret, hermes-agent ExternalSecret, opencode shell function |

The existing `mem0` item stays until Phase 4 cleanup.

---

## What mem0 vs agentmemory provides to Hermes

| Capability | mem0_selfhosted (current) | agentmemory (new) |
|---|---|---|
| Memory tools | 3 (profile / search / conclude) | 43 MCP tools + 6 lifecycle hooks |
| Search | Vector only | BM25 + vector + knowledge graph |
| Session awareness | No | Yes (summarize on idle/end) |
| Cross-agent sharing | No | Yes (OpenCode shares same store) |
| Storage | External PostgreSQL + pgvector | SQLite (no external deps) |
| Retrieval R@5 | 68.5% (LoCoMo) | 95.2% (LongMemEval-S) |

---

## Constraints

- agentmemory requires `iii-engine` binary — the official Docker deployment path (`iiidev/iii` image) or `npx @agentmemory/agentmemory` which auto-downloads it. The k8s deployment uses `npx` so no custom Containerfile is needed in agent-platform-custom.
- SQLite is single-writer: `strategy: Recreate` on the k8s deployment, VolSync handles backup snapshots.
- `AGENTMEMORY_SECRET` must be set for any non-loopback access (both Hermes in-cluster and OpenCode from Mac hit the HTTPRoute, not the ClusterIP directly).
- The agentmemory viewer port 3113 is exposed via a separate HTTPRoute but should be considered internal-only (no public gateway section).
