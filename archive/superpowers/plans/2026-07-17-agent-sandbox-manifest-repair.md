# Agent Sandbox Manifest Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `executing-plans`.

**Goal:** Restore deterministic Argo CD rendering and kubeconform validation for `agent-sandbox`.

**Architecture:** Replace one invalid floating GitHub release resource with the upstream v0.5.2 all-in-one GitOps asset. The upstream manifest owns the existing `agent-sandbox-system` namespace, so the local Kustomization and Argo CD registration remain unchanged.

**Tech Stack:** Kustomize, kubeconform, Argo CD CMP.

## Global Constraints

- Use the pinned upstream v0.5.2 `sandbox-with-extensions.yaml` asset.
- Do not modify the namespace, application registration, or controller configuration.
- Validate with the Argo CD-compatible Kustomize flags and `scripts/kubeconform.sh`.

---

### Task 1: Pin the upstream Agent Sandbox manifest

**Files:**
- Modify: `components/ai/agent-sandbox/kustomization.yaml:6`
- Test: direct `kustomize build` of `components/ai/agent-sandbox`; `scripts/kubeconform.sh`

**Interfaces:**
- Consumes: GitHub release asset `v0.5.2/sandbox-with-extensions.yaml`.
- Produces: valid Kubernetes manifests in `agent-sandbox-system` for Argo CD and kubeconform.

- [ ] **Step 1: Reproduce the failing render**

Run:

```bash
kustomize build --load-restrictor LoadRestrictionsNone --enable-exec --enable-alpha-plugins components/ai/agent-sandbox
```

Expected: non-zero exit with `releases/latest/download/manifest.yaml` resource accumulation failure.

- [ ] **Step 2: Replace the broken resource URL**

Set the sole resource to:

```yaml
  - https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.5.2/sandbox-with-extensions.yaml
```

- [ ] **Step 3: Verify the direct render passes**

Run:

```bash
kustomize build --load-restrictor LoadRestrictionsNone --enable-exec --enable-alpha-plugins components/ai/agent-sandbox
```

Expected: zero exit and a rendered `Namespace` named `agent-sandbox-system`.

- [ ] **Step 4: Verify repository manifest validation**

Run:

```bash
scripts/kubeconform.sh
```

Expected: zero exit and `All Kubernetes manifest validation completed successfully!`.

- [ ] **Step 5: Commit the repair**

Run:

```bash
git add components/ai/agent-sandbox/kustomization.yaml docs/superpowers/specs/2026-07-17-agent-sandbox-manifest-design.md docs/superpowers/plans/2026-07-17-agent-sandbox-manifest-repair.md
git commit -m "(fix): pin agent sandbox GitOps manifest"
```
