# Handoff: Garage Multi-Node Deployment (2026-06-11)

## Session Context

**Date:** June 11, 2026  
**User:** vikaspogu  
**Goal:** Deploy Garage S3 multi-node cluster with replication to protect against June 10 disk wipe disaster  

## What Happened on June 10

- Talos upgrade (with Kata extension) rebooted k8s-5-1u node
- Talos `UserVolumeConfig` with `provisioning:` section reformatted all 8 Garage HDDs
- All Garage S3 data wiped (6TB, including PostgreSQL backups)
- Root cause: `replication_factor=1` meant 100% data loss
- PostgreSQL pods crashed because WAL archiving to Garage failed

## Session Accomplishments

### ✅ Completed

1. **Fixed Talos disk configs** (all 3 nodes)
   - Removed dangerous `provisioning:` sections
   - Using `machine.disks` with WWN IDs (stable across reboots)
   - Confirmed: Current configs are SAFE and won't reformat disks
   - Files: `clusters/talos/bootstrap/os/patches/{k8s-3-4u,k8s-4-dell,k8s-5-1u}/`

2. **Recovered PostgreSQL pods**
   - Applied Garage cluster layout (version 1)
   - Created `postgres` bucket on Garage
   - Granted `main` key (GK1ef6ef65262a8e0cb0792bf2) read/write permissions
   - Both PostgreSQL clusters now healthy (pgvector17-4, postgres17-7 are 2/2 Running)

3. **Deployed Garage multi-node infrastructure** (partial)
   - Created `garage-s3-node2` component for k8s-3-4u
   - Committed and pushed to Git (commits: 2ef9c98d, dbf3ce87, a1a4abf4)
   - ArgoCD deployed both garage-s3 and garage-s3-node2 pods
   - Both pods running: garage-s3 (2/2), garage-s3-node2 (1/1)

### ❌ Critical Issues Remaining

#### **Issue 1: Node2 Running on WRONG Physical Node** 🔴

**Problem:**
- garage-s3-node2 pod is running on **k8s-5-1u** (same as node1)
- Should be running on **k8s-3-4u** (backup node with 4× 4TB drives)
- Pod affinity rules in `values.yaml` were NOT applied by bjw-s app-template

**Current Status:**
```
garage-s3:       10.69.4.12   k8s-5-1u  ❌ (both on same node!)
garage-s3-node2: 10.69.4.90   k8s-5-1u  ❌ (defeats redundancy purpose)
```

**Expected:**
```
garage-s3:       IP   k8s-5-1u  ✅
garage-s3-node2: IP   k8s-3-4u  ✅ (separate physical node)
```

**Affinity Config (Not Working):**
File: `components/default/garage-s3-node2/values.yaml` (lines 73-82)
```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - k8s-3-4u
```

**Why It's Not Working:**
- bjw-s app-template v4.6.2 may not support `affinity` at root level
- Need to check if it should be nested under `controllers.garage-s3-node2.pod.affinity`

**Fix Required:**
1. Update `values.yaml` to use correct bjw-s affinity syntax
2. Or add nodeSelector as fallback: `kubernetes.io/hostname: k8s-3-4u`
3. Delete current pod and verify it reschedules to k8s-3-4u

---

#### **Issue 2: Node2 Can't Discover Node1** 🔴

**Problem:**
Node2 logs show DNS resolution failure:
```
[WARN] garage_rpc::system: Unable to parse and/or resolve peer hostname garage-s3.default.svc.cluster.local:3901
```

**Root Cause:**
- Node2 config has `bootstrap_peers = ["garage-s3.default.svc.cluster.local:3901"]`
- DNS resolution failing from within node2 pod
- Garage RPC needs pod-to-pod connectivity, not via ClusterIP Service

**Current Config:**
File: `components/default/garage-s3-node2/resources/configuration.toml` (line 20)
```toml
rpc_public_addr = "garage-s3-node2.default.svc.cluster.local:3901"
bootstrap_peers = ["garage-s3.default.svc.cluster.local:3901"]
```

**Fix Options:**
1. **Use headless Service** - Create `clusterIP: None` service for both garage instances
2. **Use StatefulSet** - Convert to StatefulSet with stable pod DNS names
3. **Manual IP-based connection** - Use pod IPs directly (temporary workaround)

---

#### **Issue 3: Garage CLI Commands Don't Work** 🟡

**Problem:**
Cannot run `garage` CLI commands inside containers:
```bash
kubectl exec garage-s3-xxx -c app -- /garage status
# Error: connect to 10.96.84.81:3901 timed out
```

**Root Cause:**
- Distroless container (no shell: `sh`, `bash` not available)
- Garage CLI tries to connect to itself via `rpc_public_addr` (ClusterIP)
- ClusterIP might not be routable from within pod

**Workaround:**
- Use Garage Admin API (HTTP) instead of CLI:
  ```bash
  kubectl run curl-status --rm -i --image=curlimages/curl -- \
    curl -H "Authorization: Bearer 2LY8t69M-KZ2NNNwyB" \
    http://garage-s3.default.svc.cluster.local:3903/v2/GetClusterStatus
  ```

---

## Current Architecture

### Garage Node 1 (k8s-5-1u)
- **Pod:** garage-s3-6bc488c485-j2kqb (2/2 Running)
- **Storage:** 8× 900GB HDDs (/var/mnt/garage-hdd1-8)
- **Capacity:** 6.4TB configured, ~6TB used
- **RPC:** 10.69.4.12:3901
- **Status:** ✅ Operational, serving S3 requests
- **Layout:** Version 1, replication_factor=1

### Garage Node 2 (k8s-5-1u) ❌ WRONG NODE
- **Pod:** garage-s3-node2-56b57b68df-ltjgg (1/1 Running)
- **Storage:** Mounted /var/mnt/backup-garage (but on wrong node!)
- **Should be on:** k8s-3-4u (4× 4TB HDDs)
- **RPC:** 10.69.4.90:3901
- **Status:** ⚠️ Running but isolated (not connected to cluster)
- **Layout:** Version 0 (not joined to cluster yet)

### Garage IDs
```
Node1: 3a03f35f87b800a9150832e01333bd8da316f48634423ebd664beacfbf1d0d14
Node2: a70b49764f124b676bcdabdf99a1234eb8d1e556daddfc1b366f2aaae9768e88
```

---

## Files Modified This Session

### New Files Created
1. `components/default/garage-s3-node2/values.yaml` (89 lines)
2. `components/default/garage-s3-node2/resources/configuration.toml` (30 lines)
3. `components/default/garage-s3-node2/kustomization.yaml` (16 lines)

### Modified Files
1. `components/default/garage-s3/resources/configuration.toml`
   - Changed: `rpc_public_addr` from `127.0.0.1:3901` to DNS name
   - Kept: `replication_factor = 1` (tried to change to 2, but Garage rejected it)
   
2. `clusters/talos/apps/20-applications.yaml`
   - Added: garage-s3-node2 ArgoCD application entry

### Deleted Files
- Removed duplicate `garage-s3-node2/externalsecret.yaml` (both nodes share same secret)

---

## Git Commits (This Session)

```
c62e86fd - (earlier) fix k8s-3-4u disk WWIDs and configure as backup node
2ef9c98d - (feat): deploy Garage multi-node cluster with replication_factor=2
dbf3ce87 - (fix): keep replication_factor=1 in config, will be set via layout
a1a4abf4 - (fix): remove duplicate ExternalSecret from garage-s3-node2
```

---

## Configuration Reference

### Talos Disk Mounts (Verified Safe ✅)

**k8s-5-1u** (Garage node1):
```yaml
machine:
  disks:
    - device: /dev/disk/by-id/wwn-0x5000cca02278736c
      partitions:
        - mountpoint: /var/mnt/garage-hdd1
    # ... (8 total drives)
```

**k8s-3-4u** (Garage node2 target):
```yaml
machine:
  disks:
    - device: /dev/disk/by-id/wwn-0x5000cca0bc75f620
      partitions:
        - mountpoint: /var/mnt/backup-media
    - device: /dev/disk/by-id/wwn-0x5000cca0bc6e0cc0
      partitions:
        - mountpoint: /var/mnt/backup-downloads
    - device: /dev/disk/by-id/wwn-0x5000cca097de6224
      partitions:
        - mountpoint: /var/mnt/backup-garage  # ← Node2 should use this
    - device: /dev/disk/by-id/wwn-0x5000cca0bc767184
      partitions:
        - mountpoint: /var/mnt/backup-reserved
```

### Garage Secrets (1Password)

**Item:** `garage-s3`  
**Keys:**
- `GARAGE_ADMIN_TOKEN`: 2LY8t69M-KZ2NNNwyB (used in session)
- `GARAGE_RPC_SECRET`: (shared by both nodes for cluster membership)
- `GARAGE_METRICS_TOKEN`: (for Prometheus metrics)

**Secret Name:** `garage-s3-secret` (namespace: default)

---

## Next Steps (Priority Order)

### 🔴 Critical (Must Fix Before Continuing)

1. **Fix garage-s3-node2 affinity to deploy on k8s-3-4u**
   - Check bjw-s app-template v4.6.2 docs for correct affinity syntax
   - Options:
     - A. Fix `affinity` field location in values.yaml
     - B. Use `pod.nodeSelector` instead (simpler fallback)
   - Delete current pod and verify it reschedules to k8s-3-4u
   - Verify storage mounts: `/var/mnt/backup-garage` should have subdirs

2. **Fix RPC connectivity between nodes**
   - Once node2 is on k8s-3-4u, they'll be on different physical nodes
   - Options:
     - A. Create headless Service for stable pod DNS
     - B. Use pod IPs directly in bootstrap_peers (temporary)
     - C. Convert to StatefulSet (better long-term solution)
   - Test: `kubectl logs garage-s3-node2-xxx` should show successful peer connection

3. **Connect nodes and apply layout**
   ```bash
   # After node2 is on k8s-3-4u and RPC is working:
   
   # Connect node2 to cluster (via API or fixed CLI)
   curl -X POST -H "Authorization: Bearer 2LY8t69M-KZ2NNNwyB" \
     -d '{"nodeId": "a70b...", "address": "..."}' \
     http://garage-s3:3903/v2/ConnectClusterNodes
   
   # Assign node2 to layout
   garage layout assign -z dc1 -c 14TB -t gateway,storage a70b...
   
   # Apply layout version 2 (starts rebalancing)
   garage layout apply --version 2
   ```

### 🟡 Medium Priority

4. **Monitor rebalancing**
   - Rebalancing will take 4-8 hours to copy 6TB from node1 → node2
   - During rebalancing, Garage remains fully operational
   - Monitor: `garage status` or API `/v2/GetClusterStatus`

5. **Verify replication**
   - After rebalancing: `garage status` should show both nodes with data
   - Test failover: stop node1 pod, verify S3 API still works via node2
   - Test PostgreSQL backups still work during failover

### 🟢 Future Enhancements (Phases 2-5)

6. **Phase 2: Garage → Backblaze B2 backup** (off-site DR)
7. **Phase 3: Media/downloads rsync** (k8s-4-dell → k8s-3-4u)
8. **Phase 4: Kopia → Garage S3 sync** (eliminate Kopia SPOF)
9. **Phase 5: Monitoring and restore testing**

---

## Important Notes

### Talos Disk Config Safety ✅

- Current `machine.disks` configs are SAFE
- No `provisioning:` sections (removed earlier)
- WWN IDs are stable across reboots
- **Confirmed:** Disks will NOT be reformatted on next Talos upgrade

### Garage Replication Behavior

- `replication_factor` in config is READ-ONLY after cluster init
- Cannot change from 1 → 2 by editing config file
- Must use layout commands to change replication
- Garage will reject config changes that don't match existing layout

### bjw-s App-Template Quirks

- Version 4.6.2 in use
- Affinity field location may differ from standard Kubernetes
- Check docs: https://bjw-s.github.io/helm-charts/docs/common-library/
- Fallback: Use `pod.nodeSelector` for simpler node selection

---

## Debugging Commands

### Check Pod Status
```bash
export KUBECONFIG=/path/to/kubeconfig
kubectl get pods -n default | grep garage
kubectl get pods -n default -o wide | grep garage  # shows node placement
```

### Check Garage Cluster Status (via API)
```bash
kubectl run curl-status --rm -i --image=curlimages/curl -- \
  curl -s -H "Authorization: Bearer 2LY8t69M-KZ2NNNwyB" \
  http://garage-s3.default.svc.cluster.local:3903/v2/GetClusterStatus
```

### Check Garage Logs
```bash
kubectl logs garage-s3-xxx -n default -c app --tail=50
kubectl logs garage-s3-node2-xxx -n default -c app --tail=50
```

### Check Storage Mounts (on k8s-3-4u)
```bash
kubectl debug node/k8s-3-4u -it --image=busybox -- \
  sh -c "ls -la /host/var/mnt/backup-garage && \
         df -h /host/var/mnt/backup-garage"
```

### Force ArgoCD Sync
```bash
kubectl patch application garage-s3-node2 -n argo-system \
  --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```

---

## Questions to Answer Next Session

1. **bjw-s app-template affinity syntax:**
   - Is `affinity:` at root level supported?
   - Should it be `controllers.garage-s3-node2.pod.affinity:`?
   - Or use `pod.nodeSelector` instead?

2. **Garage RPC connectivity:**
   - Do we need headless Service for StatefulSet-style DNS?
   - Can we use pod IPs directly in bootstrap_peers?
   - What's the recommended Garage multi-node deployment pattern?

3. **Replication strategy:**
   - After nodes are connected, what's the layout command syntax?
   - How long will 6TB rebalancing actually take?
   - Can we increase replication speed with config tweaks?

---

## Session Environment

- **Cluster:** Talos Kubernetes (home-ops)
- **Nodes:** k8s-3-4u, k8s-4-dell, k8s-5-1u
- **ArgoCD:** Running, auto-sync enabled
- **PostgreSQL:** CloudNativePG clusters (pgvector17, postgres17)
- **Storage:** Rook-Ceph (ceph-block), Garage S3, local hostPath
- **CNI:** Cilium
- **Gateway:** Gateway API (not Ingress)

---

## Success Criteria (Not Yet Met)

- [ ] garage-s3-node2 pod running on k8s-3-4u (not k8s-5-1u)
- [ ] Both nodes see each other in cluster (no DNS errors in logs)
- [ ] `garage status` shows 2 nodes healthy
- [ ] Layout version 2 applied with replication_factor=2
- [ ] Rebalancing in progress (6TB data copying)
- [ ] S3 API functional from both nodes
- [ ] PostgreSQL backups working during rebalancing

---

## Handoff Prompt for Next Session

**Use this prompt to continue:**

```
I'm continuing the Garage S3 multi-node deployment from June 11.

Context:
- We deployed garage-s3-node2 but it's running on the WRONG node (k8s-5-1u instead of k8s-3-4u)
- Node affinity rules in values.yaml weren't applied by bjw-s app-template v4.6.2
- Nodes can't communicate because node2 can't resolve DNS bootstrap_peers

Current status:
- garage-s3: 10.69.4.12 on k8s-5-1u ✅
- garage-s3-node2: 10.69.4.90 on k8s-5-1u ❌ (should be on k8s-3-4u)

Read the full context: docs/superpowers/handoff-2026-06-11-garage-multi-node.md

TASK: Fix garage-s3-node2 to deploy on k8s-3-4u by correcting the affinity/nodeSelector configuration in components/default/garage-s3-node2/values.yaml
```

---

**End of handoff document.**
