# Staged Kubernetes v1.34.6 to v1.36.3 Upgrade Design

## Goal

Bring the home-kubernetes control plane and all five nodes to Kubernetes `v1.36.3` without downgrading `k8s-5-1u`, which is already at `v1.36.2`.

## Baseline

- `k8s-1-nab9`, `k8s-2-ser`, `k8s-3-4u`, and `k8s-4-dell` run Kubernetes `v1.34.6`.
- `k8s-5-1u` runs Kubernetes `v1.36.2`.
- All nodes run Talos `v1.13.7`.
- The Kubernetes API readiness endpoint passed before the upgrade.
- The repository's declared final Kubernetes version is `v1.36.3` in `clusters/talos/bootstrap/os/talenv.yaml`.

Kubernetes requires kubelets not be newer than the API server. The existing `k8s-5-1u` skew is already unsupported. Downgrading it is also unsupported, so it remains untouched until the final patch upgrade.

## Selected approach

Use two sequential Kubernetes minor-version stages:

1. Targeted `v1.35.7` transition for the three control-plane nodes and `k8s-4-dell` only.
2. Cluster-wide `v1.36.3` transition, which advances `k8s-5-1u` from `v1.36.2` to `v1.36.3`.

The normal `task talos:upgrade-k8s` wrapper invokes `talosctl upgrade-k8s`. Talos discovers and updates every cluster member, so it cannot safely run for the `v1.35.7` stage: its dry-run discovered `k8s-5-1u` and would include it.

## Execution design

### Stage one: v1.35.7

Use the documented Talos manual Kubernetes component upgrade procedure to target only these nodes:

- Control plane: `10.30.30.21`, `10.30.30.22`, `10.30.30.23`
- Worker: `10.30.30.24`

Apply the `v1.35.7` component image changes in Talos' documented order:

1. Pre-pull Kubernetes images on the four target nodes.
2. Update `kube-apiserver`, then verify API health after each control-plane update.
3. Update `kube-controller-manager` and `kube-scheduler` on the control-plane nodes.
4. Update `kube-proxy`.
5. Update kubelets on the four target nodes one at a time, validating node readiness after every restart.
6. Reapply bootstrap manifests and prune only through the documented Talos workflow.

Do not alter Kubernetes component images, kubelet configuration, or node state on `10.30.30.25` during this stage.

### Stage two: v1.36.3

Set `kubernetesVersion: v1.36.3` in `clusters/talos/bootstrap/os/talenv.yaml` and run the repository's standard `task talos:upgrade-k8s` command. Talos then updates all five members, including the final `v1.36.2` to `v1.36.3` patch on `k8s-5-1u`.

## Validation and stop conditions

Before each stage and after each control-plane or kubelet change:

- Kubernetes API `/readyz?verbose` must pass.
- Every affected node must be `Ready` with the expected kubelet version.
- The three control-plane nodes must remain reachable and the API server must remain available.
- PodDisruptionBudgets must permit the planned single-node disruption.

Stop immediately if API readiness fails, a control-plane node does not recover, or a workload loses all available replicas. Diagnose and restore the current stage before proceeding. Do not advance the desired version or begin stage two until all stage-one targets report `v1.35.7` and `Ready`.

## Scope and non-goals

- This upgrades Kubernetes only; Talos remains `v1.13.7`.
- No application manifests, Helm charts, or cluster bootstrap ordering change.
- No Kubernetes downgrade is attempted.
- No new tooling or repository automation is introduced.

## References

- [Talos Kubernetes upgrade guide](https://docs.siderolabs.com/kubernetes-guides/advanced-guides/upgrading-kubernetes)
- [Kubernetes version skew policy](https://kubernetes.io/releases/version-skew-policy/)
