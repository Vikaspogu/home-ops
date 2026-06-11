# Home-Ops Session Handoff — 2026-06-10 GPU/Jellyfin Residual Loose Ends

**Date:** 2026-06-10 ~13:30 UTC
**Focus:** Items left over from the all-day marathon session that brought up NVIDIA GPU Operator, restored Jellyfin from a kopia snapshot, fixed BGP, and migrated several apps. NVENC transcoding is **working end-to-end** on the RTX 3060 — this doc covers everything that wasn't tied off cleanly.

---

## TL;DR

| # | Loose end | Severity | Action |
|---|---|---|---|
| 1 | Stale `host k8s-3-pxm` crush bucket in Ceph (weight 0) | Cosmetic | One `ceph osd crush remove` |
| 2 | Disk-space alert on old `k8s-3-pxm` `/var` (5-day projection) | Stale | Verify the alert is for the renamed-away node; silence or delete the metrics target |
| 3 | `lost+found/` and `jellyfin.db.corrupt-*` leftovers in jellyfin PVC | Cosmetic | Optional cleanup — files are inert |
| 4 | `ReplicationDestination/jellyfin-dst` stuck `SyncInProgress`, no `latestImage` | Medium | Restore happened out-of-band; either retrigger volsync or delete/recreate the RD |
| 5 | Kopia repo single point of failure on `k8s-4-dell:/var/mnt/media/.kopia` | Medium-long-term | Plan migration to S3 (garage) or distributed FS |
| 6 | PSS `privileged` labels on `default` and `volsync-system` namespaces are **out-of-GitOps** (applied via `kubectl label`) | Security | Bring under GitOps so they survive cluster rebuilds |
| 7 | GT 1030 still managed by GPU Operator but useless for NVENC | Cosmetic | Optional: exclude GT 1030 from the device plugin's pool |

None of these block the cluster. None are urgent. Triage and tackle on your schedule.

---

## Commits pushed during the parent session

For cross-reference. All on `origin/main`:

- `4681a847` `(feat): register jellyfin on talos against k8s-4-dell media disk` (was already there at session start)
- `5d697ba5` `add gpu operator` (initial scaffold)
- `3e0c6eb4` `(fix): split nvidia-gpu-operator from ClusterPolicy CR` (sync-wave 30/31 split)
- `e6af0327` `(fix): enable NFD system source so GPU Operator can read OS label`
- `21400a80` `(fix): revert NVIDIA_VISIBLE_DEVICES, use CUDA_VISIBLE_DEVICES instead`
- `a20a2cc1` `(fix): pin CUDA_VISIBLE_DEVICES to RTX 3060 by UUID, not index`
- (Talos cgroup / nvidia runtime patch in `clusters/talos/bootstrap/os/patches/global/machine-files.yaml` was committed inline with other Talos work)
- (jellyfin `bgp.conf` update for k8s-4-dell + k8s-5-1u was committed separately)

The `default` and `volsync-system` namespace PSS labels were applied via `kubectl label` **only** — not committed (see item 6).

---

## Loose end 1: Stale `host k8s-3-pxm` crush bucket in Ceph

### What it looks like

```
$ kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
ID   CLASS  WEIGHT   TYPE NAME            STATUS  REWEIGHT  PRI-AFF
 -1         2.72910  root default
 -4         0.90970      host k8s-1-nab9
  0   nvme  0.90970          osd.0            up   1.00000  1.00000
 -7         0.90970      host k8s-2-ser
  1   nvme  0.90970          osd.1            up   1.00000  1.00000
 -3         0.90970      host k8s-3-4u
  2         0.90970          osd.2            up   1.00000  1.00000
-10               0      host k8s-3-pxm          ← stale, weight 0
```

### Why

During the session, the `k8s-3-pxm` node was renamed/replaced as `k8s-3-4u`. We purged `osd.2` and let rook bootstrap a fresh OSD on the new node, but the old host bucket in CRUSH was left behind. It has weight 0, so it doesn't host any PGs and doesn't affect placement — purely cosmetic.

### Fix

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd crush remove k8s-3-pxm
```

Idempotent; safe to run. CRUSH map will then show only the three real hosts.

---

## Loose end 2: Disk-space alert on `/var` of "k8s-3-pxm"

### What it looks like

At 10:14 PM on 2026-06-09 we got:

```
[FIRING] CephNodeDiskspaceWarning
Mountpoint /var on k8s-3-pxm will be full in less than 5 days based on the 48 hour trailing fill rate.
device: /dev/sda6
```

This node has since been renamed (now `k8s-3-4u`).

### Investigation needed

Two possibilities:

**(a)** The alert was generated **against the old hostname before the rename**. Prometheus's `node-exporter` target list may still contain a stale series labeled `k8s-3-pxm`. The new node would emit metrics under `k8s-3-4u`. If true, the alert is bogus and should self-resolve once the stale series ages out.

**(b)** The new `k8s-3-4u` node has the same `/var` partition pattern (it might be the same physical box, just relabeled) and the alert is still legitimate.

### Triage

```bash
# Confirm whether k8s-3-pxm series still appears
kubectl -n observability exec sts/prometheus-prometheus -- \
  promtool query instant http://localhost:9090 \
  'node_filesystem_avail_bytes{instance=~".*k8s-3-pxm.*"}'

# And whether k8s-3-4u is reporting
kubectl -n observability exec sts/prometheus-prometheus -- \
  promtool query instant http://localhost:9090 \
  'node_filesystem_avail_bytes{instance=~".*k8s-3-4u.*",mountpoint="/var"}'
```

If only `k8s-3-4u` reports now, the alert is stale — wait for it to expire or restart Prometheus. If `k8s-3-pxm` still reports, you have an actual disk-space situation to deal with: common culprits on Talos are kubelet logs and the container image cache; `crictl rmi --prune` (run via talosctl) reclaims unused images.

---

## Loose end 3: `lost+found/` and `jellyfin.db.corrupt-*` in jellyfin PVC

### What it looks like

After the kopia restore overwrote `/config/`, the PVC root might still contain:

```
/config/lost+found/                                  ← from ext4 fsck during yesterday's corruption recovery
/config/data/jellyfin.db.corrupt-2026-06-10          ← snapshot of the bad DB we attempted .recover on
/config/data/jellyfin.db.corrupt-2026-06-10-shm      ← (possibly)
/config/data/jellyfin.db.corrupt-2026-06-10-wal      ← (possibly)
```

### Why

During the marathon session we hit ext4 filesystem corruption on the `volsync-jellyfin-src` cache PVC (rook-ceph CSI nodeplugin had crashed 45+ times on k8s-4-dell, leaving FS in inconsistent state). Recovery shoved orphaned inodes into `lost+found/`. Then we tried in-place SQLite `.recover` on the corrupt main DB before falling back to a kopia snapshot restore; the recovery attempt left backup copies of the corrupted DB.

The kopia restore at `kb1ce04bee0263dd993d87a5ecca1a97c` (2026-06-08 20:05 EDT) replaced `jellyfin.db` cleanly but left the corrupt-backup siblings and `lost+found/` untouched.

### Fix

```bash
KUBECONFIG=./kubeconfig kubectl exec -n default deploy/jellyfin -- \
  rm -rf /config/lost+found /config/data/jellyfin.db.corrupt-*
```

Free up ~64 MiB. Functionally irrelevant — Jellyfin doesn't read either path.

---

## Loose end 4: `ReplicationDestination/jellyfin-dst` is stuck

### What it looks like

```
$ kubectl get replicationdestination -n default jellyfin-dst -o yaml
status:
  conditions:
  - type: Synchronizing
    status: "True"
    reason: SyncInProgress
    message: Synchronization in-progress
  lastSyncStartTime: "2026-06-09T23:13:11Z"
  latestMoverStatus:
    result: Successful
    logs: 'INFO: Snapshot restore completed successfully'
  # NOTE: no `latestImage` set, no `lastManualSync` set
```

The RD's manager has reported the mover succeeded but never recorded a `latestImage`. Meanwhile the `jellyfin` PVC currently in use was populated **out-of-band** by a manual `kopia restore` from a pod that mounted the RWX kopia repo directly — completely bypassing the volsync flow.

### Implications

- Volsync's volume-populator can no longer act on this RD (it would just say `VolSyncPopulatorReplicationDestinationNoLatestImage`).
- The `volsync-jellyfin-dst-dest` PVC + its VolumeSnapshot from the partial earlier mover run are still hanging around taking up Ceph storage (~10 GiB declared, may not be fully used).
- The `ReplicationSource` for jellyfin (the source-side backup) is **fine** and continues to run on its 6-hour schedule.

### Options

**(a) Reset the RD** — delete + recreate so it's in a sane "Idle" state waiting for the next manual restore trigger:

```bash
kubectl delete replicationdestination -n default jellyfin-dst
# Argo will recreate it from components/volsync-system/volsync-replication/replicationdestination.yaml
# trigger: manual: restore-once  → it'll start a fresh restore, which is wasteful but harmless
```

**(b) Leave it.** The RD only matters when a fresh restore is needed (i.e., next time the jellyfin PVC gets nuked). Until then it's idle from the workload's perspective. If you take this path, document why so future-you doesn't restore from kopia and discover the RD is still stuck.

**(c) Switch RD off entirely** — change `dataSourceRef` in `components/volsync-system/volsync-replication/pvc.yaml` to remove the populator link for jellyfin, since restores were done manually anyway. Source-side backups continue.

### Cleanup of orphans regardless of path

```bash
# After (a) or (c), also clean up the orphan dest PVCs:
kubectl delete pvc -n default volsync-jellyfin-dst-dest volsync-dst-jellyfin-dst-cache
kubectl delete volumesnapshot -n default volsync-jellyfin-dst-dest-20260610021835
```

---

## Loose end 5: Kopia repo SPOF on k8s-4-dell

### What it looks like

`components/volsync-system/volsync-replication/external-secret.yaml`:

```yaml
KOPIA_FS_PATH: /repository
KOPIA_REPOSITORY: filesystem:///repository
```

And the `MutatingAdmissionPolicy/volsync-mover` at `clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml` patches every volsync Job to bind-mount `/var/mnt/media/.kopia` from `k8s-4-dell`'s local disk. **All app backups land on a single physical disk on a single node.**

### Risk

Losing the k8s-4-dell media disk = losing the kopia repository = losing all volsync backups. The repo isn't replicated anywhere.

### Options ranked by effort

1. **Replicate the kopia repo to S3** (garage is already running): set up a kopia sync cronjob (`kopia repository sync-to s3://...`) to mirror the local repo. Cheap, easy, immediate.
2. **Migrate the primary repo to S3**: change `KOPIA_REPOSITORY` to `s3://garage.../jellyfin` (etc per-app). Each app's `1Password volsync-template` secret needs an S3 access key. Removes the MAP hostPath dependency entirely. More invasive — the MAP currently pins source/dest jobs to `k8s-4-dell` because of the hostPath; that pin goes away too. Several apps would need their backups re-seeded.
3. **Move the local kopia path onto a Ceph RWX volume** (via cephfs) so it lives in the ceph pool rather than one disk. Keeps the architecture but removes the single-disk SPOF. Adds latency.

I'd start with #1 — zero-config, gives you a tested off-disk copy of the repo within a day.

---

## Loose end 6: Out-of-GitOps PSS namespace labels

### What it looks like

During the session we ran:

```bash
kubectl label namespace default pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl label namespace volsync-system pod-security.kubernetes.io/enforce=privileged --overwrite
```

…because the Talos cluster admission config sets `enforce: baseline` for all namespaces except `kube-system`, and `baseline` blocks `hostPath` volumes — which both volsync's mover jobs (`/var/mnt/media/.kopia`) and the MAP-injected nvidia runtime need.

These labels are **not in any GitOps manifest**. If the namespace is ever re-created (e.g., disaster recovery, cluster rebuild), they're gone, and volsync + GPU workloads on those namespaces will fail with PSS rejection errors identical to what we saw at 12:30 UTC.

### Fix

Two patterns to choose between:

**(a) Bring the namespaces under GitOps with the labels.** The `default` namespace currently has a stale `argocd.argoproj.io/tracking-id: awx-operator:/Namespace:default/default` annotation from a deleted app. Reclaim it by adding a small `components/common/default-namespace/` (or similar) component that has a Namespace manifest with the PSS label. Same for `volsync-system`. Wire those as their own Argo Applications.

**(b) Add the namespaces to Talos's PSS exemptions instead** of overriding per-namespace. Edit `clusters/talos/bootstrap/os/clusterconfig/home-kubernetes-k8s-1-nab9.yaml` (and the other CP configs) so the PodSecurity admission config has:

```yaml
exemptions:
  namespaces:
    - kube-system
    - default          # ← add
    - volsync-system   # ← add
```

This requires regenerating Talos config + applying to all CPs. Cleaner long-term but touches every node.

**Recommendation:** (a). Keep the exemptions explicit and visible in the K8s-side GitOps tree rather than buried in Talos config.

---

## Loose end 7: GT 1030 idle but still managed by GPU Operator

### What it looks like

The GPU Operator's `nvidia-device-plugin-daemonset` on `k8s-4-dell` advertises **both** GPUs as allocatable:

```
"nvidia.com/gpu": "2"
```

Jellyfin uses one of them; the other (GT 1030) is technically allocatable to other workloads. But the GT 1030 (Pascal GP108) has **no NVENC support at all** — anything trying to use it for video encoding will hit `OpenEncodeSessionEx failed: unsupported device`. It can still do CUDA compute, just not NVENC/NVDEC.

### Risk

Low-medium. Any future pod that requests `nvidia.com/gpu: 1` and ends up on the GT 1030 will fail if it needs video encoding. CUDA-only workloads (model inference) would still work on the GT 1030, just slowly (compute capability 6.1, 2 GB VRAM).

### Fix

Two options:

1. **Exclude the GT 1030 from the device plugin's pool.** Configure the GPU Operator's `ClusterPolicy.spec.devicePlugin.config` with a ConfigMap that filters by UUID. The plugin will only advertise the RTX 3060, and `nvidia.com/gpu` allocatable will be `"1"`. Cleaner.

2. **Leave it; document.** Future pods requesting `nvidia.com/gpu: 1` get one of the two. For Jellyfin we worked around this with `CUDA_VISIBLE_DEVICES=<3060 UUID>` (commit `a20a2cc1`) — the UUID pin selects the 3060 inside the container regardless of which physical GPU the device plugin "allocated". For other GPU workloads, you'd repeat the same pattern.

---

## Things that look weird but are correct — don't fix

Documenting these so future-me doesn't go chasing them:

1. **Jellyfin pod's `NVIDIA_VISIBLE_DEVICES=void`** despite `values.yaml` saying `all`. The GPU Operator runs the device plugin in CDI mode (`DEVICE_LIST_STRATEGY=cdi-annotations,cdi-cri`); the CDI flow overwrites that env var to `void` unconditionally to disable the legacy injection path. Doesn't matter — `privileged: true` plus CDI device-spec injection together give the pod access to both `/dev/nvidia0` and `/dev/nvidia1`.

2. **`nvidia-smi -L` inside the jellyfin pod shows both GPUs.** Misleading. It reads from the host's `/dev/nvidiactl` (accessible because the pod is privileged) and enumerates all host GPUs regardless of what the pod can actually use. The real test is **`ffmpeg -init_hw_device cuda=cu:0 -c:v hevc_nvenc`** — that hits NVENC and only succeeds on the 3060.

3. **CUDA's device order is `FASTEST_FIRST`, opposite of host PCI order.** Host PCI: GT 1030 at `0000:02:00.0` (index 0), 3060 at `0000:0b:00.0` (index 1). CUDA: 3060 (CC 8.6) at index 0, GT 1030 (CC 6.1) at index 1. **Always pin by UUID, never by index.**

4. **`ReplicationSource/jellyfin` runs cleanly on its 6-hour schedule** (last sync 06:09 UTC). It only takes a snapshot of `/config` on the live PVC — has nothing to do with the broken `ReplicationDestination/jellyfin-dst` situation in loose end #4.

5. **`SystemdCgroup = false` in the Talos containerd nvidia runtime patch**, even though many tutorials show `true`. Talos's kubelet uses cgroupfs driver — `true` causes `runc create failed: expected cgroupsPath to be of format "slice:prefix:name"`. The default runc runtime omits the flag (also defaults to false), which is why every other workload works without anyone noticing.

6. **`AllowAv1Encoding: false`** in jellyfin's `/config/config/encoding.xml`. The RTX 3060 (Ampere) supports AV1 *decode* but not encode. AV1 NVENC requires Ada Lovelace (RTX 4000+). The default Jellyfin behavior toggles AV1 encoding on if the chip is detected as supporting AV1 *something*, but it doesn't distinguish encode vs decode capability. Manually disabled — leave off.

---

## Useful commands for future debugging

```bash
# Confirm Jellyfin is actually using the 3060 (not the GT 1030)
KUBECONFIG=./kubeconfig kubectl exec -n default deploy/jellyfin -- \
  /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -v error \
  -init_hw_device cuda=cu:0 -f lavfi -i color=c=black:s=320x240:d=1 \
  -c:v hevc_nvenc -f null - 2>&1 ; echo "exit=$?"
# Should: exit=0, no error lines

# Live NVENC/NVDEC utilization
KUBECONFIG=./kubeconfig kubectl exec -n default deploy/jellyfin -- \
  nvidia-smi --query-gpu=index,name,utilization.encoder,utilization.decoder,memory.used \
  --format=csv -l 2

# Get GPU UUIDs (if you ever need to repeat the pin pattern for another app)
KUBECONFIG=./kubeconfig kubectl exec -n default deploy/jellyfin -- nvidia-smi -L

# GPU Operator + ClusterPolicy state
KUBECONFIG=./kubeconfig kubectl get applications -n argo-system \
  | grep -E "nvidia|gpu"
KUBECONFIG=./kubeconfig kubectl get clusterpolicy cluster-policy \
  -o jsonpath='{.status.state}{"\n"}'

# Ceph snapshot cleanup (for loose end 4)
KUBECONFIG=./kubeconfig kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  ceph status

# What's actually using `/var/mnt/media/.kopia` (loose end 5)
KUBECONFIG=./kubeconfig kubectl get replicationsources,replicationdestinations -A
```

---

## Recommended priority

If you only do two things:

1. **Loose end 5 option #1** (kopia sync-to S3 cronjob). One source of truth for backups should not be one disk.
2. **Loose end 6 option (a)** (GitOps the namespace PSS labels). Otherwise the cluster's disaster-recovery path is broken in a subtle way.

Everything else is convenience or cosmetics. NVENC works, Jellyfin is up, backups are running.
