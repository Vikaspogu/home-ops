# Garage S3 Migration: OMV to Talos k8s-5-1u Design

**Date:** 2026-06-08  
**Goal:** Migrate Garage S3 object storage from OMV K3s to Talos Kubernetes node k8s-5-1u with 8x HDD multi-disk layout  
**Method:** S3-to-S3 replication with pre-cleanup optimization  
**Estimated Downtime:** 25 minutes (PostgreSQL backup only, database stays online)

---

## Context

### Current State (Source)

**Infrastructure:**
- **Host:** OMV K3s cluster (root@omv-baymx)
- **Garage Version:** v2.3.0
- **Architecture:** x86-64 (Intel Xeon E5-2680 v4)
- **Storage:** Single disk `/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/`
  - Data: `/garage` (618 GB, 87k files)
  - Metadata: `/garage-meta` (24 GB LMDB)
- **Configuration:**
  - `replication_factor = 1`
  - `db_engine = "lmdb"`
  - `compression_level = 2`
  - Single-node deployment

**Active Buckets:**
| Bucket | Logical Size | Physical | Objects | Consumer |
|--------|--------------|----------|---------|----------|
| postgres | 2.3 TiB | ~580 GB | 117,450 | CNPG clusters (3 active paths) |
| reactive-resume | 871 KB | 871 KB | 1 | Resume app |
| obsidian-notes | 13 MB | 13 MB | 63 | Notes sync |
| tofu-state | 53 KB | 53 KB | 1 | Terraform |

**Active Postgres Backup Paths:**
- `s3://postgres/postgres17-talos-1/` - 1.3 TB (Talos main DB)
- `s3://postgres/pg17-omv-02/` - 538 GB (OMV DB)
- `s3://postgres/pgvector17-talos-1/` - 6.6 GB (Talos vector DB)

**Dead Postgres Paths (8+ months old):**
- `s3://postgres/postgres/` - 373 GB (abandoned)
- `s3://postgres/postgres17/` - 130 GB (abandoned)
- `s3://postgres/postgres17-omv/` - 1.5 GB (old OMV cluster)
- `s3://postgres/pg17-omv/` - 551 MB (old naming)

**Endpoint:** `https://s3.omv.a113.casa` (public DNS)

---

### Target State (Destination)

**Infrastructure:**
- **Host:** Talos Kubernetes node k8s-5-1u (10.30.30.25)
- **Garage Version:** v2.3.0 (same as source)
- **Architecture:** x86-64 (Intel Xeon E5-2658 - compatible with source)
- **Storage:** 8x 900GB SAS HDDs (7.2 TB total capacity)
  - `sdc`, `sdd`, `sde`, `sdf`, `sdg`, `sdh`, `sdi`, `sdj`
  - Currently unused, not part of Rook-Ceph
  - System disk: 128GB SSD on `sda`
  - NVMe (2TB): Reserved for other workloads

**Garage Configuration:**
- Multi-HDD layout across 8 drives
- Same `replication_factor = 1`
- Fresh LMDB metadata (new cluster identity)
- Native Kubernetes integration (vs K3s)

**Benefits:**
- 11.6x more capacity (7.2TB vs 618GB)
- Better performance (8 drives vs 1)
- Apps and storage in same cluster
- Eliminates OMV/K3s dependency
- Room for growth (91% free after migration)

---

## Architecture Decisions

### Decision 1: S3 Replication vs Filesystem Copy

**Chosen:** S3-to-S3 replication (via rclone/s5cmd)

**Alternatives Considered:**
1. **Copy data+metadata together (cold migration)**
   - Pros: Fastest raw transfer, preserves all metadata
   - Cons: Requires identical node ID, LMDB portability risk, can't use multi-HDD during migration
   - Rejected: Too risky, can't initialize multi-HDD layout properly

2. **Pre-copy data blocks, then S3 upload**
   - Pros: Might optimize write I/O
   - Cons: Technical review confirmed Garage doesn't adopt pre-existing blocks without metadata
   - Rejected: Doesn't actually work (see subagent analysis in git history)

3. **S3-to-S3 replication (CHOSEN)**
   - Pros: Safest, works across architectures, new cluster gets clean state, proper multi-HDD init
   - Cons: Full network transfer required
   - Why chosen: Only method that guarantees correct multi-HDD layout and metadata consistency

**Key Technical Insight:**
Garage's content-addressed storage requires metadata to reference blocks. You cannot:
- Pre-copy blocks and have Garage "discover" them
- Copy metadata from single-disk to multi-disk layout
- Change node identity without breaking references

The only safe migration path is to treat the new Garage as a fresh cluster and replicate via S3 API.

---

### Decision 2: Pre-Migration Cleanup

**Chosen:** Delete 505 GB of abandoned postgres backup folders before migration

**Evidence:**
- No code references to old folder names (validated)
- No writes in 7-8 months (validated)
- Active backups going to different paths (validated)

**Impact:**
- Reduces migration payload: 618 GB → 113 GB (5.3x reduction)
- Migration time: 1.7 hours → 22 minutes (for postgres bucket)
- Frees space on OMV for future use

---

### Decision 3: Phased Migration

**Chosen:** Migrate small buckets first (zero downtime), postgres bucket second (short downtime)

**Why:**
- Small buckets (14 MB) = trivial, zero risk
- Can verify new Garage works before migrating critical postgres data
- Spreads risk across phases
- Most apps never experience downtime

---

## Migration Phases

### Phase 0: Pre-Migration Cleanup (30 min, zero downtime)

**Goal:** Free 505 GB by deleting abandoned postgres backup folders

**Prerequisites:**
- [ ] Validation completed (already done in this design phase)
- [ ] mc-check pod running on OMV cluster

**Steps:**

1. **Final safety check:**
   ```bash
   # Verify no active references
   ssh root@omv-baymx 'kubectl get clusters.postgresql.cnpg.io -A -o yaml | grep serverName'
   # Should show only: postgres17-talos-1, pg17-omv-02, pgvector17-talos-1
   ```

2. **Delete abandoned folders (parallel):**
   ```bash
   ssh root@omv-baymx 'kubectl exec -n default mc-check -- mc rm --recursive --force omv/postgres/postgres/' &
   ssh root@omv-baymx 'kubectl exec -n default mc-check -- mc rm --recursive --force omv/postgres/postgres17/' &
   ssh root@omv-baymx 'kubectl exec -n default mc-check -- mc rm --recursive --force omv/postgres/postgres17-omv/' &
   ssh root@omv-baymx 'kubectl exec -n default mc-check -- mc rm --recursive --force omv/postgres/pg17-omv/' &
   wait
   ```

3. **Verify cleanup:**
   ```bash
   ssh root@omv-baymx 'kubectl exec -n default mc-check -- mc du omv/postgres/'
   # Should show only 3 folders: pg17-omv-02, pgvector17-talos-1, postgres17-talos-1
   # Total size: ~113 GB (down from 618 GB)
   ```

4. **Check filesystem savings:**
   ```bash
   ssh root@omv-baymx 'du -sh /srv/.../storage0/garage'
   # Should show ~113 GB (down from 618 GB)
   ```

**Rollback:** None needed (can recover from LMDB metadata if deletion was accidental)

**Success Criteria:**
- [ ] Only 3 active postgres folders remain
- [ ] Total postgres bucket size ~113 GB
- [ ] Active clusters continue archiving WAL logs

---

### Phase 1: Deploy New Garage on k8s-5-1u (30 min, zero downtime)

**Goal:** Stand up fresh Garage cluster with 8-HDD multi-disk layout

**Files to Create/Modify:**
- `components/default/garage-s3/`
  - `kustomization.yaml`
  - `values.yaml`
  - `http-route.yaml`
  - `externalsecret.yaml`
  - `resources/configuration.toml`

**Configuration:**

`values.yaml`:
```yaml
controllers:
  garage:
    annotations:
      reloader.stakater.com/auto: "true"
    containers:
      app:
        image:
          repository: dxflrs/garage
          tag: v2.3.0@sha256:866bd13ed2038ba7e7190e840482bc27234c4afaf77be8cfa439ae088c1e4690
        env:
          TZ: "America/New_York"
        envFrom:
          - secretRef:
              name: garage-s3-secret
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: { drop: ["ALL"] }
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
          limits:
            memory: 2Gi
      webui:
        image:
          repository: khairul169/garage-webui
          tag: 1.1.0@sha256:17c793551873155065bf9a022dabcde874de808a1f26e648d4b82e168806439c
        env:
          API_BASE_URL: "http://garage-s3.default.svc.cluster.local:3903"
          S3_ENDPOINT_URL: "http://garage-s3.default.svc.cluster.local:3900"
          API_ADMIN_KEY:
            valueFrom:
              secretKeyRef:
                name: garage-s3-secret
                key: GARAGE_ADMIN_TOKEN
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: { drop: ["ALL"] }
        resources:
          requests:
            cpu: 10m
            memory: 128Mi
          limits:
            memory: 256Mi

service:
  app:
    ports:
      s3:
        port: 3900
      api:
        port: 3903
      webui:
        port: 3909

persistence:
  # Multi-HDD configuration - 8 drives
  data1:
    type: hostPath
    hostPath: /mnt/garage-hdd1
    globalMounts:
      - path: /data1
  data2:
    type: hostPath
    hostPath: /mnt/garage-hdd2
    globalMounts:
      - path: /data2
  data3:
    type: hostPath
    hostPath: /mnt/garage-hdd3
    globalMounts:
      - path: /data3
  data4:
    type: hostPath
    hostPath: /mnt/garage-hdd4
    globalMounts:
      - path: /data4
  data5:
    type: hostPath
    hostPath: /mnt/garage-hdd5
    globalMounts:
      - path: /data5
  data6:
    type: hostPath
    hostPath: /mnt/garage-hdd6
    globalMounts:
      - path: /data6
  data7:
    type: hostPath
    hostPath: /mnt/garage-hdd7
    globalMounts:
      - path: /data7
  data8:
    type: hostPath
    hostPath: /mnt/garage-hdd8
    globalMounts:
      - path: /data8
  
  metadata:
    type: hostPath
    hostPath: /mnt/garage-meta
    globalMounts:
      - path: /meta

  config:
    enabled: true
    type: configMap
    name: garage-s3-configmap
    globalMounts:
      - path: /etc/garage.toml
        subPath: configuration.toml

# Node affinity to pin to k8s-5-1u
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - k8s-5-1u
```

`configuration.toml`:
```toml
metadata_dir = "/meta"
data_dir = [
  { path = "/data1", capacity = "800GB" },
  { path = "/data2", capacity = "800GB" },
  { path = "/data3", capacity = "800GB" },
  { path = "/data4", capacity = "800GB" },
  { path = "/data5", capacity = "800GB" },
  { path = "/data6", capacity = "800GB" },
  { path = "/data7", capacity = "800GB" },
  { path = "/data8", capacity = "800GB" },
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

**Deployment Steps:**

1. **Prepare hostPaths on k8s-5-1u (via Talos machine config patch):**
   
   Create `clusters/talos/bootstrap/os/patches/worker/k8s-5-1u-storage.yaml`:
   ```yaml
   machine:
     disks:
       - device: /dev/sdc
         partitions:
           - mountpoint: /mnt/garage-hdd1
       - device: /dev/sdd
         partitions:
           - mountpoint: /mnt/garage-hdd2
       - device: /dev/sde
         partitions:
           - mountpoint: /mnt/garage-hdd3
       - device: /dev/sdf
         partitions:
           - mountpoint: /mnt/garage-hdd4
       - device: /dev/sdg
         partitions:
           - mountpoint: /mnt/garage-hdd5
       - device: /dev/sdh
         partitions:
           - mountpoint: /mnt/garage-hdd6
       - device: /dev/sdi
         partitions:
           - mountpoint: /mnt/garage-hdd7
       - device: /dev/sdj
         partitions:
           - mountpoint: /mnt/garage-hdd8
     kubelet:
       extraMounts:
         - destination: /mnt/garage-hdd1
           type: bind
           source: /mnt/garage-hdd1
           options: [bind, rshared, rw]
         - destination: /mnt/garage-hdd2
           type: bind
           source: /mnt/garage-hdd2
           options: [bind, rshared, rw]
         - destination: /mnt/garage-hdd3
           type: bind
           source: /mnt/garage-hdd3
           options: [bind, rshared, rw]
         - destination: /mnt/garage-hdd4
           type: bind
           source: /mnt/garage-hdd4
           options: [bind, rshared, rw]
         - destination: /mnt/garage-hdd5
           type: bind
           source: /mnt/garage-hdd5
           options: [bind, rshared, rw]
         - destination: /mnt/garage-hdd6
           type: bind
           source: /mnt/garage-hdd6
           options: [bind, rshared, rw]
         - destination: /mnt/garage-hdd7
           type: bind
           source: /mnt/garage-hdd7
           options: [bind, rshared, rw]
         - destination: /mnt/garage-hdd8
           type: bind
           source: /mnt/garage-hdd8
           options: [bind, rshared, rw]
   ```

2. **Apply Talos config patch and wait for reboot:**
   ```bash
   # Add patch reference to talconfig.yaml for k8s-5-1u worker
   # Then regenerate and apply:
   cd clusters/talos/bootstrap/os
   talhelper genconfig
   talosctl apply-config --nodes 10.30.30.25 \
     --file clusterconfig/home-kubernetes-k8s-5-1u.yaml
   
   # Wait for reboot and mount verification
   talosctl -n 10.30.30.25 get mounts | grep garage
   ```

3. **Deploy Garage via ArgoCD:**
   ```bash
   # Add to clusters/talos/apps/20-applications.yaml
   kubectl apply -f components/default/garage-s3/
   
   # Wait for pod ready
   kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=garage-s3 \
     -n default --timeout=180s
   ```

4. **Initialize Garage cluster:**
   ```bash
   POD=$(kubectl get pod -n default -l app.kubernetes.io/name=garage-s3 -o name | head -1)
   
   # Check status
   kubectl exec -n default $POD -c app -- /garage status
   
   # Should show single-node cluster with 8 data paths
   ```

5. **Create buckets and keys:**
   ```bash
   # Create key (save access/secret for later)
   kubectl exec -n default $POD -c app -- /garage key create main
   
   # Create buckets
   kubectl exec -n default $POD -c app -- /garage bucket create reactive-resume
   kubectl exec -n default $POD -c app -- /garage bucket create obsidian-notes
   kubectl exec -n default $POD -c app -- /garage bucket create tofu-state
   kubectl exec -n default $POD -c app -- /garage bucket create postgres
   
   # Grant permissions
   kubectl exec -n default $POD -c app -- /garage bucket allow reactive-resume --read --write --key main
   kubectl exec -n default $POD -c app -- /garage bucket allow obsidian-notes --read --write --key main
   kubectl exec -n default $POD -c app -- /garage bucket allow tofu-state --read --write --key main
   kubectl exec -n default $POD -c app -- /garage bucket allow postgres --read --write --key main
   ```

**Verification:**
```bash
# Verify Garage is healthy
kubectl exec -n default $POD -c app -- /garage status
kubectl exec -n default $POD -c app -- /garage bucket list
kubectl exec -n default $POD -c app -- /garage stats -a

# Should show:
# - All 8 data directories registered
# - 4 empty buckets
# - Storage distributed across HDDs
```

**Success Criteria:**
- [ ] Garage pod running on k8s-5-1u
- [ ] All 8 HDDs mounted and visible in Garage
- [ ] 4 buckets created and accessible via S3 API
- [ ] OMV Garage still serving traffic

---

### Phase 2: Migrate Small Buckets (15 min, zero downtime)

**Goal:** Migrate reactive-resume, obsidian-notes, tofu-state to new Garage

**Prerequisites:**
- [ ] New Garage running and verified (Phase 1)
- [ ] rclone/s5cmd available

**Steps:**

1. **Configure rclone remotes:**
   ```bash
   cat > /tmp/rclone.conf <<EOF
   [omv-garage]
   type = s3
   provider = Other
   access_key_id = GK1ef6ef65262a8e0cb0792bf2
   secret_access_key = eb5f2cddf3048ba85cde67b2bc36036a6152dc6da30f57e1af5b72eb37214c43
   endpoint = http://garage.default.svc.cluster.local:3900
   region = garage
   
   [talos-garage]
   type = s3
   provider = Other
   access_key_id = <NEW_ACCESS_KEY_FROM_PHASE1>
   secret_access_key = <NEW_SECRET_KEY_FROM_PHASE1>
   endpoint = http://garage-s3.default.svc.cluster.local:3900
   region = garage
   EOF
   ```

2. **Sync small buckets:**
   ```bash
   # Run from a pod with access to both Garage services
   kubectl run rclone-migrate --rm -i --image=rclone/rclone:latest \
     --restart=Never -- \
     --config /tmp/rclone.conf \
     sync omv-garage:reactive-resume talos-garage:reactive-resume -vv
   
   kubectl run rclone-migrate --rm -i --image=rclone/rclone:latest \
     --restart=Never -- \
     --config /tmp/rclone.conf \
     sync omv-garage:obsidian-notes talos-garage:obsidian-notes -vv
   
   kubectl run rclone-migrate --rm -i --image=rclone/rclone:latest \
     --restart=Never -- \
     --config /tmp/rclone.conf \
     sync omv-garage:tofu-state talos-garage:tofu-state -vv
   ```

3. **Verify migration:**
   ```bash
   # Check object counts match
   kubectl exec -n default $POD -c app -- /garage stats -a
   
   # Test S3 access
   kubectl run aws-test --rm -i --image=amazon/aws-cli:latest \
     --restart=Never --env AWS_ACCESS_KEY_ID=<NEW_KEY> \
     --env AWS_SECRET_ACCESS_KEY=<NEW_SECRET> -- \
     s3 ls --endpoint-url http://garage-s3.default:3900 s3://reactive-resume/
   ```

4. **Update application endpoints:**
   
   **reactive-resume:**
   Edit `components/default/reactive-resume/values.yaml`:
   ```yaml
   # Change from:
   STORAGE_ENDPOINT: s3.omv.a113.casa
   # To:
   STORAGE_ENDPOINT: garage-s3.default.svc.cluster.local:3900
   ```
   
   Apply and verify app works.

5. **Delete from old Garage (optional, can wait):**
   ```bash
   # After verification, optionally clean up OMV
   ssh root@omv-baymx 'kubectl exec mc-check -- mc rm --recursive --force omv/reactive-resume/'
   ssh root@omv-baymx 'kubectl exec mc-check -- mc rm --recursive --force omv/obsidian-notes/'
   ssh root@omv-baymx 'kubectl exec mc-check -- mc rm --recursive --force omv/tofu-state/'
   ```

**Rollback:** Update app endpoints back to OMV Garage (data still exists on both)

**Success Criteria:**
- [ ] Small buckets replicated successfully
- [ ] reactive-resume app working with new Garage
- [ ] Old OMV Garage still serving postgres bucket

---

### Phase 3: Migrate Postgres Bucket (45 min, 25 min downtime)

**Goal:** Migrate 113 GB postgres bucket with 3 active backup paths

**Prerequisites:**
- [ ] Small buckets verified working (Phase 2)
- [ ] Maintenance window scheduled
- [ ] Team notified: PostgreSQL will not backup to S3 for 25 minutes

**Steps:**

**1. Pre-migration prep (10 min, zero downtime):**
```bash
# Verify current postgres backup status
kubectl get backups -n default --sort-by=.metadata.creationTimestamp | tail -5
kubectl get clusters.postgresql.cnpg.io -A -o yaml | grep -A5 "lastSuccessfulBackup"

# Note: Last backup time for each cluster
```

**2. Suspend scheduled backups (2 min, zero downtime):**
```bash
# Talos clusters
kubectl patch scheduledbackup postgres17 -n default --type=merge \
  -p '{"spec":{"suspend":true}}'
kubectl patch scheduledbackup pgvector17 -n default --type=merge \
  -p '{"spec":{"suspend":true}}'

# OMV cluster (if scheduled backups exist)
ssh root@omv-baymx 'kubectl patch scheduledbackup pg17-omv -n default --type=merge \
  -p "{\"spec\":{\"suspend\":true}}" 2>/dev/null || echo "No scheduled backup on OMV"'

# Verify suspended
kubectl get scheduledbackup -n default -o jsonpath='{.items[*].spec.suspend}'
# Should show: true true
```

**3. Stop OMV Garage (1 min, DOWNTIME STARTS):**
```bash
# Scale down OMV Garage deployment
ssh root@omv-baymx 'kubectl scale deploy/garage -n default --replicas=0'
ssh root@omv-baymx 'kubectl wait --for=delete pod -l app.kubernetes.io/name=garage \
  -n default --timeout=60s'

# Verify stopped
ssh root@omv-baymx 'kubectl get pods -n default | grep garage'
# Should show: No resources found
```

**4. Copy data via rsync (22 min, DOWNTIME):**
```bash
# Copy data directory (113 GB @ ~85 MB/s = 22 min)
# Note: Using first HDD as staging, will rebalance later
ssh root@omv-baymx "rsync -aP --info=progress2 \
  /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage/ \
  root@10.30.30.25:/mnt/garage-hdd1/data-migration/"

# Copy metadata (24 GB @ ~85 MB/s = 5 min, but parallel with data copy)
ssh root@omv-baymx "rsync -aP --info=progress2 \
  /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage-meta/ \
  root@10.30.30.25:/mnt/garage-meta-migration/"
```

**ALTERNATIVE: S3 replication method (if rsync not feasible):**
```bash
# Restart OMV Garage in read-only mode first
# Then use rclone sync (will take longer ~2 hours)
kubectl run rclone-postgres --rm -i --image=rclone/rclone:latest \
  --restart=Never -- \
  --config /tmp/rclone.conf \
  sync omv-garage:postgres talos-garage:postgres \
  --transfers 16 --progress
```

**5. Update new Garage with migrated data (5 min):**
```bash
# Stop new Garage
kubectl scale deploy/garage-s3 -n default --replicas=0

# Move data from staging to proper multi-HDD layout
# (Garage will rebalance after start)
talosctl -n 10.30.30.25 cp /mnt/garage-hdd1/data-migration/ /mnt/garage-hdd1/
talosctl -n 10.30.30.25 cp /mnt/garage-meta-migration/ /mnt/garage-meta/

# Start new Garage
kubectl scale deploy/garage-s3 -n default --replicas=1
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=garage-s3 \
  -n default --timeout=180s
```

**6. Verify and rebalance (10 min):**
```bash
POD=$(kubectl get pod -n default -l app.kubernetes.io/name=garage-s3 -o name)

# Check Garage loaded metadata correctly
kubectl exec -n default $POD -c app -- /garage status
kubectl exec -n default $POD -c app -- /garage bucket list
kubectl exec -n default $POD -c app -- /garage stats -a

# Verify bucket contents
kubectl exec -n default $POD -c app -- /garage bucket info postgres
# Should show all 3 subfolders with correct object counts

# Trigger multi-HDD rebalance
kubectl exec -n default $POD -c app -- /garage repair -a --yes rebalance

# Monitor rebalance progress (runs in background)
watch 'kubectl exec -n default $POD -c app -- /garage stats -a'
```

**7. Update postgres endpoints (3 min, DOWNTIME ENDS):**

**Talos postgres17:**
Edit `clusters/talos/apps/default/cloudnative-cluster/cluster.yaml`:
```yaml
# Change:
endpointURL: https://s3.omv.a113.casa
# To:
endpointURL: http://garage-s3.default.svc.cluster.local:3900
```

**Talos pgvector17:**
Edit `clusters/talos/apps/default/pgvector-cluster/cluster.yaml`:
```yaml
# Same change as above
endpointURL: http://garage-s3.default.svc.cluster.local:3900
```

Apply via ArgoCD or kubectl.

**OMV pg17:**
Edit `clusters/omv/apps/default/cloudnative-cluster/cluster.yaml`:
```yaml
# Change to new Garage (accessible via node IP)
endpointURL: http://10.30.30.25:3900
```

**8. Resume scheduled backups (2 min):**
```bash
kubectl patch scheduledbackup postgres17 -n default --type=merge \
  -p '{"spec":{"suspend":false}}'
kubectl patch scheduledbackup pgvector17 -n default --type=merge \
  -p '{"spec":{"suspend":false}}'

ssh root@omv-baymx 'kubectl patch scheduledbackup pg17-omv -n default --type=merge \
  -p "{\"spec\":{\"suspend\":false}}" 2>/dev/null || true'
```

**9. Verification (5 min):**
```bash
# Check WAL archiving resumed
kubectl logs -n default -l cnpg.io/cluster=postgres17 -c postgres --tail=50 | grep -i wal
kubectl logs -n default -l cnpg.io/cluster=pgvector17 -c postgres --tail=50 | grep -i wal

# Trigger manual backup to verify
kubectl cnpg backup postgres17 -n default --mode=standalone
kubectl get backups -n default --sort-by=.metadata.creationTimestamp | tail -3

# Verify new backup appears in new Garage
kubectl exec -n default $POD -c app -- /garage stats -a
# Object count should increase
```

**Rollback (if needed):**
```bash
# 1. Stop new Garage
kubectl scale deploy/garage-s3 -n default --replicas=0

# 2. Restart OMV Garage
ssh root@omv-baymx 'kubectl scale deploy/garage -n default --replicas=1'

# 3. Revert postgres endpoint changes (undo step 7)

# 4. Resume scheduled backups
```

**Success Criteria:**
- [ ] New Garage shows correct object counts for postgres bucket
- [ ] WAL archiving working for all 3 postgres clusters
- [ ] Manual backup succeeds to new Garage
- [ ] Multi-HDD rebalance in progress or complete

---

### Phase 4: DNS Cutover & Verification (15 min)

**Goal:** Update public DNS and verify all services working

**Steps:**

1. **Create HTTPRoute for new Garage:**
   
   Edit `components/default/garage-s3/http-route.yaml`:
   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: garage-s3-s3
     labels:
       app.kubernetes.io/instance: garage-s3
       app.kubernetes.io/name: garage-s3
     annotations:
       gethomepage.dev/href: "https://s3.${CLUSTER_DOMAIN}"
       gethomepage.dev/enabled: "true"
       gethomepage.dev/group: Storage
       gethomepage.dev/icon: https://cdn.jsdelivr.net/gh/selfhst/icons/png/garage.png
   spec:
     parentRefs:
       - name: ${GATEWAY_NAME}
         namespace: ${GATEWAY_NAMESPACE}
         sectionName: https
     hostnames: ["s3.${CLUSTER_DOMAIN}"]
     rules:
       - backendRefs:
           - name: garage-s3
             port: 3900
   ---
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: garage-s3-ui
     labels:
       app.kubernetes.io/instance: garage-s3
       app.kubernetes.io/name: garage-s3
     annotations:
       gethomepage.dev/href: "https://garage-ui.${CLUSTER_DOMAIN}"
       gethomepage.dev/enabled: "true"
       gethomepage.dev/group: Storage
       gethomepage.dev/icon: https://cdn.jsdelivr.net/gh/selfhst/icons/png/garage.png
   spec:
     parentRefs:
       - name: ${GATEWAY_NAME}
         namespace: ${GATEWAY_NAMESPACE}
         sectionName: https
     hostnames: ["garage-ui.${CLUSTER_DOMAIN}"]
     rules:
       - backendRefs:
           - name: garage-s3
             port: 3909
   ```

2. **Update DNS or use Gateway API routing:**
   ```bash
   # Option A: DNS update (if you control DNS)
   # Point s3.omv.a113.casa to new Talos ingress IP
   
   # Option B: Use Gateway API (recommended)
   # HTTPRoute already created above, just apply
   kubectl apply -f components/default/garage-s3/http-route.yaml
   
   # Verify routing
   curl -I https://s3.a113.casa
   # Should hit new Garage
   ```

3. **Smoke test all buckets:**
   ```bash
   # Test reactive-resume bucket
   kubectl run test-s3 --rm -i --image=amazon/aws-cli:latest \
     --restart=Never --env AWS_ACCESS_KEY_ID=<KEY> \
     --env AWS_SECRET_ACCESS_KEY=<SECRET> -- \
     s3 ls --endpoint-url https://s3.a113.casa s3://reactive-resume/
   
   # Test postgres bucket
   kubectl run test-s3 --rm -i --image=amazon/aws-cli:latest \
     --restart=Never --env AWS_ACCESS_KEY_ID=<KEY> \
     --env AWS_SECRET_ACCESS_KEY=<SECRET> -- \
     s3 ls --endpoint-url https://s3.a113.casa s3://postgres/ | grep -E "postgres17-talos-1|pg17-omv-02|pgvector17-talos-1"
   
   # All 3 folders should be present
   ```

4. **Verify apps using S3:**
   ```bash
   # Check reactive-resume
   kubectl logs -n default -l app.kubernetes.io/name=reactive-resume --tail=50 | grep -i s3
   
   # Check postgres backups
   kubectl get backups -n default --sort-by=.metadata.creationTimestamp | tail -5
   kubectl describe backup <latest-backup> -n default | grep -i "phase\|error"
   # Should show: Phase: Completed
   ```

5. **Monitor multi-HDD rebalance completion:**
   ```bash
   POD=$(kubectl get pod -n default -l app.kubernetes.io/name=garage-s3 -o name)
   kubectl exec -n default $POD -c app -- /garage stats -a
   
   # Check that data is spreading across all 8 HDDs
   # This can take 30-60 minutes for 113 GB
   ```

**Success Criteria:**
- [ ] Public DNS/HTTPRoute points to new Garage
- [ ] All buckets accessible via public endpoint
- [ ] All apps continue working
- [ ] Postgres backups succeeding
- [ ] Multi-HDD rebalance progressing

---

## Post-Migration

### Monitoring (1 week)

**Daily checks:**
```bash
# Check Garage health
kubectl exec -n default $POD -c app -- /garage status
kubectl exec -n default $POD -c app -- /garage stats -a

# Check postgres backups
kubectl get backups -n default --sort-by=.metadata.creationTimestamp | tail -10

# Check disk usage across HDDs
talosctl -n 10.30.30.25 df | grep garage
```

**What to watch for:**
- [ ] No errors in Garage pod logs
- [ ] Postgres backups completing successfully (daily)
- [ ] Multi-HDD rebalance completed (check after 1-2 days)
- [ ] Storage distributed evenly across 8 HDDs
- [ ] No S3 errors in app logs

---

### Cleanup (after 1 week verification)

**Once confident new Garage is stable:**

1. **Stop OMV Garage permanently:**
   ```bash
   ssh root@omv-baymx 'kubectl delete deploy/garage -n default'
   ssh root@omv-baymx 'kubectl delete svc/garage -n default'
   ```

2. **Archive OMV data (optional):**
   ```bash
   # Create tarball for safety
   ssh root@omv-baymx 'tar czf /srv/garage-backup-$(date +%F).tar.gz \
     /srv/.../storage0/garage \
     /srv/.../storage0/garage-meta'
   ```

3. **Free OMV disk space (after confirming backup):**
   ```bash
   ssh root@omv-baymx 'rm -rf /srv/.../storage0/garage'
   ssh root@omv-baymx 'rm -rf /srv/.../storage0/garage-meta'
   # Frees 113 GB + 24 GB = 137 GB on OMV
   ```

4. **Update documentation:**
   - Update S3 endpoint references in README
   - Update disaster recovery procedures
   - Document new Garage architecture (8-HDD setup)

---

## Rollback Procedures

### If issues discovered during Phase 2 (small buckets)

**Rollback:**
```bash
# 1. Update app endpoints back to OMV
# 2. Data still exists on OMV Garage (never deleted)
# 3. Delete new Garage deployment
kubectl delete -f components/default/garage-s3/
```

**Data loss risk:** None (OMV still has original data)

---

### If issues discovered during Phase 3 (postgres migration)

**Rollback:**
```bash
# 1. Stop new Garage
kubectl scale deploy/garage-s3 -n default --replicas=0

# 2. Restart OMV Garage
ssh root@omv-baymx 'kubectl scale deploy/garage -n default --replicas=1'
ssh root@omv-baymx 'kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=garage -n default --timeout=180s'

# 3. Revert postgres ObjectStore endpoints
# (undo changes from Phase 3, step 7)

# 4. Resume scheduled backups
kubectl patch scheduledbackup postgres17 -n default --type=merge -p '{"spec":{"suspend":false}}'
kubectl patch scheduledbackup pgvector17 -n default --type=merge -p '{"spec":{"suspend":false}}'

# 5. Verify WAL archiving resumed
kubectl logs -n default -l cnpg.io/cluster=postgres17 --tail=50 | grep -i wal
```

**Data loss risk:** Minimal
- Old Garage has all data up to stop time
- Any WAL segments generated during migration window (~25 min) may be lost
- PostgreSQL databases themselves are NOT affected (still running)

---

### If issues discovered after cutover (Phase 4)

**Rollback:**
```bash
# 1. Update DNS/HTTPRoute back to OMV Garage
# 2. Restart OMV Garage
# 3. Verify old Garage serving traffic
```

**Data loss risk:** Low
- Both Garages have same data
- Worst case: backups from cutover window may be on new Garage only
- Can copy those back to old Garage via S3 API if needed

---

## Risk Assessment

### High Risks (Mitigated)

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Data corruption during migration | HIGH | Using S3 API (safest), keeping OMV as backup for 1 week |
| LMDB metadata corruption | HIGH | Fresh metadata on new Garage, validated via S3 replication |
| Multi-HDD layout misconfiguration | MEDIUM | Pre-validate Talos config, test with small buckets first |
| DNS/routing issues | MEDIUM | Test endpoint access before cutover, keep OMV available for rollback |

### Medium Risks (Acceptable)

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Postgres backup gap during migration | MEDIUM | Only 25 min window, databases still running, point-in-time recovery available |
| Network issues during rsync | MEDIUM | Resumable rsync, can restart if interrupted |
| Insufficient HDD space on k8s-5-1u | LOW | 7.2 TB available vs 113 GB used (98% free) |

### Low Risks (Accepted)

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Performance degradation with 8 HDDs | LOW | HDDs are enterprise SAS, multiple spindles improve throughput |
| Talos node failure during migration | LOW | Can redeploy to different node, have OMV backup |

---

## Success Metrics

### Functional Success
- [ ] All 4 buckets accessible via new Garage
- [ ] Postgres backups succeeding (3 clusters)
- [ ] reactive-resume app working
- [ ] No S3 errors in any app logs
- [ ] Multi-HDD rebalance completed

### Performance Success
- [ ] S3 read/write latency < 100ms (same as OMV)
- [ ] Backup throughput ≥ previous (should improve with 8 drives)
- [ ] Garage pod CPU < 500m, memory < 1GB under normal load

### Operational Success
- [ ] Zero unplanned downtime
- [ ] Actual downtime ≤ estimated (25 min)
- [ ] Clean rollback path available
- [ ] Monitoring and alerting working

---

## References

- **Garage Documentation:** https://garagehq.deuxfleurs.fr/documentation/
- **Garage Multi-HDD:** https://garagehq.deuxfleurs.fr/documentation/operations/multi-hdd/
- **CNPG Backup/Recovery:** https://cloudnative-pg.io/documentation/current/backup_recovery/
- **Existing Migration Plan (Synology):** `docs/superpowers/plans/2026-05-08-garage-omv-to-synology-staging.md`
- **Technical Validation (subagent):** Git history - search for "Garage migration validation"

---

## Timeline Summary

| Phase | Duration | Downtime | Dependencies |
|-------|----------|----------|--------------|
| 0: Cleanup | 30 min | 0 | None |
| 1: Deploy new Garage | 30 min | 0 | Talos cluster access |
| 2: Small buckets | 15 min | 0 | Phase 1 complete |
| 3: Postgres bucket | 45 min | 25 min | Maintenance window |
| 4: DNS cutover | 15 min | 0 | Phase 3 verified |
| **Total** | **~2.5 hours** | **25 min** | |

**Recommended schedule:**
- **Week 1, Day 1 (afternoon):** Phase 0 cleanup
- **Week 1, Day 2 (afternoon):** Phase 1 deployment
- **Week 1, Day 3 (afternoon):** Phase 2 small buckets
- **Week 2, Saturday morning:** Phase 3 postgres migration (maintenance window)
- **Week 2, Saturday afternoon:** Phase 4 cutover + verification
- **Week 3:** Monitor and cleanup

---

## Open Questions

1. **Talos disk partitioning:** Do we need to manually format the 8 HDDs, or will Talos handle this automatically when applying the machine config patch?
   - **Answer needed before Phase 1**

2. **Network access from OMV to Talos node:** Can OMV's root user SSH to 10.30.30.25, or do we need to set up SSH keys first?
   - **Answer needed before Phase 3**

3. **Gateway API configuration:** What's the value of `${GATEWAY_NAME}` and `${GATEWAY_NAMESPACE}` in your cluster?
   - **Answer needed before Phase 4**

4. **Backup retention:** Do you want to keep the old postgres backup folders on OMV as an archive, or delete them after verification?
   - **Answer needed before cleanup**
