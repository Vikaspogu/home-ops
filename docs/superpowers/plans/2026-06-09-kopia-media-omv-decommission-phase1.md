# Kopia + Media OMV Decommission — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Relocate the media library (2.9 TB) and the Kopia backup repository (68 GB) off the OMV NAS onto `k8s-4-dell` local XFS disk via `hostPath`, repoint every consuming app, migrate Jellyfin from the OMV cluster to Talos, validate a backup+restore round-trip, then power off OMV — with zero remaining runtime dependency on OMV.

**Architecture:** Both data sets move to raw local-XFS `hostPath` on `k8s-4-dell` (the existing house style: jellyfin/garage-app already use bjw-s `type: hostPath`). The media library lands on the existing `/var/mnt/media` XFS volume; the Kopia repo lands in a subdirectory of that same volume (`/var/mnt/media/.kopia`) because every dell disk is already allocated — this is acceptable since Phase 2 relocates Kopia to the ex-OMV node. All media-consuming apps (sonarr, radarr, bazarr, qbittorrent, sabnzbd, jellyfin) and all VolSync movers get pinned to `k8s-4-dell` via `nodeSelector` because `hostPath` data only exists on that node. The one-time 2.9 TB + 68 GB copy is a manual `rsync` runbook (not GitOps) run while OMV is still live.

**Tech Stack:** Kubernetes (Talos + K3s/OMV), ArgoCD, VolSync + Kopia, bjw-s app-template, Gateway API HTTPRoute, ExternalSecrets + 1Password, `rsync` over SSH.

**Reference spec:** `docs/superpowers/specs/2026-06-09-kopia-media-omv-decommission-design.md`

---

## Conventions used in this plan

- **Talos kubectl:** `KUBECONFIG=kubeconfig kubectl ...` run from the repo root (repo default; matches the gitea migration plan). If that file is absent, use the absolute kubeconfig from the handoff: `KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config kubectl ...`.
- **OMV kubectl:** `ssh root@omv-baymx 'kubectl ...'` (or `ssh root@10.30.30.54` per the handoff if the hostname does not resolve).
- **OMV shell (for rsync/du on the NAS):** `ssh root@omv-baymx` / `ssh root@10.30.30.54`.
- **Git commits:** conventional format (`(feat):`, `(fix):`, `(chore):`) per `AGENTS.md`.
- ArgoCD substitutes `${CLUSTER_DOMAIN}`, `${GATEWAY_NAME}`, `${GATEWAY_NAMESPACE}`, `${ARGOCD_APP_NAME}`.
- **Target node:** `k8s-4-dell`. Confirm the exact `kubernetes.io/hostname` label value before pinning (Task 0).

## Pre-flight facts (already verified — do not re-investigate)

- **Media apps on Talos use NFS** to `omv-baymx.a113.internal:/storage0/media`, mounted at container path `/nfs-nas-pvc`:
  - `components/default/sonarr/values.yaml:51-56` (`media:` block)
  - `components/default/radarr/values.yaml:51-56`
  - `components/default/bazarr/values.yaml:49-54`
  - `components/downloads/qbittorrent/values.yaml:140-147` (uses `advancedMounts`, controller `qbittorrent`, container `app`)
  - `components/downloads/sabnzbd/values.yaml:62-67`
- **Jellyfin runs on the OMV cluster, NOT Talos.** Registered in `clusters/omv/apps/20-applications.yaml:42-58`; its `media` volume is a `hostPath` to the OMV local disk `/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/media` (`components/default/jellyfin/values.yaml:58-62`). Phase 1 migrates it to Talos.
- **Kopia repo (Talos) is NFS** to `omv-baymx.a113.internal:/storage0/VolsyncKopia`, mounted at `/repository`, backend `filesystem:///repository`:
  - `clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml:11-25`
  - `clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml:16-20`
  - VolSync movers get the `repository` volume injected by the `volsync-mover` MutatingAdmissionPolicy: `clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml:50-102` (NFS to OMV at lines 92-101).
- **Dell disks are fully allocated.** `clusters/talos/bootstrap/os/patches/k8s-4-dell/user-volumes.yaml` defines `media` (wwn `0x50014ee214f03cdb`, ≥3 TB XFS, currently 2% used) and `downloads` (NVMe, 400 GB XFS). `nvme0n1` is reserved for future Ceph; `sdb` failed SMART. **No free disk for a dedicated kopia volume** → kopia repo goes in a subdir of the media volume: **`/var/mnt/media/.kopia`** (interim; Phase 2 moves it to ex-OMV). No new `UserVolumeConfig` is created in Phase 1.
- Sizes: media **2.9 TB**, kopia repo **68 GB** (`du` on OMV).
- **Out of scope (verified):** `audiobookshelf` and `paperless-ngx` use `synology.a113.internal`, not OMV — untouched. `garage-app` is already migrated (the stale OMV registration is removed at decommission). `syncthing` and `bytestash` are no longer needed and are removed at decommission (no data preservation).

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml` | Modify | `repository` volume nfs → hostPath `/var/mnt/media/.kopia`; pin deployment to `k8s-4-dell` |
| `clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml` | Modify | Same hostPath + pin maintenance CronJob to `k8s-4-dell` |
| `clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml` | Modify | `repository` volume injected into movers nfs → hostPath; inject `nodeSelector` to `k8s-4-dell` |
| `components/default/sonarr/values.yaml` | Modify | `media` volume nfs → hostPath `/var/mnt/media`; add `defaultPodOptions.nodeSelector` |
| `components/default/radarr/values.yaml` | Modify | Same |
| `components/default/bazarr/values.yaml` | Modify | Same |
| `components/downloads/qbittorrent/values.yaml` | Modify | `media` advancedMount nfs → hostPath; add `nodeSelector` |
| `components/downloads/sabnzbd/values.yaml` | Modify | `media` volume nfs → hostPath; add `nodeSelector` |
| `components/default/jellyfin/values.yaml` | Modify | `media` hostPath OMV-path → `/var/mnt/media`; add `nodeSelector` to `k8s-4-dell` |
| `clusters/talos/apps/20-applications.yaml` | Modify | Register `jellyfin` on Talos (ceph-block config PVC + VolSync) |
| `clusters/omv/apps/20-applications.yaml` | Modify | Remove `jellyfin`, `garage-app`, `syncthing`, `bytestash` (post-cutover) |

Runtime-only artifacts (not committed): the manual `rsync` copies, manual VolSync trigger commands.

---

## Task 0: Confirm the target node label and prepare the dell disk layout

**Files:** none (verification only).

- [ ] **Step 1: Confirm the `k8s-4-dell` hostname label**

Run:
```bash
KUBECONFIG=kubeconfig kubectl get nodes --show-labels | grep -i dell
```
Expected: a node whose `kubernetes.io/hostname` label is `k8s-4-dell`. Record the exact value; every `nodeSelector` in this plan uses `kubernetes.io/hostname: <that value>`. If it differs (e.g. `k8s-4`), substitute the real value everywhere below.

- [ ] **Step 2: Confirm the media volume is mounted and empty on dell**

Run:
```bash
KUBECONFIG=kubeconfig kubectl debug node/k8s-4-dell -it --image=ghcr.io/home-operations/busybox:1.38.0 -- sh -c 'ls -la /host/var/mnt/media; df -h /host/var/mnt/media'
```
Expected: `/host/var/mnt/media` exists, is XFS, ~3.6 TB, near-empty. (The `kubectl debug` node path prefixes the host fs with `/host`.) If the debug image cannot be scheduled, SSH to the node is unavailable on Talos by design — instead verify via `talosctl -n k8s-4-dell get uservolumestatus` that the `media` volume is `ready`.

- [ ] **Step 3: Create the kopia subdirectory on the media volume**

Run:
```bash
KUBECONFIG=kubeconfig kubectl debug node/k8s-4-dell -it --image=ghcr.io/home-operations/busybox:1.38.0 -- sh -c 'mkdir -p /host/var/mnt/media/.kopia && ls -ld /host/var/mnt/media/.kopia'
```
Expected: `/host/var/mnt/media/.kopia` exists. This is the interim Kopia repo home.

> No `UserVolumeConfig` change is needed in Phase 1 — both data sets live on the existing `media` XFS volume.

---

## Task 1: One-time data copy from OMV to dell (manual runbook)

**Files:** none (runtime operations). **Run while OMV is still powered on.** This task is non-destructive to OMV.

The dell media volume is exposed to a host shell via `kubectl debug node/k8s-4-dell`, but that path is awkward for a multi-TB `rsync`. The reliable approach is a one-shot privileged copy pod pinned to `k8s-4-dell` that mounts the host media volume and pulls from OMV's NFS export.

- [ ] **Step 1: Confirm source sizes on OMV (sanity)**

Run:
```bash
ssh root@omv-baymx 'du -sh /storage0/media /storage0/VolsyncKopia'
```
Expected: media ≈ 2.9 TB, VolsyncKopia ≈ 68 GB. Note them; used to confirm the copy is complete in Step 6.

- [ ] **Step 2: Pause Kopia maintenance + quiesce VolSync so the repo copy is consistent**

The Kopia repo must not change mid-copy. Suspend the maintenance CronJob and scale the kopia deployment to 0:
```bash
KUBECONFIG=kubeconfig kubectl patch cronjob kopia-maintenance -n volsync-system -p '{"spec":{"suspend":true}}'
KUBECONFIG=kubeconfig kubectl scale deploy kopia -n volsync-system --replicas=0
```
Expected: CronJob suspended, kopia deployment scaled to 0. (Scheduled VolSync backups still inject the repo via the policy; this is fine — the final `--checksum` pass in Step 5 catches any drift, and backups are non-urgent per the spec. To be fully safe you may also suspend in-flight movers, but it is not required.)

- [ ] **Step 3: Launch a copy pod on `k8s-4-dell` that mounts the dell media disk + OMV NFS**

Create `/tmp/omv-copy-pod.yaml` (runtime-only, not committed):
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: omv-copy
  namespace: volsync-system
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: k8s-4-dell
  containers:
    - name: copy
      image: ghcr.io/home-operations/alpine:3.22.2
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: dest-media
          mountPath: /dest/media
        - name: src-media
          mountPath: /src/media
          readOnly: true
        - name: src-kopia
          mountPath: /src/kopia
          readOnly: true
  volumes:
    - name: dest-media
      hostPath:
        path: /var/mnt/media
        type: Directory
    - name: src-media
      nfs:
        server: omv-baymx.a113.internal
        path: /storage0/media
    - name: src-kopia
      nfs:
        server: omv-baymx.a113.internal
        path: /storage0/VolsyncKopia
```
Run:
```bash
KUBECONFIG=kubeconfig kubectl apply -f /tmp/omv-copy-pod.yaml
KUBECONFIG=kubeconfig kubectl wait --for=condition=Ready pod/omv-copy -n volsync-system --timeout=120s
KUBECONFIG=kubeconfig kubectl exec -n volsync-system omv-copy -- sh -c 'apk add --no-cache rsync >/dev/null && rsync --version | head -1'
```
Expected: pod `Ready`; `rsync version ...` printed.

- [ ] **Step 4: Copy the Kopia repo (small, do first to validate the path)**

Run:
```bash
KUBECONFIG=kubeconfig kubectl exec -n volsync-system omv-copy -- \
  rsync -aH --info=progress2 /src/kopia/ /dest/media/.kopia/
```
Expected: ~68 GB copied into `/var/mnt/media/.kopia`. Note: trailing slashes copy *contents* into the destination dir.

- [ ] **Step 5: Copy the media library (large — hours)**

Run:
```bash
KUBECONFIG=kubeconfig kubectl exec -n volsync-system omv-copy -- \
  rsync -aH --info=progress2 --exclude='.kopia/' /src/media/ /dest/media/
```
Expected: ~2.9 TB copied into `/var/mnt/media`. The `--exclude='.kopia/'` guards against clobbering the repo copied in Step 4 (in case OMV's media dir ever contained one). This may run for hours; consider running inside `tmux`/`nohup` on the workstation or detaching the exec.

- [ ] **Step 6: Final integrity pass (checksum) and size compare**

Run:
```bash
KUBECONFIG=kubeconfig kubectl exec -n volsync-system omv-copy -- \
  rsync -aH --checksum --exclude='.kopia/' --itemize-changes /src/media/ /dest/media/
KUBECONFIG=kubeconfig kubectl exec -n volsync-system omv-copy -- \
  rsync -aH --checksum --itemize-changes /src/kopia/ /dest/media/.kopia/
KUBECONFIG=kubeconfig kubectl exec -n volsync-system omv-copy -- du -sh /dest/media /dest/media/.kopia
```
Expected: the two `--checksum` passes emit **no `>f` transfer lines** (nothing left to copy / verify clean). `du` on the dest matches the OMV sizes from Step 1 (media ≈ 2.9 TB including `.kopia`; `.kopia` ≈ 68 GB).

- [ ] **Step 7: Delete the copy pod**

Run:
```bash
KUBECONFIG=kubeconfig kubectl delete pod omv-copy -n volsync-system
```
Expected: pod deleted. The dell volume now holds both data sets. **Leave OMV powered on** until Task 8.

> Rollback anchor: nothing on OMV was modified; reverting is just "don't repoint the apps."

---

## Task 2: Repoint the Kopia repo to dell hostPath, pinned to `k8s-4-dell`

**Files:**
- Modify: `clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml`
- Modify: `clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml`

- [ ] **Step 1: Edit the kopia deployment patch**

Replace the entire contents of `clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml` with:

```yaml
---
# Cluster-specific deployment patch for Kopia
# Mounts the repository from local XFS on k8s-4-dell (hostPath), interim home
# under the media volume. Pinned to k8s-4-dell because hostPath data is node-local.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kopia
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/hostname: k8s-4-dell
      volumes:
        - name: repository
          hostPath:
            path: /var/mnt/media/.kopia
            type: Directory
      initContainers:
        - name: copy-config
          volumeMounts:
            - name: repository
              mountPath: /repository
      containers:
        - name: app
          volumeMounts:
            - name: repository
              mountPath: /repository
```

- [ ] **Step 2: Edit the kopia maintenance CronJob patch**

Replace the entire contents of `clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml` with:

```yaml
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kopia-maintenance
spec:
  jobTemplate:
    spec:
      template:
        spec:
          nodeSelector:
            kubernetes.io/hostname: k8s-4-dell
          containers:
            - name: maintenance
              volumeMounts:
                - name: repository
                  mountPath: /repository
          volumes:
            - name: repository
              hostPath:
                path: /var/mnt/media/.kopia
                type: Directory
```

- [ ] **Step 3: Verify the diffs**

Run: `git diff clusters/talos/apps/volsync-system/kopia/`
Expected: both files change nfs → hostPath and gain a `nodeSelector`. The `repository.config` / kopia ExternalSecret are untouched (backend stays `filesystem:///repository`).

- [ ] **Step 4: Commit (do not push yet)**

```bash
git add clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml
git commit -m "(feat): point kopia repo at k8s-4-dell local disk"
```

> Held until Task 5 so the policy change (Task 3) and all media-app changes land in one controlled push.

---

## Task 3: Repoint the VolSync mover repository volume to dell hostPath + pin movers

**Files:**
- Modify: `clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml` (the `volsync-mover` policy, lines 57-102)

**Why:** VolSync movers (`volsync-*` Jobs) get the `repository` volume injected by this policy. Today it injects an NFS volume to OMV. It must inject the dell `hostPath` instead, AND pin the mover pod to `k8s-4-dell` (the repo disk only exists there). Without the `nodeSelector`, movers scheduled elsewhere would fail to mount the hostPath.

- [ ] **Step 1: Change the injected `repository` volume from nfs to hostPath**

In `clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml`, inside the `volsync-mover` policy's `jsonPatch.expression`, replace the volume-add patch (currently lines 92-101):

```yaml
            JSONPatch{
              op: "add", path: "/spec/template/spec/volumes/-",
              value: Object.spec.template.spec.volumes{
                name: "repository",
                nfs: Object.spec.template.spec.volumes.nfs{
                  server: "omv-baymx.a113.internal",
                  path: "/storage0/VolsyncKopia"
                }
              }
            }
```
with:
```yaml
            JSONPatch{
              op: "add", path: "/spec/template/spec/volumes/-",
              value: Object.spec.template.spec.volumes{
                name: "repository",
                hostPath: Object.spec.template.spec.volumes.hostPath{
                  path: "/var/mnt/media/.kopia",
                  type: "Directory"
                }
              }
            }
```

- [ ] **Step 2: Add a `nodeSelector` mutation so movers run on `k8s-4-dell`**

In the same `volsync-mover` policy, add a third JSONPatch entry to set the pod `nodeSelector`. Inside the `mutations[].jsonPatch.expression` list (the array that currently holds the volumeMount-add and volume-add patches), append a new element after the volume-add patch:

```yaml
            ,
            JSONPatch{
              op: "add", path: "/spec/template/spec/nodeSelector",
              value: Object.spec.template.spec.nodeSelector{
                ?"kubernetes.io/hostname": optional.of("k8s-4-dell")
              }
            }
```

So the full `expression` list for `volsync-mover` becomes (volumeMount-add, volume-add hostPath, nodeSelector-add). Ensure the JSON array commas are correct: each `JSONPatch{...}` element separated by a comma, no trailing comma before the closing `]`.

> CEL/JSONPatch note: the `op: "add"` on `/spec/template/spec/nodeSelector` sets the whole map. VolSync movers do not normally set a `nodeSelector`, so adding the key is safe. If a mover ever already had a `nodeSelector`, this `add` to the object path replaces it — acceptable here since all movers must run on `k8s-4-dell` while the repo is node-local. If the CEL optional-map syntax above does not validate in this cluster's policy engine, fall back to a plain literal map: `value: {"kubernetes.io/hostname": "k8s-4-dell"}`.

- [ ] **Step 3: Verify the diff**

Run: `git diff clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml`
Expected: the `volsync-mover` policy's injected volume changes nfs → hostPath, and a `nodeSelector` add-patch is appended. The `volsync-mover-jitter` policy (lines 1-48) is unchanged.

- [ ] **Step 4: Validate YAML**

Run: `python3 -c "import yaml; list(yaml.safe_load_all(open('clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml'))); print('ok')"`
Expected: `ok`.

- [ ] **Step 5: Commit (do not push yet)**

```bash
git add clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml
git commit -m "(feat): inject kopia repo from k8s-4-dell hostPath into volsync movers"
```

---

## Task 4: Repoint the Talos media apps (arr + downloaders) to dell hostPath

Each app currently mounts `nfs omv-baymx:/storage0/media` at `/nfs-nas-pvc`. Switch to `hostPath /var/mnt/media` (same mount path → no app reconfig) and pin to `k8s-4-dell`.

**Files:**
- Modify: `components/default/sonarr/values.yaml`
- Modify: `components/default/radarr/values.yaml`
- Modify: `components/default/bazarr/values.yaml`
- Modify: `components/downloads/qbittorrent/values.yaml`
- Modify: `components/downloads/sabnzbd/values.yaml`

- [ ] **Step 1: Edit `sonarr` media volume + add nodeSelector**

In `components/default/sonarr/values.yaml`, replace the `media:` block (currently lines 51-56):

```yaml
  media:
    type: nfs
    server: omv-baymx.a113.internal
    path: "/storage0/media"
    globalMounts:
      - path: /nfs-nas-pvc
```
with:
```yaml
  media:
    type: hostPath
    hostPath: /var/mnt/media
    globalMounts:
      - path: /nfs-nas-pvc
```

Then add a top-level `defaultPodOptions` block pinning the pod to dell. If the file already has a `defaultPodOptions:` key, add the `nodeSelector` under it; otherwise add this block near the top of the file (after the `---` document start, before `controllers:`):

```yaml
defaultPodOptions:
  nodeSelector:
    kubernetes.io/hostname: k8s-4-dell
```

- [ ] **Step 2: Edit `radarr` (identical shape)**

In `components/default/radarr/values.yaml`, replace the `media:` block (currently lines 51-56) with the same hostPath block as Step 1, and add the same `defaultPodOptions.nodeSelector` block.

- [ ] **Step 3: Edit `bazarr` (identical shape)**

In `components/default/bazarr/values.yaml`, replace the `media:` block (currently lines 49-54):

```yaml
  media:
    type: nfs
    server: omv-baymx.a113.internal
    path: "/storage0/media"
    globalMounts:
      - path: /nfs-nas-pvc
```
with:
```yaml
  media:
    type: hostPath
    hostPath: /var/mnt/media
    globalMounts:
      - path: /nfs-nas-pvc
```
and add the same `defaultPodOptions.nodeSelector` block.

- [ ] **Step 4: Edit `sabnzbd` (global mount)**

In `components/downloads/sabnzbd/values.yaml`, replace the `media:` block (currently lines 62-67):

```yaml
  media:
    type: nfs
    server: omv-baymx.a113.internal
    path: "/storage0/media"
    globalMounts:
      - path: /nfs-nas-pvc
```
with:
```yaml
  media:
    type: hostPath
    hostPath: /var/mnt/media
    globalMounts:
      - path: /nfs-nas-pvc
```
and add the same `defaultPodOptions.nodeSelector` block.

- [ ] **Step 5: Edit `qbittorrent` (advancedMounts — preserve structure)**

`qbittorrent` uses `advancedMounts` (not `globalMounts`). In `components/downloads/qbittorrent/values.yaml`, replace the `media:` block (currently lines 140-147):

```yaml
  media:
    type: nfs
    server: omv-baymx.a113.internal
    path: "/storage0/media"
    advancedMounts:
      qbittorrent:
        app:
          - path: /nfs-nas-pvc
```
with:
```yaml
  media:
    type: hostPath
    hostPath: /var/mnt/media
    advancedMounts:
      qbittorrent:
        app:
          - path: /nfs-nas-pvc
```
and add the same `defaultPodOptions.nodeSelector` block.

> Note on downloads: these apps write downloads under `/nfs-nas-pvc/...` (the media tree). Keeping the same path on the same hostPath volume preserves all app config exactly. The separate `/var/mnt/downloads` NVMe is NOT introduced here (would require app path reconfig). Leave it as a future optimization, out of scope for Phase 1.

- [ ] **Step 6: Verify all diffs**

Run: `git diff components/default/sonarr/values.yaml components/default/radarr/values.yaml components/default/bazarr/values.yaml components/downloads/qbittorrent/values.yaml components/downloads/sabnzbd/values.yaml`
Expected: each file: `media` nfs→hostPath, `/nfs-nas-pvc` mount path unchanged, plus a `defaultPodOptions.nodeSelector` to `k8s-4-dell`.

- [ ] **Step 7: Validate YAML**

Run:
```bash
for f in components/default/sonarr/values.yaml components/default/radarr/values.yaml components/default/bazarr/values.yaml components/downloads/qbittorrent/values.yaml components/downloads/sabnzbd/values.yaml; do python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "ok $f"; done
```
Expected: `ok` for all five.

- [ ] **Step 8: Commit (do not push yet)**

```bash
git add components/default/sonarr/values.yaml components/default/radarr/values.yaml components/default/bazarr/values.yaml components/downloads/qbittorrent/values.yaml components/downloads/sabnzbd/values.yaml
git commit -m "(feat): point arr stack and downloaders at k8s-4-dell media disk"
```

---

## Task 5: Migrate Jellyfin from OMV cluster to Talos

Jellyfin lives on the OMV cluster. Move its registration to Talos and repoint its media hostPath to `/var/mnt/media`. Jellyfin's config PVC (`existingClaim: jellyfin`) is recreated on Talos via VolSync (restored from the shared Kopia repo, exactly like the gitea migration). The arr stack already populates the same `/nfs-nas-pvc` library layout, so Jellyfin's library DB paths remain valid.

**Files:**
- Modify: `components/default/jellyfin/values.yaml`
- Modify: `clusters/talos/apps/20-applications.yaml`

- [ ] **Step 1: Repoint jellyfin media to dell + pin to `k8s-4-dell`**

In `components/default/jellyfin/values.yaml`, replace the `media:` block (currently lines 58-62):

```yaml
  media:
    type: hostPath
    hostPath: /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/media
    globalMounts:
      - path: /nfs-nas-pvc
```
with:
```yaml
  media:
    type: hostPath
    hostPath: /var/mnt/media
    globalMounts:
      - path: /nfs-nas-pvc
```

Then add a top-level `defaultPodOptions` block (the file currently has `defaultPodOptions:` at line 2 with `enableServiceLinks: false` — add `nodeSelector` under it):

```yaml
defaultPodOptions:
  enableServiceLinks: false
  nodeSelector:
    kubernetes.io/hostname: k8s-4-dell
```

- [ ] **Step 2: Register `jellyfin` on Talos**

Append to `clusters/talos/apps/20-applications.yaml` under `applications:` (mirroring the OMV entry but with Talos storage classes per `AGENTS.md`):

```yaml
  jellyfin:
    annotations:
      argocd.argoproj.io/sync-wave: "20"
    ignoreDifferences:
      - group: ""
        kind: PersistentVolumeClaim
        name: jellyfin
        jsonPointers:
          - /spec/dataSource
          - /spec/dataSourceRef
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
```

> The OMV jellyfin registration used `longhorn-volsync` / `longhorn`. Talos uses `ceph-block` / `csi-ceph-blockpool` (per `AGENTS.md`). The jellyfin config PVC is backed up to the same shared Kopia repo, so it can be restored on Talos.

- [ ] **Step 3: Validate YAML**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('components/default/jellyfin/values.yaml')); print('ok values')"
python3 -c "import yaml; yaml.safe_load(open('clusters/talos/apps/20-applications.yaml')); print('ok apps')"
```
Expected: `ok values` and `ok apps`.

- [ ] **Step 4: Commit (do not push yet)**

```bash
git add components/default/jellyfin/values.yaml clusters/talos/apps/20-applications.yaml
git commit -m "(feat): register jellyfin on talos against k8s-4-dell media disk"
```

---

## Task 6: Controlled cutover — push, restart, restore

**Files:** none (the controlled push + runtime).

- [ ] **Step 1: Quiesce OMV jellyfin to stop config writes before its PVC is restored on Talos**

Run:
```bash
ssh root@omv-baymx 'kubectl scale deploy -n default -l app.kubernetes.io/name=jellyfin --replicas=0'
```
Expected: OMV jellyfin scaled to 0. (Stops further config-PVC writes so the last Kopia snapshot is current.) If a fresher snapshot is desired, trigger one final OMV backup before scaling down.

- [ ] **Step 2: Push all committed changes**

Run:
```bash
git push
```
Then refresh ArgoCD (manual-sync clusters):
```bash
KUBECONFIG=kubeconfig kubectl annotate application kopia -n argo-system argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true
KUBECONFIG=kubeconfig kubectl annotate application volsync -n argo-system argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true
KUBECONFIG=kubeconfig kubectl annotate application jellyfin -n argo-system argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true
```
Expected: ArgoCD reconciles the kopia/volsync/media-app changes and creates the `jellyfin` Application on Talos. (App names for the arr stack are managed by the apps generator; a single hard refresh of the parent applications app also works — resolve with `KUBECONFIG=kubeconfig kubectl get applications -n argo-system`.)

- [ ] **Step 3: Re-enable Kopia (undo Task 1 Step 2) now that it points at dell**

Run:
```bash
KUBECONFIG=kubeconfig kubectl patch cronjob kopia-maintenance -n volsync-system -p '{"spec":{"suspend":false}}'
KUBECONFIG=kubeconfig kubectl rollout status deploy kopia -n volsync-system --timeout=300s
```
Expected: maintenance CronJob un-suspended; kopia deployment back to 1 replica, `Running`, pod scheduled on `k8s-4-dell`. Confirm placement:
```bash
KUBECONFIG=kubeconfig kubectl get pods -n volsync-system -l app.kubernetes.io/name=kopia -o wide
```
Expected: pod on `k8s-4-dell`, reading `/repository` from the dell hostPath.

- [ ] **Step 4: Confirm the arr stack + downloaders rescheduled onto dell and mounted hostPath**

Run:
```bash
KUBECONFIG=kubeconfig kubectl get pods -n default -l app.kubernetes.io/name=sonarr -o wide
KUBECONFIG=kubeconfig kubectl get pods -n default -l app.kubernetes.io/name=radarr -o wide
KUBECONFIG=kubeconfig kubectl get pods -n default -l app.kubernetes.io/name=bazarr -o wide
KUBECONFIG=kubeconfig kubectl get pods -n downloads -l app.kubernetes.io/name=qbittorrent -o wide
KUBECONFIG=kubeconfig kubectl get pods -n downloads -l app.kubernetes.io/name=sabnzbd -o wide
```
Expected: all `Running` and `NODE` = `k8s-4-dell`. Spot-check the media is visible:
```bash
KUBECONFIG=kubeconfig kubectl exec -n default deploy/sonarr -- ls /nfs-nas-pvc | head
```
Expected: the media library directory listing (same content as OMV).

- [ ] **Step 5: Restore the jellyfin config PVC from the shared Kopia repo**

The Talos jellyfin app provisions a `jellyfin` PVC and a `ReplicationDestination`. Trigger the restore (same pattern as the gitea migration):
```bash
KUBECONFIG=kubeconfig kubectl get replicationdestination -n default | grep jellyfin
KUBECONFIG=kubeconfig kubectl patch replicationdestination jellyfin-dst -n default --type merge -p '{"spec":{"trigger":{"manual":"restore-once"}}}'
KUBECONFIG=kubeconfig kubectl wait --for=jsonpath='{.status.latestMoverStatus.result}'=Successful replicationdestination/jellyfin-dst -n default --timeout=900s
```
Expected: restore Job completes; the `jellyfin` config PVC binds from the restored snapshot. (The exact RD name may be `jellyfin-dst` — confirm from the `grep`. If the PVC already bound from an initial sync, confirm `kubectl get pvc jellyfin -n default` is `Bound` and skip the patch.)

- [ ] **Step 6: Start jellyfin on Talos and confirm placement**

Run:
```bash
KUBECONFIG=kubeconfig kubectl rollout status deploy -n default -l app.kubernetes.io/name=jellyfin --timeout=300s
KUBECONFIG=kubeconfig kubectl get pods -n default -l app.kubernetes.io/name=jellyfin -o wide
```
Expected: jellyfin pod `Running`, `1/1`, `NODE` = `k8s-4-dell`.

---

## Task 7: Validate

**Files:** none.

- [ ] **Step 1: Jellyfin serves media**

Run:
```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://jellyfin.${CLUSTER_DOMAIN}/health
```
Expected: `200`. In the Jellyfin UI, confirm libraries load and a title plays (validates config PVC restore + `/var/mnt/media` content).

- [ ] **Step 2: arr stack sees the library and downloads path**

In Sonarr/Radarr UI (or via `kubectl exec ... ls /nfs-nas-pvc`), confirm the root folders resolve and existing series/movies are present. Confirm qBittorrent/SABnzbd save paths under `/nfs-nas-pvc` exist and are writable:
```bash
KUBECONFIG=kubeconfig kubectl exec -n downloads deploy/sabnzbd -- sh -c 'touch /nfs-nas-pvc/.write-test && rm /nfs-nas-pvc/.write-test && echo writable'
```
Expected: `writable`.

- [ ] **Step 3: VolSync backup round-trip against the dell-local Kopia repo**

Pick any Ceph-backed app with a `replicationsource` (e.g. one of the arr stack). Trigger a backup and confirm success — this proves movers mount the dell hostPath repo and run on `k8s-4-dell`:
```bash
KUBECONFIG=kubeconfig kubectl patch replicationsource sonarr -n default --type merge -p '{"spec":{"trigger":{"manual":"verify-once"}}}'
KUBECONFIG=kubeconfig kubectl wait --for=jsonpath='{.status.latestMoverStatus.result}'=Successful replicationsource/sonarr -n default --timeout=900s
```
Expected: `Successful`. Confirm the mover ran on dell:
```bash
KUBECONFIG=kubeconfig kubectl get pods -n default -l app.kubernetes.io/created-by=volsync -o wide | grep volsync-src
```
Expected: any recent `volsync-src-*` pod shows `NODE` = `k8s-4-dell` (proves the policy `nodeSelector` works).

- [ ] **Step 4: VolSync restore round-trip (full proof)**

Confirm a restore from the dell-local repo works. The jellyfin restore in Task 6 Step 5 already exercised this; if you want an independent proof, trigger a `restore-once` on an arr-stack `replicationdestination` into a scratch PVC, or rely on the successful jellyfin restore as the round-trip evidence. Record which.

Expected: a restore completes `Successful` against the dell-local repo.

> Do not proceed to Task 8 until Steps 1-4 pass. Until OMV is powered off, every change is reversible (revert commits + scale OMV jellyfin back up + the OMV NFS exports are untouched).

---

## Task 8: Decommission OMV

**Files:**
- Modify: `clusters/omv/apps/20-applications.yaml` (remove `jellyfin`, `garage-app`, `syncthing`, `bytestash`)

**Only proceed after Task 7 passes.**

- [ ] **Step 1: Remove the four entries from the OMV applications file**

In `clusters/omv/apps/20-applications.yaml`, delete these blocks:
- `jellyfin:` (currently lines 42-58) — migrated to Talos.
- `garage-app:` (currently lines 10-16) — already migrated; stale.
- `syncthing:` (currently lines 34-40) — no longer needed.
- `bytestash:` (currently lines 18-24) — no longer needed.

Leave all other entries (`homepage`, `renovate`, `holmesgpt`, `rancher`, etc.) intact.

- [ ] **Step 2: Validate YAML and confirm the diff**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('clusters/omv/apps/20-applications.yaml')); print('ok')"
git diff clusters/omv/apps/20-applications.yaml
```
Expected: `ok`; diff shows exactly the four blocks removed, nothing else.

- [ ] **Step 3: Commit and push**

```bash
git add clusters/omv/apps/20-applications.yaml
git commit -m "(chore): remove jellyfin/garage-app/syncthing/bytestash from omv after talos cutover"
git push
```

- [ ] **Step 4: Let OMV ArgoCD prune, then confirm removal**

Run:
```bash
ssh root@omv-baymx 'kubectl get applications -n argo-system'
ssh root@omv-baymx 'kubectl annotate application <omv-apps-app> -n argo-system argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true'
ssh root@omv-baymx 'kubectl get deploy -n default -l app.kubernetes.io/name=jellyfin; kubectl get deploy -n default -l app.kubernetes.io/name=syncthing; kubectl get deploy -n default -l app.kubernetes.io/name=bytestash; kubectl get deploy -n default -l app.kubernetes.io/name=garage-app'
```
Expected: none of the four deployments remain on OMV. (Resolve `<omv-apps-app>` from the `get applications` output — the app whose source generates these entries.)

- [ ] **Step 5: Confirm zero remaining runtime dependency on OMV, then power off**

Verify nothing on Talos still references OMV:
```bash
rg -n "omv-baymx|storage0|10.30.30.54" components/ clusters/talos/ 2>/dev/null
```
Expected: **no matches** in `clusters/talos/` or in any `components/` path consumed by the Talos cluster. (Any remaining match is a missed dependency — fix before powering off.) Then confirm no Talos pod has an active NFS mount to OMV:
```bash
KUBECONFIG=kubeconfig kubectl get pods -A -o wide | grep -iE 'omv' || echo "no omv-referencing pods"
```

Once clean, power off the NAS:
```bash
ssh root@omv-baymx 'poweroff'
```
Expected: OMV (`omv-baymx`) powers down. **Phase 1 complete: zero runtime dependency on OMV.** Jellyfin and Kopia are pinned to `k8s-4-dell` (no failover yet — that is Phase 2, gated on the ex-OMV node rejoining as a Talos worker).

> Do NOT wipe the OMV disks yet. Keep them intact as a rollback anchor through a confidence window. They become the Phase 2 ex-OMV node's disks.

---

## Rollback (any time before Task 8 Step 5 power-off)

1. Scale Talos jellyfin to 0: `KUBECONFIG=kubeconfig kubectl scale deploy -n default -l app.kubernetes.io/name=jellyfin --replicas=0`.
2. Revert the Task 2-5 commits (`git revert` or `git reset` + push) so apps return to NFS/OMV and the kopia repo points back at the OMV NFS export.
3. Scale OMV jellyfin back up: `ssh root@omv-baymx 'kubectl scale deploy -n default -l app.kubernetes.io/name=jellyfin --replicas=1'`.
4. OMV NFS exports (`/storage0/media`, `/storage0/VolsyncKopia`) were never modified, so the prior state resumes. The dell copy is harmless (extra data on a local disk).

---

## Out of scope (Phase 2 / separate efforts)

- Moving the Kopia repo to its final home on the ex-OMV node (restores full Ceph independence). Phase 1 keeps it on the dell media volume as interim.
- Media replication dell → ex-OMV (`components/<ns>/media-sync/` rsync CronJob) and Jellyfin nodeAffinity relaxation for failover.
- Using the `/var/mnt/downloads` NVMe as a dedicated downloads target (would require app path reconfig).
- Garage-S3 disk topology discrepancy (values pin `k8s-5-1u`, `garage-hdd*` mounts observed on `k8s-4-dell`) — noted in the handoff, not in scope.
- Wiping/repurposing OMV hardware into a Talos worker (Phase 2 prerequisite).

## Success criteria

- OMV (`omv-baymx`) powered off with zero Talos runtime dependency (Task 8 Step 5 grep returns no matches).
- Media + Kopia data on `k8s-4-dell` local XFS; neither on Ceph.
- Jellyfin runs on Talos, serves media from `/var/mnt/media`, config restored from Kopia.
- A VolSync backup AND a restore round-trip succeed against the dell-local Kopia repo, with the mover confirmed running on `k8s-4-dell`.
