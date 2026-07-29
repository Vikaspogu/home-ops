# Synology backup removal implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:executing-plans`.

**Goal:** Remove the Synology photo backup workload from GitOps and the cluster.

**Architecture:** The application registration is the Argo CD ownership boundary. Removing that entry and its component makes Argo prune the component-created CronJob, ExternalSecret, and generated Secret.

**Tech stack:** Argo CD, Kustomize, Kubernetes CronJob, External Secrets Operator.

## Global constraints

- Do not modify the 1Password source item.
- Do not modify Synology data, Garage buckets, or unrelated backup workloads.
- Verify `default/synology-backup` and Argo `Application/synology-photos-backup` are absent after reconciliation.

---

### Task 1: Remove the Synology backup application

**Files:**

- Modify: `clusters/talos/apps/20-applications.yaml:525-531`
- Delete: `components/default/synology-photos-backup/kustomization.yaml`
- Delete: `components/default/synology-photos-backup/cronjob.yaml`
- Delete: `components/default/synology-photos-backup/externalsecret.yaml`

**Interfaces:**

- Consumes: Argo application-set source map in `clusters/talos/apps/20-applications.yaml`.
- Produces: No Argo ownership path for the Synology backup component.

- [ ] **Step 1: Remove the application map entry**

Delete the `synology-photos-backup:` map entry, including its sync-wave, destination namespace, and source path. Keep adjacent `trek` and `switchbotmqtt` entries unchanged.

- [ ] **Step 2: Delete the component directory**

Delete only `kustomization.yaml`, `cronjob.yaml`, and `externalsecret.yaml` under `components/default/synology-photos-backup/`. This leaves no manifest that can recreate `default/synology-backup`.

- [ ] **Step 3: Validate the GitOps source**

Run:

```sh
! grep -R "synology-photos-backup" components clusters
```

Expected: no application or component reference remains.

- [ ] **Step 4: Verify cluster pruning**

Run:

```sh
kubectl -n argo-system get application synology-photos-backup
kubectl -n default get cronjob synology-backup
kubectl -n default get externalsecret synology-photos-backup
```

Expected: each command returns `NotFound` after Argo CD reconciles.
