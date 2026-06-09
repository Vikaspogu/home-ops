# Gitea Migration Handoff - 2026-06-09

## Summary

**MIGRATION COMPLETE** ✅ - Gitea successfully migrated from OMV (K3s/Longhorn) to Talos (Rook-Ceph), with one remaining issue: Actions runner registration.

## What Was Accomplished

### 1. Core Migration (COMPLETE)
- **PVC Migration**: VolSync restored 3.4 GB of git repositories from OMV NFS-backed Kopia to Talos ceph-block storage
- **Database Migration**: pg_dump/pg_restore moved gitea database (1 user, 8 repositories) from OMV `pg17-omv` to Talos `postgres17` CNPG cluster
- **Application Cutover**: Gitea pod running on Talos, health checks pass, user login works, repos visible
- **OMV Decommissioned**: gitea and gitea-runner removed from `clusters/omv/apps/20-applications.yaml`, ArgoCD pruned

### 2. Critical Cluster-Wide Fix (COMPLETE)
**ROOT CAUSE**: June 4 Rook v1.20 upgrade set `snapshotPolicy: none` for RBD driver, disabling snapshots cluster-wide.

**IMPACT**: All VolumeSnapshots created after June 3 stuck at `readyToUse=false`, breaking VolSync restores.

**FIX APPLIED**: Changed `components/rook-ceph/ceph-csi-drivers/values.yaml` line 22:
```yaml
# Before:
snapshotPolicy: none

# After:
snapshotPolicy: volumeSnapshot
```

**VERIFIED**: 
- RBD CSI ctrlplugin now has `csi-snapshotter` sidecar (6/6 containers, was 5/5)
- New snapshots reach `readyToUse=true` in seconds
- VolSync destination snapshot `volsync-gitea-dst-dest-20260609140108` succeeded
- Gitea PVC bound via volume-populator with dataSourceRef

Commit: `7596c473` "(fix): enable RBD volumeSnapshot policy for ceph-csi driver"

### 3. Configuration Changes
- Gitea database host: `pg17-omv-rw` → `postgres17-rw` (external-secret.yaml)
- Runner docker PVC: `longhorn-volsync` → `ceph-block` (pvc-docker.yaml)
- Gitea boolean env vars: `"True"` → `"true"` (attempted fix for Actions API)

### 4. Current State
**Talos Cluster**:
- Gitea: `gitea-5d85dddbc7-hq8hr` (1/1 Running) at `https://gitea.a113.casa`
- Gitea-runner: `gitea-runner-674dbb88dc-qlwh9` (2/2 Running, CrashLoopBackOff on runner container)
- PVC `gitea`: 20Gi Bound on ceph-block (populated via VolSync restore)
- Database: postgres17 cluster, `gitea` DB has 1 user, 8 repositories

**OMV Cluster**:
- Gitea app removed from ArgoCD, deployments pruned
- gitea PVC (longhorn) and `gitea` DB in `pg17-omv` remain as rollback anchor (not cleaned up yet)

## Remaining Issue: Gitea Actions Runner Registration

### Problem
The gitea-runner pod crashes with:
```
time="2026-06-09T14:20:09Z" level=error msg="Your Gitea version is too old to support runner declare, please upgrade to v1.21 or later"
Error: unimplemented: 404 Not Found
```

### Root Cause Analysis
1. **Gitea version**: 1.26.2 (NEWER than required v1.21)
2. **act_runner version**: 0.6.1
3. **Actions storage initialized**: Logs show Actions storage created at `/var/lib/gitea/actions_log` and `actions_artifacts`
4. **API endpoint missing**: `/api/actions/runner/register` returns 404 (tested all variants: `/api/v1/actions/runner/register`, `/api/v1/actions/runners/registration-token`, etc.)
5. **Admin UI works**: The `/-/admin/actions/runners` page loads (Actions feature is enabled in UI)

### Configuration Checked
```yaml
# components/default/gitea/values.yaml (line 23-24)
GITEA__ACTIONS__ENABLED: "true"  # (changed from "True", no effect)
GITEA__ACTIONS__DEFAULT_ACTIONS_URL: "https://gitea.com"
```

### Evidence
- Gitea logs show: `[I] Initialising Actions storage` (Actions is initializing)
- API requests logged as `GlobalNotFound` (routes not registered)
- Env var `GITEA__ACTIONS__ENABLED=true` is set in pod
- No `[actions]` section appears in `/data/gitea/conf/app.ini`

### Hypothesis
- Gitea 1.26 may require Actions to be enabled via app.ini config file, not just env vars
- API endpoint path changed between act_runner 0.6.1 and gitea 1.26
- Missing prerequisite configuration (Actions default runner, org/repo-level enablement)

## Next Steps for Runner Registration

### Option 1: Manual Registration (Workaround)
If you have the registration token from gitea UI (Admin → Actions → Runners → Create new Runner):

```bash
# Scale runner to 0 temporarily
KUBECONFIG=~/.kube/configs/talos-cluster-config kubectl scale deploy gitea-runner -n default --replicas=0

# Delete the runner PVC to clear old .runner file
KUBECONFIG=~/.kube/configs/talos-cluster-config kubectl delete pvc gitea-runner -n default
KUBECONFIG=~/.kube/configs/talos-cluster-config kubectl patch pvc gitea-runner -n default --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'

# Update 1Password item 'gitea' field 'RUNNER_TOKEN' with the new token from UI

# Force ExternalSecret sync
KUBECONFIG=~/.kube/configs/talos-cluster-config kubectl annotate externalsecret gitea-runner -n default force-sync=$(date +%s) --overwrite

# Scale runner back up
KUBECONFIG=~/.kube/configs/talos-cluster-config kubectl scale deploy gitea-runner -n default --replicas=1

# If still failing, exec into runner pod and manually register:
kubectl exec -it -n default <runner-pod> -c runner -- \
  act_runner register --no-interactive \
  --instance https://gitea.a113.casa \
  --token <REGISTRATION_TOKEN>
```

### Option 2: Enable Actions via app.ini
Create a custom app.ini ConfigMap/Secret with:
```ini
[actions]
ENABLED = true
DEFAULT_ACTIONS_URL = https://github.com
```

Mount this into gitea pod at `/data/gitea/conf/app.ini` or use gitea's config override mechanism.

### Option 3: Investigate API Compatibility
- Check gitea 1.26 changelog for Actions API changes
- Upgrade act_runner to latest version (check compatibility matrix)
- Review https://docs.gitea.com/usage/actions/overview for 1.26-specific setup

### Option 4: Verify Actions Enabled at Repo/Org Level
Actions might need to be enabled:
- Per repository (Settings → Actions)
- Site-wide via gitea admin UI
- Database flag check

## Important Files Modified

```
components/default/gitea/external-secret.yaml (DB host OMV→Talos)
components/default/gitea-runner/pvc-docker.yaml (storageClass fix)
components/default/gitea/values.yaml (boolean case fix)
components/rook-ceph/ceph-csi-drivers/values.yaml (snapshotPolicy fix)
clusters/talos/apps/20-applications.yaml (gitea + runner registered)
clusters/omv/apps/20-applications.yaml (gitea + runner removed)
```

## Verification Commands

### Test Gitea Health
```bash
KUBECONFIG=~/.kube/configs/talos-cluster-config kubectl exec -n default \
  $(kubectl get pod -n default -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}') \
  -- wget -qO- http://localhost:3000/api/healthz
```
Expected: `{"status":"pass",...}`

### Check Database
```bash
KUBECONFIG=~/.kube/configs/talos-cluster-config kubectl exec -n default postgres17-6 -c postgres -- \
  psql -U postgres -d gitea -tAc 'SELECT count(*) FROM "user", count(*) FROM repository;'
```
Expected: `1|8`

### Test RBD Snapshots (Cluster-Wide Fix)
```bash
cat <<EOF | KUBECONFIG=~/.kube/configs/talos-cluster-config kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: test-rbd-snapshot
  namespace: default
spec:
  volumeSnapshotClassName: csi-ceph-blockpool
  source:
    persistentVolumeClaimName: <any-rbd-pvc>
EOF

# Wait 30s, then check:
kubectl get volumesnapshot test-rbd-snapshot -n default
```
Expected: `READYTOUSE=true`

### Check Runner Status
```bash
KUBECONFIG=~/.kube/configs/talos-cluster-config kubectl logs -n default \
  -l app.kubernetes.io/name=gitea-runner -c runner --tail=20
```

## Rollback Procedure (If Needed)

The OMV gitea instance is scaled to 0 but all data is intact:

```bash
# Re-register gitea on OMV
# (Add back to clusters/omv/apps/20-applications.yaml and push)

# Scale back up
ssh root@10.30.30.54 'kubectl scale deploy gitea -n default --replicas=1'

# Database and PVC are unchanged on OMV
```

## Context for New Session

**User**: `vikaspogu`  
**Primary Kubeconfig**: `~/.kube/configs/talos-cluster-config`  
**OMV Access**: `ssh root@10.30.30.54` (or IP `10.30.30.54` if DNS fails)  
**Repo**: `/Users/vikaspogu/Documents/git-repos/home-ops`  
**Cluster Domain**: `a113.casa`

**Key Constraint**: User wants gitea Actions runner working, not just gitea itself.

**Starting Point**: 
- Gitea is fully functional for git operations (push/pull/web UI)
- Focus needed: Fix runner registration to enable GitHub Actions-style CI/CD
- Consider: This might be a gitea 1.26 + act_runner 0.6.1 incompatibility requiring version changes

**Documents Created This Session**:
- Implementation plan: `docs/superpowers/plans/2026-06-09-gitea-omv-to-talos-migration.md`
- Design spec: `docs/superpowers/specs/2026-06-09-gitea-omv-to-talos-migration-design.md`
- This handoff: `docs/superpowers/handoff-2026-06-09-gitea-migration.md`

## Key Learnings

### RBD Snapshot Failure Pattern
When all RBD VolumeSnapshots get stuck at `readyToUse=false` with empty VolumeSnapshotContent status:
1. Check if `csi-snapshotter` sidecar exists in RBD ctrlplugin pods
2. Review Rook upgrade commits for `snapshotPolicy` changes
3. Verify with test snapshot on a known-good PVC
4. Look for recent Rook operator configuration changes

### VolSync Volume-Populator Pattern
When PVCs with dataSourceRef stay Pending:
- Check ReplicationDestination.status.latestImage is populated
- Verify the referenced VolumeSnapshot is `readyToUse=true`
- Watch for "VolSyncPopulatorReplicationDestinationNoLatestImage" events
- The populator creates temporary `vs-prime-*` PVCs during population

### Gitea Actions Debugging
- Actions storage initialization != Actions API enabled
- Env var `GITEA__ACTIONS__ENABLED` may not be sufficient
- Check `/api/actions/*` endpoints with curl/wget inside pod
- Verify runner version compatibility matrix with gitea version
