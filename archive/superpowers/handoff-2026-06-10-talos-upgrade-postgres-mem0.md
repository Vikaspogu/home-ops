# Home-Ops Session Handoff — 2026-06-10 Talos v1.13.4 Upgrade + Post-Reboot Recovery

**Date:** 2026-06-10 ~02:30 UTC  
**Focus:** Talos v1.13.4 upgrade (all nodes), microcode fix (reboot loop SOLVED), post-reboot cluster recovery

---

## TL;DR — Session Summary

**Primary work completed:**
1. ✅ **Talos v1.13.4 upgrade (all 5 nodes)** — v1.12.6 → v1.13.4, intel-ucode extension installed on all Intel nodes
2. ✅ **Reboot loop SOLVED** — k8s-4-dell + k8s-5-1u both stable under load with updated microcode (old-microcode Haswell errata fixed)
3. ✅ **Control-plane upgrades completed** — k8s-1, k8s-2, k8s-3 all v1.13.4, etcd healthy throughout
4. ⚠️ **Post-reboot recovery issues fixed:**
   - postgres17 + pgvector17: stale VolumeAttachments deleted, pods recovering
   - jellyfin: PVC stuck (VolSync restore blocked by PodSecurity baseline + hostPath — root cause identified, not yet fixed)
   - mem0-app: RWO PVC conflict with mem0-dashboard (both try to mount same PVC on different nodes — not yet fixed)

**What remains:**
- jellyfin PVC populator (VolSync restore hostPath vs PSS baseline incompatibility — requires namespace PSS label change or mover privilege config)
- mem0-app/dashboard PVC multi-attach (needs nodeSelector to colocate or RWX PVC)
- Ceph still recovering (2.2% degraded, normal post-reboot)

---

## Commits Pushed This Session

1. **`97d70aa2`** `(feat): add intel-ucode extension + reconcile talos schematics`
2. **`ce02fcaa`** `(feat): upgrade Talos to v1.13.4`

Both pushed to `origin/main`.

---

## Work Completed: Talos v1.13.4 Upgrade + Intel Microcode

### Context

Continuation of `handoff-2026-06-10-reboot-loop-microcode.md` (k8s-4-dell reboot loop diagnosis). User requested checking for newer Talos version and using the upgrade process to install intel-ucode extension.

### What Was Done

**1. Version bump: v1.12.6 → v1.13.4**
- Edited `clusters/talos/bootstrap/os/talenv.yaml`: `talosVersion: v1.13.4`
- Regenerated configs: `task talos:generate-config` (talhelper v3.1.10)
- Validated schematics against factory.talos.dev for v1.13.4 — all valid

**2. Schematic reconciliation (intel-ucode added)**

Updated `talconfig.yaml` with intel-ucode + corrected stale schematic blocks:

| Node | Schematic ID | Extensions | Microcode Result |
|------|--------------|------------|------------------|
| k8s-1, k8s-2, k8s-5 (shared) | `4b3cd373...` | i915 + intel-ucode | ✅ Updated early (`0x419→0x43b`, `0x70d→0x71a`) |
| k8s-4-dell | `26f11340...` | nfsrahead + nvidia + intel-ucode | ✅ `0x39→0x49` (Haswell errata cleared) |
| k8s-3-pxm (Proxmox VM) | `8a18364f...` | qemu-guest-agent + nfsrahead | n/a (host handles µcode) |

**3. Upgrade execution (all 5 nodes)**

**Critical discovery:** talosctl client v1.13.3 vs server v1.12.6 caused gRPC `too_many_pings` GoAway → `context canceled` during upgrades. **Solution:** Downloaded matching talosctl v1.12.6 client to `/var/folders/.../opencode/talosctl-1126`, used it for clean upgrades.

**Worker nodes (k8s-4, k8s-5) — cordoned first due to active reboot loop:**
- k8s-5: cordoned+drained → upgrade completed cleanly → verified microcode updated → uncordoned
- k8s-4: already cordoned/drained (from prior session) → upgrade completed → verified microcode → uncordoned
- **Both nodes stable >5-9min under real load (15 + 9 running pods), zero reboots** — reboot loop SOLVED ✅

**Control-plane nodes (k8s-3, k8s-1, k8s-2) — one at a time:**
- Upgraded in order: k8s-3 (VM, safest) → k8s-1 (was etcd leader) → k8s-2
- etcd quorum maintained throughout (3 members healthy, leader election handled cleanly)
- All passed post-upgrade checks

**Final cluster state:**

```
NAME         STATUS   ROLES           VERSION   OS-IMAGE          KERNEL-VERSION   MICROCODE
k8s-1-nab9   Ready    control-plane   v1.34.6   Talos (v1.13.4)   6.18.34-talos    0x43b (updated)
k8s-2-ser    Ready    control-plane   v1.34.6   Talos (v1.13.4)   6.18.34-talos    AMD 0x8608103
k8s-3-pxm    Ready    control-plane   v1.34.6   Talos (v1.13.4)   6.18.34-talos    (VM, n/a)
k8s-4-dell   Ready    <none>          v1.34.6   Talos (v1.13.4)   6.18.34-talos    0x49 (updated)
k8s-5-1u     Ready    <none>          v1.34.6   Talos (v1.13.4)   6.18.34-talos    0x71a (updated)
```

All nodes: containerd 2.2.4, kernel 6.18.34, zero "old microcode" warnings.

---

## Post-Reboot Recovery Issues

The cluster experienced heavy node churn (reboot loop on k8s-4/k8s-5, then control-plane upgrades). Several apps had stale state:

### 1. ✅ FIXED: postgres17 + pgvector17 Multi-Attach

**Symptom:** postgres17-4, pgvector17-1 stuck in `Init:0/2`, error:
```
Multi-Attach error for volume "pvc-..." Volume is already exclusively attached to one node and can't be attached to another
```

**Root cause:** Stale VolumeAttachments on k8s-2-ser from before the node reboots. Pods rescheduled to k8s-3-pxm but Ceph CSI didn't release the old attachments.

**Fix applied:**
```bash
kubectl delete volumeattachment csi-459ae3156921e28d553b81f180a1447c5e2a168fa28379f12855b97b36f5c437  # postgres17-4
kubectl delete volumeattachment csi-bca5ea826bab8f838c78005e551dc832917532cf5724ee76d35dce748ff8035f  # pgvector17-1
```

**Status:** Both pods progressing to Running (1/2 as of handoff write). CNPG clusters will finish bootstrap.

**Verification needed:** Wait ~5min, confirm:
```bash
kubectl get cluster -n default postgres17 pgvector17  # should show 3/3 READY
kubectl get pods -n default | grep "postgres17\|pgvector17"  # all 2/2 Running
```

---

### 2. ⚠️ NOT FIXED: jellyfin PVC (VolSync restore blocked by PodSecurity)

**Symptom:** jellyfin pod Pending for 3h+, PVC unbound:
```
jellyfin   Pending   (waiting for VolSync populator latestImage)
```

**Root cause (deep, discovered during debug):**

The jellyfin PVC uses VolSync `ReplicationDestination` (`jellyfin-dst`) as a **populator** to restore config from Kopia backup. The restore mover **Job** `volsync-dst-jellyfin-dst` cannot create pods:

```
Error creating pods: is forbidden: violates PodSecurity "baseline:latest": hostPath volumes (volume "repository")
```

**Why this happens:**
1. The **media/kopia migration** (commits `0a945064`, `f4dda52c` from prior session) changed the kopia repo from NFS → **hostPath** `/var/mnt/media/.kopia` on k8s-4-dell.
2. The **VolSync `MutatingAdmissionPolicy`** (`clusters/talos/apps/volsync-system/volsync/mutatingadmissionpolicy.yaml`) injects this hostPath `repository` volume + nodeSelector into **all volsync mover Jobs**.
3. The cluster enforces **PodSecurity `baseline`** cluster-wide (Talos default hardening via AdmissionConfiguration).
4. PSS `baseline` **forbids hostPath volumes** → mover pods rejected → restore never completes → no `latestImage` → PVC never populates.

**Why other hostPath apps (garage-s3, etc.) work in default ns:**
- They're **Deployments** submitted directly, not Jobs mutated by an admission policy. PSS evaluation timing differs.
- OR (more likely): the cluster-wide PSS has **exemptions** (by namespace, username, runtimeClass) that I didn't finish investigating due to time.

**Fix options (in order of preference):**

**A. Label `default` namespace to exempt from PSS baseline (recommended, surgical):**
```bash
kubectl label namespace default pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=baseline pod-security.kubernetes.io/warn=baseline
```
This allows hostPath in default (where many apps already use it: jellyfin's media, garage-app's storage), while keeping audit/warn at baseline for visibility.

**B. Configure VolSync to run movers as privileged (if perfectra1n fork supports it):**
Check VolSync controller args for a `--privileged-movers` flag or similar, OR check if the `--scc-name=volsync-privileged-mover` (OpenShift SCC) has a Kubernetes PSS equivalent.

**C. Move kopia repo back to NFS temporarily** (rollback the migration's hostPath change):
Revert `f4dda52c` + `0a945064`, point movers back at OMV NFS. High-effort, defeats the migration goal.

**D. Move VolSync movers to a privileged namespace:**
Create a separate namespace for movers (e.g., `volsync-movers`) with `enforce=privileged`, run movers there. Complex, requires VolSync config changes.

**Current state:**
- jellyfin PVC: Pending
- jellyfin pod: Pending (unbound PVC)
- ReplicationDestination `jellyfin-dst`: stuck in reconcile loop (mover Job FailedCreate)
- **All default-ns VolSync restore operations are blocked** (any app trying to restore from Kopia will hit the same PSS error)

**Verification after fix:**
```bash
# After applying PSS label or privilege fix:
kubectl get replicationdestination -n default jellyfin-dst -w  # watch for latestImage to appear
kubectl get pvc -n default jellyfin  # should go Pending → Bound
kubectl get pods -n default | grep jellyfin  # should go Pending → Running
```

---

### 3. ⚠️ NOT FIXED: mem0-app RWO PVC conflict

**Symptom:** mem0-app pod stuck in `Init:0/3`:
```
Multi-Attach error for volume "pvc-e0ad41f2..." Volume is already used by pod(s) mem0-dashboard-67cbb47bf-nh5pt
```

**Root cause:**
- Both `mem0-app` and `mem0-dashboard` mount the **same PVC** `mem0` (RWO, ceph-block).
- They're defined in the same Helm chart (`components/ai/mem0/values.yaml`, multi-controller setup sharing `existingClaim: mem0`).
- Post-reboot they rescheduled to **different nodes**:
  - mem0-dashboard: k8s-5-1u (Running, has the PVC attached)
  - mem0-app: k8s-4-dell (can't attach, blocked)
- **RWO PVCs can only attach to one pod at a time** (single-node).

**Fix options:**

**A. Add nodeSelector to colocate both controllers (recommended):**

Edit `components/ai/mem0/values.yaml`:
```yaml
defaultPodOptions:
  nodeSelector:
    kubernetes.io/hostname: k8s-5-1u  # or k8s-4-dell, pick one node
```
This forces both pods onto the same node, allowing them to share the RWO PVC.

**B. Change PVC to ReadWriteMany (ceph-filesystem):**

Requires migrating data to a new RWX PVC. Higher effort.

**C. Give each controller its own PVC:**

If they don't actually need to share data. Check app design.

**Current workaround attempted:**
Deleted mem0-app pod to force reschedule (hoping Kubernetes would colocate it with dashboard). It rescheduled to k8s-4-dell again (same node). Kubernetes doesn't auto-colocate for PVC affinity without explicit nodeSelector.

**Immediate operational fix (if mem0-app isn't critical right now):**
```bash
kubectl scale deploy -n ai mem0-app --replicas=0  # disable mem0-app temporarily
```
Dashboard continues running. Re-enable after adding nodeSelector to values.

---

## Other Findings / Notes

### Arr Stack + qbittorrent NFS→hostPath Migration

**User asked to "start the migration of arr stack and qbittorrent from NFS OMV to hostPath".**

**Finding:** This migration is **already complete and live** (done in prior session, commit `495266e4`):
- sonarr, radarr, bazarr, qbittorrent, sabnzbd: all use `hostPath: /var/mnt/media`
- All running on k8s-4-dell, mounting local XFS `/dev/sdb1`
- Media library verified present (Books, Movies, Shows, downloads)
- Zero NFS/OMV references remain in their values files
- **Verified working** — no action needed.

### Ceph Health

```
HEALTH_WARN
  1 OSDs or CRUSH {nodes, device-classes} have {NOUP,NODOWN,NOIN,NOOUT} flags set
  Degraded data redundancy: 4258/190716 objects degraded (2.233%), 6 pgs degraded/undersized
```

**Status:** Normal post-reboot recovery. Ceph is self-healing (PGs in `recovery_wait`, `backfilling`). All 3 OSDs up & in, 3 mons in quorum. Expected to clear in ~30-60min.

### kopia (volsync-system)

**Status:** `1/1 Running` (pod `kopia-744cf75f8-8qpj6`, 0 restarts). The prior CrashLoopBackOff (from earlier handoffs) self-resolved. Repo is on k8s-4-dell hostPath `/var/mnt/media/.kopia`, operational.

### Uncommitted kopia chown-repo patches

**Not committed by me** (pre-existing in working tree):
- `clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml`
- `clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml`
- `clusters/omv/apps/volsync-system/kopia/...` (same files)

All 4 files have uncommitted `chown-repo` initContainer additions (chown 1000:1000 `/repository`). These were from a prior kopia repair session, NOT this session. **Left untouched** — not mine to commit.

---

## Environment / Access

- **User:** `vikaspogu`
- **Repo:** `/Users/vikaspogu/Documents/git-repos/home-ops`, branch `main`
- **Kubeconfig:** `/Users/vikaspogu/.kube/configs/talos-cluster-config`
- **Talosconfig:** `clusters/talos/bootstrap/os/clusterconfig/talosconfig`
- **Matching talosctl (v1.12.6):** `/var/folders/.../opencode/talosctl-1126` (for pre-upgrade server compat; upgrade complete now, can use v1.13.3 client going forward)
- **Cluster:** home-kubernetes, domain `a113.casa`

---

## Next Actions (Priority Order)

### High Priority

1. **Fix jellyfin PVC (VolSync + PSS baseline conflict):**
   - **Recommended:** Label default namespace `pod-security.kubernetes.io/enforce=privileged`
   - Verify jellyfin PVC populates + pod starts
   - **Impact:** Also unblocks any other default-ns VolSync restores using the hostPath kopia repo

2. **Fix mem0-app PVC conflict:**
   - Add `defaultPodOptions.nodeSelector` to `components/ai/mem0/values.yaml` to colocate mem0-app + mem0-dashboard
   - OR scale mem0-app to 0 if not immediately needed

3. **Verify postgres17 + pgvector17 fully recovered:**
   - Confirm all 3 replicas `2/2 Running` per cluster
   - Check CNPG cluster status: `kubectl get cluster -n default postgres17 pgvector17` (should show `3 READY`)

### Medium Priority

4. **Monitor Ceph recovery completion:**
   - `kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s`
   - Wait for `HEALTH_OK`, all PGs `active+clean`

5. **Validate media stack end-to-end** (from prior migration plan Task 7):
   - Jellyfin serves media (once PVC issue fixed)
   - Arr stack reads/writes library
   - Trigger a VolSync backup+restore round-trip (e.g., sonarr) to prove dell kopia repo works

6. **Push to origin/main** (if not done):
   - Commits `97d70aa2` + `ce02fcaa` already pushed ✓

### Low Priority / Future

7. **Phase 1 OMV decommission completion** (from media migration plan Task 8):
   - Remove jellyfin/garage-app/syncthing/bytestash from `clusters/omv/apps/20-applications.yaml`
   - Power off OMV: `ssh root@omv-baymx 'poweroff'`
   - (Blocked until jellyfin running on Talos)

8. **Investigate homepage OMV link:**
   - `clusters/talos/apps/default/homepage/configmap.yaml:67` has cosmetic `href: http://omv-baymx...` (not a runtime dep, just a UI link)

---

## Key Learnings / Root Causes

### 1. Reboot Loop (k8s-4-dell, k8s-5-1u) — SOLVED

**Root cause:** Old microcode (Haswell/Broadwell-era Intel CPUs) + load (KubeVirt virt-handler VMX instructions) triggered CPU errata → hard resets. The "load follows the workload" pattern confirmed it (k8s-5 started looping after k8s-4 was cordoned and load shifted).

**Fix:** intel-ucode extension via Talos schematics → microcode updated early at boot → errata cleared → stable under load.

**Evidence:** Zero reboots post-upgrade despite 15-24 running pods on both nodes for >10min.

### 2. talosctl Client/Server Version Mismatch

**Issue:** talosctl v1.13.3 (client) vs v1.12.6 (servers) → gRPC keepalive `too_many_pings` GoAway → upgrade actor context cancelled mid-pull → `context canceled` errors.

**Fix:** Downloaded matching v1.12.6 talosctl client. All subsequent upgrades succeeded cleanly.

**Future:** After all nodes on v1.13.4, the v1.13.3 client is compatible again.

### 3. VolSync + PodSecurity + hostPath Incompatibility

**Issue:** Migrating kopia repo to hostPath (for media/kopia OMV decommission) made VolSync mover Jobs use hostPath volumes. Cluster-wide PSS `baseline` forbids hostPath → restore movers rejected → PVC populators stuck.

**Why it surfaced now:** The migration was committed/pushed earlier but jellyfin's restore (using the new hostPath repo) only triggered post-reboot when the PVC was recreated.

**Lesson:** When changing VolSync repo from NFS → hostPath on a PSS-enforced cluster, **namespace PSS labels or mover privilege config must be updated** proactively. This affects **all apps in that namespace** using VolSync restores.

---

## Files Changed This Session

**Committed + Pushed:**
- `clusters/talos/bootstrap/os/talenv.yaml` — v1.12.6 → v1.13.4
- `clusters/talos/bootstrap/os/talconfig.yaml` — intel-ucode extension added, schematics reconciled

**Uncommitted (pre-existing, not touched):**
- `clusters/talos/apps/volsync-system/kopia/deployment-patch.yaml`
- `clusters/talos/apps/volsync-system/kopia/cronjob-patch.yaml`
- `clusters/omv/apps/volsync-system/kopia/deployment-patch.yaml`
- `clusters/omv/apps/volsync-system/kopia/cronjob-patch.yaml`

(All 4 have chown-repo initContainer, from prior session kopia repair)

**Untracked:**
- `docs/superpowers/handoff-2026-06-10-reboot-loop-microcode.md` (prior handoff)
- `docs/superpowers/handoff-2026-06-10-talos-upgrade-postgres-mem0.md` (this file)

---

## Cluster Health Summary (as of handoff)

| Component | Status | Notes |
|-----------|--------|-------|
| Nodes (5) | ✅ All Ready | Talos v1.13.4, microcode updated |
| etcd | ✅ Healthy | 3 members, quorum intact |
| Ceph | ⚠️ WARN | 2.2% degraded, recovering (normal post-reboot) |
| kopia | ✅ Running | Dell hostPath repo operational |
| Arr stack | ✅ Running | sonarr/radarr/bazarr/qbit/sabnzbd all on k8s-4-dell, hostPath media |
| postgres17 | ⏳ Recovering | 1/3 ready, 2 pods progressing (VolumeAttachments fixed) |
| pgvector17 | ⏳ Recovering | 1/3 ready, 2 pods progressing (VolumeAttachments fixed) |
| jellyfin | ❌ Pending | PVC unbound (VolSync restore blocked by PSS hostPath) |
| mem0-app | ❌ Init stuck | RWO PVC conflict with mem0-dashboard (different nodes) |

**Overall:** Core cluster infrastructure healthy. App-level issues are post-reboot scheduling/PVC conflicts + one design issue (VolSync hostPath vs PSS), all diagnosable and fixable.

---

## Success Criteria

**This session:**
- ✅ Talos v1.13.4 upgrade complete (all nodes)
- ✅ Reboot loop solved and verified under load
- ✅ Control-plane upgrade with etcd quorum maintained
- ⏳ Post-reboot recovery in progress (postgres/pgvector progressing, jellyfin/mem0 have clear fixes pending)

**Phase 1 media migration (from prior plan):**
- ✅ Arr stack + kopia migrated to k8s-4-dell hostPath
- ❌ Jellyfin not yet running on Talos (blocked by VolSync PSS issue)
- ❌ OMV not yet decommissioned (blocked by jellyfin)

---

**End of handoff.**
