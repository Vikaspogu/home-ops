# Homelab Architecture Rebuild — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate from 2 Kubernetes clusters (Talos + K3s/OMV) and 2 NAS solutions (Synology + OMV) into one Talos cluster, with Synology as the non-media NAS/Kopia target and `k8s-4-dell` local disks as the hot media tier.

**Architecture:** Current Talos keeps `k8s-1-nab9`, `k8s-2-ser`, and `k8s-3-pxm` as the control-plane/worker set, then adds `k8s-4-dell` as a worker-only GPU/media node. Rook-Ceph remains the block storage tier, Synology NFS stores non-media NAS data plus the Kopia repository, media/download/transcode paths live on `k8s-4-dell` Talos user volumes, and Garage's future storage-worker move remains deferred.

**Tech Stack:** Talos Linux, Kubernetes, Cilium, ArgoCD, Rook-Ceph, Garage S3, Synology NFS, VolSync/Kopia, Envoy Gateway, NVIDIA GPU (`k8s-4-dell`), KubeVirt

---

## Current Amendment Alignment

This plan has been updated to match the approved design spec as amended on 2026-05-08 and 2026-05-10:

- `k8s-3-pxm` is not replaced in this migration. It remains an etcd/control-plane member.
- `k8s-4-dell` is the current new node at `10.30.30.24`; the older Supermicro `k8s-4` plan is deferred and needs a future hostname/IP.
- Media moves from OMV to `k8s-4-dell` local Talos user volumes, not to Synology as the primary runtime path.
- Synology is the target for non-media NFS data, the Kopia repository, and media backup/replica after cutover.
- Garage on a future multi-HDD storage worker remains a separate later phase.

## File Structure

### Files to Modify

| File | Responsibility |
|------|---------------|
| `clusters/talos/bootstrap/os/talconfig.yaml` | Add `k8s-4-dell` worker-only node while keeping `k8s-3-pxm` in place |
| `clusters/talos/bootstrap/os/patches/global/machine-sysctls.yaml` | Add `vhost_net` kernel module |
| `components/rook-ceph/rook-ceph-cluster/values.yaml` | Keep current OSDs; reserve `k8s-4-dell` NVMe for a later OSD after media migration |
| `components/default/garage-app/values.yaml` | Keep OMV runtime until future storage-worker Garage cutover |
| `components/default/garage-app/resources/configuration.toml` | Future storage-worker multi-disk config only; not part of the immediate Talos media cutover |
| `components/default/jellyfin/values.yaml` | Replace OMV hostPath with `k8s-4-dell` local media/transcode hostPaths and add GPU resources |
| `components/default/syncthing/values.yaml` | Replace OMV hostPath with Synology NFS |
| `components/default/bytestash/values.yaml` | Replace OMV hostPath with Ceph PVC |
| `clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml` | Move Kopia repository NFS mount from OMV to Synology |
| `clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml` | Move Kopia maintenance repository NFS mount from OMV to Synology |
| `clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml` | Inject Synology NFS repository into VolSync mover pods |
| `clusters/talos/apps/kube-system/cilium/networking.yaml` | Narrow LB IP pool to dedicated range |
| `clusters/talos/apps/default/cloudnative-cluster/cluster.yaml` | Update S3 endpoint after DNS change |
| `components/default/reactive-resume/values.yaml` | Update S3 endpoint |
| `clusters/talos/apps/20-applications.yaml` | Add OMV apps that move to Talos and switch VolSync app env from Longhorn to Ceph |
| `components/default/gitea-runner/pvc-docker.yaml` | Replace the hardcoded `longhorn-volsync` storage class before removing Longhorn |

### Files to Create

| File | Responsibility |
|------|---------------|
| `clusters/talos/bootstrap/os/patches/global/machine-kernel-modules.yaml` | `vhost_net` kernel module for KubeVirt |
| `components/default/garage-app/kustomization-storage-worker.yaml` | Deferred Garage nodeSelector patch for the future storage worker |
| `components/kube-system/nvidia-device-plugin/kustomization.yaml` | NVIDIA device plugin DaemonSet |
| `components/kube-system/nvidia-device-plugin/values.yaml` | NVIDIA device plugin config |
| `components/default/filebrowser/kustomization.yaml` | FileBrowser app (read-only backup browser) |
| `components/default/filebrowser/values.yaml` | FileBrowser config |
| `components/default/filebrowser/http-route.yaml` | FileBrowser ingress |
| `components/default/media-rsync/kustomization.yaml` | rsync CronJob for `k8s-4-dell` media backup/replica to Synology |
| `components/default/media-rsync/cronjob.yaml` | rsync CronJob spec |
| `components/kubevirt/kubevirt-operator/kustomization.yaml` | KubeVirt operator |
| `components/kubevirt/kubevirt-operator/values.yaml` | KubeVirt operator config |
| `components/kubevirt/cdi/kustomization.yaml` | CDI operator |
| `components/kubevirt/kubevirt-manager/kustomization.yaml` | kubevirt-manager web UI |
| `components/default/nfs-healthcheck/kustomization.yaml` | NFS health-check CronJob |
| `components/default/nfs-healthcheck/cronjob.yaml` | NFS health-check spec |

### Files to Delete

| File | Reason |
|------|--------|
| `clusters/omv/` (entire directory) | OMV/K3s cluster decommissioned |
| `components/storage/velero/` | Velero removed |
| `components/longhorn-system/` | Longhorn removed (OMV only) |
| `components/storage/openebs/` | OpenEBS unused |

---

## Phase 1: Pre-Migration Code Changes (Git commits, no cluster changes yet)

### Task 1: Confirm Current IP Addressing Plan

The approved spec already contains the current IP plan. Do not reopen the earlier `k8s-3` replacement plan in this task.

**Files:**
- No repo changes unless the live network inventory differs from the spec.

- [ ] **Step 1: Confirm the current plan**

Use this as the expected inventory:

```
Host IPs:
  k8s-1: 10.30.30.21
  k8s-2: 10.30.30.22
  k8s-3-pxm: 10.30.30.23
  k8s-4-dell: 10.30.30.24
  Synology: 10.30.30.10 (existing)

VIP (Kubernetes API): 10.30.30.150

Cilium LB Pool: 10.30.30.160-10.30.30.200
  - Excludes all host IPs (.10, .21-.24)
  - Excludes VIP (.150)
  - Excludes DHCP range (check Unifi config)

Unifi DHCP range: 10.30.30.100-10.30.30.149 (or whatever is configured)
```

- [ ] **Step 2: Verify Cilium pool config still matches**

Run:
```bash
rg -n "10\\.30\\.30\\.(160|200)|start:|stop:" clusters/talos/apps/kube-system/cilium/networking.yaml
```
Expected: the load balancer pool is a dedicated range that does not include host IPs, Synology, DHCP, or the API VIP.

---

### Task 2: Keep Garage Storage Worker Work Deferred

The current amended spec keeps Garage's multi-HDD storage-worker migration out of the immediate `k8s-4-dell` media cutover. Do not assign the deferred Supermicro node to `k8s-4` or `10.30.30.24` in this plan.

**Files:**
- No immediate repo changes.

- [ ] **Step 1: Preserve the future storage-worker assumptions**

Keep these assumptions for the later Garage phase:
- The future storage worker gets a new hostname/IP.
- Its HDDs are mounted individually through Talos machine config.
- Garage uses multiple `data_dir` entries on that future worker.
- `s3.omv.a113.casa` can be repointed after Garage is healthy on the future worker.

- [ ] **Step 2: Do not modify Garage runtime for the media cutover**

During the immediate OMV-to-Talos media migration, leave Garage serving from its current runtime until the separate Garage storage-worker cutover is executed.

Reference future config shape only:

```toml
metadata_dir = "/meta"
data_dir = [
  { path = "/data1", capacity = "3600GiB" },
  { path = "/data2", capacity = "3600GiB" },
  { path = "/data3", capacity = "3600GiB" },
  { path = "/data4", capacity = "3600GiB" },
]
```

---

### Task 3: Update Talos Node Definitions

Add `k8s-4-dell` as a worker-only Talos node. Keep `k8s-3-pxm` unchanged as the third control-plane/etcd member.

**Files:**
- Modify: `clusters/talos/bootstrap/os/talconfig.yaml`

- [ ] **Step 1: Verify k8s-3-pxm remains in place**

Run:
```bash
rg -n 'hostname: "k8s-3-pxm"|ipAddress: "10\.30\.30\.23"|controlPlane: true' clusters/talos/bootstrap/os/talconfig.yaml
```
Expected: `k8s-3-pxm` is still present as a control-plane node. Do not replace it in this migration.

- [ ] **Step 2: Add k8s-4-dell worker-only node**

Add a worker node for the Dell tower at `10.30.30.24` using the NVIDIA-capable Talos image from the amended spec.

```yaml
  - hostname: "k8s-4-dell"
    ipAddress: "10.30.30.24"
    installDiskSelector:
      model: CT500MX500SSD1
    talosImageURL: factory.talos.dev/installer/c1c8847e58bca7ae9584c3b209f21c50add404d9cb9466a1d4ea8be43a160b8a
    controlPlane: false
    networkInterfaces:
      - deviceSelector:
          hardwareAddr: "d8:9e:f3:3c:9b:81"
        dhcp: false
        addresses:
          - "10.30.30.24/24"
        routes:
          - network: 0.0.0.0/0
            gateway: "10.30.30.1"
        mtu: 1500
    schematic:
      customization:
        systemExtensions:
          officialExtensions:
            - siderolabs/nfsrahead
            - siderolabs/nonfree-kmod-nvidia-lts
            - siderolabs/nvidia-container-toolkit-lts
```

- [ ] **Step 3: Add k8s-4-dell user volume config**

Create Talos user volumes for local media, downloads, and transcode paths. The exact manifest location should match the current Talos bootstrap layout.

```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: media
provisioning:
  diskSelector:
    match: disk.transport == "sata"
  minSize: 1TB
  maxSize: 8TB
filesystem:
  type: xfs
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: downloads
provisioning:
  diskSelector:
    match: disk.transport == "nvme"
  minSize: 100GB
  maxSize: 512GB
filesystem:
  type: xfs
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: transcode
provisioning:
  diskSelector:
    match: disk.transport == "nvme"
  minSize: 50GB
  maxSize: 256GB
filesystem:
  type: xfs
```

Expected runtime paths after apply:
- `/var/mnt/media`
- `/var/mnt/downloads`
- `/var/mnt/transcode`

- [ ] **Step 4: Verify talconfig structure**

Run:
```bash
cd clusters/talos/bootstrap/os && cat talconfig.yaml | grep -c "hostname:"
```
Expected: `4` current nodes (`k8s-1-nab9`, `k8s-2-ser`, `k8s-3-pxm`, `k8s-4-dell`).

- [ ] **Step 5: Commit**

```bash
git add clusters/talos/bootstrap/os/talconfig.yaml
git commit -m "feat: add k8s-4-dell Talos worker with local media volumes"
```

---

### Task 4: Add vhost_net Kernel Module for KubeVirt

All nodes need the `vhost_net` kernel module for KubeVirt VM support.

**Files:**
- Create: `clusters/talos/bootstrap/os/patches/global/machine-kernel-modules.yaml`
- Modify: `clusters/talos/bootstrap/os/talconfig.yaml` (add patch reference)

- [ ] **Step 1: Create the kernel module patch**

```yaml
machine:
  kernel:
    modules:
      - name: vhost_net
```

Write to `clusters/talos/bootstrap/os/patches/global/machine-kernel-modules.yaml`.

- [ ] **Step 2: Add patch reference to talconfig.yaml**

Add `"@./patches/global/machine-kernel-modules.yaml"` to the `patches` list in talconfig.yaml:

```yaml
patches:
  - "@./patches/global/machine-files.yaml"
  - "@./patches/global/machine-kubelet.yaml"
  - "@./patches/global/machine-kernel-modules.yaml"
  - "@./patches/global/machine-network.yaml"
  - "@./patches/global/machine-sysctls.yaml"
  - "@./patches/global/machine-time.yaml"
```

- [ ] **Step 3: Commit**

```bash
git add clusters/talos/bootstrap/os/patches/global/machine-kernel-modules.yaml clusters/talos/bootstrap/os/talconfig.yaml
git commit -m "feat: add vhost_net kernel module patch for KubeVirt support"
```

---

### Task 5: Narrow CiliumLoadBalancerIPPool

Replace the overly broad `10.30.30.0/24` with a dedicated range that doesn't overlap host IPs or VIP.

**Files:**
- Modify: `clusters/talos/apps/kube-system/cilium/networking.yaml`

- [ ] **Step 1: Update the IP pool CIDR to a dedicated range**

In `clusters/talos/apps/kube-system/cilium/networking.yaml`, replace the CiliumLoadBalancerIPPool block:

Old:
```yaml
spec:
  allowFirstLastIPs: "No"
  blocks:
    - cidr: 10.30.30.0/24
```

New:
```yaml
spec:
  allowFirstLastIPs: "No"
  blocks:
    - start: "10.30.30.160"
      stop: "10.30.30.200"
```

This gives 41 LB IPs, avoiding:
- Host IPs: .10, .21-.24
- VIP: .150
- DHCP range

- [ ] **Step 2: Commit**

```bash
git add clusters/talos/apps/kube-system/cilium/networking.yaml
git commit -m "fix: narrow CiliumLoadBalancerIPPool to 10.30.30.160-200, avoid host/VIP overlap"
```

---

### Task 6: Keep Ceph OSD Changes Deferred for k8s-4-dell

Do not add a `k8s-4-dell` OSD during the media cutover. The amended spec reserves `k8s-4-dell` `nvme0n1` / Kingston `SNV3S1000G` 1TB NVMe for a future Rook/Ceph OSD after media migration.

**Files:**
- No immediate repo changes unless current values drift from the spec.

- [ ] **Step 1: Verify current explicit OSD list**

Run:
```bash
rg -n 'name: "k8s-1-nab9"|name: "k8s-2-ser"|name: "k8s-3-pxm"|name: "k8s-4-dell"|SNV3S1000G|nvme0n1' components/rook-ceph/rook-ceph-cluster/values.yaml
```

Expected current storage nodes:
```yaml
    nodes:
      - name: "k8s-1-nab9"
        devices:
          - name: "nvme0n1"
      - name: "k8s-2-ser"
        devices:
          - name: "nvme0n1"
      - name: "k8s-3-pxm"
        devices:
          - name: "sdb"
```

If `k8s-4-dell` is already listed here before media migration is complete, stop and validate the disk assignment. Do not consume the reserved `SNV3S1000G` NVMe as a user volume.

- [ ] **Step 2: Document future OSD addition after media cutover**

Future change after media is stable: add `k8s-4-dell` with explicit device `nvme0n1` only after confirming it is the Kingston `SNV3S1000G` 1TB NVMe and is not allocated to a Talos user volume.

---

### Task 7: Keep Garage Multi-Disk Deployment Deferred

Garage remains on the current runtime through the immediate media/Kopia migration. This task records the future storage-worker shape only.

**Files:**
- No immediate repo changes.

- [ ] **Step 1: Keep current Garage component unchanged during Phase 1**

Do not change `components/default/garage-app/values.yaml` or `components/default/garage-app/resources/configuration.toml` as part of the OMV media and Kopia cutover unless you are actively executing the separate Garage storage-worker migration.

- [ ] **Step 2: Future multi-disk Garage configuration**

Use this only after the future storage worker has a new hostname/IP and mounted HDD paths:

```toml
metadata_dir = "/meta"

data_dir = [
  { path = "/data1", capacity = "3600GiB" },
  { path = "/data2", capacity = "3600GiB" },
  { path = "/data3", capacity = "3600GiB" },
  { path = "/data4", capacity = "3600GiB" },
]

db_engine = "lmdb"
metadata_auto_snapshot_interval = "6h"

replication_factor = 1

compression_level = 2

rpc_bind_addr = "[::]:3901"
rpc_public_addr = "127.0.0.1:3901"

[s3_api]
s3_region = "garage"
api_bind_addr = "[::]:3900"

[admin]
api_bind_addr = "[::]:3903"
```

- [ ] **Step 3: Future Garage hostPath shape**

Use future storage-worker mount paths, not `k8s-4-dell` media paths:
```yaml
persistence:
  data1:
    type: hostPath
    hostPath: /var/mnt/hdd1/garage
    globalMounts:
      - path: /data1
  data2:
    type: hostPath
    hostPath: /var/mnt/hdd2/garage
    globalMounts:
      - path: /data2
  data3:
    type: hostPath
    hostPath: /var/mnt/hdd3/garage
    globalMounts:
      - path: /data3
  data4:
    type: hostPath
    hostPath: /var/mnt/hdd4/garage
    globalMounts:
      - path: /data4
  meta:
    type: hostPath
    hostPath: /var/mnt/hdd1/garage-meta
    globalMounts:
      - path: /meta
```

The actual hostPath `/var/mnt/hddN/` depends on the future storage-worker disk plan. Do not assume this node is `k8s-4-dell` or `10.30.30.24`.

Add `nodeSelector` only when the future storage-worker hostname is known:

```yaml
controllers:
  garage:
    annotations:
      reloader.stakater.com/auto: "true"
    pod:
      nodeSelector:
        kubernetes.io/hostname: <future-storage-worker>
```

---

### Task 8: Update Jellyfin for k8s-4-dell Local Media + GPU

Replace the OMV hostPath with `k8s-4-dell` local media/transcode hostPaths and add GPU scheduling.

**Files:**
- Modify: `components/default/jellyfin/values.yaml`

- [ ] **Step 1: Replace OMV hostPath with k8s-4-dell hostPaths and add GPU resources**

Replace the `media` and `transcode` persistence entries:

Old:
```yaml
  transcode:
    enabled: true
    type: emptyDir
    globalMounts:
      - path: /transcode
  media:
    type: hostPath
    hostPath: /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/media
    globalMounts:
      - path: /nfs-nas-pvc
```

New:
```yaml
  transcode:
    type: hostPath
    hostPath: /var/mnt/transcode
    globalMounts:
      - path: /transcode
  media:
    type: hostPath
    hostPath: /var/mnt/media
    globalMounts:
      - path: /nfs-nas-pvc
```

Add GPU resource request to the container spec. In the `resources` section:

Old:
```yaml
        resources:
          requests:
            cpu: 100m
            memory: 2Gi
          limits:
            memory: 6Gi
```

New:
```yaml
        resources:
          requests:
            cpu: 100m
            memory: 2Gi
          limits:
            memory: 6Gi
            nvidia.com/gpu: 1
```

Add GPU tolerations in the `defaultPodOptions` section:

Old:
```yaml
defaultPodOptions:
  enableServiceLinks: false
```

New:
```yaml
defaultPodOptions:
  enableServiceLinks: false
  tolerations:
    - key: nvidia.com/gpu
      operator: Equal
      value: present
      effect: PreferNoSchedule
  nodeSelector:
    nvidia.com/gpu.present: "true"
    kubernetes.io/hostname: k8s-4-dell
```

Note: The `nodeSelector` label `nvidia.com/gpu.present` is set by the NVIDIA device plugin / Node Feature Discovery. Verify the exact label name after deploying the NVIDIA device plugin in Task 13. The hostname pin keeps hostPath media local to the pod.

- [ ] **Step 2: Commit**

```bash
git add components/default/jellyfin/values.yaml
git commit -m "feat: update Jellyfin for k8s-4-dell local media and GPU transcoding"
```

---

### Task 9: Update Syncthing for Synology NFS

Replace OMV hostPath mounts with Synology NFS.

**Files:**
- Modify: `components/default/syncthing/values.yaml`

- [ ] **Step 1: Replace OMV hostPaths with NFS volumes**

Replace both persistence entries that use the OMV UUID path.

Old config hostPath:
```yaml
    hostPath: /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/syncthing/config
```

New:
```yaml
    type: nfs
    server: 10.30.30.10
    path: /volume1/syncthing/config
```

Old data hostPath:
```yaml
    hostPath: /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/syncthing/data
```

New:
```yaml
    type: nfs
    server: 10.30.30.10
    path: /volume1/syncthing/data
```

- [ ] **Step 2: Commit**

```bash
git add components/default/syncthing/values.yaml
git commit -m "feat: migrate Syncthing storage from OMV hostPath to Synology NFS"
```

---

### Task 10: Update Bytestash Storage

Replace OMV hostPath with a Ceph PVC (small dataset, belongs on distributed storage).

**Files:**
- Modify: `components/default/bytestash/values.yaml`

- [ ] **Step 1: Replace OMV hostPath with PVC**

Replace the persistence entry:

Old:
```yaml
  data:
    type: hostPath
    hostPath: /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/bytestash
    globalMounts:
      - path: /data/snippets
```

New:
```yaml
  data:
    type: persistentVolumeClaim
    accessMode: ReadWriteOnce
    size: 2Gi
    storageClass: ceph-block
    globalMounts:
      - path: /data/snippets
```

- [ ] **Step 2: Commit**

```bash
git add components/default/bytestash/values.yaml
git commit -m "feat: migrate Bytestash from OMV hostPath to Ceph PVC"
```

---

### Task 11: Update S3 Endpoint References

All components referencing `s3.omv.a113.casa` keep the same hostname. The DNS record is repointed only during the later Garage storage-worker cutover, not during the immediate media/Kopia migration.

**Files:**
- No immediate repo changes if DNS stays same.

- [ ] **Step 1: Verify all S3 endpoint references**

No code changes are needed for:
- `clusters/talos/apps/default/cloudnative-cluster/cluster.yaml` (line 56: `endpointURL: https://s3.omv.a113.casa`)
- `components/default/reactive-resume/values.yaml` (line 41: `STORAGE_ENDPOINT: s3.omv.a113.casa`)

The Velero reference in `components/storage/velero/values.yaml` will be deleted entirely (Task 16).

- [ ] **Step 2: Keep DNS cutover attached to the deferred Garage phase**

During the future Garage storage-worker phase:
1. Get the Garage service's Cilium LB IP
2. Update DNS record `s3.omv.a113.casa` → new LB IP
3. Verify CNPG backup, VolSync, and Reactive Resume connectivity

---

### Task 11a: Update Kopia and VolSync Repository Mounts

Move the Talos Kopia UI, Kopia maintenance CronJob, and VolSync mover pods from OMV NFS to Synology NFS. This changes where the shared filesystem repository is mounted; app-level VolSync secrets keep using `filesystem:///repository`.

**Files:**
- Modify: `clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml`
- Modify: `clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml`
- Modify: `clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml`

- [ ] **Step 1: Update Kopia deployment repository mount**

Replace:

```yaml
server: omv-baymx.a113.internal
path: "/storage0/VolsyncKopia"
```

with:

```yaml
server: 10.30.30.10
path: "/volume1/VolsyncKopia"
```

in `clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml`.

- [ ] **Step 2: Update Kopia maintenance repository mount**

Apply the same replacement in `clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml`.

- [ ] **Step 3: Update VolSync mover injected repository mount**

Apply the same replacement in `clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml`.

- [ ] **Step 4: Verify rendered manifests**

Run:
```bash
kustomize build --enable-helm clusters/talos/apps/volsync-system/kopia | rg "10.30.30.10|/volume1/VolsyncKopia|omv-baymx"
kustomize build --enable-helm clusters/talos/apps/volsync-system/volsync | rg "10.30.30.10|/volume1/VolsyncKopia|omv-baymx"
```

Expected: Synology server/path render; `omv-baymx` does not render in either output.

- [ ] **Step 5: Commit**

```bash
git add clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml
git commit -m "feat: move Kopia and VolSync repository mounts to Synology"
```

---

### Task 12: Consolidate Applications into Talos Cluster

Move apps currently deployed only on OMV cluster into the Talos cluster's ArgoCD config. Apps that use shared `components/` definitions just need entries in `clusters/talos/apps/20-applications.yaml`.

For apps restored through VolSync, keep the ArgoCD app name, Kubernetes namespace, and PVC name the same as the OMV source. The shared VolSync component uses `${ARGOCD_APP_NAME}` for the `ReplicationSource`, `ReplicationDestination`, PVC name, repository secret, and `sourceIdentity.sourceName`; changing the app name breaks automatic restore identity matching.

**Files:**
- Modify: `clusters/talos/apps/20-applications.yaml`

- [ ] **Step 1: Add OMV-only apps to Talos applications manifest**

Add entries for apps that currently only exist in `clusters/omv/apps/20-applications.yaml` and are not already in Talos. Comparing the two files:

Apps already in Talos: argo-cd, valkey, homepage
Apps to add from OMV: garage-app, bytestash, syncthing, jellyfin, gitea, gitea-runner

Add to `clusters/talos/apps/20-applications.yaml`:

```yaml
  garage-app:
    annotations:
      argocd.argoproj.io/sync-wave: "20"
    destination:
      namespace: default
    source:
      path: components/default/garage-app

  bytestash:
    annotations:
      argocd.argoproj.io/sync-wave: "20"
    destination:
      namespace: default
    source:
      path: components/default/bytestash

  syncthing:
    annotations:
      argocd.argoproj.io/sync-wave: "20"
    destination:
      namespace: default
    source:
      path: components/default/syncthing

  jellyfin:
    annotations:
      argocd.argoproj.io/sync-wave: "20"
    destination:
      namespace: default
    source:
      path: components/default/jellyfin
      plugin:
        env:
          - name: STORAGE_CLASS
            value: ceph-block
          - name: VOLUME_SNAPSHOT_CLASS
            value: csi-ceph-blockpool
          - name: VOLSYNC_CAPACITY
            value: 10Gi
          - name: VOLSYNC_CACHE_CAPACITY
            value: 15Gi

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
          - name: VOLSYNC_CAPACITY
            value: 2Gi
          - name: VOLSYNC_CACHE_CAPACITY
            value: 8Gi
```

Note: Rancher is NOT migrated (was OMV-only, decommissioned with OMV cluster).

- [ ] **Step 2: Replace gitea-runner Docker PVC storage class**

`components/default/gitea-runner/pvc-docker.yaml` is not generated by the VolSync component and currently hardcodes the OMV-only Longhorn storage class. Replace:

```yaml
storageClassName: longhorn-volsync
```

with:

```yaml
storageClassName: ceph-block
```

Keep the PVC name `gitea-runner-docker` and size `100Gi`.

- [ ] **Step 3: Commit**

```bash
git add clusters/talos/apps/20-applications.yaml components/default/gitea-runner/pvc-docker.yaml
git commit -m "feat: add OMV-migrated apps (Garage, Jellyfin, Syncthing, etc.) to Talos cluster"
```

---

### Task 13: Create NVIDIA Device Plugin Deployment

Deploy the NVIDIA device plugin DaemonSet for GPU scheduling on `k8s-4-dell`.

**Files:**
- Create: `components/kube-system/nvidia-device-plugin/kustomization.yaml`
- Create: `components/kube-system/nvidia-device-plugin/values.yaml`
- Modify: `clusters/talos/apps/30-system.yaml`

- [ ] **Step 1: Create kustomization.yaml**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
helmCharts:
  - name: nvidia-device-plugin
    repo: https://nvidia.github.io/k8s-device-plugin
    version: 0.17.1
    releaseName: nvidia-device-plugin
    namespace: kube-system
    valuesFile: values.yaml
```

Write to `components/kube-system/nvidia-device-plugin/kustomization.yaml`.

- [ ] **Step 2: Create values.yaml**

```yaml
---
tolerations:
  - key: nvidia.com/gpu
    operator: Equal
    value: present
    effect: PreferNoSchedule
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: feature.node.kubernetes.io/pci-10de.present
              operator: In
              values:
                - "true"
```

Write to `components/kube-system/nvidia-device-plugin/values.yaml`.

- [ ] **Step 3: Add ArgoCD application entry**

Add to `clusters/talos/apps/30-system.yaml`:

```yaml
  nvidia-device-plugin:
    annotations:
      argocd.argoproj.io/sync-wave: "30"
    destination:
      namespace: kube-system
    source:
      path: components/kube-system/nvidia-device-plugin
```

- [ ] **Step 4: Commit**

```bash
git add components/kube-system/nvidia-device-plugin/ clusters/talos/apps/30-system.yaml
git commit -m "feat: add NVIDIA device plugin for GPU scheduling on k8s-4-dell"
```

---

### Task 14: Create KubeVirt Operator + CDI + Manager

Deploy KubeVirt components for VM management. Zero overhead when idle (no VMs).

**Files:**
- Create: `components/kubevirt/kubevirt-operator/kustomization.yaml`
- Create: `components/kubevirt/kubevirt-operator/kubevirt-cr.yaml`
- Create: `components/kubevirt/cdi/kustomization.yaml`
- Create: `components/kubevirt/cdi/cdi-cr.yaml`
- Create: `components/kubevirt/kubevirt-manager/kustomization.yaml`
- Create: `components/kubevirt/kubevirt-manager/values.yaml`
- Create: `components/kubevirt/kubevirt-manager/http-route.yaml`
- Modify: `clusters/talos/apps/30-system.yaml`

- [ ] **Step 1: Create KubeVirt operator kustomization**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/kubevirt/kubevirt/releases/download/v1.5.1/kubevirt-operator.yaml
  - kubevirt-cr.yaml
```

Write to `components/kubevirt/kubevirt-operator/kustomization.yaml`.

- [ ] **Step 2: Create KubeVirt CR**

```yaml
---
apiVersion: kubevirt.io/v1
kind: KubeVirt
metadata:
  name: kubevirt
  namespace: kubevirt
spec:
  configuration:
    developerConfiguration:
      useEmulation: false
```

Write to `components/kubevirt/kubevirt-operator/kubevirt-cr.yaml`.

- [ ] **Step 3: Create CDI kustomization**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/kubevirt/containerized-data-importer/releases/download/v1.62.0/cdi-operator.yaml
  - cdi-cr.yaml
```

Write to `components/kubevirt/cdi/kustomization.yaml`.

- [ ] **Step 4: Create CDI CR**

```yaml
---
apiVersion: cdi.kubevirt.io/v1beta1
kind: CDI
metadata:
  name: cdi
spec:
  config:
    uploadProxyURLOverride: ""
```

Write to `components/kubevirt/cdi/cdi-cr.yaml`.

- [ ] **Step 5: Create kubevirt-manager kustomization and values**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
helmCharts:
  - name: kubevirt-manager
    repo: https://kubevirt-manager.github.io/kubevirt-manager
    version: 0.5.0
    releaseName: kubevirt-manager
    namespace: kubevirt
    valuesFile: values.yaml
resources:
  - http-route.yaml
```

Write to `components/kubevirt/kubevirt-manager/kustomization.yaml`.

```yaml
---
{}
```

Write to `components/kubevirt/kubevirt-manager/values.yaml`.

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: kubevirt-manager
  namespace: kubevirt
spec:
  parentRefs:
    - name: internal
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
    - kubevirt.${CLUSTER_DOMAIN}
  rules:
    - backendRefs:
        - name: kubevirt-manager
          port: 8080
```

Write to `components/kubevirt/kubevirt-manager/http-route.yaml`.

- [ ] **Step 6: Add ArgoCD application entries**

Add to `clusters/talos/apps/30-system.yaml`:

```yaml
  kubevirt-operator:
    annotations:
      argocd.argoproj.io/sync-wave: "30"
    destination:
      namespace: kubevirt
    source:
      path: components/kubevirt/kubevirt-operator

  cdi:
    annotations:
      argocd.argoproj.io/sync-wave: "30"
    destination:
      namespace: cdi
    source:
      path: components/kubevirt/cdi

  kubevirt-manager:
    annotations:
      argocd.argoproj.io/sync-wave: "30"
    destination:
      namespace: kubevirt
    source:
      path: components/kubevirt/kubevirt-manager
```

- [ ] **Step 7: Commit**

```bash
git add components/kubevirt/ clusters/talos/apps/30-system.yaml
git commit -m "feat: add KubeVirt operator, CDI, and kubevirt-manager for VM support"
```

---

### Task 15: Create NFS Health Check CronJob

Monitor Synology NFS availability and alert on failures.

**Files:**
- Create: `components/default/nfs-healthcheck/kustomization.yaml`
- Create: `components/default/nfs-healthcheck/cronjob.yaml`
- Modify: `clusters/talos/apps/30-system.yaml`

- [ ] **Step 1: Create kustomization.yaml**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cronjob.yaml
```

Write to `components/default/nfs-healthcheck/kustomization.yaml`.

- [ ] **Step 2: Create cronjob.yaml**

```yaml
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nfs-healthcheck
spec:
  schedule: "*/5 * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      activeDeadlineSeconds: 60
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: check
              image: busybox:1.37
              command:
                - /bin/sh
                - -c
                - |
                  if ls /nfs-test/ > /dev/null 2>&1; then
                    echo "NFS mount healthy"
                  else
                    echo "ERROR: NFS mount failed"
                    exit 1
                  fi
              volumeMounts:
                - name: nfs-test
                  mountPath: /nfs-test
                  readOnly: true
          volumes:
            - name: nfs-test
              nfs:
                server: 10.30.30.10
                path: /volume1/media
```

Write to `components/default/nfs-healthcheck/cronjob.yaml`.

- [ ] **Step 3: Add ArgoCD application entry**

Add to `clusters/talos/apps/30-system.yaml`:

```yaml
  nfs-healthcheck:
    annotations:
      argocd.argoproj.io/sync-wave: "30"
    destination:
      namespace: default
    source:
      path: components/default/nfs-healthcheck
```

- [ ] **Step 4: Commit**

```bash
git add components/default/nfs-healthcheck/ clusters/talos/apps/30-system.yaml
git commit -m "feat: add NFS health-check CronJob for Synology monitoring"
```

---

### Task 16: Create FileBrowser for Browsable Backups

Deploy FileBrowser only after the future storage worker exists and has a local backup copy of Synology data. Do not pin this workload to `k8s-4-dell` as part of the media cutover.

**Files:**
- Create: `components/default/filebrowser/kustomization.yaml`
- Create: `components/default/filebrowser/values.yaml`
- Create: `components/default/filebrowser/http-route.yaml`
- Modify: `clusters/talos/apps/20-applications.yaml`

- [ ] **Step 1: Create kustomization.yaml**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
helmCharts:
  - name: app-template
    repo: https://bjw-s.github.io/helm-charts
    version: 3.7.3
    releaseName: filebrowser
    namespace: default
    valuesFile: values.yaml
resources:
  - http-route.yaml
```

Write to `components/default/filebrowser/kustomization.yaml`.

- [ ] **Step 2: Create values.yaml**

```yaml
---
controllers:
  filebrowser:
    strategy: Recreate
    containers:
      app:
        image:
          repository: filebrowser/filebrowser
          tag: v2.31.2
        env:
          TZ: America/New_York
          FB_DATABASE: /config/filebrowser.db
          FB_ROOT: /data
          FB_NOAUTH: "true"
        resources:
          requests:
            cpu: 10m
            memory: 64Mi
          limits:
            memory: 256Mi
    pod:
      nodeSelector:
        kubernetes.io/hostname: <future-storage-worker>

service:
  app:
    ports:
      http:
        port: 80

persistence:
  config:
    type: emptyDir
    globalMounts:
      - path: /config
  data:
    type: hostPath
    hostPath: /var/mnt/backup/synology
    globalMounts:
      - path: /data
        readOnly: true
```

Write to `components/default/filebrowser/values.yaml`.

Note: The `hostPath` for data depends on where the future storage worker writes Synology backups. This is deferred until that worker has a hostname/IP and mounted HDD paths.

- [ ] **Step 3: Create http-route.yaml**

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: filebrowser
spec:
  parentRefs:
    - name: internal
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
    - files.${CLUSTER_DOMAIN}
  rules:
    - backendRefs:
        - name: filebrowser
          port: 80
```

Write to `components/default/filebrowser/http-route.yaml`.

- [ ] **Step 4: Add ArgoCD application entry**

Add to `clusters/talos/apps/20-applications.yaml`:

```yaml
  filebrowser:
    annotations:
      argocd.argoproj.io/sync-wave: "20"
    destination:
      namespace: default
    source:
      path: components/default/filebrowser
```

- [ ] **Step 5: Commit**

```bash
git add components/default/filebrowser/ clusters/talos/apps/20-applications.yaml
git commit -m "feat: add FileBrowser for browsable Synology backup access"
```

---

### Task 17: Create Media rsync Backup CronJob

Nightly rsync from `k8s-4-dell` local media storage to Synology for the media backup/replica copy.

**Files:**
- Create: `components/default/media-rsync/kustomization.yaml`
- Create: `components/default/media-rsync/cronjob.yaml`
- Modify: `clusters/talos/apps/30-system.yaml`

- [ ] **Step 1: Create kustomization.yaml**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cronjob.yaml
```

Write to `components/default/media-rsync/kustomization.yaml`.

- [ ] **Step 2: Create cronjob.yaml**

```yaml
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: media-rsync
spec:
  schedule: "0 2 * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      activeDeadlineSeconds: 28800
      template:
        spec:
          restartPolicy: Never
          nodeSelector:
            kubernetes.io/hostname: k8s-4-dell
          containers:
            - name: rsync
              image: ghcr.io/home-operations/rsync:3.4.1
              command:
                - /bin/sh
                - -c
                - |
                  echo "Starting media replica $(date)"
                  rsync -avhP --delete \
                    /media/ /synology/media/ && \
                  echo "Media replica complete $(date)"
              volumeMounts:
                - name: media
                  mountPath: /media
                  readOnly: true
                - name: synology-media
                  mountPath: /synology/media
              resources:
                requests:
                  cpu: 50m
                  memory: 128Mi
                limits:
                  memory: 512Mi
          volumes:
            - name: media
              hostPath:
                path: /var/mnt/media
                type: Directory
            - name: synology-media
              nfs:
                server: 10.30.30.10
                path: /volume1/media
```

Write to `components/default/media-rsync/cronjob.yaml`.

Note: This is media replica direction only. Non-media Synology backup to a future storage worker remains deferred until that worker exists. The `rsync` container image may need to be updated; use a pinned digest before deploying.

- [ ] **Step 3: Add ArgoCD application entry**

Add to `clusters/talos/apps/30-system.yaml`:

```yaml
  media-rsync:
    annotations:
      argocd.argoproj.io/sync-wave: "30"
    destination:
      namespace: default
    source:
      path: components/default/media-rsync
```

- [ ] **Step 4: Commit**

```bash
git add components/default/media-rsync/ clusters/talos/apps/30-system.yaml
git commit -m "feat: add nightly k8s-4-dell media replica to Synology"
```

---

### Task 18: Decide GPU Taint for k8s-4-dell

The amended spec says `k8s-4-dell` is currently untainted. Decide whether to add `PreferNoSchedule` before pinning GPU workloads broadly.

**Files:**
- No immediate repo changes unless a taint automation manifest is added.

- [ ] **Step 1: Verify current node labels**

Run after `k8s-4-dell` joins:

```bash
kubectl get node k8s-4-dell --show-labels
```

Expected: NVIDIA labels are present after Node Feature Discovery / NVIDIA device plugin is running.

- [ ] **Step 2: Optional taint**

If the cluster should avoid general workloads landing on the GPU/media node, apply:

```bash
kubectl taint nodes k8s-4-dell nvidia.com/gpu=present:PreferNoSchedule
```

If general workloads are acceptable on `k8s-4-dell`, leave the node untainted and rely on explicit `nodeSelector` for Jellyfin/media workloads.

- [ ] **Step 3: Ensure label exists for GPU selectors**

Run if Node Feature Discovery has not created the expected label:
```bash
kubectl label nodes k8s-4-dell nvidia.com/gpu.present=true --overwrite
```

---

## Phase 2: Cleanup — Remove Decommissioned Components

### Task 19: Remove OMV Cluster Configuration

Delete the entire OMV cluster directory and related components.

**Files:**
- Delete: `clusters/omv/` (entire directory)

- [ ] **Step 1: Remove OMV cluster directory**

```bash
git rm -r clusters/omv/
```

- [ ] **Step 2: Commit**

```bash
git commit -m "chore: remove decommissioned OMV/K3s cluster configuration"
```

---

### Task 20: Remove Velero, Longhorn, and OpenEBS Components

Remove storage backends that are no longer used.

**Files:**
- Delete: `components/storage/velero/` (Velero removed per spec)
- Delete: `components/longhorn-system/` (Longhorn was OMV-only)
- Delete: `components/storage/openebs/` (unused)

- [ ] **Step 1: Check for references before deleting**

```bash
grep -r "velero" clusters/talos/ components/ --include="*.yaml" -l
grep -r "longhorn" clusters/talos/ components/ --include="*.yaml" -l
grep -r "openebs" clusters/talos/ components/ --include="*.yaml" -l
```

Expected: No references in `clusters/talos/` (only in `clusters/omv/` which was already deleted in Task 19). If there are references in `clusters/talos/`, remove them before deleting the component directories.

- [ ] **Step 2: Remove directories**

```bash
git rm -r components/storage/velero/ || true
git rm -r components/longhorn-system/ || true
git rm -r components/storage/openebs/ || true
```

- [ ] **Step 3: Commit**

```bash
git commit -m "chore: remove Velero, Longhorn, and OpenEBS components"
```

---

### Task 21: Remove Proxmox-Related Config

Do not remove `k8s-3-pxm` or Proxmox-specific Talos config during this migration. The amended spec keeps that node in place.

**Files:**
- No immediate repo changes.

- [ ] **Step 1: Verify k8s-3-pxm references remain intentional**

```bash
grep -ri "proxmox\|nocloud\|qemu-guest-agent\|k8s-3-pxm" clusters/ components/ --include="*.yaml" -l
```

Expected: references tied to `k8s-3-pxm` may remain. Only remove Proxmox config in a future maintenance plan that explicitly replaces `k8s-3-pxm`.

---

## Phase 3: Operational Runbook (Manual Steps During Maintenance Window)

These are not code changes — they're operational procedures executed during the maintenance window. Document them here for reference.

### Task 22: Pre-Migration Data Transfer Runbook

This is the Phase 1a/1b/1c operational procedure. Execute from a workstation with kubectl access to Talos and network access to OMV and Synology. Media copies to `k8s-4-dell` local storage; non-media NAS data and the Kopia repository copy to Synology.

- [ ] **Step 1: Start bulk media rsync from OMV to k8s-4-dell (Phase 1a)**

Run as a temporary Kubernetes Job pinned to `k8s-4-dell`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: omv-media-to-k8s4-dell
  namespace: default
spec:
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/hostname: k8s-4-dell
      containers:
        - name: rsync
          image: ghcr.io/home-operations/rsync:3.4.1
          command:
            - sh
            - -c
            - |
              rsync -aH --numeric-ids --info=progress2 --partial --inplace /source/ /dest/
          volumeMounts:
            - name: source
              mountPath: /source
              readOnly: true
            - name: dest
              mountPath: /dest
      volumes:
        - name: source
          nfs:
            server: omv-baymx.a113.internal
            path: /storage0/media
        - name: dest
          hostPath:
            path: /var/mnt/media
            type: DirectoryOrCreate
```

Do not use `--delete` for the first online pass.

- [ ] **Step 2: Start bulk non-media rsync from OMV to Synology**

Run in tmux sessions on OMV or a workstation:

```bash
# Syncthing
rsync -avhP --info=progress2 omv:/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/syncthing/ synology:/volume1/syncthing/

# Nextcloud
rsync -avhP --info=progress2 omv:/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/nextcloud/ synology:/volume1/nextcloud/

# Bytestash (small)
rsync -avhP --info=progress2 omv:/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/bytestash/ synology:/volume1/bytestash/

# Kopia repository used by VolSync
rsync -aH --numeric-ids --info=progress2 --partial omv:/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/VolsyncKopia/ synology:/volume1/VolsyncKopia/
```

- [ ] **Step 3: Stage Garage data to Synology (Phase 1b)**

Garage staging is separate from the media cutover. Follow `docs/superpowers/plans/2026-05-08-garage-omv-to-synology-staging.md` for the cold metadata sync requirements. The quick reference is:

```bash
rsync -avhP --info=progress2 omv:/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage/ synology:/volume1/staging/garage/
rsync -avhP --info=progress2 omv:/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage-meta/ synology:/volume1/staging/garage-meta/
```

- [ ] **Step 4: Verify (Phase 1c)**

```bash
# Compare file counts
ssh omv "find /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/media -type f | wc -l"
kubectl -n default logs job/omv-media-to-k8s4-dell

# Compare non-media and Kopia repository counts
ssh omv "find /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/VolsyncKopia -type f | wc -l"
ssh synology "find /volume1/VolsyncKopia -type f | wc -l"

# Spot check media from k8s-4-dell local media path after the app cutover
# Checksum Garage metadata
ssh omv "md5sum /srv/.../garage-meta/db"
ssh synology "md5sum /volume1/staging/garage-meta/db"
```

Do NOT proceed to Phase 1d until verified.

---

### Task 23: Media, NFS, and Kopia Cutover Runbook (Phase 1d)

Execute during the maintenance window.

- [ ] **Step 1: Stop writers for the data being moved**

Scale down apps that write to media, OMV-backed non-media paths, or VolSync/Kopia repository state:

```bash
kubectl -n default scale deploy/jellyfin --replicas=0 || true
kubectl -n default scale deploy/sonarr --replicas=0 || true
kubectl -n default scale deploy/radarr --replicas=0 || true
kubectl -n default scale deploy/bazarr --replicas=0 || true
kubectl -n downloads scale deploy/qbittorrent --replicas=0 || true
kubectl -n downloads scale deploy/sabnzbd --replicas=0 || true
kubectl -n default scale deploy/syncthing --replicas=0 || true
kubectl -n volsync-system patch cronjob/kopia-maintenance --type=merge -p '{"spec":{"suspend":true}}' || true
kubectl get jobs -A | rg 'volsync|kopia' || true
```

Do not proceed if active VolSync mover jobs are still running against the old OMV repository.

- [ ] **Step 2: Final delta rsync**

```bash
# Re-run the k8s-4-dell media rsync Job with --delete added to the rsync command.
# Catch any changes since bulk transfer for Synology-backed data.
rsync -avhP --delete omv:/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/syncthing/ synology:/volume1/syncthing/
rsync -avhP --delete omv:/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/nextcloud/ synology:/volume1/nextcloud/
rsync -avhP --delete omv:/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/bytestash/ synology:/volume1/bytestash/
rsync -aH --numeric-ids --delete --info=progress2 omv:/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/VolsyncKopia/ synology:/volume1/VolsyncKopia/
```

- [ ] **Step 3: Push the code changes from Tasks 1-21**

Push the branch with all pre-migration code changes. ArgoCD should reconcile apps to:
- `k8s-4-dell` local hostPaths for media workloads
- Synology NFS for Syncthing, Nextcloud, and Kopia/VolSync repository mounts
- Ceph PVCs for VolSync-backed app config data

- [ ] **Step 4: ArgoCD sync and verify**

```bash
# Check ArgoCD sync status
argocd app list

# Verify media and Synology-backed apps are healthy
kubectl get pods -n default | grep -E "jellyfin|sonarr|radarr|bazarr|syncthing|nextcloud"
kubectl get pods -n downloads | grep -E "qbittorrent|sabnzbd"

# Verify Kopia and VolSync repository mounts use Synology
kubectl -n volsync-system get deploy/kopia cronjob/kopia-maintenance -o yaml | rg "10.30.30.10|/volume1/VolsyncKopia"
kubectl -n volsync-system get mutatingadmissionpolicy volsync-mover -o yaml | rg "10.30.30.10|/volume1/VolsyncKopia"
```

---

### Task 24: k8s-4-dell Readiness Runbook (Phase 2)

This phase validates the additive `k8s-4-dell` worker. It does not remove `k8s-3-pxm` from etcd.

- [ ] **Step 1: Take etcd snapshot before node/storage work**

```bash
talosctl etcd snapshot /tmp/etcd-backup-$(date +%Y%m%d).db --nodes 10.30.30.21
```

- [ ] **Step 2: Verify k8s-4-dell is joined and worker-only**

```bash
kubectl get nodes -o wide | rg 'k8s-3-pxm|k8s-4-dell'
talosctl disks --nodes 10.30.30.24
talosctl get uservolumes --nodes 10.30.30.24
```

Expected:
- `k8s-3-pxm` remains Ready.
- `k8s-4-dell` is Ready and is not an etcd/control-plane member.
- User volumes for media/downloads/transcode are present.

- [ ] **Step 3: Verify local media paths on k8s-4-dell**

Run a short-lived pod pinned to `k8s-4-dell` that mounts the host paths:

```bash
kubectl -n default run k8s4-media-check --restart=Never --image=ghcr.io/home-operations/busybox:1.37.0 --overrides='
{
  "spec": {
    "nodeSelector": {"kubernetes.io/hostname": "k8s-4-dell"},
    "containers": [{
      "name": "check",
      "image": "ghcr.io/home-operations/busybox:1.37.0",
      "command": ["sh", "-c", "df -h /media /downloads /transcode && touch /transcode/.write-test && rm /transcode/.write-test"],
      "volumeMounts": [
        {"name": "media", "mountPath": "/media"},
        {"name": "downloads", "mountPath": "/downloads"},
        {"name": "transcode", "mountPath": "/transcode"}
      ]
    }],
    "volumes": [
      {"name": "media", "hostPath": {"path": "/var/mnt/media", "type": "Directory"}},
      {"name": "downloads", "hostPath": {"path": "/var/mnt/downloads", "type": "Directory"}},
      {"name": "transcode", "hostPath": {"path": "/var/mnt/transcode", "type": "Directory"}}
    ]
  }
}'
kubectl -n default logs pod/k8s4-media-check
kubectl -n default delete pod/k8s4-media-check
```

- [ ] **Step 4: Verify GPU plugin and labels**

```bash
kubectl get node k8s-4-dell --show-labels | rg 'nvidia|gpu|pci-10de'
kubectl -n kube-system get pods | rg 'nvidia|device-plugin'
```

- [ ] **Step 5: Verify Ceph remains healthy without k8s-4-dell OSD**

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
```

Expected: current OSD set is healthy. A `k8s-4-dell` OSD is added only after media migration and separate disk assignment review.

---

### Task 25: Garage Data Migration Runbook (Phase 3)

This is deferred until the future storage worker has a new hostname/IP and mounted HDD paths.

- [ ] **Step 1: Copy Garage data from Synology staging to future storage-worker HDDs**

From a pod or node with access:

```bash
# Split Garage data across 4 HDDs by hex prefix
# Garage stores blocks in directories like 00/, 01/, ... ff/
# Distribute: 00-3f → hdd1, 40-7f → hdd2, 80-bf → hdd3, c0-ff → hdd4
rsync -avhP synology:/volume1/staging/garage/00/ /var/mnt/hdd1/garage/00/
# ... (script to distribute hex prefixes across 4 disks)

# Copy metadata to hdd1 on the future storage worker
rsync -avhP synology:/volume1/staging/garage-meta/ /var/mnt/hdd1/garage-meta/
```

- [ ] **Step 2: Deploy Garage and register node**

```bash
# ArgoCD should pick up the new Garage config
# Then register the node and assign partitions
kubectl exec -n default deploy/garage -- garage node id
kubectl exec -n default deploy/garage -- garage layout assign <node-id> -z dc1 -c 14T
kubectl exec -n default deploy/garage -- garage layout apply --version 1
```

- [ ] **Step 3: Verify Garage S3**

```bash
# List buckets
kubectl exec -n default deploy/garage -- garage bucket list
# Check each bucket
kubectl exec -n default deploy/garage -- garage bucket info postgres
kubectl exec -n default deploy/garage -- garage bucket info volsync
```

- [ ] **Step 4: Update DNS**

Update `s3.omv.a113.casa` DNS record to point to the new Garage Cilium LB IP.

```bash
# Get Garage service LB IP
kubectl get svc -n default garage -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# Update DNS record (in Unifi or Cloudflare)
```

- [ ] **Step 5: Verify CNPG backup connectivity**

```bash
kubectl -n default exec -it postgres17-1 -- pg_isready
# Check barman backup status
kubectl get scheduledbackup -n default
```

---

## Summary Checklist

| Phase | Tasks | Type |
|-------|-------|------|
| Phase 1 (Pre-migration code) | Tasks 1-18 | Git commits |
| Phase 2 (Cleanup) | Tasks 19-21 | Git commits |
| Phase 3 (Operational) | Tasks 22-25 | Manual runbook |

**Critical path blockers:**
1. Confirmed `k8s-4-dell` Talos user volumes — blocks media app cutover.
2. Synology NFS exports for `syncthing`, `nextcloud`, and `VolsyncKopia` — blocks non-media/Kopia cutover.
3. Final cold Kopia repository sync with no active VolSync mover jobs — blocks safe OMV shutdown.
4. Future storage-worker hostname/IP and HDD mount plan — blocks deferred Garage/FileBrowser work.
