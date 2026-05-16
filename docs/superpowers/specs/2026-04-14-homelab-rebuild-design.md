# Homelab Architecture Rebuild — Design Spec

**Date:** 2026-04-14
**Last updated:** 2026-05-10
**Status:** Approved; amended with additive `k8s-4-dell` worker
**Goal:** Rebuild homelab for reliability, performance, simplification, and full IaC coverage

---

## Overview

Consolidate from 2 Kubernetes clusters (Talos + K3s/OMV) and 2 NAS solutions (Synology + OMV) into a single Talos cluster with Synology as primary NAS for non-media data and `k8s-4-dell` local disks for hot media. Eliminate OpenMediaVault and K3s over time. Everything rebuildable from code.

2026-05-08 amendment: the current execution path is additive. `k8s-3-pxm` remains in the cluster and is not removed from etcd in this session. The Dell tower was added as a new worker, `k8s-4-dell`, at `10.30.30.24`. The earlier plan to reuse the `k8s-4` name/IP for the Supermicro storage worker is deferred and must be re-planned with a new hostname/IP unless `k8s-4-dell` is intentionally renamed or removed later.

2026-05-10 amendment: media storage direction changed from Synology-primary to `k8s-4-dell` local-primary for performance. Synology remains the NAS and should be used as a backup/replica target for media after migration. `k8s-4-dell` uses Talos `UserVolumeConfig` documents for local media/download/transcode paths; one NVMe is reserved for a future Rook/Ceph OSD.

## Hardware

| Node | Hardware | Specs | Role |
|------|----------|-------|------|
| k8s-1-nab9 | Mini PC | Existing NVMe | Control Plane + Worker |
| k8s-2-ser | Mini PC | Existing NVMe | Control Plane + Worker |
| k8s-3-pxm | Proxmox VM | Existing Talos VM | Control Plane + Worker; kept in place |
| k8s-4-dell | Dell Tower | 56 cores, ~252Gi RAM detected, RTX 3060 LHR, GT 1030, multiple NVMe/HDD | Worker + GPU |
| Supermicro 4U | Deferred | 56 cores, 378GB RAM, 1TB NVMe (Kingston), 4x 3.64TB HDD, 500GB SSD | Future storage worker; needs new hostname/IP |
| Synology | 4-bay NAS | 4x HDD (~20TB usable, 14.6TB free), M.2 cache | Primary NAS for non-media data; media backup/replica |

### Target Decommissioning

- Proxmox-backed `k8s-3-pxm` — **not removed in the 2026-05-08 additive node session**
- Proxmox on Supermicro — deferred; wipe only after new hostname/IP and storage role are decided
- OpenMediaVault VM — wipe after data migrated
- K3s cluster on OMV — remove after cutover
- Velero — remove
- CloudStack — already deprecated
- Helmfile — replace by kustomize `--enable-helm` for bootstrap

## Cluster Topology

### Control Plane

- Current 3-member etcd quorum: `k8s-1-nab9`, `k8s-2-ser`, `k8s-3-pxm`
- VIP: 10.30.30.150 floats across control plane nodes
- `allowSchedulingOnControlPlanes: true` — all nodes run workloads
- `k8s-4-dell` is worker only (no etcd, no VIP)
- Replacing `k8s-3-pxm` with bare metal remains a separate future maintenance window

### Node Configuration (Talos)

All current Kubernetes nodes run Talos Linux. `k8s-3-pxm` remains a Proxmox VM; new physical nodes use per-node schematics via Image Factory:

| Node | Platform | Talos Extensions |
|------|----------|-----------------|
| k8s-1-nab9, k8s-2-ser | `metal` | `nfsrahead` |
| k8s-3-pxm | Proxmox VM | Existing Talos config |
| k8s-4-dell | `metal` | `nfsrahead`, `nonfree-kmod-nvidia-lts`, `nvidia-container-toolkit-lts` |
| Future Supermicro worker | `metal` | `nfsrahead` |

All nodes get `vhost_net` kernel module for KubeVirt.

`k8s-4-dell` Talos details:
- IP/MAC: `10.30.30.24`, `d8:9e:f3:3c:9b:81`
- Talos Image Factory schematic: `c1c8847e58bca7ae9584c3b209f21c50add404d9cb9466a1d4ea8be43a160b8a`
- Installer: `factory.talos.dev/installer/c1c8847e58bca7ae9584c3b209f21c50add404d9cb9466a1d4ea8be43a160b8a`
- ISO used: `https://factory.talos.dev/image/c1c8847e58bca7ae9584c3b209f21c50add404d9cb9466a1d4ea8be43a160b8a/v1.12.6/metal-amd64.iso`
- OS disk selector: model `CT500MX500SSD1`; do not use this disk for Ceph/Garage
- Required NVIDIA kernel modules: `nvidia`, `nvidia_uvm`, `nvidia_drm`, `nvidia_modeset`

### Scheduling Strategy

- GPU workloads → `k8s-4-dell`; pods should request `nvidia.com/gpu: 1`
- `k8s-4-dell` is currently untainted; decide separately whether to add `nvidia.com/gpu=present:PreferNoSchedule`
- Garage → deferred storage worker via `nodeSelector` after HDD mount plan is finalized
- FileBrowser → deferred storage worker via `nodeSelector` after HDD mount plan is finalized
- General workloads → spread across all current nodes
- Light workloads (DNS, monitoring, MQTT) prefer mini PCs
- Heavy workloads (databases, AI/ML) prefer Dell/future storage worker

### Failure Tolerance

| Scenario | Impact | Recovery |
|----------|--------|----------|
| Any single node | Cluster survives, Ceph rebuilds | Pods reschedule, self-healing |
| k8s-3-pxm | etcd member and workloads affected | Restore VM/node or use etcd recovery runbook |
| k8s-4-dell (GPU node) | GPU workloads down (Jellyfin, AI/ML) | Wait for node return |
| Future storage worker | Backups unavailable, Garage down | Live data unaffected |
| Both mini PCs | Quorum lost, full outage | Must recover 1 mini PC |
| Full cluster | Rebuild from IaC | talhelper + ArgoCD + Garage restores |

**Mitigation:** Put mini PCs on separate UPS/power circuits.

## Storage Architecture

### Three Storage Tiers

#### Tier 1: Block Storage (Rook-Ceph)

| Setting | Value |
|---------|-------|
| OSDs | Target 4; explicit devices only |
| MONs | 3 (pinned to control plane nodes) |
| Replication | size: 3, min_size: 2 |
| Failure domain | host |
| Storage class | `ceph-block` (default) |
| Compression | zstd (aggressive) |

OSD devices:
- k8s-1: `nvme0n1` (existing)
- k8s-2: `nvme0n1` (existing)
- k8s-3-pxm: existing OSD configuration remains unchanged
- k8s-4-dell: reserve `nvme0n1` / Kingston `SNV3S1000G` 1TB NVMe for a future Rook/Ceph OSD after media migration; do not allocate it as a Talos user volume
- Future storage worker: assign explicit OSD disk after hostname/IP is re-planned

Config: `useAllNodes: false`, explicit per-node device list.

`k8s-4-dell` disks observed during Talos maintenance:
- `sdb`: Crucial `CT500MX500SSD1` 500GB SSD — Talos OS disk
- `nvme0n1`: Kingston `SNV3S1000G` 1TB NVMe
- `nvme1n1`: Kingston `OM8PGP4512Q-A0` 512GB NVMe
- `nvme2n1`: Samsung `SSD 970 EVO` 250GB NVMe
- `sdc`: MARSHAL `MAL38000` 8TB HDD — bad SMART data; exclude from primary storage
- `sdd`: WDC `WD40EZAZ-00S` 4TB HDD — healthy enough for read-heavy media

#### Tier 2: Object Storage (Garage S3)

| Setting | Value |
|---------|-------|
| Location | Deferred storage worker |
| Storage | Future HDD set, each mounted individually (Garage multi-disk) |
| Replication | 1 (single node) |
| Buckets | `postgres/`, `volsync/`, `apps/` |
| Pinning | `nodeSelector` to future storage worker |

Used by:
- CloudNative-PG + barman → Postgres WAL archives

Garage multi-disk config mounts each HDD separately and configures multiple `data_dir` entries. The original Supermicro 4x 3.64TB plan is deferred because `k8s-4-dell` now owns the `k8s-4` identity/IP. No parity protection — single disk failure loses data on that disk only. See [Risk #1](#risk-1-hdd-mount-configuration-for-future-storage-node) for Talos mount details.

#### Tier 3: File Storage (Synology NAS)

| Setting | Value |
|---------|-------|
| NFS IP | 10.30.30.10 |
| Management SSH | 10.30.10.100:24 |
| Protocol | NFSv4.1 |
| Volume | `/volume1` — 21TB total, 6.4TB used, 15TB free |
| Health check | K8s CronJob monitors NFS availability |

Serves: photos, personal files, ROMs, Syncthing, Kopia backup repository, and media backup/replica. The earlier Synology-primary media target is superseded by the 2026-05-10 `k8s-4-dell` local media amendment.

##### Current NFS Exports (Synology)

| Export | Clients | Status |
|--------|---------|--------|
| `/volume1/homes` | `10.30.30.0/24` | Exists |
| `/volume1/media` | `10.30.30.0/24` | Exists |
| `/volume1/photo` | `10.30.30.0/24` | Exists |
| `/volume1/syncthing` | — | **Must create** |
| `/volume1/nextcloud` | — | **Must create** |
| `/volume1/VolsyncKopia` | — | **Must create** |

Create missing shared folders via DSM → Control Panel → Shared Folder, then enable NFS with permissions for `10.30.30.0/24`.

##### Synology NFS Server Settings

| Setting | Value | Rationale |
|---------|-------|-----------|
| NFS version | NFSv4.1 enabled | Already configured (`nfsv4_enable=yes`, `nfs_minor_ver_enable=1`) |
| Squash | No mapping (`no_root_squash`) | Kubelet mounts as root; root_squash causes permission denied on subpath creation |
| Async | Yes (default) | Sync drops writes to 15-30 MB/s; async is acceptable for non-critical data |
| NFS threads | Increase to 16-32 | Default 8 is undersized for multiple K8s pods; 4 nodes × nconnect=16 = 64 TCP connections |
| Client IP restriction | `10.30.30.0/24` | Limit NFS access to K8s node subnet |
| Recycle bin | Disable on K8s shares | Prevents silent space consumption from pod file operations |

To increase NFS threads (resets on DSM update — add as scheduled task at boot):
```bash
echo 32 > /proc/fs/nfsd/threads
```

##### Talos NFS Client Settings (existing)

Already configured in `clusters/talos/bootstrap/os/patches/global/machine-files.yaml`:

```ini
[ NFSMount_Global_Options ]
nfsvers=4.1
hard=True
nconnect=16
noatime=True
```

| Option | Value | Rationale |
|--------|-------|-----------|
| `hard` | Yes | **Required for data integrity.** Retries indefinitely on NFS failure. `soft` risks silent data corruption (EIO on partial writes). Pod hangs are preferable to corrupted data — use liveness probes and NFS health-check CronJob instead. |
| `nfsvers=4.1` | Yes | Single port (2049), integrated locking, session trunking for nconnect |
| `nconnect=16` | Yes (max) | Multiple TCP connections per mount, distributes I/O. Critical for media streaming throughput. |
| `noatime` | Yes | Eliminates metadata writes on every read — major improvement for media workloads |

**Add to nfsmount.conf** (not yet configured):

```ini
timeo=30
retrans=3
```

- `timeo=30` = 3 second initial retransmit timeout (fine for LAN). With `hard`, this controls backoff start, not a deadline.
- `retrans=3` = 3 retries before logging "server not responding" and continuing exponential backoff.

##### nfsrahead Configuration (NEW)

The `siderolabs/nfsrahead` extension is installed on all nodes but **not configured** — it's using the default 128 KB readahead, which is far too small for media streaming.

Add `/etc/nfs.conf` to `machine-files.yaml`:

```ini
[nfsrahead]
nfs4=16000
default=128
```

`nfs4=16000` = 16 MB readahead for NFSv4 mounts. Matches typical SSD readahead and allows efficient pre-fetching for sequential media reads (Jellyfin, Audiobookshelf).

##### Known Issues: NFS + Kubernetes

- **Kubelet wedge** ([kubernetes #31272](https://github.com/kubernetes/kubernetes/issues/31272)): If NFS becomes unreachable, kubelet can hang on subpath unmounts, blocking the entire node. Mitigated by NFS health-check CronJob + node-level liveness.
- **Stale file handles** ([kubernetes #75918](https://github.com/kubernetes/kubernetes/issues/75918)): NFS server restart can leave stale handles. NFSv4.1 grace period helps, but pod restart may still be needed.
- **SQLite on NFS = corruption**: All app databases (Jellyfin, Sonarr, etc.) must live on Ceph PVCs, never NFS. NFS mounts are for media files only. Current config is correct — `config` PVCs use Ceph, `media` mounts use NFS.

### Deferred Supermicro Disk Layout

| Drive | Size | Type | Role |
|-------|------|------|------|
| 500GB SSD | scsi0 | SSD | Talos OS |
| 1TB NVMe | Kingston SNV3S1000G | NVMe | Ceph OSD |
| 4x 3.64TB | HDD | HDD | Garage (multi-disk), backups, KubeVirt VM storage |

HDDs should be mounted individually via Talos `machine.disks` config at `/var/mnt/hdd{1-4}` after the future storage worker hostname/IP is assigned. Do not assume this node is `k8s-4` or `10.30.30.24`; those now refer to `k8s-4-dell`.

## Backup & Disaster Recovery

### Backup Tools

| Tool | Source | Target | Schedule |
|------|--------|--------|----------|
| VolSync + Kopia | App PVCs (Ceph) | Kopia repo on Synology NFS (`/volume1/VolsyncKopia/`) | Per-app (existing, every 6h) |
| CNPG + barman | Postgres databases | Garage S3 (`postgres/`) | Continuous WAL + scheduled daily |
| rsync CronJob | Synology (photos, docs) | Future storage worker HDD hostPath | Nightly |
| rsync (optional) | Garage data dirs | Synology | Weekly (3rd copy) |

### Browsable Backups

- **FileBrowser pod** on future storage worker, read-only mount of rsync'd Synology data
- Web UI for browsing photos, documents, media files
- Accessible via HTTPRoute through Envoy Gateway

### 3-2-1 Backup Chain

```
App PVCs (Ceph NVMe) → Kopia repo (Synology NAS) → [optional offsite]
Postgres (Ceph NVMe) → Garage S3 (future storage worker HDD) → Synology (optional 3rd copy)
Synology (photos, docs) → rsync (future storage worker HDD) → [2nd copy on different media]
```

- 3 copies of critical data (live + Kopia/Garage + Synology)
- 2 different media types (NVMe + HDD/NAS)
- 1 offsite-capable (Synology)

## Networking

### No changes to core networking

| Component | Config |
|-----------|--------|
| Cilium CNI | v1.19.2, BGP peering with Unifi (ASN 64514 ↔ 64513) |
| Envoy Gateway | Gateway API (internal + external gateways) |
| Cloudflare Tunnel | External access |
| CoreDNS + Unifi DNS | Internal resolution |
| cert-manager | TLS automation |

### Fix: CiliumLoadBalancerIPPool

**Current:** `10.30.30.0/24` (entire server VLAN, conflicts with host IPs)
**New:** `10.30.30.160-10.30.30.200` (avoids host IPs .10/.21-.24, VIP .150, DHCP range)

### NFS Tuning

Existing config: NFSv4.1, `hard`, `nconnect=16`, `noatime` (in `machine-files.yaml`).

Changes needed:
- Add `timeo=30,retrans=3` to `nfsmount.conf`
- Add `/etc/nfs.conf` with `nfsrahead` config (`nfs4=16000`)
- Health-check CronJob alerts on NFS issues
- See Tier 3 storage section for full details

### BGP: Add k8s-4-dell Peer

`bgp.conf` needs `neighbor 10.30.30.24 peer-group k8s` for `k8s-4-dell`. A future Supermicro/storage worker needs a separate IP and separate BGP peer entry.

## GPU & AI/ML

| Setting | Value |
|---------|-------|
| Node | `k8s-4-dell` |
| GPU | NVIDIA RTX 3060 LHR plus GT 1030 detected |
| Talos extensions | `nonfree-kmod-nvidia-lts`, `nvidia-container-toolkit-lts` |
| K8s plugin | NVIDIA device plugin DaemonSet |
| Taint | Not currently applied; optional `nvidia.com/gpu=present:PreferNoSchedule` after scheduling policy is decided |
| Scheduling | Pods request `nvidia.com/gpu: 1` in resource limits |

GPU workloads:
- Jellyfin — NVENC/NVDEC hardware transcoding
- ivan + ChromaDB — AI agent, vector DB
- Future LLM inference (12GB VRAM fits smaller models)

Non-GPU pods can still schedule on `k8s-4-dell` while the node remains untainted.

## KubeVirt (VM Management)

| Setting | Value |
|---------|-------|
| Talos config | `vhost_net` kernel module on all nodes |
| Operator | KubeVirt operator + CR via ArgoCD |
| CDI | Containerized Data Importer |
| Web UI | kubevirt-manager (NoVNC console) |
| VM storage | `ceph-block` PVCs or future storage worker HDD hostPath |
| VM networking | Masquerade (default) + LoadBalancer for SSH |
| VM access | SSH via Cilium LB IP, VNC via kubevirt-manager, `virtctl` |
| GPU passthrough | Available on `k8s-4-dell` after KubeVirt passthrough policy is configured |
| VM definitions | YAML in Git, deployed via ArgoCD |

Day 1: Install operator + CDI + kubevirt-manager. No VMs until needed. Zero overhead when idle.

## Technology Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| OS | Talos Linux | Immutable, API-driven, bare metal on all nodes |
| K8s | Kubernetes (via Talos) | Single consolidated cluster |
| CNI | Cilium | Networking, LB IPAM, BGP, network policy |
| GitOps | ArgoCD | Declarative app delivery |
| Block storage | Rook-Ceph | NVMe-backed distributed block storage |
| Object storage | Garage | S3-compatible backup target on future storage worker HDDs |
| Primary NAS | Synology DSM | Media, files, NFSv4.1/SMB |
| Ingress | Envoy Gateway | Gateway API (HTTPRoute) |
| TLS | cert-manager | Automated certificates |
| DNS | CoreDNS + Unifi DNS + Cloudflare | Internal + external resolution |
| Secrets | External Secrets + 1Password | Secret management |
| Encryption | SOPS + Age | GitOps secret encryption |
| GPU | NVIDIA device plugin + container toolkit | Jellyfin transcoding, AI/ML |
| PVC backup | VolSync + Kopia | PVC snapshots → Kopia repo on Synology NFS |
| DB backup | CloudNative-PG + barman | Postgres WAL → Garage S3 |
| NAS backup | rsync CronJob + FileBrowser | Synology → future storage worker, browsable web UI |
| VMs | KubeVirt + CDI + kubevirt-manager | Learning/experimentation VMs |
| Monitoring | Prometheus + Grafana | Metrics |
| Logging | Loki | Log aggregation |
| IaC | talhelper + go-task + kustomize | Node provisioning, cluster config, bootstrap |
| Dependencies | Renovate | Automated updates |

---

## GitOps Repo Changes

### Bootstrap

The bootstrap pipeline is unchanged structurally:

1. **`task bootstrap:talos`** — talhelper generates machine configs from `talconfig.yaml` + `talenv.yaml`
2. **`task bootstrap:apps talos`** runs `scripts/bootstrap-apps.sh talos`:
   - Creates namespaces → Applies SOPS secrets → Applies CRDs
   - Deploys Cilium → CoreDNS → Spegel (pre-ArgoCD networking)
   - Deploys ArgoCD → root-application → app-of-apps takes over
3. **ArgoCD app-of-apps** — numbered values files (00→30) with sync waves control deployment order
4. **Plugin env substitution** — `setenv-cmp-plugin` runs `kustomize build | envsub` for apps with `plugin.env`

**Change: Replace helmfile with kustomize.** The kustomization.yaml files for all 3 bootstrap charts already exist with identical repos, versions, and values:

| Chart | Kustomization (already exists) | Values |
|-------|-------------------------------|--------|
| Cilium 1.19.2 | `clusters/talos/apps/kube-system/cilium/kustomization.yaml` | `values.yaml` (same dir) |
| CoreDNS 1.45.2 | `components/kube-system/coredns/kustomization.yaml` | `values.yaml` (same dir) |
| Spegel 0.6.0 | `components/kube-system/spegel/kustomization.yaml` | `values.yaml` (same dir) |

Replace `sync_helm_releases()` in `bootstrap-apps.sh`:

```bash
function sync_helm_releases() {
    log debug "Syncing bootstrap Helm releases via kustomize"

    local -r bootstrap_apps=(
        "${ROOT_DIR}/clusters/${CLUSTER_NAME}/apps/kube-system/cilium"
        "${ROOT_DIR}/components/kube-system/coredns"
        "${ROOT_DIR}/components/kube-system/spegel"
    )

    for app_dir in "${bootstrap_apps[@]}"; do
        local app_name
        app_name=$(basename "${app_dir}")
        log info "Deploying ${app_name}"

        if ! kustomize build "${app_dir}" --enable-helm \
            | kubectl apply --server-side --force-conflicts -f-; then
            log error "Failed to deploy ${app_name}"
        fi

        # Wait for rollout (Cilium must be ready before CoreDNS, CoreDNS before Spegel)
        if ! kubectl -n kube-system rollout status deploy,ds \
            -l "app.kubernetes.io/name=${app_name}" --timeout=300s 2>/dev/null; then
            log warn "Rollout status check completed for ${app_name}"
        fi

        log info "${app_name} deployed successfully"
    done
}
```

Benefits: eliminates helmfile dependency, single source of truth for chart versions, no version drift between bootstrap and ArgoCD.

### 2026-05-08 Talos Additive Worker

Files updated:
- `clusters/talos/bootstrap/os/talconfig.yaml` — added `k8s-4-dell`
- `clusters/talos/bootstrap/os/clusterconfig/.gitignore` — ignored generated `k8s-4-dell.yaml`

Node settings:
- Hostname: `k8s-4-dell`
- IP/MAC: `10.30.30.24`, `d8:9e:f3:3c:9b:81`
- Install disk selector: model `CT500MX500SSD1`
- Talos schematic: `c1c8847e58bca7ae9584c3b209f21c50add404d9cb9466a1d4ea8be43a160b8a`
- NVIDIA modules: `nvidia`, `nvidia_uvm`, `nvidia_drm`, `nvidia_modeset`

Commands used:

```bash
task talos:generate-config SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/age-key.txt
task talos:apply-node IP=10.30.30.24 MODE='auto --insecure'
task talos:apply-node IP=10.30.30.24 MODE=auto
```

Verification completed:
- `kubectl get nodes` showed `k8s-4-dell` Ready
- Talos `MachineStatus` reached running
- NVIDIA kernel modules loaded on `10.30.30.24`
- `talosctl health` passed

### Storage Migration: OMV → Talos Local + Synology

All `omv-baymx.a113.internal` NFS references are removed. Media references move to `k8s-4-dell` local Talos user volumes; non-media NAS references move to Synology `10.30.30.10`. All OMV UUID hostPaths (`/srv/dev-disk-by-uuid-9d2e4cb9-...`) are replaced.

#### Media mounts (5 files — change to `k8s-4-dell` local hostPaths)

| File | Current |
|------|---------|
| `components/default/sonarr/values.yaml` | `omv-baymx:/storage0/media` |
| `components/default/radarr/values.yaml` | `omv-baymx:/storage0/media` |
| `components/default/bazarr/values.yaml` | `omv-baymx:/storage0/media` |
| `components/downloads/qbittorrent/values.yaml` | `omv-baymx:/storage0/media` |
| `components/downloads/sabnzbd/values.yaml` | `omv-baymx:/storage0/media` |

Target media mount: `/var/mnt/media` on `k8s-4-dell`. Downloads/incomplete scratch should use `/var/mnt/downloads`; Jellyfin transcode/cache should use `/var/mnt/transcode`. Pin these media workloads to `k8s-4-dell` so hostPath storage remains local to the pods.

qBittorrent operational note: after PVC rescheduling, stale `/config/qBittorrent/lockfile` and `/config/qBittorrent/ipc-socket` can keep the pod in CrashLoop. The 2026-05-08 remediation scaled the app to 0, removed those two paths from the PVC, then scaled it back to 1.

#### App-specific mounts

| File | Current | New Target |
|------|---------|------------|
| `components/default/jellyfin/values.yaml` | OMV UUID hostPath `/storage0/media` | `k8s-4-dell` local hostPaths: `/var/mnt/media`, `/var/mnt/transcode` |
| `components/default/syncthing/values.yaml` | OMV UUID hostPath `/storage0/syncthing/{config,data}` | Synology NFS `10.30.30.10:/volume1/syncthing/{config,data}` |
| `components/default/nextcloud/pvc.yaml` | `omv-baymx:/storage0/nextcloud` | Synology `10.30.30.10:/volume1/nextcloud` |
| `components/default/bytestash/values.yaml` | OMV UUID hostPath `/storage0/bytestash` | Ceph PVC (`ceph-block`, small dataset) |

#### Kopia/VolSync → Synology NFS

Kopia repo moves from OMV NFS to Synology NFS at `10.30.30.10:/volume1/VolsyncKopia`. Three files change:

| File | Change |
|------|--------|
| `clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml` | NFS server + path |
| `clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml` | NFS server + path |
| `clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml` | NFS server + path (injected into VolSync mover pods) |

Keeps backups on a separate storage tier from Ceph.

#### Garage → Future Storage Worker HDD HostPaths

| File | Change |
|------|--------|
| `components/default/garage-app/values.yaml` | OMV UUID hostPaths → `/var/mnt/hdd{1-4}/garage` + nodeSelector to future storage worker |
| `components/default/garage-app/resources/configuration.toml` | Single `data_dir` → multi-disk array with 4 entries |

### Gitea Migration (CRITICAL)

#### Postgres host

`components/default/gitea/external-secret.yaml`:
- `INIT_POSTGRES_HOST: "pg17-omv-rw.default.svc.cluster.local"` → `postgres17-rw.default.svc.cluster.local`
- `GITEA__database__HOST: "pg17-omv-rw.default.svc.cluster.local:5432"` → `postgres17-rw.default.svc.cluster.local:5432`

**Pre-requisite:** pg_dump/pg_restore Gitea DB from OMV → Talos Postgres before cutover.

#### Container registry URL (`gitea.omv.*` → `gitea.*`)

| File | Current | New |
|------|---------|-----|
| `components/ai/ivan/values.yaml` | `gitea.omv.a113.casa/vpogu/ivan-agent` | `gitea.${CLUSTER_DOMAIN}/vpogu/ivan-agent` |
| `components/ai/ivan/values.yaml` | `GITEA_DOMAIN: "gitea.omv.${CLUSTER_DOMAIN}"` | `GITEA_DOMAIN: "gitea.${CLUSTER_DOMAIN}"` |
| `components/ai/ivan-dashboard/values.yaml` | `gitea.omv.a113.casa/vpogu/ivan-dashboard-{api,ui}` | `gitea.${CLUSTER_DOMAIN}/vpogu/ivan-dashboard-{api,ui}` |
| `components/ai/ivan/external-secret.yaml` | `GITEA_URL: "https://gitea.omv.${CLUSTER_DOMAIN}"` | `GITEA_URL: "https://gitea.${CLUSTER_DOMAIN}"` |
| `components/argo-system/argocd-image-updater/values.yaml` | `prefix`/`api_url`: `gitea.omv.${CLUSTER_DOMAIN}` | `gitea.${CLUSTER_DOMAIN}` |
| `components/argo-system/argocd-image-updater/imageupdater.yaml` | All `gitea.omv.${CLUSTER_DOMAIN}/vpogu/*` image refs | `gitea.${CLUSTER_DOMAIN}/vpogu/*` |
| `components/kube-system/reflector/external-secrets.yaml` | `"gitea.omv.a113.casa"` docker auth | `"gitea.${CLUSTER_DOMAIN}"` |

**DNS:** Create `gitea.${CLUSTER_DOMAIN}` record → Envoy Gateway LB IP. Gitea's own config already uses `gitea.${CLUSTER_DOMAIN}` (no `omv`).

### S3 Endpoint DNS

4 files reference `s3.omv.a113.casa`. Decision: **keep hostname, repoint DNS record** to new Garage LB IP after Phase 3. Zero code changes.

| File | Reference |
|------|-----------|
| `clusters/talos/apps/default/cloudnative-cluster/cluster.yaml` | CNPG barman backup |
| `components/default/reactive-resume/values.yaml` | S3 storage endpoint |
| `components/ai/ivan/external-secret.yaml` | `AWS_ENDPOINT_URL` |
| `components/storage/velero/values.yaml` | Deleted with Velero |

Reactive Resume v5 operational note: `APP_URL` and `AUTH_SECRET` are required for startup. `APP_URL` is set in `components/default/reactive-resume/values.yaml`, and `AUTH_SECRET` is templated from the `reactive-resume` ExternalSecret.

### Decommissioned Reference Cleanup

**Ivan AI agent** (`components/ai/ivan/external-secret.yaml`) — remove:
- `OMV_URL`, `OMV_USERNAME`, `OMV_PASSWORD`
- `PROXMOX_API_URL`, `PROXMOX_API_TOKEN_ID`, `PROXMOX_API_TOKEN_SECRET`, `PROXMOX_DEFAULT_NODE`
- `openmediavault` and `proxmox` from `dataFrom` extracts

**Homepage dashboard** (`clusters/talos/apps/default/homepage/configmap.yaml`) — remove:
- OMV-Loki entry (`http://omv-baymx.a113.internal:81`)
- Proxmox entry (`https://pxm-baymx.a113.internal:8006/`)

**Observability** — `clusters/talos/apps/25-observability.yaml` references `clusters/omv/apps/observability/kube-prometheus-stack`. Move kustomization to `components/observability/kube-prometheus-stack-cluster/` before deleting `clusters/omv/`. Remove etcd disable overrides (Talos has etcd).

**common-values.yaml** — fix `app-source: omv` → `app-source: talos`.

### Files & Components to Delete

| Path | Reason |
|------|--------|
| `clusters/omv/` | Entire OMV/K3s cluster decommissioned |
| `components/longhorn-system/` | Longhorn, OMV-only |
| `components/kube-system/traefik/` | Traefik, OMV-only |
| `components/system-upgrade/k3s/` | K3s upgrade controller |
| `components/cattle-system/rancher/` | Rancher, OMV-only |
| `components/storage/velero/` | Velero removed |
| `components/storage/openebs/` | OpenEBS unused |
| `clusters/talos/bootstrap/apps/helmfile.yaml` | Replaced by kustomize bootstrap |
| `scripts/velero-backup-pvcs.sh` | Velero removed |
| `scripts/velero-restore-pvcs.sh` | Velero removed |
| `omv.kubeconfig` (repo root) | OMV cluster decommissioned |

### CI/CD & Tooling Updates

- `.github/workflows/pr-webhook.yaml` — remove OMV file group and `OMV_*` change tracking
- `scripts/kubeconform.sh` — update default `STORAGE_CLASS` to `ceph-block`, `VOLUME_SNAPSHOT_CLASS` to `csi-ceph-blockpool`
- `bootstrap-apps.sh` — remove `helmfile` from `check_cli`

### 1Password Secrets

The `environment-variables` ExternalSecret pulls from 1Password items `talos`, `cloudflare`, `synology-homepage`. Verify:
- `NAS_IP_ADDRESS` → Synology (10.30.30.10)
- `KUBE_API_IP_ADDRESS` → 10.30.30.150

No structural changes — just verify 1Password values.

### Talos Disk Notes for k8s-4-dell

Talos doesn't auto-mount non-OS disks. `k8s-4-dell` currently installs Talos to the Crucial `CT500MX500SSD1` via model selector. Do not add that disk to Ceph or Garage.

Current `k8s-4-dell` local storage is managed by `clusters/talos/bootstrap/os/patches/k8s-4-dell/user-volumes.yaml`, referenced only from the `k8s-4-dell` node block in `talconfig.yaml`.

| Talos mount | Backing disk | Stable selector | Purpose |
|-------------|--------------|-----------------|---------|
| `/var/mnt/media` | `sdd` / WDC `WD40EZAZ-00S` 4TB HDD | `/dev/disk/by-id/wwn-0x50014ee214f03cdb` | Completed media library |
| `/var/mnt/downloads` | `nvme1n1` / Kingston `OM8PGP4512Q-A0` 512GB NVMe | `/dev/disk/by-id/nvme-eui.00000000000000000026b7382439f6f5` | qBittorrent/SABnzbd incomplete downloads and scratch |
| `/var/mnt/transcode` | `nvme2n1` / Samsung `SSD 970 EVO` 250GB NVMe | `/dev/disk/by-id/nvme-eui.0025385581b3be2f` | Jellyfin transcode/cache/temp |

Intentionally excluded:

| Disk | Reason |
|------|--------|
| `sdb` / Crucial `CT500MX500SSD1` 500GB SSD | Current Talos system disk |
| `sdc` / MARSHAL `MAL38000NS-T72` 8TB HDD | Bad SMART evidence: high reallocated sectors, pending sectors, and ATA error count |
| `nvme0n1` / Kingston `SNV3S1000G` 1TB NVMe | Reserved as a future raw Rook/Ceph OSD after media migration |

Before applying the `UserVolumeConfig` patch, wipe the old disposable content from `sdd`, `nvme1n1`, and `nvme2n1`. Do not wipe `sdb`. Do not add `nvme0n1` to user volumes; keep it raw for the future Ceph OSD plan.

### Talos HDD Mounts for Future Storage Worker

The original 4-HDD Supermicro plan is deferred. When the future storage worker is added, assign a new hostname/IP first, then add `machine.disks` to that node entry in `talconfig.yaml`:

```yaml
  - hostname: "k8s-storage-1"
    # ... existing config ...
    patches:
      - |-
        machine:
          disks:
            - device: /dev/sdb
              partitions:
                - mountpoint: /var/mnt/hdd1
            - device: /dev/sdc
              partitions:
                - mountpoint: /var/mnt/hdd2
            - device: /dev/sdd
              partitions:
                - mountpoint: /var/mnt/hdd3
            - device: /dev/sde
              partitions:
                - mountpoint: /var/mnt/hdd4
```

---

## Migration Plan

### Phase 1a: Bulk Data Transfer (days before maintenance window)

rsync media from OMV → `k8s-4-dell` local storage while everything runs. Non-media NAS data still moves OMV → Synology.

| Data | Size (est.) | Target | Used by |
|------|-------------|--------|---------|
| `media/` | ~2TB | `k8s-4-dell:/var/mnt/media/` | Jellyfin, Sonarr, Radarr, Bazarr, qBittorrent, SABnzbd |
| `syncthing/` | varies | `/volume1/syncthing/` | Syncthing |
| `nextcloud/` | varies | `/volume1/nextcloud/` | Nextcloud |
| `bytestash/` | small | `/volume1/bytestash/` | Bytestash (temp, migrates to Ceph PVC) |
| `VolsyncKopia/` | varies | `/volume1/VolsyncKopia/` | Kopia (permanent home on Synology NFS) |

Strategy: run media copy as a Kubernetes rsync Job pinned to `k8s-4-dell`, mounting OMV NFS read-only as source and `/var/mnt/media` as the local hostPath destination. Use `-aH --numeric-ids --info=progress2 --partial --inplace` for the initial online copy. After media cutover, rsync local media to Synology as the backup/replica.

### Phase 1b: Garage Data Staging

| Data | Synology Target | Permanent? |
|------|-----------------|------------|
| `garage/` | `/volume1/staging/garage/` | No — moves to future storage worker HDDs after hardware swap |
| `garage-meta/` | `/volume1/staging/garage-meta/` | No — moves to future storage worker HDDs after hardware swap |

### Phase 1c: Verification

- File count comparison (`find | wc -l`) on both sides
- Spot check: play media files from `k8s-4-dell` local media path
- Checksum Garage meta files
- Do NOT proceed until verified

### Phase 1d: Cutover (during maintenance window, ~2-4 hours)

1. Final delta rsync (catch changes since bulk transfer)
2. Migrate Gitea database from OMV Postgres → Talos Postgres (pg_dump/pg_restore)
3. Move observability kustomization from `clusters/omv/` to `components/observability/kube-prometheus-stack-cluster/`
4. Push Git changes for all migration updates:
   - **Media migrations** — all `omv-baymx:/storage0/media` → `k8s-4-dell` local hostPaths
   - **NFS migrations** — non-media NAS paths `omv-baymx` → `10.30.30.10` (syncthing, nextcloud, kopia/volsync)
   - **Storage** — Bytestash → Ceph PVC
   - **Gitea** — Postgres host → Talos CNPG, all `gitea.omv.*` → `gitea.*`
   - **Cleanup** — Ivan/Homepage remove OMV/Proxmox refs
   - **Fixes** — common-values.yaml label, CiliumLoadBalancerIPPool range, helmfile → kustomize bootstrap
5. ArgoCD reconcile — apps restart with new mounts
6. Verify: media playback, Syncthing sync, Kopia repo access, Gitea login
7. OMV NFS is now unused — safe to wipe

### Phase 2a: Additive Dell Worker (completed 2026-05-08)

1. Keep `k8s-3-pxm` in place; do not remove etcd member
2. Generate Talos config for `k8s-4-dell`
3. Boot Dell tower with Talos Image Factory ISO for schematic `c1c8847e58bca7ae9584c3b209f21c50add404d9cb9466a1d4ea8be43a160b8a`
4. Install Talos to Crucial `CT500MX500SSD1`
5. Apply node config to `10.30.30.24`
6. Add NVIDIA kernel modules after initial install and re-apply config
7. Verify `k8s-4-dell` Ready in Kubernetes and Talos health passing
8. Add/confirm BGP peer `10.30.30.24` for Cilium
9. Leave GPU taint unset until workload scheduling policy is decided

### Phase 2b: Deferred Hardware Replacement / Storage Worker

1. Decide whether `k8s-3-pxm` will remain long term or be replaced in a separate maintenance window
2. If replacing an etcd member, take an etcd snapshot and document remove/re-add steps before touching the node
3. Assign the Supermicro/future storage worker a new hostname and IP; do not reuse `k8s-4-dell` or `10.30.30.24`
4. Install Talos bare metal on the future storage worker
5. Configure HDD mounts via `machine.disks`
6. Add the new BGP peer to Unifi
7. Add explicit Ceph/Garage disk selections and allow Ceph to rebalance

### Phase 3: Service Migration

1. Move Garage data from Synology staging → future storage worker HDDs (split across disks by hex prefix)
2. Deploy Garage pod on future storage worker with new hostPaths (multi-disk config)
3. Re-register Garage node, reassign partitions
4. Verify all S3 buckets/objects intact (postgres, volsync, apps)
5. Repoint DNS: `s3.omv.a113.casa` → new Garage Cilium LB IP
6. Verify CNPG backup and Reactive Resume S3 connectivity
7. Verify NVIDIA device plugin on `k8s-4-dell`
8. Verify Jellyfin GPU transcoding works (NVENC/NVDEC)
9. Deploy rsync CronJob + FileBrowser for Synology backups on future storage worker
10. Deploy KubeVirt operator + CDI + kubevirt-manager
11. Verify Kopia repo on Synology NFS is accessible, run test backup

### Phase 4: Cleanup

1. Remove `clusters/omv/` (entire OMV/K3s cluster config)
2. Remove decommissioned components (Longhorn, Traefik, K3s upgrade, Rancher, Velero, OpenEBS)
3. Remove orphaned files (`omv.kubeconfig`, `helmfile.yaml`, Velero scripts)
4. Update GitHub Actions (remove OMV tracking, fix kubeconform defaults)
5. Create `gitea.${CLUSTER_DOMAIN}` DNS record
6. Clean up staging data on Synology (`/volume1/staging/garage*`)
7. Final ArgoCD reconcile and verify all apps healthy

---

## Risks & Open Items

### Open

#### Risk #1: HDD Mount Configuration for Future Storage Node

Talos doesn't auto-mount non-OS disks. The future Garage/backup disks need explicit `machine.disks` config. The original `k8s-4` Supermicro mapping is stale because `k8s-4-dell` now owns `10.30.30.24`. **Blocks Garage deployment until storage worker identity and disk layout are re-planned.**

#### Risk #2: Etcd Quorum During k8s-3-pxm Replacement

The 2026-05-08 additive path avoided this risk by keeping `k8s-3-pxm` in place. If `k8s-3-pxm` is replaced later, etcd will temporarily lose a member; if either mini PC fails during that window, cluster quorum is at risk.

**Mitigations:**
- Take etcd snapshot before any future `k8s-3-pxm` replacement
- Document exact etcd member removal and re-addition steps
- Have a tested etcd restore procedure ready
- Minimize time in 2-member state

#### Risk #3: Ceph Degradation During Migration

If a future migration removes an existing OSD before the new worker/storage OSD is healthy, Ceph may run degraded. With replication=3 and only 2 available OSDs, some PGs will be degraded.

**Mitigations:**
- Temporarily set `min_size: 1` during migration (accept reduced redundancy)
- Prefer additive expansion first, then remove old OSDs only after the new OSD is healthy

#### Risk #4: NVIDIA Driver / Talos Version Lock

`nonfree-kmod-nvidia-lts` must match exact Talos version. Every Talos upgrade requires a matching NVIDIA extension rebuild. The 2026-05-08 install also required explicit kernel modules (`nvidia`, `nvidia_uvm`, `nvidia_drm`, `nvidia_modeset`); without them, `ext-nvidia-persistenced` can fail while waiting for the NVIDIA sysfs driver path.

**Mitigations:**
- Add Renovate rule to track Talos + NVIDIA extension versions together
- Test upgrades on non-GPU nodes first, then `k8s-4-dell` after NVIDIA extension compatibility is confirmed

#### Risk #5: Garage Data Migration Sizing

Existing Garage data (~4.4TB) won't fit on a single 3.64TB HDD. Must be split across 4 disks by hex prefix during restore. Needs testing before the maintenance window.

#### Risk #6: Gitea Postgres Migration

Gitea DB on OMV Postgres must be migrated to Talos CNPG before cutover. Either pg_dump/pg_restore (preserves data) or let Gitea re-initialize (data loss). **Blocks Phase 1d.**

#### Risk #7: Gitea Container Registry URL Change

All Ivan/dashboard images at `gitea.omv.a113.casa` must move to `gitea.${CLUSTER_DOMAIN}`. Requires either pushing images to new URL before updating references, or setting up a redirect. Affects ArgoCD Image Updater, Ivan, Ivan Dashboard, reflector secret.

### Resolved

#### Risk #8: LB IP Pool Overlaps VIP (RESOLVED)

**Decision:** Pool narrowed to `10.30.30.160-200`. Excludes host IPs (.10, .21-.24), VIP (.150), DHCP range.

#### Risk #9: Multiple Apps Reference OMV (RESOLVED)

Comprehensive audit completed. Found **18+ files** across both clusters. Full file-by-file migration plan in "GitOps Repo Changes" section.

#### Risk #10: Garage S3 Endpoint DNS (RESOLVED)

**Decision:** Keep `s3.omv.a113.casa` hostname, repoint DNS record to new Garage LB IP after Phase 3. Zero code changes needed.

#### Risk #11: Observability Breaks When OMV Deleted (RESOLVED)

**Fix:** Move kustomization to shared components before deleting `clusters/omv/`. Scheduled as Phase 1d step 3.

#### Risk #12: common-values.yaml Label Bug (RESOLVED)

**Fix:** `app-source: omv` → `app-source: talos`. Scheduled in Phase 1d.

#### Risk #13: Additive Dell Worker Join (RESOLVED)

**Fix:** Added `k8s-4-dell` as a worker at `10.30.30.24` without removing `k8s-3-pxm`. Talos health passed and the Kubernetes node reached Ready.

#### Risk #14: qBittorrent CrashLoop After PVC Reuse (RESOLVED)

**Fix:** Scaled qBittorrent to 0, removed stale `/config/qBittorrent/lockfile` and `/config/qBittorrent/ipc-socket` from the PVC, then scaled back to 1.

#### Risk #15: Reactive Resume v5 Startup Requirements (RESOLVED)

**Fix:** Added `APP_URL` to `values.yaml` and templated `AUTH_SECRET` from the `reactive-resume` ExternalSecret.
