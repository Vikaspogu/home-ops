# Gitea Runner Burst Pool Design

## Goal

Allow up to four trusted Gitea Actions jobs to run concurrently without sharing runner registration state or Docker daemon state between runner deployments.

## Scope

- Raise the existing `gitea-runner` capacity from one to two jobs.
- Add a second long-lived `gitea-runner-burst` deployment with capacity one for the initial rollout.
- Give the burst deployment its own VolSync-managed runner-data PVC and its own Docker-data PVC.
- Register the new component as an ArgoCD application at sync wave 20.
- Add a rendered-manifest regression test covering both pools.

## Non-goals

- Queue-driven autoscaling.
- Ephemeral per-job runners.
- Webhook receivers, custom controllers, KEDA, or new RBAC.
- Public ingress, new external secrets, or new Gitea registration tokens.
- Changes to Gitea Actions workflow files.

## Architecture

`gitea-runner` and `gitea-runner-burst` are independent, long-lived Gitea `act_runner` deployments. Both use the existing Gitea registration token and advertise the existing Ubuntu labels, allowing Gitea to dispatch matching work to either free capacity slot.

Each deployment owns two storage domains:

| Deployment | Runner data | Docker data |
| --- | --- | --- |
| `gitea-runner` | `gitea-runner` | `gitea-runner-docker` |
| `gitea-runner-burst` | `gitea-runner-burst` | `gitea-runner-burst-docker` |

The runner-data PVC is created by the existing VolSync component from `${ARGOCD_APP_NAME}`. The Docker-data PVC is explicit because Docker state is not replicated by VolSync.

## Capacity rollout

The existing runner immediately moves to `runner.capacity: 2`. The burst deployment begins at `runner.capacity: 1`; the staged deployment therefore provides three concurrent jobs. After observed validation with representative builds, change the burst capacity to two for a four-job steady-state maximum.

This staging is intentionally different from the final four-slot target. Two independent privileged Docker daemons with concurrent workloads can increase memory, CPU, image-layer, and node-pressure demand. The first production rollout must establish a safe measured baseline.

## Security and isolation

The existing Docker-in-Docker daemon is privileged. This design preserves its current trusted-project model and does not make it appropriate for untrusted pull requests. It improves fault isolation by ensuring the two daemons never mount the same `/var/lib/docker` claim and the runners never share a `.runner` registration file.

No new Kubernetes permissions, endpoint, or plaintext secret are introduced. The burst component receives its own ExternalSecret target backed by the existing concealed `RUNNER_TOKEN` in the `gitea` 1Password item. Gitea supports a registration token registering multiple runners until it is reset.

## Verification

A focused rendered-manifest test must prove:

1. The baseline config map has capacity two.
2. The burst config map has capacity one for the staged rollout.
3. The burst deployment mounts `gitea-runner-burst` and `gitea-runner-burst-docker` only.
4. The burst component renders a Deployment, its Docker PVC, and its VolSync runner-data PVC.
5. `clusters/talos/apps/20-applications.yaml` registers the burst application with the existing Ceph/VolSync settings at sync wave 20.

Run the focused test, repository kubeconform validation, and pre-commit hooks before opening the merge request.

The initial staged pool capacity is three concurrent jobs.

```bash
bash scripts/test-gitea-runner-pool-rendered-manifest.sh
bash scripts/kubeconform.sh
pre-commit run --all-files
```
