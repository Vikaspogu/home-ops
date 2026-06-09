# Design: Migrate Gitea (+ runner) from OMV → Talos, reusing the shared VolSync/Kopia backend

**Date:** 2026-06-09
**Status:** Approved (design phase)
**Related handoff:** `docs/superpowers/handoff-2026-06-09-omv-garage-cutover.md`

---

## Goal

Move `gitea` and `gitea-runner` from the OMV (K3s) cluster to the Talos cluster,
reusing the **same VolSync backend** for the gitea PVC, and relocating gitea's
Postgres database from `pg17-omv` into the Talos `postgres17` CNPG cluster.

This decouples gitea from `pg17-omv` (whose Garage S3 backup endpoint is currently
broken per the related handoff) without depending on that broken S3 path.

---

## Architecture overview

Gitea has **two stateful layers**, migrated by two different mechanisms, plus a
runner with disposable state.

| Layer | Source (OMV) | Target (Talos) | Method |
|---|---|---|---|
| Postgres `gitea` DB (~93 MB) | `pg17-omv` (Garage S3 backups) | `postgres17` (Garage S3, in-cluster) | `pg_dump -Fc` → `pg_restore` |
| Gitea PVC `/var/lib/gitea` (repos, config, Actions) | Longhorn PVC, VolSync→Kopia | ceph-block PVC, VolSync→Kopia | VolSync `ReplicationDestination` restore from the **shared** Kopia repo |
| Runner PVCs (`gitea-runner`, `gitea-runner-docker`) | Longhorn (disposable cache) | ceph-block (fresh) | No restore — recreate empty |

### Key enabler: the VolSync backend is already shared (no new backend)

Both clusters' Kopia movers write to the **same physical Kopia repository**:

- Backend: OMV NFS export `omv-baymx.a113.internal:/storage0/VolsyncKopia`.
- OMV mounts it via `hostPath`
  (`/srv/dev-disk-by-uuid-.../storage0/VolsyncKopia`).
- Talos mounts the identical directory via NFS, injected into every mover Job by
  the `volsync-mover` `MutatingAdmissionPolicy`
  (`clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml`,
  `server: omv-baymx.a113.internal`, `path: /storage0/VolsyncKopia`).
- Repository config (`components/volsync-system/kopia/config/repository.config`):
  `filesystem` storage at `/repository`, Kopia identity
  hostname/username = `volsync` (shared across both clusters).
- `KOPIA_REPOSITORY: filesystem:///repository` and `KOPIA_FS_PATH: /repository`
  from `components/volsync-system/volsync-replication/external-secret.yaml`.

Because the repository and Kopia identity are shared, a Talos
`ReplicationDestination` with `sourceIdentity.sourceName: gitea` reads the
snapshot OMV created for gitea — the literal same backend. No backend migration,
no rclone copy, no new bucket.

---

## In-repo changes

### 1. `components/default/gitea/external-secret.yaml` — repoint DB host

Change the database host from the OMV cluster to the Talos cluster:

- `INIT_POSTGRES_HOST`: `pg17-omv-rw.default.svc.cluster.local`
  → `postgres17-rw.default.svc.cluster.local`
- `GITEA__database__HOST`: `pg17-omv-rw.default.svc.cluster.local:5432`
  → `postgres17-rw.default.svc.cluster.local:5432`

The `postgres-init` initContainer (already present in `values.yaml`) creates the
`gitea` role and database on `postgres17` using `INIT_POSTGRES_SUPER_PASS`, the
same as it does today against `pg17-omv`. No other secret keys change; credentials
come from the same 1Password items (`gitea`, `cloudnative-pg`).

### 2. `components/default/gitea/values.yaml` — no change required

- The `ssh` service is `type: LoadBalancer` on port 2222. On Talos this allocates
  a Cilium L2-announced VIP (works within the Talos L2 segment). See Open Items.
- `persistence.config.existingClaim: gitea` is unchanged; the PVC is provisioned
  via the `volsync-replication` component using the Talos storage class.

### 3. `components/default/gitea/http-route.yaml` / `http-route-pages.yaml` — no change

Both use `${GATEWAY_NAME}` / `${GATEWAY_NAMESPACE}` / `${CLUSTER_DOMAIN}`
substitutions and are cluster-agnostic.

### 4. `components/default/gitea-runner/*` — no manifest change required

- DB-independent (registers to gitea via `RUNNER_TOKEN` from the 1Password `gitea`
  item).
- PVCs `gitea-runner` (`/data`) and `gitea-runner-docker` (`/var/lib/docker`) hold
  only caches and are recreated empty on Talos.

### 5. `clusters/talos/apps/20-applications.yaml` — add both apps (sync-wave "20")

`gitea` entry mirrors the current OMV registration but with Talos storage classes
and the VolSync restore `ignoreDifferences` block:

```yaml
  gitea:
    annotations:
      argocd.argoproj.io/sync-wave: "20"
    ignoreDifferences:
      - group: ""
        kind: PersistentVolumeClaim
        name: gitea
        jsonPointers:
          - /spec/dataSource
          - /spec/dataSourceRef
    destination:
      namespace: default
    source:
      path: components/default/gitea
      plugin:
        env:
          - name: STORAGE_CLASS
            value: ceph-block
          - name: VOLUME_SNAPSHOT_CLASS
            value: csi-ceph-blockpool
          - name: VOLSYNC_CAPACITY
            value: 20Gi
          - name: VOLSYNC_CACHE_CAPACITY
            value: 30Gi
          - name: VOLSYNC_SCHEDULE
            value: "20 */6 * * *"
```

`gitea-runner` entry:

```yaml
  gitea-runner:
    annotations:
      argocd.argoproj.io/sync-wave: "20"
    destination:
      namespace: default
    source:
      path: components/default/gitea-runner
      plugin:
        env:
          - name: STORAGE_CLASS
            value: ceph-block
          - name: VOLUME_SNAPSHOT_CLASS
            value: csi-ceph-blockpool
```

> The current OMV `gitea-runner` registration
> (`clusters/omv/apps/20-applications.yaml` lines 87–99) sets only
> `STORAGE_CLASS=longhorn-volsync` and `VOLUME_SNAPSHOT_CLASS=longhorn` — no
> capacity/cache/schedule env. The Talos registration therefore only needs the two
> storage-class values swapped to `ceph-block` / `csi-ceph-blockpool`.

### 6. `clusters/omv/apps/20-applications.yaml` — remove both apps

Remove the `gitea` and `gitea-runner` entries so OMV ArgoCD prunes them **after**
the Talos cutover is verified.

---

## Runtime cutover sequence (operational — not in-repo)

Order matters; the in-repo changes are committed first, but Talos gitea must not
serve traffic until the DB and PVC are restored.

1. **Quiesce gitea on OMV** — scale the OMV gitea Deployment to 0 replicas to stop
   writes. Confirm no active connections to the `gitea` DB on `pg17-omv`.
2. **Dump the DB** — `pg_dump -Fc -d gitea` from `pg17-omv-1`, copy the dump out.
3. **Restore the DB into Talos** — ensure the `gitea` role/DB exist on `postgres17`
   (let gitea's `postgres-init` create them, or pre-create), then
   `pg_restore --no-owner --role=gitea -d gitea` into `postgres17-rw`.
4. **VolSync restore the gitea PVC on Talos** — confirm the latest OMV-created
   gitea Kopia snapshot timestamp, then trigger the Talos `ReplicationDestination`
   (`gitea-dst`, `trigger.manual: restore-once`) to populate the new ceph-block
   PVC from the shared repo.
5. **Sync Talos ArgoCD** — gitea starts on Talos against the restored PVC and the
   restored DB on `postgres17-rw`.
6. **Runner re-registration** — generate a fresh runner registration token in the
   migrated gitea (Admin → Actions → Runners), update the 1Password `gitea` item's
   `RUNNER_TOKEN`, let `gitea-runner` register. Runner PVCs start empty.
7. **Verify** (see below), then **remove** gitea/gitea-runner from OMV and let OMV
   ArgoCD prune.

---

## Verification

- Talos gitea pod `Running`; web UI reachable at `https://gitea.${CLUSTER_DOMAIN}`.
- A known repository's commit history and Actions runs are present (PVC restore OK).
- Login works and existing users/orgs are present (DB restore OK).
- `gitea-runner` shows `idle`/online in gitea Admin; a test Actions job succeeds.
- New VolSync ReplicationSource on Talos completes a snapshot to the shared Kopia
  repo (`gitea` source, hostname `volsync`) with 0 errors.
- Postgres backups: `postgres17` continues archiving to its in-cluster Garage S3
  (unaffected; gitea is just another DB in that cluster).

---

## Error handling / rollback

- The DB migration is **non-destructive** to OMV: `pg_dump` is a copy; `pg17-omv`
  and the OMV gitea PVC remain intact until explicitly pruned.
- Rollback: scale Talos gitea to 0, restore the gitea/gitea-runner entries in the
  OMV applications file, scale OMV gitea back up. OMV state is unchanged.
- Decommission of `pg17-omv` and the OMV gitea PVC happens **only after** the Talos
  instance is verified, keeping the broken OMV→Garage S3 backup path irrelevant to
  this migration (we use `pg_dump`, never that S3 endpoint).

---

## Open items (confirm during implementation)

- **SSH on Talos (port 2222):** gitea's `ssh` LoadBalancer currently rides OMV's
  real node IP (`10.30.30.54` via Klipper). On Talos it becomes a Cilium L2 VIP.
  Confirm the Talos LB pool is acceptable and that DNS / clients for
  `ssh.${CLUSTER_DOMAIN}` are updated to the new VIP. (Related handoff documents
  that Talos L2 VIPs are not reachable from the OMV L2 segment — relevant only if
  any SSH consumer lives on OMV.)
- **Runner registration token:** the old runner registration is bound to the
  previous instance state and is not expected to transfer; a fresh token is part
  of the cutover (step 6).

---

## Out of scope

- Orphaned `blinko` / `mac` / `memos` databases in `pg17-omv` (handled separately
  per the related handoff).
- The OMV `pg17-omv` Garage S3 backup endpoint fix (Option A/B in the handoff).
  This migration removes gitea's dependency on `pg17-omv` but does not itself fix
  or decommission that cluster.
