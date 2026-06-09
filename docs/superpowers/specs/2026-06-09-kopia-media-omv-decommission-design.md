# Kopia + Media Migration off OMV — Design

Date: 2026-06-09
Status: Approved (pending final spec review)

## Goal

Fully decommission the OMV NAS (`omv-baymx`) by relocating the two bulk data sets it
currently serves — the **media library (2.9 TB)** and the **kopia backup repository
(68 GB)** — onto Talos node local disks, with **no dependency on Ceph** for either data
set. Provide **cross-node failover for Jellyfin** (media serving) using local-disk
replication, and preserve **backup independence** for kopia (the backup target must not
live on the storage it protects).

## Why not Ceph (rejected)

Putting these data sets on Ceph was explicitly rejected for two correct reasons:

1. **Circular dependency (kopia):** Kopia is the VolSync backup *target* for Ceph-backed
   app PVCs. Hosting the kopia repo on Ceph means a Ceph failure destroys both the data
   and its backups simultaneously. Backups must live on storage independent of what they
   protect.
2. **Performance + waste (media):** Ceph uses 3× replication (2.9 TB media → ~8.7 TB raw)
   and mixing HDD/NVMe OSDs into one pool drags large sequential media reads to HDD speed
   plus network/replication overhead. The dedicated bulk disks exist for raw local-XFS
   speed.

Ceph remains reserved for small app-config PVCs only.

## Storage layer decision (researched)

For the media library's failover requirement, the workload profile is:
single writer (the *arr stack), read-mostly consumer (Jellyfin), large **immutable**
media files, two bulk-storage nodes, priority on native local-XFS read performance and
minimal operational burden, explicitly **not Ceph**.

Evaluated: Longhorn (2-replica `best-effort`), SeaweedFS CSI, OpenEBS
(Mayastor/LocalPV), in-cluster NFS, and one-way scheduled file replication.

**Chosen: one-way `rsync` replication (CronJob) between two `hostPath` local-XFS disks.**

Rationale:
- **Best read path:** Jellyfin reads raw local XFS on whichever node it lands on — no
  iSCSI, NVMe-TCP, FUSE, or storage engine in the data path. Nothing beats this for HDD
  media streaming.
- **Real failover:** Both nodes hold a full copy; a rescheduled pod reads the local copy.
- **No corruption risk:** Media files are immutable and there is a single writer, so
  one-way sync has no write-write conflict. The only cost is freshness lag (sync every
  ~15 min), which is harmless for a media library.
- **Lowest ops burden + Talos-clean:** No system extensions, no hugepages, no Longhorn
  `--preserve` upgrade footgun that could nuke a 3 TB replica, no separate distributed
  filesystem to operate. Survives Talos upgrades trivially (just files on a disk).

Longhorn (2-replica, `dataLocality: best-effort`) is the documented fallback if
synchronous (near-zero-lag) replication is later required, accepting its operational
costs. SeaweedFS, OpenEBS Mayastor (requires 3 nodes; we have 2), and in-cluster NFS
(SPOF + network reads) were rejected.

Access method for the disks: raw **`hostPath`** on Talos `UserVolumeConfig`-provisioned
XFS volumes, matching the existing `garage-s3` house style. No new CSI/provisioner.

## Target topology

Two bulk-storage Talos worker nodes:

| Node | Role | Bulk mounts |
|---|---|---|
| `k8s-4-dell` | primary / hot | `/var/mnt/media` (3.6 TB XFS, currently empty), `/var/mnt/downloads` (476 GB NVMe), `/var/mnt/kopia` (Phase 1 interim, new) |
| ex-OMV node (after rejoin) | standby / cold + backup target | `/var/mnt/media` (replica), `/var/mnt/kopia` (final home) |

Ex-OMV hardware brings 16 cores / 144 GB RAM and 4× 3.6 TB disks (sda + sdd/sde/sdf),
ample for a media replica and the kopia repo.

## Current state (verified)

- Kopia backend: `filesystem:///repository`, repo mounted at `/repository`.
  - Talos: `nfs` from `omv-baymx.a113.internal:/storage0/VolsyncKopia`
    (`clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml`,
    `cronjob-patch.yaml`).
  - VolSync movers get the `repository` volume injected via
    `clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml`
    (currently NFS to OMV).
- Media-consuming apps mounting OMV at `/nfs-nas-pvc`:
  - `nfs` to `omv-baymx:/storage0/media`: `sonarr`, `radarr`, `bazarr`,
    `qbittorrent` (downloads ns), `sabnzbd` (downloads ns).
  - `hostPath` to OMV local disk: `jellyfin`.
  - `audiobookshelf`, `paperless-ngx` also use NFS (different paths — verify scope
    during planning; out of scope unless they reference `/storage0/media`).
- Sizes: media **2.9 TB**, kopia repo **68 GB** (`du` on OMV).
- Dell `/var/mnt/media` = `/dev/sdc1`, 3.6 TB, 2% used (ready).

## Design — Phase 1 (immediate: decommission OMV)

Done **before** the OMV hardware rejoins as a Talos node. OMV is powered off at the end
of this phase.

1. **Provision dell kopia volume.** Add a Talos `UserVolumeConfig` named `kopia` on
   `k8s-4-dell` (small, e.g. 100 GB) → mounts at `/var/mnt/kopia`. (Media volume already
   exists at `/var/mnt/media`.)
2. **Copy data off OMV** (one-time, manual/scripted; not GitOps):
   - `omv:/storage0/media` → dell `/var/mnt/media` (2.9 TB).
   - `omv:/storage0/VolsyncKopia` → dell `/var/mnt/kopia` (68 GB).
   - Verify integrity (checksums / `rsync --checksum` final pass).
3. **Repoint kopia repo to dell hostPath, pinned to `k8s-4-dell`:**
   - `kopia/deployment-patch.yaml`, `kopia/cronjob-patch.yaml`: `nfs` → `hostPath`
     `/var/mnt/kopia` + `nodeSelector` to `k8s-4-dell`.
   - `volsync/mutatingadmissionpolicy.yaml`: repository volume `nfs` → `hostPath`
     `/var/mnt/kopia`, and add a mover `nodeSelector`/affinity to `k8s-4-dell` (movers
     must run where the repo disk is).
   - `repository.config` / kopia ExternalSecret unchanged (still
     `filesystem:///repository`).
4. **Repoint media apps to dell hostPath, pinned to `k8s-4-dell`:**
   - `jellyfin`, `sonarr`, `radarr`, `bazarr`, `qbittorrent`, `sabnzbd`: media volume →
     `hostPath` `/var/mnt/media` (mount path `/nfs-nas-pvc` unchanged to avoid app
     reconfig) + `nodeAffinity`/`nodeSelector` to `k8s-4-dell`.
   - `qbittorrent`/`sabnzbd` downloads target → dell `/var/mnt/downloads` where
     applicable.
5. **Validate:** apps healthy, libraries visible, a VolSync backup + restore round-trip
   succeeds against the dell-local kopia repo.
6. **Decommission OMV:** remove remaining OMV ArgoCD apps, power off `omv-baymx`.

End of Phase 1: zero runtime dependency on OMV. Jellyfin and kopia are **pinned** to
`k8s-4-dell` (no failover yet).

## Design — Phase 2 (after ex-OMV rejoins as a Talos node)

1. **Wipe + join ex-OMV hardware as a Talos worker node.** (Talos install — separate
   from this spec's app changes; produces a node, e.g. `k8s-6-omv`.)
2. **Provision ex-OMV bulk volumes** via Talos `UserVolumeConfig`:
   - `media` → `/var/mnt/media` (≥3 TB) for the replica.
   - `kopia` → `/var/mnt/kopia` for the final backup-repo home.
3. **Relocate kopia repo to the ex-OMV node** (restore backup independence — repo now on
   a different physical node than the Ceph OSDs and the primary apps):
   - One-time copy dell `/var/mnt/kopia` → ex-OMV `/var/mnt/kopia`.
   - Update kopia patches + `mutatingadmissionpolicy.yaml` `nodeSelector`/hostPath to the
     ex-OMV node.
   - Decommission the dell `/var/mnt/kopia` interim volume.
4. **Establish media replication (dell → ex-OMV):**
   - New GitOps component: a **media-sync `CronJob`** running one-way
     `rsync -a --delete` from dell `/var/mnt/media` to ex-OMV `/var/mnt/media` every
     ~15 min (interval tunable). Implemented as a standard
     `components/<ns>/media-sync/` app (CronJob + hostPath mounts on both nodes, or a
     push from a pod pinned to dell over SSH/`rsyncd`). Mechanism detail finalized in the
     plan.
5. **Enable Jellyfin failover:**
   - Change Jellyfin `nodeAffinity` from "pinned to dell" → "prefer dell, allow ex-OMV"
     so it can reschedule to the standby and read the local replica.
   - The *arr stack and downloaders **stay pinned to dell** (single writer keeps sync
     one-way and conflict-free).
6. **Validate failover:** cordon/drain dell; confirm Jellyfin reschedules to the ex-OMV
   node and serves media from the local replica.

## Kopia failover stance (explicit)

Kopia repo is **pinned** to a single node (dell in Phase 1, ex-OMV in Phase 2) — not
replicated. Backups run every 6 h and are non-urgent; if the backup node is down, backups
pause and resume on recovery. Replicating the backup target was rejected as unnecessary
complexity. Backup *independence* (the real requirement) is satisfied by keeping the repo
on a different physical node than the Ceph OSDs it protects (achieved in Phase 2).

## Files to change

Phase 1:
- New: ex-`k8s-4-dell` Talos `UserVolumeConfig` for `kopia`
  (`clusters/talos/bootstrap/os/patches/k8s-4-dell/...`).
- `clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml` — nfs → hostPath +
  nodeSelector.
- `clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml` — same.
- `clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml` — repository
  volume nfs → hostPath + mover nodeSelector.
- `components/default/jellyfin/values.yaml` — hostPath → dell `/var/mnt/media` +
  nodeAffinity.
- `components/default/{sonarr,radarr,bazarr}/values.yaml` — nfs → dell hostPath +
  nodeAffinity.
- `components/downloads/{qbittorrent,sabnzbd}/values.yaml` — nfs → dell hostPath +
  nodeAffinity.
- OMV app removal in `clusters/omv/...` (final decommission).

Phase 2:
- New: ex-OMV node Talos config + `UserVolumeConfig` (media, kopia).
- New: `components/<ns>/media-sync/` rsync CronJob component + cluster registration.
- Kopia patches + `mutatingadmissionpolicy.yaml` — relocate nodeSelector/hostPath to
  ex-OMV node.
- `components/default/jellyfin/values.yaml` — relax nodeAffinity to allow failover.

## Out of scope / to verify during planning

- `audiobookshelf`, `paperless-ngx` NFS paths (only in scope if they reference
  `/storage0/media`).
- The exact one-time data-copy procedure (manual runbook, not GitOps).
- The precise rsync push/pull mechanism (SSH vs in-cluster `rsyncd` vs shared scheduling)
  — decided in the implementation plan.
- Garage-S3 disk topology discrepancy (values pin `k8s-5-1u`, but `garage-hdd*` mounts
  observed on `k8s-4-dell`) — noted, not in scope.

## Success criteria

- OMV (`omv-baymx`) powered off with zero cluster runtime dependency on it (end Phase 1).
- Media + kopia data on Talos local disks; neither on Ceph.
- VolSync backup + restore round-trip succeeds against the local kopia repo.
- (Phase 2) Jellyfin reschedules to the standby node on primary-node drain and serves
  media from the local replica; kopia repo resides on a node independent of Ceph OSDs.
