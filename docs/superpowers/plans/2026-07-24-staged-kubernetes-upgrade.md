# Staged Kubernetes Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `executing-plans` for task-by-task execution.

**Goal:** Safely converge home-kubernetes from `v1.34.6` to `v1.36.3` through `v1.35.7`, without downgrading `k8s-5-1u` from its existing `v1.36.2`.

**Architecture:** Stage one uses Talos' documented manual Kubernetes component procedure so that only the three control-plane nodes and `k8s-4-dell` receive `v1.35.7`. Stage two uses the repository's existing `task talos:upgrade-k8s` wrapper to move every node, including `k8s-5-1u`, to `v1.36.3`.

**Tech Stack:** Talos `v1.13.7`, `talosctl`, `talhelper`, Kubernetes `kubectl`, go-task.

## Global Constraints

- Use `/Users/vikaspogu/.kube/configs/talos-cluster-config` explicitly for every Kubernetes command.
- Use `clusters/talos/bootstrap/os/clusterconfig/talosconfig` explicitly for every Talos command.
- Keep `k8s-5-1u` (`10.30.30.25`) untouched throughout stage one.
- Do not proceed past a failed readiness, node-recovery, or workload-availability check.
- Make no Talos version change; it remains `v1.13.7`.

---

### Task 1: Capture the upgrade baseline and safety backup

**Files:**
- Modify: none
- Test: live Kubernetes and Talos readiness checks

**Interfaces:**
- Consumes: reachable API server and Talos control plane at `10.30.30.21`
- Produces: a timestamped local etcd snapshot and a recorded pre-upgrade baseline

- [ ] **Step 1: Verify API, node, and disruption baseline**

Run:

```bash
KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
kubectl get --raw='/readyz?verbose'
KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
kubectl get nodes -o wide
KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
kubectl get poddisruptionbudgets --all-namespaces
```

Expected: `/readyz?verbose` succeeds and all five nodes are `Ready`. Record PDBs and primary placement; do not drain nodes during this upgrade.

- [ ] **Step 2: Save an etcd snapshot before live mutation**

Run:

```bash
mkdir -p /tmp/talos-upgrade-backups
talosctl --talosconfig clusters/talos/bootstrap/os/clusterconfig/talosconfig \
  --nodes 10.30.30.21 etcd snapshot \
  /tmp/talos-upgrade-backups/etcd-before-k8s-v1.35.7-$(date +%Y%m%d%H%M%S).db
```

Expected: `talosctl` reports a completed snapshot and the output file exists locally.

- [ ] **Step 3: Record the exclusion boundary**

Run:

```bash
KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
kubectl get node k8s-5-1u -o wide
```

Expected: `k8s-5-1u` remains `Ready` at `v1.36.2`; do not drain, patch, reboot, or include `10.30.30.25` in a stage-one command.

### Task 2: Apply the targeted v1.35.7 stage

**Files:**
- Modify: none
- Test: Talos component image and Kubernetes readiness checks

**Interfaces:**
- Consumes: baseline from Task 1 and Talos manual component patch API
- Produces: control plane and `k8s-4-dell` running Kubernetes `v1.35.7`; `k8s-5-1u` remains `v1.36.2`

The manual stage uses explicit `v1.35.7` image references. Keep `clusters/talos/bootstrap/os/talenv.yaml` at its final `v1.36.3` target to prevent a generated configuration from downgrading `k8s-5-1u`.

- [ ] **Step 1: Pre-pull v1.35.7 images only on stage-one nodes**

Run:

```bash
set -euo pipefail
for ip in 10.30.30.21 10.30.30.22 10.30.30.23 10.30.30.24; do
  for image in \
    registry.k8s.io/kube-apiserver:v1.35.7 \
    registry.k8s.io/kube-controller-manager:v1.35.7 \
    registry.k8s.io/kube-scheduler:v1.35.7 \
    registry.k8s.io/kube-proxy:v1.35.7 \
    ghcr.io/siderolabs/kubelet:v1.35.7; do
    talosctl --talosconfig clusters/talos/bootstrap/os/clusterconfig/talosconfig \
      --nodes "${ip}" image pull "${image}"
  done
done
```

Expected: all five images are available on the four target nodes. The loop does not include `10.30.30.25`.

- [ ] **Step 2: Upgrade the API server on each control-plane node**

Run:

```bash
set -euo pipefail
for ip in 10.30.30.21 10.30.30.22 10.30.30.23; do
  talosctl --talosconfig clusters/talos/bootstrap/os/clusterconfig/talosconfig \
    --nodes "${ip}" patch mc --mode=no-reboot -p 'cluster:
  apiServer:
    image: registry.k8s.io/kube-apiserver:v1.35.7'
  for attempt in {1..60}; do
    if KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
      kubectl get --raw='/readyz?verbose'; then
      break
    fi
    test "${attempt}" -eq 60 && exit 1
    sleep 5
  done
done
```

Expected: API readiness succeeds after each static-pod replacement.

- [ ] **Step 3: Upgrade controller managers, schedulers, and proxy configuration**

Run:

```bash
set -euo pipefail
for component in controllerManager scheduler proxy; do
  case "${component}" in
    controllerManager) image=registry.k8s.io/kube-controller-manager:v1.35.7 ;;
    scheduler) image=registry.k8s.io/kube-scheduler:v1.35.7 ;;
    proxy) image=registry.k8s.io/kube-proxy:v1.35.7 ;;
  esac
  for ip in 10.30.30.21 10.30.30.22 10.30.30.23; do
    talosctl --talosconfig clusters/talos/bootstrap/os/clusterconfig/talosconfig \
      --nodes "${ip}" patch mc --mode=no-reboot -p "cluster:
  ${component}:
    image: ${image}"
    for attempt in {1..60}; do
      if KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
        kubectl get --raw='/readyz?verbose'; then
        break
      fi
      test "${attempt}" -eq 60 && exit 1
      sleep 5
    done
  done
done
```

Expected: each component updates across the control plane in Talos' documented order; API readiness remains successful after every patch.

- [ ] **Step 4: Reconcile bootstrap manifests and verify the proxy image**

Run:

```bash
talosctl --talosconfig clusters/talos/bootstrap/os/clusterconfig/talosconfig \
  --nodes 10.30.30.21 get manifests -o yaml | \
yq eval-all '.spec | .[] | splitDoc' - > /tmp/talos-v1.35.7-manifests.yaml
KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
kubectl diff -f /tmp/talos-v1.35.7-manifests.yaml
KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
kubectl apply -f /tmp/talos-v1.35.7-manifests.yaml
```

Expected: the diff shows `kube-proxy:v1.35.7`, then bootstrap resources apply without errors.

- [ ] **Step 5: Upgrade kubelets one node at a time, excluding k8s-5-1u**

Run:

```bash
set -euo pipefail
for target in \
  10.30.30.21:k8s-1-nab9 \
  10.30.30.22:k8s-2-ser \
  10.30.30.23:k8s-3-4u \
  10.30.30.24:k8s-4-dell; do
  ip=${target%:*}
  node=${target#*:}
  talosctl --talosconfig clusters/talos/bootstrap/os/clusterconfig/talosconfig \
    --nodes "${ip}" patch mc --mode=no-reboot -p 'machine:
  kubelet:
    image: ghcr.io/siderolabs/kubelet:v1.35.7'
  KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
    kubectl wait --for=condition=Ready "node/${node}" --timeout=10m
  KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
    kubectl get node "${node}" -o wide
done
```

Expected: each target reports `Ready` with `v1.35.7` before the next kubelet patch. The loop does not include `k8s-5-1u`.

- [ ] **Step 6: Verify the completed intermediate state**

Run:

```bash
KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
kubectl get --raw='/readyz?verbose'
KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
kubectl get nodes -o wide
```

Expected: `k8s-1-nab9`, `k8s-2-ser`, `k8s-3-4u`, and `k8s-4-dell` show `v1.35.7`; `k8s-5-1u` remains `Ready` at `v1.36.2`.

### Task 3: Execute the standard cluster-wide v1.36.3 cutover

**Files:**
- Modify: `clusters/talos/bootstrap/os/talenv.yaml:4`
- Test: repository command and live cluster convergence checks

**Interfaces:**
- Consumes: successful Task 2 state with no node below `v1.35.7`
- Produces: all five nodes on Kubernetes `v1.36.3`

- [ ] **Step 1: Set the final declared target**

Change `clusters/talos/bootstrap/os/talenv.yaml`:

```yaml
kubernetesVersion: v1.36.3
```

Commit:

```bash
git add clusters/talos/bootstrap/os/talenv.yaml
git commit -m "chore: upgrade Kubernetes v1.36.3"
```

Expected: Git declares the final converged version before the repository task reads it.

- [ ] **Step 2: Preview the final all-node operation**

Run:

```bash
talosctl --talosconfig clusters/talos/bootstrap/os/clusterconfig/talosconfig \
  --nodes 10.30.30.21 upgrade-k8s --to v1.36.3 --dry-run
```

Expected: discovery includes all five nodes and contains no downgrade. In particular, `k8s-5-1u` must only transition from `v1.36.2` to `v1.36.3`.

- [ ] **Step 3: Run the repository's standard final upgrade**

Run:

```bash
task talos:upgrade-k8s
```

Expected: Talos pre-pulls images, updates control-plane components, reconciles bootstrap manifests, and upgrades kubelets on every node. If interrupted, rerun the same command; Talos resumes the documented upgrade workflow.

- [ ] **Step 4: Verify the final cluster state**

Run:

```bash
KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
kubectl get --raw='/readyz?verbose'
KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
kubectl get nodes -o wide
KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config \
kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded
```

Expected: API readiness succeeds; all five nodes are `Ready` at `v1.36.3`; no non-terminal pods remain outside `Running`.

- [ ] **Step 5: Clean temporary local upgrade output**

Run:

```bash
rm -f /tmp/talos-v1.35.7-manifests.yaml
```

Expected: only the explicit temporary bootstrap-manifest file is removed; retain the etcd snapshot from Task 1.

## References

- [Talos Kubernetes upgrade guide](https://docs.siderolabs.com/kubernetes-guides/advanced-guides/upgrading-kubernetes)
- [Talos CLI reference](https://docs.siderolabs.com/talos/v1.13/reference/cli)
- [Kubernetes version skew policy](https://kubernetes.io/releases/version-skew-policy/)
