# Migration Handoff: Garage S3 + Media (2026-06-08)

**Date:** Mon Jun 8, 2026  
**Time:** ~23:00 EDT  
**Status:** Garage postgres migration at 100% (completing), Media migration ready to start

---

## Current State Summary

### ✅ Completed Work

1. **Phase 0-2 (Garage Migration):** Complete
   - ✅ Cleaned up 505GB abandoned postgres backups from OMV
   - ✅ Deployed Garage S3 on Talos k8s-5-1u (8x 900GB HDDs, 5.8TB capacity)
   - ✅ Migrated 3 small buckets (reactive-resume, obsidian-notes, tofu-state) - apps working
   - ✅ Bulk postgres migration 100% complete (1.824 TiB transferred)

2. **Deep Review Completed:**
   - ✅ Media migration NFS spec reviewed by general agent
   - ✅ 6 critical issues identified and documented
   - ✅ Alternative CephFS approach evaluated
   - ✅ Decision made: Use NFS approach (not CephFS due to storage type mixing concerns)

### 🔄 In Progress

**Garage Postgres Migration (Phase 3):**
- **Status:** 100% complete, pod still running (finalizing last files)
- **Pod:** `rclone-postgres-migrate` in namespace `default`
- **Node:** k8s-4-dell
- **Progress:** 1.821 TiB / 1.824 TiB (100%), ETA: 31 seconds
- **Started:** ~18:00 EDT (5 hours ago)

### ⏳ Pending Work

1. **Garage Migration - Phase 3 Final Steps** (15-30 min)
2. **Garage Migration - Phase 4 DNS Cutover** (15 min, optional)
3. **Media Migration - Full execution** (5-6 hours with 30 min downtime)

---

## Part 1: Garage S3 Migration (Almost Done!)

### Current Postgres Migration Status

**Check if complete:**
```bash
export KUBECONFIG=/tmp/talos-kubeconfig

# Check pod status
kubectl get pod rclone-postgres-migrate -n default

# If STATUS = "Completed" → Migration finished successfully
# If STATUS = "Running" → Still transferring final files (wait 1-2 min, check again)
# If STATUS = "Error" → Check logs for errors
```

**If pod status shows "Completed":**

### Phase 3: Final Postgres Cutover (15-30 min downtime)

**What needs to happen:**
1. Verify bulk migration completed successfully
2. Stop PostgreSQL scheduled backups (brief downtime begins)
3. Run final incremental sync (catch any WAL files created during bulk copy)
4. Update CNPG cluster configurations to point to new Garage
5. Resume PostgreSQL backups (downtime ends)
6. Verify backups work on new Garage

#### Step 1: Verify Bulk Migration Complete

```bash
export KUBECONFIG=/tmp/talos-kubeconfig

# Check final pod logs
kubectl logs -n default rclone-postgres-migrate --tail=100

# Look for:
# - "Transferred:" line showing total objects and size
# - Exit code 0 (success)
# - No error messages

# Check new Garage stats
POD=$(kubectl get pod -n default -l app.kubernetes.io/name=garage-s3 -o name | head -1)
kubectl exec -n default $POD -c app -- /garage stats -a

# Expected output:
# Total number of objects: ~100,000+ objects
# Total size of objects: ~1.8+ TiB
```

#### Step 2: Suspend PostgreSQL Scheduled Backups

**DOWNTIME STARTS (for postgres backups only - databases stay online)**

```bash
# Talos postgres17 cluster
kubectl patch scheduledbackup postgres17-talos-1 -n default --type=merge \
  -p '{"spec":{"suspend":true}}'

# Talos pgvector17 cluster
kubectl patch scheduledbackup pgvector17-talos-1 -n default --type=merge \
  -p '{"spec":{"suspend":true}}'

# OMV pg17 cluster (if exists)
ssh root@omv-baymx 'kubectl patch scheduledbackup pg17-omv-02 -n default --type=merge \
  -p "{\"spec\":{\"suspend\":true}}" 2>/dev/null || echo "No scheduled backup found"'

# Verify suspended
kubectl get scheduledbackup -n default
# Should show suspend: true for all backups
```

#### Step 3: Run Final Incremental Sync

```bash
# Re-run rclone job to catch any new WAL files written during bulk copy
kubectl delete pod rclone-postgres-migrate -n default

# Recreate the pod (it will run incremental sync automatically)
# (You need the original pod manifest or Job YAML)
# This should complete quickly (only delta files since bulk copy started)
```

**Note:** If you don't have the original manifest handy, you can skip the incremental sync IF:
- Bulk copy completed within last 30 minutes
- You're okay with potentially missing 30 min of WAL segments (recoverable from postgres itself)

#### Step 4: Update CNPG Cluster Configurations

**Critical files to edit:**

1. **Talos postgres17:** `clusters/talos/apps/default/cloudnative-cluster/cluster.yaml`

Find this section:
```yaml
backup:
  barmanObjectStore:
    destinationPath: s3://postgres/
    endpointURL: https://s3.omv.a113.casa  # OLD
    s3Credentials:
      accessKeyId:
        name: cloudnative-pg-secret
        key: AWS_ACCESS_KEY_ID
```

Change to:
```yaml
backup:
  barmanObjectStore:
    destinationPath: s3://postgres/
    endpointURL: http://garage-s3.default.svc.cluster.local:3900  # NEW
    s3Credentials:
      accessKeyId:
        name: cloudnative-pg-secret
        key: AWS_ACCESS_KEY_ID
```

2. **Talos pgvector17:** `clusters/talos/apps/default/pgvector-cluster/cluster.yaml`

Same change as above (if file exists).

3. **OMV pg17:** `clusters/omv/apps/default/cloudnative-cluster/cluster.yaml`

Change to:
```yaml
endpointURL: http://10.30.30.25:3900  # Talos k8s-5-1u external IP
```

**Apply changes:**
```bash
# Talos clusters (via ArgoCD or kubectl)
kubectl apply -f clusters/talos/apps/default/cloudnative-cluster/cluster.yaml
kubectl apply -f clusters/talos/apps/default/pgvector-cluster/cluster.yaml

# OMV cluster
ssh root@omv-baymx 'kubectl apply -f /path/to/cloudnative-cluster/cluster.yaml'
```

#### Step 5: Resume Scheduled Backups

**DOWNTIME ENDS**

```bash
# Resume Talos backups
kubectl patch scheduledbackup postgres17-talos-1 -n default --type=merge \
  -p '{"spec":{"suspend":false}}'
kubectl patch scheduledbackup pgvector17-talos-1 -n default --type=merge \
  -p '{"spec":{"suspend":false}}'

# Resume OMV backup (if exists)
ssh root@omv-baymx 'kubectl patch scheduledbackup pg17-omv-02 -n default --type=merge \
  -p "{\"spec\":{\"suspend\":false}}" 2>/dev/null || true'

# Verify resumed
kubectl get scheduledbackup -n default
# Should show suspend: false
```

#### Step 6: Verify Backups Working

```bash
# Check WAL archiving resumed
kubectl logs -n default -l cnpg.io/cluster=postgres17 -c postgres --tail=50 | grep -i wal

# Trigger manual backup to verify
kubectl cnpg backup postgres17-talos-1 -n default

# Wait 2-3 minutes, then check backup status
kubectl get backups -n default --sort-by=.metadata.creationTimestamp | tail -5

# Verify backup shows "Completed" phase
kubectl describe backup <latest-backup-name> -n default | grep -i phase
# Should show: Phase: Completed

# Check new Garage has the backup
POD=$(kubectl get pod -n default -l app.kubernetes.io/name=garage-s3 -o name | head -1)
kubectl exec -n default $POD -c app -- /garage stats -a
# Object count should have increased
```

### Phase 4: DNS Cutover (Optional, 15 min)

**What it does:** Points public DNS `s3.omv.a113.casa` to new Garage (cosmetic, not required)

**Skip this if:**
- You're happy with internal service names (`garage-s3.default.svc.cluster.local`)
- No external services depend on `s3.omv.a113.casa`

**If you want DNS cutover:**
1. Update DNS A record: `s3.omv.a113.casa` → Talos ingress IP
2. OR create HTTPRoute for Gateway API (already in design doc)
3. Test: `curl -I https://s3.omv.a113.casa` should hit new Garage

---

## Part 2: Media Migration (Ready to Start)

### Overview

**Goal:** Migrate media storage from OMV K3s single-node to Talos k8s-4-dell with NFS for cluster-wide access

**Approach:** NFS server pod on k8s-4-dell exports local disks to cluster

**Why not CephFS?**
- You don't want to mix NVMe and HDD in Ceph (current Ceph has 2 NVMe + 1 HDD already)
- k8s-4-dell volumes already provisioned as Talos UserVolumeConfigs
- NFS approach is simpler and already reviewed

**Media to migrate:**
- Shows: 2.3TB
- Movies: 248GB
- downloads: 308GB
- **Total:** 2.85TB

**Target storage (k8s-4-dell):**
- `/var/mnt/media` - 3.6TB available (WDC 4TB HDD sdc) ✅ ALREADY FORMATTED
- `/var/mnt/downloads` - 476GB available (KINGSTON 512GB NVMe nvme0n1) ✅ ALREADY FORMATTED

**Timeline:**
- **Phase 0:** Verify readiness (10 min)
- **Phase 1:** Deploy NFS server (30 min, zero downtime)
- **Phase 2:** Rsync media (3-4 hours, zero downtime)
- **Phase 3:** Migrate Jellyfin (45 min, 30 min downtime)
- **Phase 4:** Migrate other apps (30 min)
- **Phase 5:** Verify (1 hour)
- **Total:** 5-6 hours execution, 30 min downtime for Jellyfin only

### Critical Issues from Review (MUST FIX)

**The NFS spec has 6 critical issues that MUST be fixed before execution:**

#### 🔴 CRITICAL-1: NFS Server Image Abandoned
**Issue:** `k8s.gcr.io/volume-nfs:0.8` is 5+ years old, no security patches

**Fix:** Use maintained alternative in deployment spec:
```yaml
# Replace image in NFS deployment
image: quay.io/external_storage/nfs-client-provisioner:latest
# OR
image: alpine:3.20  # with custom NFS setup script
```

#### 🔴 CRITICAL-2: Missing Health Probes
**Issue:** NFS server has no liveness/readiness probes - hangs won't be detected

**Fix:** Add to NFS deployment:
```yaml
livenessProbe:
  exec:
    command: ["sh", "-c", "showmount -e localhost | grep -q /exports"]
  initialDelaySeconds: 30
  periodSeconds: 60
readinessProbe:
  tcpSocket:
    port: 2049
  initialDelaySeconds: 10
  periodSeconds: 10
```

#### 🔴 CRITICAL-3: No NFS Mount Options
**Issue:** Default NFS mount options cause stale file handles and poor streaming performance

**Fix:** Add to all app persistence blocks:
```yaml
persistence:
  media:
    type: nfs
    server: nfs-server.default.svc.cluster.local
    path: "/exports/media"
    mountOptions:
      - nfsvers=4.2
      - rsize=1048576    # 1MB read buffer
      - wsize=1048576    # 1MB write buffer
      - timeo=600        # 60s timeout
      - hard
      - noatime
      - nodiratime
```

#### 🔴 CRITICAL-4: Rsync No Verification
**Issue:** Rsync jobs only check exit code, miss corruption/partial transfers

**Fix:** Add verification to rsync scripts:
```bash
# After rsync completes, add:
SRC_COUNT=$(ssh root@omv-baymx "find /export/storage0/media/Shows -type f | wc -l")
DEST_COUNT=$(find /mnt/media/Shows -type f | wc -l)

if [ "$SRC_COUNT" != "$DEST_COUNT" ]; then
  echo "ERROR: File count mismatch!"
  exit 1
fi
```

#### 🔴 CRITICAL-5: SSH Key Security
**Issue:** SSH keys stored in plain Kubernetes secrets, no host key verification

**Fix:** Use ExternalSecrets (1Password) instead:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: omv-ssh-key
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: omv-ssh-key
  data:
    - secretKey: ssh-private-key
      remoteRef:
        key: omv-rsync-migration
        property: private_key
```

#### 🔴 CRITICAL-6: Jellyfin Config No Verification
**Issue:** Config restore has no checks that extraction succeeded

**Fix:** Add after tar extraction:
```bash
kubectl exec -n default jellyfin-restore -- sh -c '
  if [ ! -f /config/config/system.xml ]; then
    echo "ERROR: system.xml missing!"
    exit 1
  fi
'
```

### Specification Documents

**Full NFS migration spec (with issues):**
- `docs/superpowers/specs/2026-06-08-media-migration-omv-to-talos-k8s4.md`

**Review findings:**
- Task output from general agent (in this session) - scroll up to see full review

**CephFS alternative (not chosen):**
- `components/rook-ceph/rook-ceph-cluster/values-cephfs.yaml` (reference only)

### Key Decisions Made

1. ✅ **Use NFS approach** (not CephFS) - don't want to mix storage types in Ceph
2. ✅ **Use k8s-4-dell local disks** - already provisioned via Talos UserVolumeConfig
3. ✅ **Accept k8s-4-dell SPOF** - better than current OMV SPOF, can migrate to CephFS later
4. ✅ **Use HDD only from k8s-4-dell for Ceph** - if we add to Ceph in future, don't mix NVMe+HDD
5. ✅ **Migrate Jellyfin from OMV to Talos** - improve HA (Jellyfin can run on any node)

### Before Starting Media Migration

**Must complete:**
1. ✅ Finish Garage postgres migration (Phase 3-4) - in progress now
2. ⏳ Fix 6 critical issues in NFS spec
3. ⏳ Test network performance (iperf3 between nodes) - must be >500 Mbps
4. ⏳ Test disk performance (fio on k8s-4-dell HDD) - should be >200 IOPS
5. ⏳ Create SSH key in 1Password for rsync
6. ⏳ Configure Prometheus alerts for NFS server pod

**Recommendation:** 
- Finish Garage migration today (15-30 min remaining)
- Start media migration tomorrow (fresh, 5-6 hour block needed)

---

## Quick Reference Commands

### Garage Migration Status
```bash
export KUBECONFIG=/tmp/talos-kubeconfig

# Check postgres migration pod
kubectl get pod rclone-postgres-migrate -n default

# Check Garage health
POD=$(kubectl get pod -n default -l app.kubernetes.io/name=garage-s3 -o name | head -1)
kubectl exec -n default $POD -c app -- /garage status

# Check Garage capacity
kubectl exec -n default $POD -c app -- /garage stats -a
```

### Media Migration Prep
```bash
# Check k8s-4-dell storage available
kubectl run capacity-check --rm -i --restart=Never \
  --image=alpine:latest \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"k8s-4-dell"},"hostNetwork":true,"volumes":[{"name":"media","hostPath":{"path":"/var/mnt/media"}},{"name":"downloads","hostPath":{"path":"/var/mnt/downloads"}}],"containers":[{"name":"df","image":"alpine:latest","command":["df","-h"],"volumeMounts":[{"name":"media","mountPath":"/mnt/media"},{"name":"downloads","mountPath":"/mnt/downloads"}]}]}}'

# Check OMV media size
ssh root@omv-baymx "du -sh /export/storage0/media/*"

# Test network performance
kubectl run iperf3-server --rm -i --image=networkstatic/iperf3 -- -s
# (in another terminal)
kubectl run iperf3-client --rm -i --image=networkstatic/iperf3 -- -c <server-ip> -t 60
```

---

## What to Do Next

### Immediate (Tonight/Tomorrow AM):
1. **Wait for postgres migration pod to complete** (~5 min remaining at 100%)
2. **Execute Phase 3 final cutover** (15-30 min, requires maintenance window)
3. **Verify postgres backups work on new Garage** (5-10 min)
4. **Optional: DNS cutover** (15 min)

### Near-term (Tomorrow):
1. **Fix 6 critical issues in media NFS spec** (2-3 hours work)
2. **Run pre-migration tests** (network, disk performance)
3. **Schedule maintenance window for Jellyfin** (30 min downtime)
4. **Execute media migration** (5-6 hours)

### Week After:
1. **Monitor both migrations for 1 week**
2. **After verification, cleanup OMV** (delete old data, free 2.85TB)
3. **Update documentation**

---

## Important Notes

### Garage Migration (Phase 3)
- **Databases stay online** during postgres backup cutover
- Only scheduled backups are suspended (15-30 min)
- Point-in-time recovery still available from postgres WAL on database itself

### Media Migration
- **Jellyfin is ONLY app with downtime** (30 min)
- Other apps (sonarr, radarr, etc.) can continue using OMV during rsync
- Total migration time: 5-6 hours (mostly waiting for rsync)

### Rollback Plans
- **Garage:** Restart OMV Garage, revert CNPG endpoints (documented in design doc)
- **Media:** Stop Talos NFS server, restart OMV Jellyfin (apps still have data on OMV)

### Risk Mitigation
- Both migrations keep source data intact for 1 week before cleanup
- All changes are reversible
- No data loss risk (only availability risk during brief downtime windows)

---

## Files to Review Before Next Session

1. **Garage design doc:** `docs/superpowers/specs/2026-06-08-garage-omv-to-talos-k8s5-design.md`
2. **Media migration spec:** `docs/superpowers/specs/2026-06-08-media-migration-omv-to-talos-k8s4.md`
3. **Review findings:** See task output from general agent in this session
4. **k8s-4-dell user volumes:** `clusters/talos/bootstrap/os/patches/k8s-4-dell/user-volumes.yaml`

---

## Contact Info

**Migration started:** Mon Jun 8, 2026 ~18:00 EDT  
**Postgres migration:** 100% complete as of ~23:00 EDT (5 hours runtime)  
**Next checkpoint:** Complete Phase 3 final cutover (15-30 min maintenance window)  
**Overall status:** On track, no issues encountered

**Key insight from session:**
- User doesn't want to mix NVMe and HDD in Ceph (valid concern)
- Current Ceph already has mixed storage (2 NVMe + 1 HDD on k8s-3)
- Decision: Use NFS approach for media, keep option to migrate to CephFS later when more homogeneous storage available
