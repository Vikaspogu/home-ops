# Home-Ops Session Handoff — 2026-06-10 Bugfix Session

> Continuation of `handoff-2026-06-09-work-session-end.md`.
> This session focused on the three open work streams: gitea-runner rootless
> DinD, KubeVirt stuck Deploying, and media migration.

**Date:** 2026-06-10 ~00:30 UTC
**Focus:** Debugging (systematic-debugging skill applied throughout)

---

## Executive Summary

### ✅ Fixed & Verified
1. **Gitea Runner rootless DinD** — `2/2 Running`, registered with Gitea, running CI jobs. No `privileged: true`.
2. **KubeVirt stuck Deploying** — now `phase: Deployed`, all control-plane pods healthy. Root cause was a repo policy bug, not KubeVirt.

### 🔍 Investigated (root cause undetermined)
3. **k8s-4-dell reboot** — abrupt cold power-cycle at 00:21:17 killed the media copy pod. No in-band cause found; needs iDRAC/BMC SEL.

### ⏳ Pending decision
4. **Media migration** — data intact (2.7T), copy pod (`omv-copy`) died on reboot, won't auto-restart. Awaiting decision to resume/verify.

---

## Work Stream 1: Gitea Runner Rootless DinD — ✅ FIXED

**Symptom:** daemon container `CrashLoopBackOff`:
`[rootlesskit:parent] error: failed to start the child: fork/exec /proc/self/exe: operation not permitted`

**Two root causes, both fixed:**

### Cause A: seccomp blocked user-namespace creation
- Kubelet has `seccompDefault: true` → RuntimeDefault seccomp applied to all pods.
- RuntimeDefault blocks `clone`/`unshare` with `CLONE_NEWUSER` without `CAP_SYS_ADMIN`.
- rootlesskit's `fork/exec /proc/self/exe` (to create the userns) got EPERM.
- **Fix:** set daemon container `seccompProfile: { type: Unconfined }`.
- Ruled out: kernel userns (`max_user_namespaces=11255`, enabled), AppArmor (disabled on Talos: `/sys/module/apparmor/parameters/enabled` = `N`), namespace PSS (no labels on `default`).
- Commit: `80a04bdb`

### Cause B: slirp4netns missing /dev/net/tun
- After seccomp fix, userns created OK but failed at network setup:
  `setting up tap tap0 ... exit status 1`
- slirp4netns (rootlesskit's default net driver) creates a tap device, needs `/dev/net/tun`.
- The `dind-rootless` image doesn't provide it.
- **Fix:** mount host `/dev/net/tun` (CharDevice) into the daemon container only.
- Verified `/dev/net/tun` exists on both `k8s-4-dell` and `k8s-5-1u` (`crw-rw-rw- 10,200`).
- Commit: `a9a6a664`

**Verification:** runner log shows
`runner: ..., with labels: [ubuntu-latest ubuntu-24.04 ubuntu-22.04], declare successfully`
and `task 6907 repo is vpogu/ivan-plugin` — registered and running real CI.

**File:** `components/default/gitea-runner/values.yaml`

---

## Work Stream 2: KubeVirt Stuck Deploying — ✅ FIXED

**Symptom:** KubeVirt CR stuck `phase: Deploying` 40+ min; only `virt-operator` pods existed, no virt-api/controller/handler. install-strategy ConfigMap never created.

**Root cause (NOT KubeVirt):** the repo's `volsync-mover` MutatingAdmissionPolicy.
- It matched **all** `batch/v1` Jobs cluster-wide.
- Its CEL `matchConditions` accessed `object.metadata.name`, `object.metadata.labels[...]`, and `object.spec.template.spec.volumes` **without `has()` guards**.
- KubeVirt's install-strategy Job uses `generateName` (no `metadata.name`) and has no volumes → the CEL **errored** ("no such key: name/volumes").
- Per k8s semantics, an erroring matchCondition under `failurePolicy: Fail` **denies the request** (unless another condition returns literal `false`).
- virt-operator's Job creation was denied → reconcile looped forever:
  `policy 'volsync-mover' ... denied request: ... no such key: name`

**This was a latent cluster-wide hazard** — it would deny ANY Job with `generateName` or without volumes, not just KubeVirt's.

**Fix:** guarded all matchConditions in both policies (`volsync-mover` and `volsync-mover-jitter`) with `has()` / `in` so absent fields yield `false` instead of erroring:
```yaml
- expression: has(object.metadata.name) && object.metadata.name.startsWith("volsync-")
- expression: >
    has(object.metadata.labels) &&
    "app.kubernetes.io/created-by" in object.metadata.labels &&
    object.metadata.labels["app.kubernetes.io/created-by"] == "volsync"
- expression: >
    !has(object.spec.template.spec.volumes) ||
    !object.spec.template.spec.volumes.exists(item, item.name == "repository")
```
Applied to both `clusters/talos/.../mutatingadmissionpolicy.yaml` and the `clusters/omv/...` copy.
Commit: `0f45a3ca`

**Verification:** after policy synced + a reconcile nudge (`kubectl annotate kubevirt ...`):
- install-strategy Job ran → `Completed`
- ConfigMap `kubevirt-install-strategy-hcpxl` created
- virt-api x2, virt-controller x2, virt-handler x5, virt-operator x2 all `Running`
- CR: `Available=True Progressing=False Degraded=False Created=True`, `phase: Deployed`
- CDI: `Deployed`

---

## Work Stream 3: Media Migration — ⏳ BLOCKED (node reboot)

**What happened:** `k8s-4-dell` **rebooted** at ~00:21:17 UTC (cold/full BIOS POST boot).
This killed the bare `omv-copy` rsync pod (now orphaned `Unknown`, exit 255).

**Data status: INTACT**
- `/dev/sdb1` at `/var/mnt/media`: **2.7T used, 914G free, 75%**
- Dirs present: `Books, Movies, Shows, downloads`, plus `.kopia`
- Copy was at ~93% (2.6T) before reboot; rsync was interrupted, NOT confirmed complete.

**`omv-copy` is a standalone Pod (no Job owner) → will NOT auto-restart.**

### Reboot investigation (root cause UNDETERMINED in-band)

Ruled out via talosctl/kubectl:
| Cause | Evidence against |
|-------|------------------|
| OOM | 264GB RAM, 245GB free; no OOM logs |
| Kernel panic/oops/BUG | none in captured boot log |
| MCE/thermal (logged) | none |
| Disk full | sys 62%, media 75% |
| Talos-initiated reboot/upgrade | machined shows NO shutdown sequence |

What it was: **abrupt cold power-cycle** (full BIOS POST at 00:21:17, no graceful
shutdown logged). Kernel ring buffer was wiped by the cold boot; Talos captured no
panic. Note: `x86/CPU: Running old microcode` warning on this Dell node.

**Most plausible:** out-of-band hardware/firmware event (watchdog/BMC reset, power
blip, thermal/hardware fault) that bypassed the kernel log. Also note: throughout the
session, k8s-4-dell's kubelet (10250) was flaky (connection refused/timeout) — the
node was unstable *before* the final reset.

**To definitively diagnose:** check **iDRAC/BMC System Event Log (SEL)** — out-of-band,
not reachable via talosctl/kubectl. There was also one `FreeDiskSpaceFailed` image-GC
warning post-reboot (couldn't free 23GB); worth watching but disk is not currently full.

### Next steps for media (awaiting decision)
1. **(Recommended)** Check iDRAC SEL for k8s-4-dell to find the reboot cause before
   loading it with another multi-hour copy.
2. Recreate `omv-copy` to resume rsync (skips already-copied files) — see
   `docs/superpowers/plans/2026-06-09-kopia-media-omv-decommission-phase1.md`.
3. Run the plan's checksum-verification rsync pass.
4. Then: Jellyfin PVC restore, service validation, OMV decommission.

---

## Commits This Session
- `80a04bdb` (fix): set Unconfined seccomp for rootless DinD daemon
- `a9a6a664` (fix): mount /dev/net/tun for rootless DinD slirp4netns
- `0f45a3ca` (fix): guard volsync-mover CEL matchConditions against missing fields

All pushed to `origin/main`.

---

## Current Cluster State (end of session)
- gitea-runner: `2/2 Running` (high restart counts are from debug iterations + reboot recovery; stable now)
- KubeVirt: `Deployed`, healthy; CDI `Deployed`
- k8s-4-dell: `Ready` (rebooted 00:21, recovered)
- media data: intact on k8s-4-dell, copy NOT confirmed complete
- `omv-copy` pod: orphaned `Unknown`/`Failed`, needs cleanup + restart to resume

## Environment
- KUBECONFIG: `/Users/vikaspogu/.kube/configs/talos-cluster-config`
- talosctl context `home-kubernetes`; k8s-4-dell = `10.30.30.24`
- Repo: `/Users/vikaspogu/Documents/git-repos/home-ops`, branch `main`
