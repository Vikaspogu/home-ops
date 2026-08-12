# KubeVirt + ARC Enablement Plan

**Status:** Draft — no deployment work starts without approval of each rollout gate.

## Goal

Run GitHub Actions jobs in ephemeral KubeVirt VMs using Actions Runner Controller
(ARC), without privileged Docker-in-Docker runners.

## Preconditions

- Cilium has reconciled the committed `bpf.datapathMode: veth` change and cluster
  networking is healthy.
- KubeVirt **v1.9.0** is used; it is built for Kubernetes v1.36.
- `k8s-5-1u` is the first and only KubeVirt worker. Do not use `k8s-4-dell`
  until the canary is stable, due to the historical VMX/microcode reboot incident.
- Existing KubeVirt v1.4/CDI manifests and residual CRDs are reviewed before
  upgrading them. Select a CDI release supported by KubeVirt v1.9 from its
  release documentation; do not retain the old v1.65.0 pin by assumption.

## Phase 1 — KubeVirt canary

1. Confirm Cilium agent rollout and application connectivity after the veth
   change. Stop and roll back Cilium if networking is degraded.
2. Update `components/kubevirt/operator/` to KubeVirt v1.9.0 and its matching
   release manifests. Update CDI to the verified compatible release.
3. Re-enable the two existing ArgoCD applications in
   `clusters/talos/apps/30-system.yaml`.
4. Add KubeVirt workload placement so `virt-handler` and VM workloads schedule
   only on the explicitly labelled `k8s-5-1u` canary worker. Keep KubeVirt
   control-plane components away from workload nodes where practical.
5. Let ArgoCD reconcile. Require `KubeVirt.status.phase=Deployed`, CDI
   `status.phase=Deployed`, and no degraded KubeVirt components.
6. Apply a disposable, Git-tracked or explicitly temporary VM with:
   - pod networking;
   - a fixed non-conflicting MAC address;
   - KVM requested;
   - no persistent disk and no LiveMigration.
7. Verify boot, DNS and egress, service connectivity, clean shutdown/deletion,
   and KubeVirt/Cilium events. Observe `k8s-5-1u` for stability under the VM
   workload before continuing.

**Rollback:** disable the two ArgoCD applications through Git. Confirm VMIs and
KubeVirt pods are removed; retain PVCs if any were later created.

## Phase 2 — ARC foundation

1. Create `actions-runner-system` manifests using the official ARC controller
   and a pinned chart version. Register it as a separate ArgoCD application.
2. Create a GitHub App for the intended GitHub organization or repositories.
   Store its app ID, installation ID, and private key in 1Password; project
   them only through an `ExternalSecret`. Do not use a PAT in Git.
3. Deploy ARC controller only. Verify controller health, GitHub authentication,
   and no runner pods before adding a runner scale set.
4. Grant a dedicated runner ServiceAccount only the namespace-scoped permissions
   needed to read the VM template and create/watch/delete VMIs and DataVolumes.
   Keep CDI clone-source permission as narrow as the upstream runner requires.

**Rollback:** remove the ARC application and its runner namespace through Git;
revoke the GitHub App installation if the proof of concept is abandoned.

## Phase 3 — one VM-backed GitHub runner

1. Build a minimal, pinned Ubuntu runner VM image with the GitHub Actions runner
   preregistered only through ARC JIT configuration. Store its base disk on
   `ceph-block`.
2. Create one golden `VirtualMachine` template in a dedicated template namespace:
   small CPU/memory limits, fixed MAC, pod network, `runStrategy: Manual`, and
   read-only base image/clone semantics.
3. Deploy one ARC runner scale set using a pinned
   `electrocucaracha/kubevirt-actions-runner` image digest. Set `minRunners: 0`,
   `maxRunners: 1`, explicit wait/cleanup timeouts, and the dedicated ServiceAccount.
4. Trigger a harmless GitHub workflow. Verify the lifecycle:
   ARC pod → VMI → job → VMI deletion → runner cleanup.
5. Confirm the workflow has no privileged container, no host device mounts, and
   no plaintext GitHub credentials.

**Rollback:** set the scale set maximum to zero, wait for the active job to
finish or cancel it in GitHub, then remove the runner scale-set application.

## Phase 4 — acceptance and expansion

1. Run representative container-build and VM-required GitHub workflows.
2. Confirm failed jobs also remove VMIs/DataVolumes within the configured cleanup
   timeout.
3. Measure boot time, job duration, CPU, memory, and Ceph I/O. Keep concurrency
   at one until capacity and cleanup behavior are demonstrated.
4. Monitor `k8s-5-1u` for a defined stability window. Only then decide whether
   to label `k8s-4-dell` as an additional KubeVirt worker and raise runner
   concurrency.
5. Document runbook commands, alerting, upgrade/rollback procedure, and the
   KubeVirt/ARC version pins.

## Success criteria

- Cilium veth networking remains healthy.
- KubeVirt v1.9.0 and compatible CDI are `Deployed` on Kubernetes v1.36.3.
- A canary VM boots and cleans up without node instability.
- ARC creates exactly one ephemeral VMI-backed GitHub runner job.
- No runner or VM workload requires privileged Docker-in-Docker.
- Failed and successful jobs leave no orphaned VMIs, pods, or DataVolumes.
