# Headroom `headroom_retrieve` Plugin Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate the headroom `headroom_retrieve` plugin into the custom Hermes image so Hermes can decompress CCR markers produced by the headroom proxy, and configure both deployments to wire them together correctly.

**Architecture:** The plugin is fetched from upstream (`chopratejas/headroom`) at container build time via a pinned git SHA, patched in-place with a single `sed` to read the proxy URL from an env var, and copied into the Hermes plugin directory. Hermes is configured to enable the plugin and point it at headroom's cluster-internal address. Headroom is configured to exclude the `headroom_retrieve` tool from re-compression to prevent loops.

**Tech Stack:** Containerfile (Podman/Docker), Python 3, Kubernetes (bjw-s app-template Helm), ArgoCD GitOps, Renovate Bot

**Spec:** `docs/superpowers/specs/2026-06-18-headroom-hermes-plugin-design.md`

---

## File Map

| Repo | File | Change |
|------|------|--------|
| `agent-platform-custom` | `images/hermes-agent/Containerfile` | Add `ARG HEADROOM_PLUGIN_SHA` + clone/patch/copy `RUN` block |
| `agent-platform-custom` | `images/hermes-agent/defaults/config.yaml` | Add `headroom_retrieve` to `plugins.enabled` |
| `home-ops` | `components/ai/hermes-agent/values.yaml` | Add `HEADROOM_PROXY_URL` env var to `app` container |
| `home-ops` | `components/ai/headroom/values.yaml` | Add `HEADROOM_EXCLUDE_TOOLS` env var |

---

## Task 1: Fetch the plugin in the Containerfile

**Repo:** `agent-platform-custom`

**Files:**
- Modify: `images/hermes-agent/Containerfile`

- [ ] **Step 1: Read the current Containerfile end**

Open `images/hermes-agent/Containerfile`. Note the last `COPY` line that copies the agentmemory plugin:

```dockerfile
COPY plugins/memory/agentmemory /opt/hermes/plugins/memory/agentmemory
```

This is the insertion point — the new block goes immediately after it.

- [ ] **Step 2: Add the ARG and RUN block after the agentmemory COPY**

Insert the following immediately after the `COPY plugins/memory/agentmemory ...` line:

```dockerfile
# renovate: datasource=github-commits depName=chopratejas/headroom
ARG HEADROOM_PLUGIN_SHA=8894ee0c18e6dfe858cf0034ec424fd0768a1334

RUN git clone --no-checkout https://github.com/chopratejas/headroom.git /tmp/headroom \
    && git -C /tmp/headroom checkout "${HEADROOM_PLUGIN_SHA}" -- plugins/hermes/headroom_retrieve \
    && sed -i \
         's|_PROXY_URL = "http://127.0.0.1:8787"|_PROXY_URL = os.environ.get("HEADROOM_PROXY_URL", "http://127.0.0.1:8787")|' \
         /tmp/headroom/plugins/hermes/headroom_retrieve/__init__.py \
    && mkdir -p /opt/hermes/plugins/headroom \
    && cp -r /tmp/headroom/plugins/hermes/headroom_retrieve \
         /opt/hermes/plugins/headroom/headroom_retrieve \
    && rm -rf /tmp/headroom
```

- [ ] **Step 3: Verify the sed pattern matches upstream**

The upstream `__init__.py` line to be patched is:
```python
_PROXY_URL = "http://127.0.0.1:8787"
```

The `sed` expression replaces exactly that string. Confirm by checking:
```bash
curl -s "https://raw.githubusercontent.com/chopratejas/headroom/8894ee0c18e6dfe858cf0034ec424fd0768a1334/plugins/hermes/headroom_retrieve/__init__.py" \
  | grep "_PROXY_URL"
```
Expected output:
```
_PROXY_URL = "http://127.0.0.1:8787"
```

If the line differs, update the `sed` expression to match.

- [ ] **Step 4: Commit**

```bash
cd /Users/vikaspogu/Documents/git-repos/agent-platform-custom
git add images/hermes-agent/Containerfile
git commit -m "(feat): fetch headroom_retrieve plugin from upstream at build time"
```

---

## Task 2: Enable the plugin in defaults/config.yaml

**Repo:** `agent-platform-custom`

**Files:**
- Modify: `images/hermes-agent/defaults/config.yaml`

- [ ] **Step 1: Open the file and locate `plugins.enabled`**

The current content is:
```yaml
plugins:
  enabled:
    - rtk-rewrite
```

- [ ] **Step 2: Add `headroom_retrieve` to the list**

Edit the block to:
```yaml
plugins:
  enabled:
    - rtk-rewrite
    - headroom_retrieve
```

`rtk-rewrite` remains — it rewrites outgoing tool call arguments (correctness). `headroom_retrieve` adds the decompression tool. They operate at different points and do not conflict.

- [ ] **Step 3: Commit**

```bash
git add images/hermes-agent/defaults/config.yaml
git commit -m "(feat): enable headroom_retrieve plugin in hermes defaults config"
```

---

## Task 3: Add `HEADROOM_PROXY_URL` env var to hermes-agent deployment

**Repo:** `home-ops`

**Files:**
- Modify: `components/ai/hermes-agent/values.yaml`

- [ ] **Step 1: Locate the `app` container env block**

In `components/ai/hermes-agent/values.yaml`, find the `containers.app.env` block. It currently ends with:
```yaml
        TZ: America/New_York
```

- [ ] **Step 2: Add the env var**

Add immediately after `TZ: America/New_York`:
```yaml
        HEADROOM_PROXY_URL: http://headroom.ai.svc.cluster.local:8787
```

The full env block tail should look like:
```yaml
        AGENTMEMORY_URL: http://agentmemory.ai.svc.cluster.local:3111
        TZ: America/New_York
        HEADROOM_PROXY_URL: http://headroom.ai.svc.cluster.local:8787
```

- [ ] **Step 3: Commit**

```bash
cd /Users/vikaspogu/Documents/git-repos/home-ops
git add components/ai/hermes-agent/values.yaml
git commit -m "(feat): add HEADROOM_PROXY_URL env var to hermes-agent"
```

---

## Task 4: Add `HEADROOM_EXCLUDE_TOOLS` env var to headroom deployment

**Repo:** `home-ops`

**Files:**
- Modify: `components/ai/headroom/values.yaml`

- [ ] **Step 1: Locate the headroom container env block**

In `components/ai/headroom/values.yaml`, find the `containers.app.env` block. It currently ends with:
```yaml
          HOME: /data
```

- [ ] **Step 2: Add the env var**

Add immediately after `HOME: /data`:
```yaml
          HEADROOM_EXCLUDE_TOOLS: "read_file,headroom_retrieve"
```

- `read_file` — Hermes file reads need verbatim content, same rationale as Claude Code's `Read` tool exclusion
- `headroom_retrieve` — prevents the retrieved original being re-compressed on the next request, which would create an endless marker→retrieve→marker loop

The full env block tail should look like:
```yaml
          HOME: /data
          HEADROOM_EXCLUDE_TOOLS: "read_file,headroom_retrieve"
```

- [ ] **Step 3: Commit**

```bash
git add components/ai/headroom/values.yaml
git commit -m "(feat): exclude read_file and headroom_retrieve from headroom compression"
```

---

## Task 5: Build and verify the image locally

**Repo:** `agent-platform-custom`

- [ ] **Step 1: Build the image**

```bash
cd /Users/vikaspogu/Documents/git-repos/agent-platform-custom/images/hermes-agent
podman build \
  --build-arg HEADROOM_PLUGIN_SHA=8894ee0c18e6dfe858cf0034ec424fd0768a1334 \
  -t hermes-agent-test:local \
  -f Containerfile \
  .
```

Expected: build completes without error. The `git clone` step should print clone progress and the `sed` step should complete silently.

- [ ] **Step 2: Verify the plugin files are present**

```bash
podman run --rm hermes-agent-test:local \
  ls /opt/hermes/plugins/headroom/headroom_retrieve/
```

Expected output:
```
__init__.py
plugin.yaml
```

- [ ] **Step 3: Verify the `_PROXY_URL` patch was applied**

```bash
podman run --rm hermes-agent-test:local \
  grep "_PROXY_URL" /opt/hermes/plugins/headroom/headroom_retrieve/__init__.py
```

Expected output:
```python
_PROXY_URL = os.environ.get("HEADROOM_PROXY_URL", "http://127.0.0.1:8787")
```

If the original `"http://127.0.0.1:8787"` string appears instead, the `sed` pattern did not match — go back to Task 1 Step 3 and fix it.

- [ ] **Step 4: Verify the plugin is in the enabled list**

```bash
podman run --rm hermes-agent-test:local \
  cat /opt/hermes-defaults/config.yaml | grep -A5 "plugins:"
```

Expected output includes:
```yaml
plugins:
  enabled:
    - rtk-rewrite
    - headroom_retrieve
```

- [ ] **Step 5: Verify `plugin.yaml` contains `provides_tools`**

```bash
podman run --rm hermes-agent-test:local \
  cat /opt/hermes/plugins/headroom/headroom_retrieve/plugin.yaml
```

Expected output:
```yaml
name: headroom_retrieve
version: 1.0.0
description: "Retrieve original content compressed by the headroom proxy (CCR markers)"
author: akb4q
provides_tools:
- headroom_retrieve
```

---

## Task 6: Push and let CI build the image

**Repo:** `agent-platform-custom`

- [ ] **Step 1: Push both commits**

```bash
cd /Users/vikaspogu/Documents/git-repos/agent-platform-custom
git push
```

- [ ] **Step 2: Monitor the CI build**

Watch the Gitea Actions run for `images/hermes-agent`. The build should succeed and push the new image tag to `gitea.a113.casa/vpogu/agent-platform-hermes-agent`.

- [ ] **Step 3: Note the new image tag**

The tag format is `YYYYMMDDHHMMSS-<short-sha>-oci`. Copy it — it is needed for the next task.

---

## Task 7: Update the image tag in home-ops and sync

**Repo:** `home-ops`

- [ ] **Step 1: Update the image tag in hermes-agent values.yaml**

In `components/ai/hermes-agent/values.yaml`, update all three occurrences of the image tag (initContainers `hermes-bootstrap`, initContainers `seed-config`, and containers `app`) to the new tag from Task 6.

The three locations are at lines containing:
```yaml
          tag: 20260617143811-f5079a4-oci
```

Replace each with the new tag, e.g.:
```yaml
          tag: <new-tag-from-ci>
```

> Note: Renovate normally handles tag bumps automatically. This manual step is only needed if you want to deploy immediately without waiting for a Renovate PR.

- [ ] **Step 2: Commit and push**

```bash
git add components/ai/hermes-agent/values.yaml
git commit -m "(chore): bump hermes-agent image tag with headroom_retrieve plugin"
git push
```

- [ ] **Step 3: Verify ArgoCD sync**

ArgoCD will detect the change and sync the `hermes-agent` application. Verify in the ArgoCD UI or via:

```bash
kubectl -n ai get pods -l app.kubernetes.io/name=hermes-agent -w
```

Expected: the old pod terminates, a new pod starts and reaches `Running`.

- [ ] **Step 4: Verify headroom sync**

The headroom deployment also changed (new `HEADROOM_EXCLUDE_TOOLS` env var). ArgoCD should sync it automatically. Verify:

```bash
kubectl -n ai get pods -l app.kubernetes.io/name=headroom -w
```

Expected: headroom pod restarts and reaches `Running`.

---

## Task 8: Smoke test the integration

- [ ] **Step 1: Verify the plugin is loaded in hermes logs**

```bash
kubectl -n ai logs -l app.kubernetes.io/name=hermes-agent --tail=100 | grep -i headroom
```

Expected: a log line indicating the `headroom_retrieve` plugin was registered, e.g.:
```
[plugin] headroom_retrieve registered (toolset: headroom)
```

- [ ] **Step 2: Verify headroom env var is set**

```bash
kubectl -n ai exec deploy/headroom -- env | grep HEADROOM_EXCLUDE_TOOLS
```

Expected:
```
HEADROOM_EXCLUDE_TOOLS=read_file,headroom_retrieve
```

- [ ] **Step 3: Verify hermes env var is set**

```bash
kubectl -n ai exec deploy/hermes-agent -- env | grep HEADROOM_PROXY_URL
```

Expected:
```
HEADROOM_PROXY_URL=http://headroom.ai.svc.cluster.local:8787
```

- [ ] **Step 4: Verify headroom proxy is reachable from hermes**

```bash
kubectl -n ai exec deploy/hermes-agent -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://headroom.ai.svc.cluster.local:8787/health', timeout=5).status)"
```

Expected output: `200`

---

## Renovate Configuration Note

The `# renovate: datasource=github-commits depName=chopratejas/headroom` comment above `ARG HEADROOM_PLUGIN_SHA` will cause Renovate to open PRs bumping the SHA when new commits land on `headroom` main. No additional Renovate config changes are needed — the `datasource=github-commits` preset is a standard Renovate datasource.

If your `renovate.json` has a `packageRules` block that restricts datasources, verify `github-commits` is not excluded.
