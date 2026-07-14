# Authentik Kubernetes State Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Initialize the Authentik OpenTofu root with an empty, GitOps-provisioned Kubernetes state backend.

**Architecture:** Home Ops reconciles a dedicated `tofu-state` Namespace through the existing Argo CD application map. The Authentik OpenTofu root stores its default workspace in a Secret in that namespace and uses a Kubernetes Lease for locking. The existing Garage backend is not migrated because its bucket is empty.

**Tech Stack:** Argo CD, Kustomize, Kubernetes Namespace/Secret/Lease, OpenTofu Kubernetes backend, Authentik provider.

## Global Constraints

- Do not commit kubeconfig paths, tokens, client certificates, Terraform state, or plan files.
- Do not modify Garage or Envoy policy; the target is a fresh Kubernetes backend.
- Do not run `tofu init -migrate-state`; Garage has no state to preserve.
- Supply Kubernetes access only through `KUBE_CONFIG_PATH`.
- Before the first apply, import any Authentik object that already exists rather than recreating it.
- Treat Terraform state as sensitive; keep Kubernetes Secret encryption, RBAC, and backups enabled.

## File Structure

- `components/default/tofu-state/namespace.yaml`: creates only the dedicated state namespace.
- `components/default/tofu-state/kustomization.yaml`: Kustomize entry point for that namespace.
- `clusters/talos/apps/20-applications.yaml`: registers the namespace component as an Argo CD application.
- `/Users/vikaspogu/Documents/git-repos/homelab-orchestrator/terraform/authentik/backend.tf`: replaces the S3 backend with the Kubernetes backend.

---

### Task 1: Deliver the `tofu-state` Namespace Through GitOps

**Files:**
- Create: `components/default/tofu-state/namespace.yaml`
- Create: `components/default/tofu-state/kustomization.yaml`
- Modify: `clusters/talos/apps/20-applications.yaml`
- Test: Kustomize render and Home Ops manifest validation

**Interfaces:**
- Consumes: Argo CD's existing application map in `clusters/talos/apps/20-applications.yaml`.
- Produces: an Argo CD application named `tofu-state` that reconciles the `tofu-state` Namespace.

- [ ] **Step 1: Verify the new Kustomize entry point is absent**

  Run:

  ```bash
  kustomize build components/default/tofu-state
  ```

  Expected: non-zero exit because the component does not exist yet.

- [ ] **Step 2: Create the minimal Namespace component**

  Create `components/default/tofu-state/namespace.yaml`:

  ```yaml
  ---
  apiVersion: v1
  kind: Namespace
  metadata:
    name: tofu-state
  ```

  Create `components/default/tofu-state/kustomization.yaml`:

  ```yaml
  ---
  apiVersion: kustomize.config.k8s.io/v1beta1
  kind: Kustomization
  resources:
    - ./namespace.yaml
  ```

- [ ] **Step 3: Register the component in the existing Argo CD application map**

  Add this entry in alphabetical order among the default applications in `clusters/talos/apps/20-applications.yaml`:

  ```yaml
  tofu-state:
    annotations:
      argocd.argoproj.io/sync-wave: "20"
    destination:
      namespace: tofu-state
    source:
      path: components/default/tofu-state
  ```

- [ ] **Step 4: Render and validate the Home Ops change**

  Run:

  ```bash
  kustomize build components/default/tofu-state
  ```

  Expected: one `v1/Namespace` named `tofu-state`.

  Run:

  ```bash
  pre-commit run --files \
    components/default/tofu-state/kustomization.yaml \
    components/default/tofu-state/namespace.yaml \
    clusters/talos/apps/20-applications.yaml
  ./scripts/kubeconform.sh
  ```

  Expected: all selected pre-commit hooks pass and the script ends with `All Kubernetes manifest validation completed successfully!`.

- [ ] **Step 5: Commit the GitOps component**

  ```bash
  git add components/default/tofu-state/kustomization.yaml \
    components/default/tofu-state/namespace.yaml \
    clusters/talos/apps/20-applications.yaml
  git commit -m "Add Kubernetes namespace for OpenTofu state"
  ```

### Task 2: Confirm the Namespace Is Reconciled Before Backend Cutover

**Files:**
- Modify: none
- Test: live Argo CD and Kubernetes Namespace state

**Interfaces:**
- Consumes: the committed `tofu-state` Argo CD application from Task 1 and `KUBE_CONFIG_PATH` pointing at the Talos cluster kubeconfig.
- Produces: a live `tofu-state` Namespace in `Active` phase.

- [ ] **Step 1: Confirm Argo CD created and synchronized the application**

  Run:

  ```bash
  kubectl --kubeconfig "$KUBE_CONFIG_PATH" \
    -n argocd get applications.argoproj.io tofu-state \
    -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
  ```

  Expected: `Synced` followed by `Healthy`. If not, inspect the Argo CD application conditions and fix GitOps delivery before changing OpenTofu.

- [ ] **Step 2: Confirm the Namespace is active**

  Run:

  ```bash
  kubectl --kubeconfig "$KUBE_CONFIG_PATH" get namespace tofu-state \
    -o jsonpath='{.status.phase}{"\n"}'
  ```

  Expected: `Active`.

### Task 3: Initialize the Empty Kubernetes Backend

**Files:**
- Modify: `/Users/vikaspogu/Documents/git-repos/homelab-orchestrator/terraform/authentik/backend.tf`
- Test: OpenTofu initialization, plan review, state Secret, and Lease locking

**Interfaces:**
- Consumes: active `tofu-state` Namespace from Task 2 and `KUBE_CONFIG_PATH` for the Talos cluster.
- Produces: Kubernetes backend state named by `secret_suffix = "authentik"`; the default workspace uses Secret `tfstate-default-authentik`.

- [ ] **Step 1: Replace the S3 backend block**

  Replace the entire backend block with:

  ```hcl
  terraform {
    backend "kubernetes" {
      namespace     = "tofu-state"
      secret_suffix = "authentik"
    }
  }
  ```

  Do not add `config_path`, a token, or any endpoint credential to the file. The backend reads the kubeconfig path from `KUBE_CONFIG_PATH`.

- [ ] **Step 2: Initialize as a fresh backend**

  Run from `/Users/vikaspogu/Documents/git-repos/homelab-orchestrator/terraform/authentik`:

  ```bash
  KUBE_CONFIG_PATH="$KUBE_CONFIG_PATH" tofu init -reconfigure
  ```

  Expected: backend initialization completes without accessing Garage. Do not use `-migrate-state`.

- [ ] **Step 3: Review the fresh-state plan before applying**

  Run:

  ```bash
  KUBE_CONFIG_PATH="$KUBE_CONFIG_PATH" tofu plan
  ```

  Expected: resources are proposed for creation because the backend is intentionally empty. Compare each address with the Authentik server. If an object already exists, stop and import it with the provider-supported `tofu import <address> <id>` form, then rerun the plan. Proceed only when the plan contains intended changes.

- [ ] **Step 4: Hold the reviewed apply at confirmation**

  In terminal A, run:

  ```bash
  KUBE_CONFIG_PATH="$KUBE_CONFIG_PATH" tofu apply
  ```

  Expected: OpenTofu displays the reviewed plan and waits for `Enter a value:`. Do not confirm yet; the backend Lease must remain held at this prompt.

- [ ] **Step 5: Prove the held Lease rejects a second client, then complete the apply**

  In terminal B, run:

  ```bash
  KUBE_CONFIG_PATH="$KUBE_CONFIG_PATH" tofu plan -lock-timeout=0s
  ```

  Expected: immediate state-lock acquisition failure. Return to terminal A, type `yes` only after reconfirming the displayed plan, and wait for the apply to finish.

  Then run:

  ```bash
  kubectl --kubeconfig "$KUBE_CONFIG_PATH" -n tofu-state \
    get secret tfstate-default-authentik
  ```

  Expected: the reviewed Authentik changes apply successfully and the state Secret exists. Do not print or decode the Secret.

- [ ] **Step 6: Commit the backend cutover**

  ```bash
  git add backend.tf
  git commit -m "Store Authentik state in Kubernetes"
  ```

## Plan Self-Review

- Spec coverage: Task 1 implements the GitOps namespace and Argo application; Task 2 proves it exists before use; Task 3 configures, initializes, safely reviews, applies, and verifies the Kubernetes backend.
- Placeholder scan: no TBD/TODO items or unresolved implementation choices remain.
- Interface consistency: Task 1 produces `tofu-state`; Task 2 verifies it; Task 3 consumes it with the same namespace and `authentik` suffix.
