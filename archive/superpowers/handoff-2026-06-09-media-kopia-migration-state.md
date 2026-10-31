# Home-Ops Session Handoff — 2026-06-09

> **⚠️ NEW SESSIONS: USE THIS HANDOFF — it's the single source of truth.**
> Other `handoff-*.md` files in this directory are stale/uncommitted and should be ignored.

**Current work streams:**
1. **Media + Kopia Migration (Phase 1)** — kopia cutover DONE, media copy running (20%, ~2h45m ETA)
2. **KubeVirt + Gitea Runner Fix (Design)** — research complete, design approved, ready for spec writing

**Next actions:**
- Media migration: when copy completes → checksum verify → push T4+T5 → validate → decommission OMV
- KubeVirt/Runner: write design spec → implementation plan

---

## Work Stream 1: Media + Kopia Migration (Phase 1)

**Status:** In progress — kopia cutover DONE, media copy running

**Next action:** When media copy completes → checksum verify → push T4+T5 → validate → decommission OMV.

---

## What This Migration Does

**Goal:** Decommission the OMV NAS (`omv-baymx`) by moving the media library (2.8 TB) and Kopia backup repo (68 GB) off OMV NFS onto Talos node `k8s-4-dell` local XFS disk via `hostPath`. No Ceph (circular dependency for kopia, replication waste for media). Provide cross-node failover for Jellyfin in Phase 2 via rsync replication.

**Key decision (revised during execution):** Copy kopia repo FIRST (fast), cut it over to dell immediately, THEN do the long media copy — so scheduled VolSync backups (every 6h) write to the new dell repo instead of mutating the OMV repo mid-copy.

**Authoritative docs:**
- Design spec: `docs/superpowers/specs/2026-06-09-kopia-media-omv-decommission-design.md`
- Implementation plan: `docs/superpowers/plans/2026-06-09-kopia-media-omv-decommission-phase1.md`
- This handoff: `docs/superpowers/handoff-2026-06-09-media-kopia-migration-state.md`

---

## Current State (as of 2026-06-09T16:55Z)

### ✅ COMPLETED

1. **Manifest edits (Tasks 2-5)** — 4 commits, all spec + quality reviewed:
   - `0a945064` Task 2: kopia deployment-patch + cronjob-patch (nfs → hostPath `/var/mnt/media/.kopia`, pin to `k8s-4-dell`)
   - `f4dda52c` Task 3: VolSync mover MutatingAdmissionPolicy (inject hostPath repo + nodeSelector to dell)
   - `495266e4` Task 4: arr stack + downloaders (sonarr/radarr/bazarr/qbittorrent/sabnzbd) nfs → hostPath `/var/mnt/media`, pin to dell
   - `4681a847` Task 5: Jellyfin migrate OMV cluster → Talos (values hostPath + nodeSelector, register in `clusters/talos/apps/20-applications.yaml`)

2. **Task 0: Dell node prep** — `/var/mnt/media` confirmed (3.6 TB XFS, empty), `/var/mnt/media/.kopia` subdir created, writable, node label `kubernetes.io/hostname=k8s-4-dell` verified.

3. **OMV NFS reachability** — Both exports (`omv-baymx.a113.internal:/storage0/media` = 2.8 TB, `:/storage0/VolsyncKopia` = 67.5 GB) confirmed mountable from Talos cluster.

4. **Task 1a: Kopia repo copy + verify** — 67.5 GB (223,363 files) copied OMV → dell `/var/mnt/media/.kopia`, `--checksum` verified byte-identical, 0 errors.

5. **Kopia cutover (pushed commits T2+T3 to `origin/main` at `f4dda52c`):**
   - Talos kopia deployment + maintenance CronJob + VolSync mover MutatingAdmissionPolicy all now use **dell hostPath** `/var/mnt/media/.kopia`, pinned to `k8s-4-dell`.
   - Kopia pod `1/1 Running` on `k8s-4-dell`, reading the dell repo ✓
   - Maintenance CronJob re-enabled (was suspended during copy).
   - **Mover verification:** Triggered `volsync-src-gotify` test backup → confirmed mover mounts hostPath repo + lands on `k8s-4-dell` ✓
   - **Talos backups now write to the dell repo.** OMV repo is frozen (from Talos perspective).

6. **OMV cluster kopia decommissioned:**
   - The OMV cluster runs its OWN separate kopia + volsync stack (`clusters/omv/apps/05-storage-and-certificate.yaml` lines 27-41), which was also actively maintaining the shared repo.
   - Stopped: `kopia-maintenance` CronJob suspended, `kopia` + `volsync` deployments scaled to 0, auto-sync disabled on both OMV ArgoCD apps.
   - OMV kopia/volsync manifests still in Git → removed at Task 8 final decommission.

### ⏳ IN PROGRESS

7. **Task 1b: Media copy** — 2.8 TB rsync running **detached** in pod `omv-copy` (volsync-system namespace):
   - Command: `rsync -aH --exclude=".kopia/" --info=progress2,stats2 /src/media/ /dest/media/` (nohup + background, logs to `/tmp/media-rsync.log` in pod)
   - **Current progress (as of 16:55 UTC):** 20% done, 327 GB copied, ~108 MB/s, **ETA ~2h45m** (finishes ~19:40 UTC)
   - Source: OMV NFS `omv-baymx:/storage0/media` (mounted at `/src/media` in pod)
   - Dest: dell hostPath `/var/mnt/media` (mounted at `/dest/media` in pod)
   - Pod nodeName: `k8s-4-dell`

   **How to check progress:**
   ```bash
   export KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config  # or kubeconfig
   kubectl exec -n volsync-system omv-copy -- sh -c 'ps | grep "[r]sync"; tr "\r" "\n" < /tmp/media-rsync.log | tail -3; du -sh /dest/media'
   ```

### 🔜 PENDING (in order)

8. **Task 1c: Checksum verify media copy** (run when Task 1b completes):
   ```bash
   kubectl exec -n volsync-system omv-copy -- \
     rsync -aH --checksum --exclude='.kopia/' --itemize-changes /src/media/ /dest/media/
   ```
   Expected: **no `>f` transfer lines** (nothing left to copy). Then compare sizes:
   ```bash
   kubectl exec -n volsync-system omv-copy -- sh -c 'echo "src:"; du -sh /src/media; echo "dest:"; du -sh /dest/media'
   ```
   Expected: both ~2.8 TB (dest includes the 67.5G `.kopia` subdir). Then delete the copy pod.

9. **Task 6b: Push media apps + Jellyfin, restore Jellyfin PVC, cutover:**
   - Push commits T4 + T5 (currently held local): `git push origin 4681a847:main` (advances `origin/main` through jellyfin commit)
   - Refresh ArgoCD apps (arr stack, downloaders, jellyfin will reconcile)
   - **Jellyfin PVC restore:** Trigger `ReplicationDestination jellyfin-dst` restore from the shared Kopia repo (Jellyfin's config PVC exists on OMV, backed up to the repo we copied). Wait for `latestMoverStatus.result=Successful`.
   - Confirm arr stack + downloaders + jellyfin reschedule to `k8s-4-dell`, mount `/var/mnt/media`.

10. **Task 7: Validate:**
    - Jellyfin serves media (curl `/health`, browse UI, play a title)
    - Arr stack sees library + downloads paths (writable test)
    - **VolSync backup + restore round-trip:** trigger a test backup (e.g. sonarr), confirm mover runs on `k8s-4-dell` + succeeds, then restore to a scratch PVC to prove the dell repo works end-to-end.

11. **Task 8: Decommission OMV:**
    - **Edit `clusters/omv/apps/20-applications.yaml`:** remove `jellyfin`, `garage-app`, `syncthing`, `bytestash` entries.
    - **Edit `clusters/omv/apps/05-storage-and-certificate.yaml`:** remove `kopia` and `volsync` entries (lines 27-41) — this was missed in the original plan.
    - Commit + push → let OMV ArgoCD prune.
    - Verify zero Talos→OMV refs: `rg -n "omv-baymx|storage0|10.30.30.54" components/ clusters/talos/` (expect no matches).
    - Power off: `ssh root@omv-baymx 'poweroff'` (or `ssh root@10.30.30.54`).

---

## Rollback (any time before Task 8 power-off)

1. Scale Talos jellyfin to 0: `kubectl scale deploy -n default -l app.kubernetes.io/name=jellyfin --replicas=0`
2. Revert commits T2-T5 (`git revert` or reset) and push → apps return to OMV NFS.
3. Scale OMV jellyfin back up: `ssh root@omv-baymx 'kubectl scale deploy -n default -l app.kubernetes.io/name=jellyfin --replicas=1'`
4. OMV NFS exports were never modified; the dell copy is extra data. Harmless to leave or wipe.

---

## Key Decisions Made During Execution

1. **Kopia-first cutover strategy:** Originally planned to copy both together, but VolSync movers fire every 6h (next at 18:00 UTC). Copying kopia first (30 min) and cutting it over immediately meant movers write to the new dell repo during the long media copy, avoiding repo divergence.

2. **ArgoCD auto-sync conflicts:** Scaling kopia deployment to 0 (to quiesce the repo) fought with ArgoCD self-heal. Solution: disabled auto-sync on the kopia app temporarily, scaled to 0, then re-enabled after the copy. Similar for OMV kopia/volsync.

3. **OMV cluster kopia was separate:** The OMV K3s cluster runs its own kopia+volsync stack (not just an NFS export for Talos). It was actively maintaining the shared repo and had to be stopped. Task 8 must remove its ArgoCD registration from `05-storage-and-certificate.yaml` (not just `20-applications.yaml`).

4. **Jellyfin cluster migration:** The spec said "repoint jellyfin storage" but Jellyfin actually runs on the OMV cluster (not Talos), so Task 5 is a full cluster migration (new Talos ArgoCD app + config PVC restore from Kopia).

5. **No new UserVolumeConfig for kopia:** Dell has no free disk for a dedicated `/var/mnt/kopia` volume (all disks allocated). Kopia repo lives at `/var/mnt/media/.kopia` (subdir of the media volume) as an interim solution. Phase 2 moves it to the ex-OMV node's dedicated disk.

---

## Environment / Access

- **User:** `vikaspogu`
- **Talos kubeconfig:** `kubeconfig` in repo root (or `/Users/vikaspogu/.kube/configs/talos-cluster-config`)
- **OMV kubeconfig:** `/Users/vikaspogu/.kube/configs/omv-cluster-config`
- **OMV SSH:** `ssh root@omv-baymx` or `ssh root@10.30.30.54`
- **Repo:** `/Users/vikaspogu/Documents/git-repos/home-ops`
- **Branch:** `main`, currently 5 commits ahead of `origin/main` (spec commit + T2/T3 pushed, T4/T5 held local)
- **Cluster domain:** `a113.casa`

---

## Files Changed (committed but some not pushed)

**Pushed (at `origin/main` = `f4dda52c`):**
- `clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml` — nfs → hostPath, nodeSelector dell
- `clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml` — same
- `clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml` — mover repo injection nfs → hostPath + nodeSelector

**Local only (held for post-media-copy push):**
- `components/default/sonarr/values.yaml` — media nfs → hostPath, nodeSelector
- `components/default/radarr/values.yaml` — same
- `components/default/bazarr/values.yaml` — same
- `components/downloads/qbittorrent/values.yaml` — media nfs → hostPath (advancedMounts), nodeSelector
- `components/downloads/sabnzbd/values.yaml` — media nfs → hostPath, nodeSelector
- `components/default/jellyfin/values.yaml` — media hostPath OMV-path → `/var/mnt/media`, nodeSelector dell
- `clusters/talos/apps/20-applications.yaml` — new `jellyfin` app entry (ceph-block config PVC + VolSync)

**To be changed at Task 8 (not edited yet):**
- `clusters/omv/apps/20-applications.yaml` — remove jellyfin, garage-app, syncthing, bytestash
- `clusters/omv/apps/05-storage-and-certificate.yaml` — remove kopia, volsync

---

## Out of Scope (Phase 2, after ex-OMV rejoins as Talos node)

- Relocate kopia repo from dell interim home → dedicated disk on ex-OMV node (restores Ceph independence)
- Media rsync replication dell → ex-OMV (`components/<ns>/media-sync/` CronJob)
- Jellyfin nodeAffinity relaxation (prefer dell, allow ex-OMV failover)
- Wiping/repurposing OMV hardware into a Talos worker

---

## Troubleshooting / Notes

- **If copy pod dies/restarts:** The rsync is detached (nohup+background), but pod restart wipes `/tmp`. Re-run from the last `du` checkpoint (partial dest survives). Rsync's incremental nature makes re-runs safe.
- **If the next VolSync backup wave (18:00 UTC) happens mid-copy:** Not a problem — movers now write to the dell repo (cutover done). The OMV repo is frozen and untouched by movers.
- **If ArgoCD reverts kopia back to NFS:** Auto-sync was re-enabled after the cutover. If something reverted unexpectedly, check `kubectl get application kopia -n argo-system -o yaml` and the deployment's volume source.
- **Media copy pod name:** `omv-copy` in `volsync-system` namespace, pinned to `k8s-4-dell`.
- **Kopia repo on OMV:** Lives at `/storage0/VolsyncKopia` on the OMV NAS. Talos accessed it via NFS (now uses dell copy). OMV cluster accessed it via local hostPath (now stopped). Physical repo untouched; safe to leave until OMV hardware is wiped.

---

## Success Criteria (Phase 1 complete when)

- OMV (`omv-baymx`) powered off ✓
- Zero Talos runtime dependency on OMV ✓
- Media + kopia data on `k8s-4-dell` local XFS, neither on Ceph ✓
- Jellyfin runs on Talos, serves media from `/var/mnt/media` ✓
- VolSync backup + restore round-trip succeeds against the dell-local Kopia repo ✓

---

## Work Stream 2: KubeVirt + Gitea Runner Fix

**Status:** ✅ KubeVirt deployed via ArgoCD, ready for gitea-runner refactor (Tasks 9-13)

**Goals:**
1. ✅ Deploy KubeVirt for VM workloads on Talos cluster (k8s-4-dell + k8s-5-1u now, k8s-6-omv in Phase 2)
2. ⏳ Fix gitea-runner's privileged Docker-in-Docker issues

**Next action:** Execute Tasks 9-13 (gitea-runner rootless DinD refactor + testing)

### Research Findings Summary

#### KubeVirt on Talos: ✅ SUPPORTED

**Official support:** YES — Talos v1.13 docs have full KubeVirt install guide  
**Hardware verified:** Both k8s-4-dell and k8s-5-1u have VT-x + `/dev/kvm`  
**Installation:** Standard kubectl apply kubevirt-operator + KubeVirt CR + CDI operator  
**Storage:** Use existing Rook-Ceph `ceph-block` for VM PVCs; optionally add `local-path-provisioner` for CDI scratch space  
**Features:** LiveMigration (requires shared storage), NetworkBindingPlugins (optional Multus for bridge networking)  
**Talos-specific notes:**
- No `rpc.statd` daemon → must use `nolock` mount option for NFS-CSI (if used)
- Bridge mode networking requires Talos machine config changes (optional)

**Recommendation:** Straightforward deployment, well-documented, no blockers.

---

#### Sysbox on Talos: ❌ NOT SUPPORTED (high-risk)

**Official support:** NO — Sysbox distro compat lists Ubuntu/Debian/Fedora/RHEL/Amazon Linux/Flatcar, NOT Talos  
**Key conflicts:**
1. **Containerd config:** Sysbox requires runtime registration in containerd config. Talos uses immutable machine config, not editable `/etc/containerd/config.toml`.
2. **Systemd services:** Sysbox installs sysbox-fs + sysbox-mgr as systemd user services. Talos doesn't support this (extensions or static binaries only).
3. **Installation method:** Sysbox K8s DaemonSet expects to patch host containerd config via privileged pod + restart containerd. May not work on Talos's immutable OS structure.

**Community evidence:** Zero GitHub issues or docs mentioning Talos. Flatcar (similar immutable OS) required Sysbox Enterprise Edition with custom install guide (now deprecated).

**Conclusion:** Sysbox on Talos is NOT officially supported and would require custom Talos System Extension build + containerd machine config integration — high-risk, high-effort, no community precedent.

---

#### Alternatives for Gitea Runner's DinD Issues

Given Sysbox is impractical, alternatives to fix gitea-runner's privileged Docker-in-Docker:

**Option A: Rootless Docker-in-Docker (RECOMMENDED — pragmatic)**
- Replace `docker:29-dind` with `docker:dind-rootless`
- Remove `privileged: true`, no Sysbox needed
- **Trade-offs:** Requires cgroupv2 (Talos has it ✓), fuse-overlayfs storage driver (not overlay2), some Docker features unsupported (minor)
- **Effort:** Low — change 1 image tag + security context in gitea-runner values

**Option B: Daemonless builds (Kaniko)**
- Remove DinD sidecar, use Kaniko for unprivileged container image builds
- **Trade-offs:** Only for `docker build` equivalent; Docker Compose, `docker run`, etc. not supported. Gitea workflows need rewrite.
- **Effort:** Medium — workflow changes required

**Option C: KubeVirt VMs for runner jobs**
- Runner spawns a lightweight VM per CI job (instead of DinD container)
- Full isolation, real nested virtualization
- **Trade-offs:** VM boot overhead (~10-20s), need to build/maintain runner VM images, more complex
- **Effort:** High — only makes sense if KubeVirt is already deployed for other workloads

**Option D: Kubernetes-native CI (Tekton, Argo Workflows)**
- Replace gitea-runner entirely with K8s-native job executor
- **Trade-offs:** Loses Gitea Actions integration, large migration
- **Effort:** Very high

---

### Approved Design (Verbal)

**For Goal 1 (KubeVirt):**  
Standard KubeVirt deployment on Talos following official docs. Deploy KubeVirt operator + CDI, use Rook-Ceph for VM PVCs, target nodes: k8s-4-dell + k8s-5-1u (+ k8s-6 in Phase 2).

**For Goal 2 (Gitea Runner):**  
Start with **Option A (rootless DinD)** as the pragmatic fix. Skip Sysbox (not viable on Talos). If rootless DinD proves insufficient later, revisit Option C (KubeVirt VMs for jobs) once KubeVirt is stable.

**User decision:** Proceed with writing the design spec for KubeVirt deployment + rootless DinD gitea-runner refactor (two independent features, single spec or separate specs TBD).

---

### Completed (2026-06-09)

✅ **KubeVirt Deployment (Tasks 1-4 equivalent):**
- Structure: `components/kubevirt/operator/` (sync wave 30) + `components/kubevirt/cdi-operator/` (sync wave 31)
- ArgoCD apps: `kubevirt-operator` and `cdi-operator` both **Synced & Healthy**
- KubeVirt operator: v1.4.0, CR status: **Deploying** (control plane rolling out)
- CDI operator: v1.65.0, CR status: **Deployed**
- Both operators deployed via ArgoCD (no manual kubectl apply)
- Namespaces: `kubevirt` and `cdi`

**Docs:**
- Design spec: `docs/superpowers/specs/2026-06-09-kubevirt-gitea-runner-design.md` ✅
- Implementation plan: `docs/superpowers/plans/2026-06-09-kubevirt-gitea-runner-implementation.md` ✅

**Remaining Tasks:**
- Tasks 5-8: KubeVirt testing (deferred - can validate later)
- **Tasks 9-13: Gitea runner rootless DinD refactor** (ready to execute)

---

### Research References

- **KubeVirt on Talos:** https://docs.siderolabs.com/talos/v1.13/advanced-guides/install-kubevirt
- **Sysbox repo:** https://github.com/nestybox/sysbox
- **Sysbox distro compat:** https://github.com/nestybox/sysbox/blob/master/docs/distro-compat.md (no Talos)
- **Research notes:** `/tmp/kubevirt-sysbox-research/research-notes.md` (local, not committed)

---
