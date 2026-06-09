# Handoff — Kopia + Media OMV Decommission

Date: 2026-06-09
Status: **Design APPROVED, spec committed. Next step: write implementation plan (Phase 1).**

## TL;DR for the next session

The user wants to fully decommission the OMV NAS (`omv-baymx`) by moving its two bulk
data sets — **media library (2.9 TB)** and **kopia backup repo (68 GB)** — onto Talos
node **local disks (hostPath)**, explicitly **NOT Ceph**. A design spec is written,
reviewed, and committed. The next action is to invoke the **writing-plans** skill to
produce the Phase 1 implementation plan (after the user approves the spec, if they
haven't already).

**Do NOT re-brainstorm.** The design is settled. Read the spec, then write the plan.

## Authoritative documents

- **Design spec (source of truth):**
  `docs/superpowers/specs/2026-06-09-kopia-media-omv-decommission-design.md`
  (committed as `bd144f98`)
- This handoff: `docs/superpowers/handoff-2026-06-09-kopia-media-omv-decommission.md`
- Prior related work (gitea migration, same session):
  `docs/superpowers/handoff-2026-06-09-gitea-migration.md`

## Approved decisions (do not relitigate)

1. **OMV end state:** full decommission → hardware later rejoins as a Talos node.
2. **No Ceph for media or kopia.** Reasons the user gave (both correct):
   - Kopia on Ceph = circular dependency (kopia is the VolSync backup *target* for
     Ceph PVCs; can't store backups on the thing they back up).
   - Media on Ceph = 3× replication waste (~8.7 TB raw) + HDD/network performance hit.
   - Ceph stays reserved for small app-config PVCs only.
3. **Storage layer = raw `hostPath` on Talos `UserVolumeConfig` XFS disks** (matches the
   existing `garage-s3` house style). No new CSI/provisioner.
4. **Media failover mechanism = one-way `rsync` CronJob replication** between two
   local-XFS nodes. Chosen over Longhorn/SeaweedFS/OpenEBS/NFS because the workload is
   single-writer (arr stack) + read-mostly (Jellyfin) + immutable files → one-way sync is
   the best fit, fastest reads (raw local XFS, no engine in path), lowest ops, Talos-clean
   (no `--preserve` footgun). Longhorn 2-replica `best-effort` is the documented fallback
   if synchronous replication is ever needed.
5. **Failover-critical apps:** Jellyfin (media serving) + Kopia repo independence. The
   *arr stack + downloaders stay **pinned** (single writer keeps sync conflict-free).
6. **Kopia is pinned, not replicated.** Independence (not HA) is the requirement — satisfied
   by living on a node separate from the Ceph OSDs (achieved in Phase 2).
7. **Two phases:**
   - **Phase 1 (now):** copy data → dell local disks, repoint all apps pinned to
     `k8s-4-dell`, power off OMV. Kopia interim home = dell `/var/mnt/kopia`.
   - **Phase 2 (after ex-OMV rejoins as Talos node):** relocate kopia repo to ex-OMV node,
     add rsync media replication dell → ex-OMV, relax Jellyfin affinity for failover.

## Verified facts (from investigation)

| Fact | Value | Source |
|---|---|---|
| Media library size | 2.9 TB | `du` on OMV |
| Kopia repo size | 68 GB | `du` on OMV |
| Dell `/var/mnt/media` | `/dev/sdc1`, 3.6 TB, 2% used (empty, ready) | node debug |
| Dell `/var/mnt/downloads` | 476 GB NVMe | node debug |
| Ceph | 3 OSDs, ~2.5 TB avail, 3× replicated, failureDomain host | cephcluster |
| Ex-OMV future disks | sda 3.6TB + 3× 3.6TB unused (sdd/sde/sdf), 16 cores, 144 GB RAM | `lsblk` on OMV |
| Kopia backend | `filesystem:///repository` (NOT S3) | repository.config + ExternalSecret |

## Current architecture (what exists today)

- **Kopia repo** mounted at `/repository`:
  - Talos: `nfs` from `omv-baymx.a113.internal:/storage0/VolsyncKopia`
    - `clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml`
    - `clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml`
  - VolSync movers get the `repository` volume injected via a MutatingAdmissionPolicy:
    - `clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml`
      (currently NFS to OMV)
- **Media apps** mount OMV at container path `/nfs-nas-pvc`:
  - `nfs` → `omv-baymx:/storage0/media`: `sonarr`, `radarr`, `bazarr`,
    `qbittorrent` (downloads ns), `sabnzbd` (downloads ns)
  - `hostPath` → OMV local disk: `jellyfin`
  - `audiobookshelf`, `paperless-ngx` also use NFS — **VERIFY** whether they reference
    `/storage0/media` (only in scope if so).

## Phase 1 plan outline (what the implementation plan must cover)

1. New Talos `UserVolumeConfig` `kopia` on `k8s-4-dell` (~100 GB) → `/var/mnt/kopia`
   (`clusters/talos/bootstrap/os/patches/k8s-4-dell/...`). Media volume already exists.
2. One-time data copy (manual runbook, NOT GitOps):
   - `omv:/storage0/media` → dell `/var/mnt/media` (2.9 TB)
   - `omv:/storage0/VolsyncKopia` → dell `/var/mnt/kopia` (68 GB)
   - Integrity verification (`rsync --checksum` final pass).
3. Repoint kopia → dell hostPath `/var/mnt/kopia`, pinned to `k8s-4-dell`:
   - kopia `deployment-patch.yaml` + `cronjob-patch.yaml`: nfs → hostPath + nodeSelector
   - `mutatingadmissionpolicy.yaml`: repository volume nfs → hostPath + mover nodeSelector
   - `repository.config` / kopia ExternalSecret unchanged (still `filesystem:///repository`)
4. Repoint media apps → dell hostPath `/var/mnt/media`, pinned to `k8s-4-dell`:
   - keep mount path `/nfs-nas-pvc` unchanged to avoid app reconfig
   - jellyfin, sonarr, radarr, bazarr, qbittorrent, sabnzbd
   - downloads → dell `/var/mnt/downloads` where applicable
5. Validate: apps healthy, libraries visible, VolSync backup+restore round-trip against
   dell-local kopia repo.
6. Decommission OMV: remove OMV ArgoCD apps, power off `omv-baymx`.

## Phase 2 plan outline (defer until ex-OMV is a Talos node)

1. Wipe + join ex-OMV hardware as Talos worker (e.g. `k8s-6-omv`).
2. `UserVolumeConfig` on ex-OMV: `media` (≥3 TB), `kopia`.
3. Relocate kopia repo dell → ex-OMV node (restores Ceph independence); decommission dell
   `/var/mnt/kopia` interim volume.
4. New GitOps component `components/<ns>/media-sync/`: one-way `rsync -a --delete`
   CronJob dell `/var/mnt/media` → ex-OMV `/var/mnt/media`, ~15 min (mechanism — SSH vs
   in-cluster rsyncd — decided in plan).
5. Relax Jellyfin nodeAffinity: prefer dell, allow ex-OMV (failover). arr stack stays
   pinned to dell.
6. Validate failover: drain dell, confirm Jellyfin reschedules to ex-OMV and serves from
   local replica.

## Open items to resolve during planning

- Verify audiobookshelf/paperless NFS paths (scope only if `/storage0/media`).
- Exact one-time data-copy runbook (manual).
- Precise rsync push/pull mechanism (SSH vs in-cluster `rsyncd` vs shared scheduling).
- Garage-S3 topology note: values pin `k8s-5-1u` but `garage-hdd*` mounts were observed
  on `k8s-4-dell` — flagged, NOT in scope for this work.

## Environment / access

- User: `vikaspogu`
- Talos kubeconfig: `/Users/vikaspogu/.kube/configs/talos-cluster-config`
  (note: `~` does not expand in this shell — use the absolute path)
- OMV kubeconfig: `/Users/vikaspogu/.kube/configs/omv-cluster-config`
- OMV SSH: `ssh root@10.30.30.54`
- Repo: `/Users/vikaspogu/Documents/git-repos/home-ops`
- Cluster domain: `a113.casa`
- Repo conventions: see `AGENTS.md` (bjw-s app-template, Gateway API HTTPRoute,
  ExternalSecrets + 1Password, VolSync, ArgoCD sync-waves, hostPath via Talos
  UserVolumeConfig).

## Next session: exact first actions

1. Read the spec: `docs/superpowers/specs/2026-06-09-kopia-media-omv-decommission-design.md`.
2. If the user hasn't explicitly approved the spec yet, ask them to confirm before planning.
3. Invoke the **writing-plans** skill to produce the **Phase 1** implementation plan
   (Phase 2 is gated on the ex-OMV node existing — plan it later or as a separate doc).
4. Do not start editing manifests until the plan is written and approved.
