# Hermes SearXNG Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Execute task-by-task with review checkpoints.

**Goal:** Route Hermes `web_search` requests to the in-cluster SearXNG Service without changing secret management or web extraction behavior.

**Architecture:** Hermes receives SearXNG's ClusterIP base URL through the non-secret Helm `env:` map. Its mounted `config.yaml` explicitly selects SearXNG for the search capability only. `web_extract` retains its existing provider-selection path.

**Tech Stack:** Kubernetes, Kustomize with Helm charts, bjw-s app-template v5.0.1, `yq`, Kustomize.

## Global Constraints

- Use `http://searxng.ai.svc.cluster.local:8080` as the SearXNG base URL.
- Keep `SEARXNG_URL` in Helm `env:`, not in `externalsecret.yaml`.
- Set `web.search_backend: searxng`; do not set `web.backend` or `web.extract_backend`.
- Keep `web/ddgs` in `plugins.enabled` unchanged.
- Do not alter the SearXNG component, Argo CD registration, or Gateway route.

---

### Task 1: Configure the Hermes SearXNG Search Backend

**Files:**
- Modify: `components/ai/hermes-agent/values.yaml:48-73`
- Modify: `components/ai/hermes-agent/configmap.yaml:7-220`
- Validate: rendered `components/ai/hermes-agent` Kustomization

**Interfaces:**
- Consumes: SearXNG ClusterIP Service `searxng.ai.svc.cluster.local:8080`, which provides JSON search output.
- Produces: Hermes environment variable `SEARXNG_URL` and config key `web.search_backend: searxng`.

- [ ] **Step 1: Prove the source configuration lacks the requested contract**

Run:

```bash
yq -e '.controllers.app.containers.app.env.SEARXNG_URL == "http://searxng.ai.svc.cluster.local:8080"' components/ai/hermes-agent/values.yaml
yq -r '.data["config.yaml"]' components/ai/hermes-agent/configmap.yaml | yq -e '.web.search_backend == "searxng"' -
```

Expected: both commands fail because neither setting exists.

- [ ] **Step 2: Add the minimal non-secret service endpoint**

In `components/ai/hermes-agent/values.yaml`, add this exact entry to `controllers.app.containers.app.env`, alongside the existing internal URLs:

```yaml
SEARXNG_URL: http://searxng.ai.svc.cluster.local:8080
```

- [ ] **Step 3: Explicitly select SearXNG for search only**

In the `data.config.yaml` block of `components/ai/hermes-agent/configmap.yaml`, add:

```yaml
web:
  search_backend: searxng
```

Do not add `web.backend` or `web.extract_backend`; either could change `web_extract` routing. Do not change the existing `plugins.enabled` list.

- [ ] **Step 4: Verify both source contracts pass**

Run:

```bash
yq -e '.controllers.app.containers.app.env.SEARXNG_URL == "http://searxng.ai.svc.cluster.local:8080"' components/ai/hermes-agent/values.yaml
yq -r '.data["config.yaml"]' components/ai/hermes-agent/configmap.yaml | yq -e '.web.search_backend == "searxng"' -
```

Expected: both commands exit `0`.

- [ ] **Step 5: Render the Helm-backed Kustomization**

Run:

```bash
kustomize build --enable-helm --load-restrictor=LoadRestrictionsNone components/ai/hermes-agent > /tmp/hermes-agent-rendered.yaml
```

Expected: command exits `0` and writes a non-empty rendered manifest. The render must preserve the SearXNG URL environment value and ConfigMap web selector.

- [ ] **Step 6: Commit the manifest configuration**

```bash
git add components/ai/hermes-agent/values.yaml components/ai/hermes-agent/configmap.yaml
git commit -m "feat: route Hermes search through SearXNG"
```
