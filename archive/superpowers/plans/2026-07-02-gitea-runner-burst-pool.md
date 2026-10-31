# Gitea Runner Burst Pool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide a staged, isolated second Gitea runner pool so trusted workflows run concurrently without sharing runner or Docker state.

**Architecture:** Keep the existing `gitea-runner` deployment and raise its capacity to two. Add an independent `gitea-runner-burst` app-template release with distinct config, secret target, VolSync data PVC, and Docker PVC; stage it at one concurrent job. Gitea dispatches matching Ubuntu-label workflows across the independent pools.

**Tech Stack:** Kubernetes, Kustomize Helm charts, bjw-s app-template `5.0.1`, ArgoCD, ExternalSecrets, VolSync, Rook-Ceph, Gitea `act_runner` `0.6.1`.

## Global Constraints

- The baseline runner config map must set `runner.capacity: 2`.
- The burst runner starts at `runner.capacity: 1`; increasing it is a later measured operational change.
- The burst runner must use `gitea-runner-burst` for runner data and `gitea-runner-burst-docker` for Docker data, never either existing runner claim.
- Both pools use the same pinned runner, Docker, and Ubuntu-label configuration as the current working runner.
- The burst component must use ExternalSecrets and must not store token material in Git.
- The burst ArgoCD application uses sync wave `20`, namespace `default`, Ceph block storage, `csi-ceph-blockpool`, a 2 GiB VolSync data claim, 8 GiB VolSync cache, and schedule `"40 */6 * * *"`.
- Do not add queue-driven autoscaling, an HTTP endpoint, custom RBAC, controller code, or per-job ephemeral behavior.
- Configuration-file behavior is verified with a Helm-enabled Kustomize rendering test; no unit-test framework is introduced.

---

### Task 1: Rendered-manifest regression test

**Files:**
- Create: `scripts/test-gitea-runner-pool-rendered-manifest.sh`

**Interfaces:**
- Consumes: `components/default/gitea-runner`, future `components/default/gitea-runner-burst`, and `clusters/talos/apps/20-applications.yaml`.
- Produces: an executable, zero-exit rendered-manifest contract test.

- [ ] **Step 1: Write the failing test**

Create this executable Bash test. It follows `scripts/test-ntfy-rendered-manifest.sh`, renders Helm charts with Kustomize, and substitutes the ArgoCD plugin inputs locally.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly APPS_FILE="${ROOT_DIR}/clusters/talos/apps/20-applications.yaml"
readonly BASELINE_COMPONENT="${ROOT_DIR}/components/default/gitea-runner"
readonly BURST_COMPONENT="${ROOT_DIR}/components/default/gitea-runner-burst"
readonly baseline_manifest="$(mktemp)"
readonly burst_manifest="$(mktemp)"
trap 'rm -f -- "${baseline_manifest}" "${burst_manifest}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_equals() {
    local actual="$1"
    local expected="$2"
    local message="$3"

    [[ "${actual}" == "${expected}" ]] || fail "${message}: expected ${expected}, got ${actual:-<empty>}"
}

render_component() {
    local app_name="$1"
    local component="$2"
    local output="$3"

    export ARGOCD_APP_NAME="${app_name}"
    export ARGOCD_ENV_STORAGE_CLASS="ceph-block"
    export ARGOCD_ENV_VOLUME_SNAPSHOT_CLASS="csi-ceph-blockpool"
    export ARGOCD_ENV_VOLSYNC_CAPACITY="2Gi"
    export ARGOCD_ENV_VOLSYNC_CACHE_CAPACITY="8Gi"
    export ARGOCD_ENV_VOLSYNC_SCHEDULE="40 */6 * * *"
    export CLUSTER_DOMAIN="example.local"

    kustomize build --enable-helm "${component}" | envsubst >"${output}"
}

config_capacity() {
    local manifest="$1"
    local config_map="$2"

    yq ea -r "select(.kind == \"ConfigMap\" and .metadata.name == \"${config_map}\") | .data.\"config.yaml\" | from_yaml | .runner.capacity" "${manifest}"
}

resource_count() {
    local manifest="$1"
    local kind="$2"
    local name="$3"

    yq ea -r "[select(.kind == \"${kind}\" and .metadata.name == \"${name}\")] | length" "${manifest}"
}

claim_reference_count() {
    local manifest="$1"
    local claim="$2"

    yq ea -r "[select(.kind == \"Deployment\" and .metadata.name == \"gitea-runner-burst\") | .spec.template.spec.volumes[]? | select(.persistentVolumeClaim.claimName == \"${claim}\")] | length" "${manifest}"
}

render_component "gitea-runner" "${BASELINE_COMPONENT}" "${baseline_manifest}"
render_component "gitea-runner-burst" "${BURST_COMPONENT}" "${burst_manifest}"

assert_equals "$(config_capacity "${baseline_manifest}" "gitea-runner-config")" "2" "baseline runner capacity"
assert_equals "$(config_capacity "${burst_manifest}" "gitea-runner-burst-config")" "1" "burst runner capacity"
assert_equals "$(resource_count "${burst_manifest}" "Deployment" "gitea-runner-burst")" "1" "burst deployment"
assert_equals "$(resource_count "${burst_manifest}" "PersistentVolumeClaim" "gitea-runner-burst-docker")" "1" "burst Docker PVC"
assert_equals "$(resource_count "${burst_manifest}" "PersistentVolumeClaim" "gitea-runner-burst")" "1" "burst runner-data PVC"
assert_equals "$(claim_reference_count "${burst_manifest}" "gitea-runner-burst")" "1" "burst runner-data claim reference"
assert_equals "$(claim_reference_count "${burst_manifest}" "gitea-runner-burst-docker")" "1" "burst Docker-data claim reference"
assert_equals "$(claim_reference_count "${burst_manifest}" "gitea-runner")" "0" "baseline runner-data isolation"
assert_equals "$(claim_reference_count "${burst_manifest}" "gitea-runner-docker")" "0" "baseline Docker-data isolation"
assert_equals "$(yq e -r '.applications."gitea-runner-burst".annotations."argocd.argoproj.io/sync-wave"' "${APPS_FILE}")" "20" "burst ArgoCD sync wave"
assert_equals "$(yq e -r '.applications."gitea-runner-burst".destination.namespace' "${APPS_FILE}")" "default" "burst ArgoCD namespace"
assert_equals "$(yq e -r '.applications."gitea-runner-burst".source.path' "${APPS_FILE}")" "components/default/gitea-runner-burst" "burst ArgoCD path"
assert_equals "$(yq e -r '.applications."gitea-runner-burst".source.plugin.env[] | select(.name == "STORAGE_CLASS") | .value' "${APPS_FILE}")" "ceph-block" "burst storage class"
assert_equals "$(yq e -r '.applications."gitea-runner-burst".source.plugin.env[] | select(.name == "VOLUME_SNAPSHOT_CLASS") | .value' "${APPS_FILE}")" "csi-ceph-blockpool" "burst snapshot class"
assert_equals "$(yq e -r '.applications."gitea-runner-burst".source.plugin.env[] | select(.name == "VOLSYNC_CAPACITY") | .value' "${APPS_FILE}")" "2Gi" "burst VolSync capacity"
assert_equals "$(yq e -r '.applications."gitea-runner-burst".source.plugin.env[] | select(.name == "VOLSYNC_CACHE_CAPACITY") | .value' "${APPS_FILE}")" "8Gi" "burst VolSync cache capacity"
assert_equals "$(yq e -r '.applications."gitea-runner-burst".source.plugin.env[] | select(.name == "VOLSYNC_SCHEDULE") | .value' "${APPS_FILE}")" "40 */6 * * *" "burst VolSync schedule"

printf 'PASS: rendered Gitea runner pools have independent claims, staged capacity, and ArgoCD registration\n'
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bash scripts/test-gitea-runner-pool-rendered-manifest.sh
```

Expected: failure because `components/default/gitea-runner-burst` does not exist yet.

- [ ] **Step 3: Keep the failing test unchanged while implementing Tasks 2 and 3**

The test is the behavior contract. Do not weaken it to accommodate an incorrect storage relationship.

### Task 2: Baseline capacity and isolated burst component

**Files:**
- Modify: `components/default/gitea-runner/configmap.yaml:11-17`
- Create: `components/default/gitea-runner-burst/configmap.yaml`
- Create: `components/default/gitea-runner-burst/external-secret.yaml`
- Create: `components/default/gitea-runner-burst/kustomization.yaml`
- Create: `components/default/gitea-runner-burst/pvc-docker.yaml`
- Create: `components/default/gitea-runner-burst/values.yaml`

**Interfaces:**
- Consumes: the existing `gitea-runner` component layout, Gitea `RUNNER_TOKEN` field, and the VolSync component's `${ARGOCD_APP_NAME}` data-claim convention.
- Produces: two independently stateful Gitea runner deployments that expose matching Ubuntu labels.

- [ ] **Step 1: Increase baseline concurrency**

Change the existing ConfigMap to:

```yaml
runner:
  file: /data/.runner
  capacity: 2
```

Do not change labels, timeouts, cache, or container configuration.

- [ ] **Step 2: Create the burst ConfigMap**

Create `gitea-runner-burst-config` using the current runner ConfigMap as the exact behavioral template, with only these identity changes:

```yaml
metadata:
  name: gitea-runner-burst-config
runner:
  file: /data/.runner
  capacity: 1
```

Keep the same timeout, fetch behavior, Docker host, labels, cache settings, and volume policy as the baseline ConfigMap.

- [ ] **Step 3: Create the burst ExternalSecret**

Create an ExternalSecret named `gitea-runner-burst` targeting `gitea-runner-burst-secret`, sourced from the existing `gitea` 1Password item, with only:

```yaml
data:
  GITEA_RUNNER_REGISTRATION_TOKEN: "{{ .RUNNER_TOKEN }}"
```

- [ ] **Step 4: Create isolated Docker storage**

Create a `ReadWriteOnce`, `ceph-block`, 100 GiB PVC named `gitea-runner-burst-docker`.

- [ ] **Step 5: Create the burst Kustomization**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
components:
  - ../../volsync-system/volsync-replication
resources:
  - ./external-secret.yaml
  - ./configmap.yaml
  - ./pvc-docker.yaml
helmCharts:
  - name: app-template
    releaseName: gitea-runner-burst
    namespace: default
    repo: oci://ghcr.io/bjw-s-labs/helm
    version: "5.0.1"
    valuesFile: values.yaml
```

- [ ] **Step 6: Create burst Helm values**

Copy the existing runner's controller, runner image digest, Docker image, Docker readiness command, security context, resource requests/limits, and persistence layout. Change only identity and state references:

```yaml
controllers:
  app:
    replicas: 1
    strategy: Recreate
    containers:
      runner:
        envFrom:
          - secretRef:
              name: gitea-runner-burst-secret
persistence:
  docker-data:
    existingClaim: gitea-runner-burst-docker
  config:
    name: gitea-runner-burst-config
  data:
    existingClaim: gitea-runner-burst
```

No value may reference `gitea-runner-docker`, `gitea-runner-secret`, or `gitea-runner-config`.

- [ ] **Step 7: Run direct Helm-enabled manifest renders**

Run:

```bash
export ARGOCD_APP_NAME=gitea-runner
export ARGOCD_ENV_STORAGE_CLASS=ceph-block
export ARGOCD_ENV_VOLUME_SNAPSHOT_CLASS=csi-ceph-blockpool
export ARGOCD_ENV_VOLSYNC_CAPACITY=2Gi
export ARGOCD_ENV_VOLSYNC_CACHE_CAPACITY=8Gi
export ARGOCD_ENV_VOLSYNC_SCHEDULE='40 */6 * * *'
kustomize build --enable-helm components/default/gitea-runner | envsubst >/tmp/gitea-runner.yaml

export ARGOCD_APP_NAME=gitea-runner-burst
kustomize build --enable-helm components/default/gitea-runner-burst | envsubst >/tmp/gitea-runner-burst.yaml
```

Expected: both commands exit zero; the second render includes `Deployment/gitea-runner-burst`, `PersistentVolumeClaim/gitea-runner-burst`, and `PersistentVolumeClaim/gitea-runner-burst-docker`.

### Task 3: ArgoCD registration, validation, and documentation

**Files:**
- Modify: `clusters/talos/apps/20-applications.yaml:142-161`
- Modify: `docs/superpowers/specs/2026-07-02-gitea-runner-burst-pool-design.md`

**Interfaces:**
- Consumes: the `components/default/gitea-runner-burst` component and the app-of-apps plugin environment contract.
- Produces: ArgoCD reconciliation of the burst runner and documented staged operational capacity.

- [ ] **Step 1: Register the burst application directly after `gitea-runner`**

```yaml
gitea-runner-burst:
  annotations:
    argocd.argoproj.io/sync-wave: "20"
  destination:
    namespace: default
  source:
    path: components/default/gitea-runner-burst
    plugin:
      env:
        - name: STORAGE_CLASS
          value: ceph-block
        - name: VOLUME_SNAPSHOT_CLASS
          value: csi-ceph-blockpool
        - name: VOLSYNC_CAPACITY
          value: 2Gi
        - name: VOLSYNC_CACHE_CAPACITY
          value: 8Gi
        - name: VOLSYNC_SCHEDULE
          value: "40 */6 * * *"
```

- [ ] **Step 2: Record validation and rollout evidence in the design document**

Append `## Validation` with these exact commands:

```bash
bash scripts/test-gitea-runner-pool-rendered-manifest.sh
bash scripts/kubeconform.sh
pre-commit run --all-files
```

State that the first live rollout permits three concurrent jobs and requires observed resource headroom before the burst capacity changes from one to two.

- [ ] **Step 3: Run focused and repository validation**

Run:

```bash
bash scripts/test-gitea-runner-pool-rendered-manifest.sh
bash scripts/kubeconform.sh
pre-commit run --all-files
```

Expected: all commands exit zero. The focused test validates Helm rendering, capacity, storage isolation, and Argo registration; kubeconform validates repository manifests; pre-commit validates YAML and secret policy.

- [ ] **Step 4: Commit the reviewed change**

```bash
git add components/default/gitea-runner/configmap.yaml components/default/gitea-runner-burst clusters/talos/apps/20-applications.yaml scripts/test-gitea-runner-pool-rendered-manifest.sh docs/superpowers/specs/2026-07-02-gitea-runner-burst-pool-design.md docs/superpowers/plans/2026-07-02-gitea-runner-burst-pool.md
git commit -m "feat: add isolated Gitea runner burst pool"
```

Expected: one focused commit, ready for independent review.

## Plan self-review

- Spec coverage: Task 1 makes capacity, storage, and registration invariants executable. Task 2 creates independent runner pools and directly renders the Helm-backed manifests. Task 3 registers the workload, documents staged operation, and runs all validation.
- Placeholder scan: no TBD, TODO, or deferred implementation instructions remain.
- Consistency: component name, release name, VolSync claim, Docker claim, config map, ExternalSecret target, and ArgoCD app name are all `gitea-runner-burst` with the resource-specific suffix only where required.
