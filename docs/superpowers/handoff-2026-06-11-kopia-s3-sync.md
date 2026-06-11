# Handoff: Kopia Repository Sync to Garage S3

**Date:** June 11, 2026  
**Status:** Research complete, ready for implementation  
**Goal:** Eliminate Kopia repository Single Point of Failure by syncing to Garage S3

---

## Context

### Current State
- ✅ **Garage S3 multi-node cluster operational** (completed earlier today)
  - Node1: k8s-5-1u (5.8 TiB capacity)
  - Node2: k8s-3-4u (12.7 TiB capacity)
  - Layout version 2 applied, rebalancing in progress
  - Both nodes healthy and auto-reconnecting
- ✅ **Kopia repository running** in `volsync-system` namespace
  - Backend: `filesystem:///repository` (currently NFS, migrating to hostPath)
  - Size: ~68 GB
  - Version: 0.23.0
  - Used by VolSync for all PVC backups

### Problem
**Single Point of Failure:** If Kopia repository storage fails, all backup data is lost. This defeats the purpose of having backups.

### Solution
Use **Kopia's native `repository sync-to s3`** command to replicate the repository to Garage S3 for disaster recovery.

---

## Research Summary

### Why Kopia Native `sync-to`?

Kopia v0.6.0+ includes built-in repository replication specifically designed for this use case:
- ✅ **Official solution** - documented in Kopia docs
- ✅ **Repository-aware** - understands Kopia's internal blob structure
- ✅ **Incremental syncs** - only copies changed/new blobs (not full 68 GB each time)
- ✅ **Safe for live repositories** - no consistency issues
- ✅ **Resumable** - can recover from interrupted syncs
- ✅ **No additional tools** - uses existing Kopia binary

### Alternatives Considered (and rejected)

1. **Rclone filesystem sync:** Works but not repository-aware, potential consistency issues
2. **Restic backup of Kopia repo:** Double encryption/deduplication overhead, overkill
3. **Dual backend Kopia:** Not supported - Kopia uses single backend only

### Official Documentation
From `https://kopia.io/docs/advanced/synchronization/`:
> "Maintaining multiple copies of a repository is important for disaster recovery scenarios. Kopia v0.6.0 adds support for automatic repository replication."

---

## Implementation Plan

### Phase 1: Prepare Garage S3 (30 minutes)

1. **Create S3 bucket in Garage:**
   ```bash
   # Get access to garage-s3 pod
   export KUBECONFIG=/path/to/kubeconfig
   POD=$(kubectl get pod -n default -l app.kubernetes.io/instance=garage-s3 -o name | head -1)
   
   # Create bucket (via API or Web UI)
   kubectl exec -n default $POD -c app -- /garage bucket create kopia-backup
   
   # Create access key for Kopia
   kubectl exec -n default $POD -c app -- /garage key create kopia-backup-key
   
   # Grant permissions
   kubectl exec -n default $POD -c app -- /garage bucket allow \
     --read --write kopia-backup --key kopia-backup-key
   ```

2. **Store credentials in 1Password:**
   - Create new item: `kopia-s3-backup`
   - Add fields:
     - `AWS_ACCESS_KEY_ID`: (from Garage key create output)
     - `AWS_SECRET_ACCESS_KEY`: (from Garage key create output)
     - `S3_ENDPOINT`: `s3.${CLUSTER_DOMAIN}` (will be substituted by ArgoCD)
     - `S3_BUCKET`: `kopia-backup`

### Phase 2: Create Kubernetes Resources (1 hour)

**File 1:** `/components/volsync-system/kopia/sync-s3-external-secret.yaml`
```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: kopia-s3
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: kopia-s3-secret
    template:
      engineVersion: v2
      data:
        AWS_ACCESS_KEY_ID: "{{ .AWS_ACCESS_KEY_ID }}"
        AWS_SECRET_ACCESS_KEY: "{{ .AWS_SECRET_ACCESS_KEY }}"
        S3_ENDPOINT: "{{ .S3_ENDPOINT }}"
        S3_BUCKET: "{{ .S3_BUCKET }}"
  dataFrom:
    - extract:
        key: kopia-s3-backup
```

**File 2:** `/components/volsync-system/kopia/sync-to-s3-cronjob.yaml`
```yaml
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kopia-sync-to-s3
  namespace: volsync-system
  labels:
    app.kubernetes.io/name: kopia
    app.kubernetes.io/component: sync
spec:
  schedule: "0 3 * * *"  # Daily at 3 AM
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
            fsGroupChangePolicy: "OnRootMismatch"
            supplementalGroups:
              - 100
          containers:
            - name: sync-to-s3
              image: ghcr.io/home-operations/kopia:0.23.0@sha256:76865b421548b1d7bb26a8268f0f0bc828be4eec3f8d8b9c8ece991c99878f94
              command:
                - sh
                - -c
                - |
                  set -e
                  echo "Starting Kopia repository sync to S3 at $(date)"
                  
                  # Prepare Kopia config
                  mkdir -p /tmp/kopia/cache /tmp/kopia/logs
                  cp /config-ro/repository.config /tmp/kopia/repository.config
                  
                  # Sync repository to S3
                  kopia --config-file=/tmp/kopia/repository.config repository sync-to s3 \
                    --bucket="${S3_BUCKET}" \
                    --endpoint="${S3_ENDPOINT}" \
                    --access-key="${AWS_ACCESS_KEY_ID}" \
                    --secret-access-key="${AWS_SECRET_ACCESS_KEY}" \
                    --delete \
                    --no-progress
                  
                  echo "Sync completed successfully at $(date)"
              env:
                - name: KOPIA_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: kopia-secret
                      key: KOPIA_PASSWORD
                - name: AWS_ACCESS_KEY_ID
                  valueFrom:
                    secretKeyRef:
                      name: kopia-s3-secret
                      key: AWS_ACCESS_KEY_ID
                - name: AWS_SECRET_ACCESS_KEY
                  valueFrom:
                    secretKeyRef:
                      name: kopia-s3-secret
                      key: AWS_SECRET_ACCESS_KEY
                - name: S3_ENDPOINT
                  valueFrom:
                    secretKeyRef:
                      name: kopia-s3-secret
                      key: S3_ENDPOINT
                - name: S3_BUCKET
                  valueFrom:
                    secretKeyRef:
                      name: kopia-s3-secret
                      key: S3_BUCKET
                - name: KOPIA_CACHE_DIRECTORY
                  value: /tmp/kopia/cache
                - name: KOPIA_LOG_DIR
                  value: /tmp/kopia/logs
                - name: TZ
                  value: "America/New_York"
              resources:
                requests:
                  cpu: 100m
                  memory: 512Mi
                limits:
                  memory: 2Gi
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              volumeMounts:
                - name: config-ro
                  mountPath: /config-ro
                  readOnly: true
                - name: repository
                  mountPath: /repository
                  readOnly: true
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: config-ro
              configMap:
                name: kopia-repository-configmap
            - name: repository
              # NOTE: This volume mount will match the main kopia deployment
              # Currently NFS, will be hostPath after migration
              nfs:
                server: omv-baymx.a113.internal
                path: /storage0/VolsyncKopia
            - name: tmp
              emptyDir:
                sizeLimit: 4Gi
```

**File 3:** Update `/components/volsync-system/kopia/kustomization.yaml`
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: volsync-system
resources:
  - ./externalsecret.yaml
  - ./sync-s3-external-secret.yaml  # ADD THIS
  - ./http-route.yaml
  - ./maintenance-cronjob.yaml
  - ./sync-to-s3-cronjob.yaml  # ADD THIS
configMapGenerator:
  - name: kopia-repository-configmap
    files:
      - repository.config=./resources/repository.config
generatorOptions:
  disableNameSuffixHash: true
helmCharts:
  - name: app-template
    releaseName: kopia
    namespace: volsync-system
    repo: oci://ghcr.io/bjw-s-labs/helm
    version: "4.6.2"
    valuesFile: values.yaml
```

### Phase 3: Deploy and Test (30 minutes)

1. **Commit and push:**
   ```bash
   git add components/volsync-system/kopia/
   git commit -m "(feat): add Kopia repository sync to Garage S3

   - Create ExternalSecret for S3 credentials
   - Add daily CronJob to sync repository to S3
   - Uses Kopia native sync-to command for incremental sync
   - Eliminates Kopia SPOF with off-node backup"
   git push
   ```

2. **Wait for ArgoCD sync** (or force it)

3. **Verify ExternalSecret created:**
   ```bash
   kubectl get externalsecret kopia-s3 -n volsync-system
   kubectl get secret kopia-s3-secret -n volsync-system
   ```

4. **Test sync manually (don't wait for cron):**
   ```bash
   kubectl create job --from=cronjob/kopia-sync-to-s3 test-sync-001 -n volsync-system
   kubectl logs -f job/test-sync-001 -n volsync-system
   ```

5. **Verify sync succeeded:**
   ```bash
   # Check job status
   kubectl get job test-sync-001 -n volsync-system
   
   # Verify blobs in S3 bucket via Garage
   POD=$(kubectl get pod -n default -l app.kubernetes.io/instance=garage-s3 -o name | head -1)
   kubectl exec -n default $POD -c app -- /garage bucket info kopia-backup
   ```

### Phase 4: Validate Recovery (1 hour)

**CRITICAL:** Test that you can actually recover from the S3 copy!

1. **Connect to S3 repository (read-only):**
   ```bash
   # From a test pod or local machine
   kopia repository connect s3 \
     --bucket=kopia-backup \
     --endpoint=s3.${CLUSTER_DOMAIN} \
     --access-key="${AWS_ACCESS_KEY_ID}" \
     --secret-access-key="${AWS_SECRET_ACCESS_KEY}" \
     --password="${KOPIA_PASSWORD}" \
     --readonly
   ```

2. **List snapshots from S3:**
   ```bash
   kopia snapshot list
   ```

3. **Verify snapshot count matches source repository**

4. **Test restoring a small snapshot** (in test environment)

5. **Document recovery procedure** for disaster scenarios

---

## Operational Details

### Sync Schedule
- **Frequency:** Daily at 3 AM
- **Duration:** First sync ~68 GB (depends on network), subsequent syncs only deltas (typically <1 GB)
- **Concurrency:** `Forbid` - only one sync job at a time
- **Retention:** Keep last 1 successful job, last 3 failed jobs

### Key Flags Explained
- `--delete`: Remove blobs from S3 that were deleted from source (keeps repos in sync after compaction)
- `--no-progress`: Clean output suitable for cron logs (no progress bars)
- `--endpoint`: Garage S3 endpoint
- `--bucket`: Target S3 bucket name

### Monitoring
- **CronJob status:** `kubectl get cronjob kopia-sync-to-s3 -n volsync-system`
- **Recent jobs:** `kubectl get jobs -n volsync-system -l job-name=kopia-sync-to-s3`
- **Logs:** `kubectl logs -l job-name=kopia-sync-to-s3-<hash> -n volsync-system`
- **Add alerting:** Create PrometheusRule for failed CronJobs (future enhancement)

### Storage Impact
- **Garage S3 usage:** ~68 GB initially, grows with repository
- **Network bandwidth:** Minimal after first sync (only incremental changes)
- **Repository overhead:** None (sync reads repository, doesn't modify it)

---

## Important Notes

### Repository Volume Mount
**IMPORTANT:** The CronJob needs access to the same `/repository` volume as the main Kopia deployment.

**Current state:** Repository is on NFS (`omv-baymx:/storage0/VolsyncKopia`)

**After migration:** When repository moves to hostPath per the other handoff doc, update the CronJob volume mount:
```yaml
volumes:
  - name: repository
    hostPath:
      path: /var/mnt/kopia  # New location on k8s-4-dell
      type: Directory
```

And add node affinity to pin CronJob to the same node:
```yaml
spec:
  jobTemplate:
    spec:
      template:
        spec:
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                      - key: kubernetes.io/hostname
                        operator: In
                        values:
                          - k8s-4-dell
```

### Garage S3 Compatibility
Kopia's S3 implementation should work with Garage (S3-compatible). If you encounter issues:
1. Try adding `--region=garage` flag
2. Try `--disable-tls --force-path-style` if TLS issues
3. Fallback: Use rclone if Kopia S3 doesn't work (unlikely)

### Recovery Scenarios

**Scenario 1: Primary repository corrupted**
1. Stop all VolSync operations
2. Connect to S3 repository: `kopia repository connect s3 ...`
3. Verify snapshots intact: `kopia snapshot list`
4. Either:
   - A) Use S3 as new primary (update repository.config)
   - B) Sync S3 back to new local filesystem: `kopia repository sync-to filesystem`

**Scenario 2: Node failure (after hostPath migration)**
1. Repository data lost on k8s-4-dell
2. Provision new node or use ex-OMV node
3. Sync from S3: `kopia repository sync-to filesystem --path=/var/mnt/kopia`
4. Update Kopia deployment to point to new location

---

## Success Criteria

- [x] Research completed (Kopia native sync-to is the solution)
- [ ] Garage S3 bucket `kopia-backup` created
- [ ] S3 credentials stored in 1Password
- [ ] ExternalSecret created and synced
- [ ] CronJob created and deployed
- [ ] Manual test sync completed successfully
- [ ] Blobs visible in Garage S3 bucket
- [ ] Recovery test completed (can connect to S3 repo and list snapshots)
- [ ] Documentation updated with recovery procedures

---

## Next Steps (Priority Order)

1. **Create Garage S3 bucket** and access key (Phase 1)
2. **Store credentials** in 1Password (Phase 1)
3. **Create Kubernetes resources** per Phase 2 above
4. **Deploy and test** per Phase 3
5. **Validate recovery** per Phase 4 (CRITICAL - don't skip!)
6. **After Kopia hostPath migration:** Update CronJob volume mount and node affinity
7. **Future enhancement:** Add Prometheus alerting for failed sync jobs

---

## Related Work

- **Garage S3 multi-node cluster:** Completed today (June 11, 2026)
  - Handoff: `docs/superpowers/handoff-2026-06-11-garage-multi-node.md`
  - Status: ✅ Operational with 2-node redundancy
- **Kopia → hostPath migration:** Separate effort
  - Handoff: `docs/superpowers/handoff-2026-06-09-kopia-media-omv-decommission.md`
  - Status: Design approved, implementation pending
  - **Coordination needed:** Update sync CronJob after migration completes

---

## Troubleshooting

### Sync job fails with "access denied"
- Check S3 credentials in secret
- Verify bucket permissions in Garage: `garage bucket info kopia-backup`

### Sync job fails with "connection refused"
- Verify Garage S3 endpoint is correct
- Check network connectivity from volsync-system namespace to Garage pods
- Try adding `--region=garage` flag

### "Invalid signature" errors
- Garage S3 might have signature version issues
- Try adding `--force-path-style` flag

### First sync takes too long / times out
- Initial 68 GB sync may take hours depending on network
- Increase job `activeDeadlineSeconds` if needed
- Consider running first sync interactively to monitor progress

### How to verify sync is working?
```bash
# Check blob count in S3 matches source
kopia blob list --storage=s3 --bucket=kopia-backup ... | wc -l
kopia blob list | wc -l  # Should match (or be close)
```

---

## References

- **Kopia Documentation:** https://kopia.io/docs/advanced/synchronization/
- **Kopia Repository Sync Command:** `kopia repository sync-to --help`
- **Garage S3 Documentation:** https://garagehq.deuxfleurs.fr/documentation/connect/cli/
- **Research Task Output:** (see task results above)

---

**Handoff created:** 2026-06-11 17:40 UTC  
**Next session prompt:**

```
Continue Kopia → Garage S3 sync implementation from June 11 handoff.

Context:
- Research complete: Use Kopia native 'repository sync-to s3'
- Garage S3 multi-node cluster is operational
- Ready to implement Phase 1: Create S3 bucket and credentials

Read: docs/superpowers/handoff-2026-06-11-kopia-s3-sync.md

TASK: Start with Phase 1 - create Garage S3 bucket 'kopia-backup' and access key
```

---

**End of handoff document.**
