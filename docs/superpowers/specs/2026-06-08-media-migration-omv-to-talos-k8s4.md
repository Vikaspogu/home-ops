# Media Migration: OMV K3s to Talos k8s-4-dell

**Date:** 2026-06-08  
**Goal:** Migrate media storage from OMV single-node K3s to Talos multi-node cluster for improved HA  
**Method:** Local storage on k8s-4-dell + NFS export for cluster-wide access  
**Estimated Downtime:** 30 minutes (media apps only, during final cutover)

---

## Context

### Current State (Source)

**Infrastructure:**
- **Host:** OMV K3s cluster (root@omv-baymx) - single node
- **Storage:** `/export/storage0/media` on OMV local disk (7.3TB total, 4.5TB used)
- **Media size:**
  - Shows: 2.3TB
  - Movies: 248GB
  - downloads: 308GB
  - **Total: 2.85TB**

**Applications consuming OMV media:**
| App | NFS Mount | Path | Usage |
|-----|-----------|------|-------|
| sonarr | omv-baymx:/storage0/media | `/nfs-nas-pvc` | TV show management |
| radarr | omv-baymx:/storage0/media | `/nfs-nas-pvc` | Movie management |
| bazarr | omv-baymx:/storage0/media | `/nfs-nas-pvc` | Subtitle management |
| qbittorrent | omv-baymx:/storage0/media | `/nfs-nas-pvc` | Download client |
| sabnzbd | omv-baymx:/storage0/media | `/nfs-nas-pvc` | Usenet client |
| **jellyfin** | **hostPath (OMV local)** | `/nfs-nas-pvc` | **Media server (runs ON OMV!)** |

**Applications NOT migrating (using Synology):**
- audiobookshelf → `synology:/volume1/media/audiobookshelf`
- paperless-ngx → `synology:/volume1/...`

**Current HA status:**
- ❌ Jellyfin: Single point of failure (OMV node only)
- ⚠️ Other apps: NFS from single OMV node (better, but still SPOF)

---

### Target State (Destination)

**Infrastructure:**
- **Host:** Talos Kubernetes k8s-4-dell (10.30.30.24)
- **Storage:** Local disks with XFS filesystems (already configured!)
  - `/var/mnt/media` - 3.6TB available (WDC 4TB HDD)
  - `/var/mnt/downloads` - 476GB available (KINGSTON 512GB NVMe)
- **Access method:** NFS server pod exports local storage to cluster

**Disk inventory (k8s-4-dell):**
```
nvme0n1:  512GB NVMe (KINGSTON OM8PGP4512Q) → /var/mnt/downloads ✅
nvme1n1:  1TB NVMe (KINGSTON SNV3S1000G)    → Reserved for future Ceph OSD
nvme2n1:  250GB NVMe (Samsung 970 EVO)      → Talos system disk
sdb:      8TB HDD (MARSHAL MAL38000)        → FAILED SMART, do not use ❌
sdc:      4TB HDD (WDC WD40EZAZ)            → /var/mnt/media ✅
```

**HA Architecture:**
```
┌─────────────────────────────────────────────────────────────┐
│  Talos Kubernetes Cluster (multi-node)                       │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐ │
│  │  k8s-1-nab9    │  │  k8s-2-ser     │  │  k8s-3-pxm     │ │
│  │                │  │                │  │                │ │
│  │  [Jellyfin]───┼──┼──NFS mount─────┼──┼────────────────┤ │
│  │  [Sonarr]     │  │  [Radarr]      │  │  [Bazarr]      │ │
│  └────────────────┘  └────────────────┘  └────────────────┘ │
│         │                   │                   │            │
│         └───────────────────┴───────────────────┘            │
│                             │                                │
│                     NFS exports (RWX)                        │
│                             │                                │
│  ┌─────────────────────────▼────────────────────────────┐   │
│  │  k8s-4-dell (10.30.30.24)                            │   │
│  │  ┌─────────────────────────────────────────────┐     │   │
│  │  │  NFS Server Pod                             │     │   │
│  │  │  - Exports: /exports/media (RWX)            │     │   │
│  │  │  - Exports: /exports/downloads (RWX)        │     │   │
│  │  └──────────────┬──────────────────────────────┘     │   │
│  │                 │                                     │   │
│  │  ┌──────────────▼──────────────────┐                 │   │
│  │  │  Local Storage (hostPath)       │                 │   │
│  │  │  /var/mnt/media    (3.6TB HDD)  │                 │   │
│  │  │  /var/mnt/downloads (476GB NVMe)│                 │   │
│  │  └─────────────────────────────────┘                 │   │
│  └───────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

**HA Benefits over current state:**
- ✅ Jellyfin can run on **any** Talos node (vs OMV only)
- ✅ If k8s-1/2/3 goes down → Jellyfin reschedules to healthy node
- ⚠️ If k8s-4-dell goes down → Media inaccessible until recovery (~2-5 min reboot)
- ✅ **Better than current:** OMV SPOF → Multi-node cluster with single storage node

**Future improvement path:**
- Phase 2: Add k8s-4-dell or k8s-3 to Ceph cluster
- Phase 3: Migrate from NFS → CephFS (true HA, no SPOF)

---

## Migration Phases

### Phase 0: Verify Readiness (10 min, zero downtime)

**Prerequisites:**
- [ ] Postgres migration to new Garage complete (Phase 3 of Garage migration)
- [ ] k8s-4-dell disks already formatted and mounted (ALREADY DONE ✅)
- [ ] Talos cluster healthy

**Verification:**

1. **Check k8s-4-dell storage:**
   ```bash
   export KUBECONFIG=/tmp/talos-kubeconfig
   
   # Verify mounts exist
   talosctl -n 10.30.30.24 get mounts | grep -E "media|downloads"
   # Should show:
   # u-media       1    /dev/sdc1    /var/mnt/media      xfs
   # u-downloads   1    /dev/nvme0n1p1 /var/mnt/downloads xfs
   ```

2. **Check available capacity:**
   ```bash
   kubectl run capacity-check --rm -i --restart=Never \
     --image=alpine:latest \
     --overrides='{
       "spec": {
         "nodeSelector": {"kubernetes.io/hostname": "k8s-4-dell"},
         "hostNetwork": true,
         "volumes": [
           {"name": "media", "hostPath": {"path": "/var/mnt/media"}},
           {"name": "downloads", "hostPath": {"path": "/var/mnt/downloads"}}
         ],
         "containers": [{
           "name": "df",
           "image": "alpine:latest",
           "command": ["df", "-h"],
           "volumeMounts": [
             {"name": "media", "mountPath": "/mnt/media"},
             {"name": "downloads", "mountPath": "/mnt/downloads"}
           ]
         }]
       }
     }' | grep "/mnt/"
   
   # Expected output:
   # /dev/sdc1        3.6T   71.3G   3.6T   2%   /mnt/media
   # /dev/nvme0n1p1   476.6G  9.2G  467.4G  2%   /mnt/downloads
   ```

3. **Check OMV media size:**
   ```bash
   ssh root@omv-baymx "du -sh /export/storage0/media/*"
   # Expected:
   # 2.3T  Shows
   # 248G  Movies
   # 308G  downloads
   ```

**Success Criteria:**
- [ ] k8s-4-dell has 3.6TB free on /var/mnt/media (sufficient for 2.55TB Shows+Movies)
- [ ] k8s-4-dell has 476GB free on /var/mnt/downloads (sufficient for 308GB downloads)
- [ ] Talos cluster all nodes Ready

---

### Phase 1: Deploy NFS Server on k8s-4-dell (30 min, zero downtime)

**Goal:** Set up NFS server pod to export local storage to cluster

**Files to create:**

#### 1. `components/default/nfs-media-server/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: default
resources:
  - ./resources/service-account.yaml
  - ./resources/rbac.yaml
  - ./resources/deployment.yaml
  - ./resources/service.yaml
```

#### 2. `components/default/nfs-media-server/resources/service-account.yaml`
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-server
  namespace: default
```

#### 3. `components/default/nfs-media-server/resources/rbac.yaml`
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nfs-server
rules:
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nfs-server
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: nfs-server
subjects:
  - kind: ServiceAccount
    name: nfs-server
    namespace: default
```

#### 4. `components/default/nfs-media-server/resources/deployment.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-server
  namespace: default
  labels:
    app.kubernetes.io/name: nfs-server
    app.kubernetes.io/instance: nfs-media
spec:
  replicas: 1
  strategy:
    type: Recreate  # Only one NFS server at a time
  selector:
    matchLabels:
      app.kubernetes.io/name: nfs-server
      app.kubernetes.io/instance: nfs-media
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nfs-server
        app.kubernetes.io/instance: nfs-media
    spec:
      serviceAccountName: nfs-server
      # Pin to k8s-4-dell where local storage exists
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - k8s-4-dell
      containers:
        - name: nfs-server
          image: k8s.gcr.io/volume-nfs:0.8
          ports:
            - name: nfs
              containerPort: 2049
              protocol: TCP
            - name: mountd
              containerPort: 20048
              protocol: TCP
            - name: rpcbind
              containerPort: 111
              protocol: TCP
          securityContext:
            privileged: true
            capabilities:
              add:
                - SYS_ADMIN
                - SETPCAP
          volumeMounts:
            - name: media
              mountPath: /exports/media
            - name: downloads
              mountPath: /exports/downloads
      volumes:
        - name: media
          hostPath:
            path: /var/mnt/media
            type: Directory
        - name: downloads
          hostPath:
            path: /var/mnt/downloads
            type: Directory
```

#### 5. `components/default/nfs-media-server/resources/service.yaml`
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nfs-server
  namespace: default
  labels:
    app.kubernetes.io/name: nfs-server
    app.kubernetes.io/instance: nfs-media
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: nfs-server
    app.kubernetes.io/instance: nfs-media
  ports:
    - name: nfs
      port: 2049
      protocol: TCP
      targetPort: 2049
    - name: mountd
      port: 20048
      protocol: TCP
      targetPort: 20048
    - name: rpcbind
      port: 111
      protocol: TCP
      targetPort: 111
```

**Deployment:**

```bash
cd /Users/vikaspogu/Documents/git-repos/home-ops

# Create directory structure
mkdir -p components/default/nfs-media-server/resources

# Create files (use Write tool for each file above)

# Deploy via kubectl
kubectl apply -k components/default/nfs-media-server/

# Wait for NFS server ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=nfs-server \
  -n default --timeout=180s
```

**Verification:**

```bash
# Check pod is running on k8s-4-dell
kubectl get pod -n default -l app.kubernetes.io/name=nfs-server -o wide
# Should show NODE=k8s-4-dell

# Check NFS exports
kubectl exec -n default deploy/nfs-server -- showmount -e localhost
# Expected output:
# Export list for localhost:
# /exports/downloads *
# /exports/media *

# Test NFS mount from another node
kubectl run nfs-test --rm -i --restart=Never --image=alpine:latest -- \
  sh -c "apk add --no-cache nfs-utils && \
         mount -t nfs nfs-server.default.svc.cluster.local:/exports/media /mnt && \
         ls -la /mnt && \
         umount /mnt"
# Should show empty directory (no media yet)
```

**Success Criteria:**
- [ ] NFS server pod running on k8s-4-dell
- [ ] Service `nfs-server.default.svc.cluster.local` reachable
- [ ] NFS exports visible via showmount
- [ ] Test mount succeeds from another node

---

### Phase 2: Rsync Media from OMV (2-4 hours, zero downtime)

**Goal:** Copy media files from OMV to k8s-4-dell while OMV stays online

**Method:** Incremental rsync in background, apps continue using OMV NFS

**Steps:**

1. **Create rsync job ConfigMap:**

```yaml
# components/default/media-migration/rsync-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: media-migration-rsync
  namespace: default
data:
  rsync-media.sh: |
    #!/bin/sh
    set -e
    
    echo "Starting media rsync from OMV to k8s-4-dell..."
    echo "Source: root@omv-baymx:/export/storage0/media/"
    echo "Target: /mnt/media/"
    
    # Rsync Shows and Movies (exclude downloads for now)
    rsync -avP --stats --exclude='downloads/' \
      root@omv-baymx:/export/storage0/media/ /mnt/media/
    
    echo "Media rsync complete!"
    
  rsync-downloads.sh: |
    #!/bin/sh
    set -e
    
    echo "Starting downloads rsync from OMV to k8s-4-dell..."
    echo "Source: root@omv-baymx:/export/storage0/media/downloads/"
    echo "Target: /mnt/downloads/"
    
    # Rsync downloads directory
    rsync -avP --stats \
      root@omv-baymx:/export/storage0/media/downloads/ /mnt/downloads/
    
    echo "Downloads rsync complete!"
```

2. **Create rsync job for media:**

```yaml
# components/default/media-migration/rsync-media-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: rsync-media-omv-to-talos
  namespace: default
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        app: media-migration
        target: media
    spec:
      restartPolicy: OnFailure
      # Pin to k8s-4-dell where storage exists
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - k8s-4-dell
      containers:
        - name: rsync
          image: instrumentisto/rsync-ssh:latest
          command: ["/bin/sh", "/scripts/rsync-media.sh"]
          volumeMounts:
            - name: media
              mountPath: /mnt/media
            - name: scripts
              mountPath: /scripts
            - name: ssh-key
              mountPath: /root/.ssh/id_rsa
              subPath: ssh-private-key
              readOnly: true
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              memory: 2Gi
      volumes:
        - name: media
          hostPath:
            path: /var/mnt/media
            type: Directory
        - name: scripts
          configMap:
            name: media-migration-rsync
            defaultMode: 0755
        - name: ssh-key
          secret:
            secretName: omv-ssh-key
            defaultMode: 0600
```

3. **Create SSH key secret (if not exists):**

```bash
# Generate SSH key on your workstation if needed
ssh-keygen -t ed25519 -f /tmp/omv-rsync-key -N ""

# Copy public key to OMV
ssh-copy-id -i /tmp/omv-rsync-key.pub root@omv-baymx

# Create Kubernetes secret
kubectl create secret generic omv-ssh-key -n default \
  --from-file=ssh-private-key=/tmp/omv-rsync-key

# Clean up local key
rm /tmp/omv-rsync-key /tmp/omv-rsync-key.pub
```

4. **Run rsync jobs:**

```bash
# Start media rsync (Shows + Movies = 2.55TB)
kubectl apply -f components/default/media-migration/rsync-media-job.yaml

# Monitor progress
kubectl logs -n default -l target=media -f

# Expected duration: ~2-3 hours for 2.55TB over network
# Progress will show:
# - Number of files transferred
# - Transfer speed (MB/s)
# - ETA
```

5. **After media completes, rsync downloads separately:**

```yaml
# components/default/media-migration/rsync-downloads-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: rsync-downloads-omv-to-talos
  namespace: default
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        app: media-migration
        target: downloads
    spec:
      restartPolicy: OnFailure
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
                      - k8s-4-dell
      containers:
        - name: rsync
          image: instrumentisto/rsync-ssh:latest
          command: ["/bin/sh", "/scripts/rsync-downloads.sh"]
          volumeMounts:
            - name: downloads
              mountPath: /mnt/downloads
            - name: scripts
              mountPath: /scripts
            - name: ssh-key
              mountPath: /root/.ssh/id_rsa
              subPath: ssh-private-key
              readOnly: true
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              memory: 2Gi
      volumes:
        - name: downloads
          hostPath:
            path: /var/mnt/downloads
            type: Directory
        - name: scripts
          configMap:
            name: media-migration-rsync
            defaultMode: 0755
        - name: ssh-key
          secret:
            secretName: omv-ssh-key
            defaultMode: 0600
```

```bash
# Start downloads rsync (308GB)
kubectl apply -f components/default/media-migration/rsync-downloads-job.yaml

# Monitor progress
kubectl logs -n default -l target=downloads -f

# Expected duration: ~30-45 min for 308GB
```

**Verification:**

```bash
# Check rsync job completion
kubectl get jobs -n default | grep rsync
# Both should show COMPLETIONS=1/1

# Verify file counts match
# OMV:
ssh root@omv-baymx "find /export/storage0/media/Shows -type f | wc -l"
ssh root@omv-baymx "find /export/storage0/media/Movies -type f | wc -l"

# k8s-4-dell (via NFS server pod):
kubectl exec -n default deploy/nfs-server -- find /exports/media/Shows -type f | wc -l
kubectl exec -n default deploy/nfs-server -- find /exports/media/Movies -type f | wc -l

# Counts should match
```

**Success Criteria:**
- [ ] rsync jobs completed successfully
- [ ] File counts match between OMV and k8s-4-dell
- [ ] Shows + Movies on /var/mnt/media (~2.55TB)
- [ ] downloads on /var/mnt/downloads (~308GB)
- [ ] OMV NFS still serving apps (no downtime yet)

---

### Phase 3: Migrate Jellyfin to Talos (45 min, 30 min downtime)

**Goal:** Move Jellyfin from OMV K3s to Talos cluster with new media paths

**Downtime window:** 30 minutes (Jellyfin unavailable during migration)

**Steps:**

1. **Export Jellyfin config from OMV:**

```bash
# Backup Jellyfin config from OMV
ssh root@omv-baymx "kubectl get pvc jellyfin -n default -o yaml" > /tmp/jellyfin-pvc.yaml

# Export Jellyfin data
ssh root@omv-baymx "tar czf /tmp/jellyfin-config-backup.tar.gz \
  -C /path/to/jellyfin/config ."  # Find actual PVC path first

# Copy backup to local
scp root@omv-baymx:/tmp/jellyfin-config-backup.tar.gz /tmp/
```

2. **Create Jellyfin PVC on Talos (Ceph storage for config):**

```yaml
# components/default/jellyfin/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jellyfin
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ceph-block
  resources:
    requests:
      storage: 20Gi  # Jellyfin config/metadata
```

3. **Restore Jellyfin config to new PVC:**

```bash
# Create PVC
kubectl apply -f components/default/jellyfin/pvc.yaml

# Wait for PVC bound
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/jellyfin -n default --timeout=60s

# Upload config backup to PVC
kubectl run jellyfin-restore --rm -i --restart=Never \
  --image=alpine:latest \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "restore",
        "image": "alpine:latest",
        "command": ["sleep", "3600"],
        "volumeMounts": [{
          "name": "config",
          "mountPath": "/config"
        }]
      }],
      "volumes": [{
        "name": "config",
        "persistentVolumeClaim": {"claimName": "jellyfin"}
      }]
    }
  }' -- sh -c "sleep infinity" &

# Copy backup into pod
kubectl cp /tmp/jellyfin-config-backup.tar.gz default/jellyfin-restore:/tmp/

# Extract inside pod
kubectl exec -n default jellyfin-restore -- \
  tar xzf /tmp/jellyfin-config-backup.tar.gz -C /config/

# Delete restore pod
kubectl delete pod jellyfin-restore -n default
```

4. **Update Jellyfin values.yaml for Talos NFS:**

```yaml
# components/default/jellyfin/values.yaml
---
defaultPodOptions:
  enableServiceLinks: false
controllers:
  jellyfin:
    strategy: Recreate
    annotations:
      reloader.stakater.com/auto: "true"
    containers:
      app:
        image:
          repository: jellyfin/jellyfin
          tag: 10.11.11@sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db
        env:
          DOTNET_SYSTEM_IO_DISABLEFILELOCKING: "true"
          JELLYFIN_FFmpeg__probesize: 50000000
          JELLYFIN_FFmpeg__analyzeduration: 50000000
          TZ: America/New_York
        resources:
          requests:
            cpu: 100m
            memory: 2Gi
          limits:
            memory: 6Gi
        probes:
          liveness: &probes
            enabled: true
            custom: true
            spec:
              httpGet:
                path: /health
                port: &port 8096
              initialDelaySeconds: 0
              periodSeconds: 30
              timeoutSeconds: 1
              failureThreshold: 3
          readiness: *probes
          startup:
            enabled: false

service:
  app:
    ports:
      http:
        port: *port

persistence:
  config:
    enabled: true
    existingClaim: jellyfin
    globalMounts:
      - path: /config
  transcode:
    enabled: true
    type: emptyDir
    globalMounts:
      - path: /transcode
  media:
    type: nfs  # Changed from hostPath to NFS
    server: nfs-server.default.svc.cluster.local  # NFS server service
    path: "/exports/media"  # NFS export path
    globalMounts:
      - path: /nfs-nas-pvc
        readOnly: false  # Allow Jellyfin to write watched status, etc.
```

5. **Stop Jellyfin on OMV (DOWNTIME STARTS):**

```bash
# Scale down Jellyfin on OMV
ssh root@omv-baymx "kubectl scale deploy jellyfin -n default --replicas=0"

# Verify stopped
ssh root@omv-baymx "kubectl get pods -n default -l app.kubernetes.io/name=jellyfin"
# Should show: No resources found
```

6. **Deploy Jellyfin on Talos:**

```bash
# Apply updated configuration
kubectl apply -k components/default/jellyfin/

# Wait for pod ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=jellyfin \
  -n default --timeout=300s

# Check which node it's running on
kubectl get pod -n default -l app.kubernetes.io/name=jellyfin -o wide
# Should show any node (k8s-1, k8s-2, k8s-3, k8s-4, k8s-5) - NOT tied to k8s-4-dell!
```

7. **Verify Jellyfin access (DOWNTIME ENDS if successful):**

```bash
# Check Jellyfin web UI accessible
curl -I https://jellyfin.${CLUSTER_DOMAIN}/health
# Should return 200 OK

# Test media library scan
kubectl logs -n default -l app.kubernetes.io/name=jellyfin --tail=50
# Should show library scan starting

# Verify shows/movies visible in Jellyfin UI
# Login and check library contents
```

**Rollback (if issues):**

```bash
# 1. Stop Jellyfin on Talos
kubectl scale deploy jellyfin -n default --replicas=0

# 2. Revert Jellyfin values.yaml to hostPath pointing to OMV

# 3. Restart Jellyfin on OMV
ssh root@omv-baymx "kubectl scale deploy jellyfin -n default --replicas=1"
```

**Success Criteria:**
- [ ] Jellyfin config restored on Talos
- [ ] Jellyfin pod running on Talos (any node, not k8s-4-dell!)
- [ ] Web UI accessible
- [ ] Shows and Movies libraries visible
- [ ] Can play media files
- [ ] OMV Jellyfin stopped

---

### Phase 4: Migrate Other Media Apps (30 min, brief downtime per app)

**Goal:** Update sonarr, radarr, bazarr, qbittorrent, sabnzbd to use Talos NFS

**Method:** Rolling update, one app at a time

**Apps to update:**

1. **sonarr** (TV shows)
2. **radarr** (Movies)
3. **bazarr** (Subtitles)
4. **qbittorrent** (Downloads)
5. **sabnzbd** (Downloads)

**Generic update pattern:**

```yaml
# For each app: components/default/<app>/values.yaml
persistence:
  media:
    type: nfs  # Changed from NFS
    server: nfs-server.default.svc.cluster.local  # New server
    path: "/exports/media"  # Shows + Movies
    globalMounts:
      - path: /nfs-nas-pvc
  # For download clients (qbittorrent, sabnzbd), ADD:
  downloads:
    type: nfs
    server: nfs-server.default.svc.cluster.local
    path: "/exports/downloads"  # Dedicated downloads volume
    globalMounts:
      - path: /downloads
```

**Execution (per app):**

```bash
# Example: Update sonarr
cd /Users/vikaspogu/Documents/git-repos/home-ops

# 1. Edit values.yaml (change NFS server to nfs-server.default.svc.cluster.local)

# 2. Apply changes
kubectl apply -k components/default/sonarr/

# 3. Wait for new pod ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=sonarr \
  -n default --timeout=180s

# 4. Verify app functional
kubectl logs -n default -l app.kubernetes.io/name=sonarr --tail=20
# Should show no errors accessing media

# 5. Repeat for next app
```

**Verification per app:**

```bash
# Check pod can access media
kubectl exec -n default deploy/<app-name> -- ls -lh /nfs-nas-pvc/Shows | head -5
# Should show TV shows

kubectl exec -n default deploy/<app-name> -- ls -lh /nfs-nas-pvc/Movies | head -5
# Should show movies

# For download clients, check downloads mount
kubectl exec -n default deploy/<app-name> -- ls -lh /downloads | head -5
# Should show download files
```

**Success Criteria:**
- [ ] All 5 apps updated to use Talos NFS
- [ ] All apps running and healthy
- [ ] Apps can read/write to media paths
- [ ] No errors in pod logs

---

### Phase 5: Final Sync & Verification (1 hour)

**Goal:** Ensure all media is up-to-date, verify functionality

**Steps:**

1. **Run final incremental rsync (capture any changes during migration):**

```bash
# Re-run rsync to catch any files written during Phase 2-4
kubectl apply -f components/default/media-migration/rsync-media-job.yaml
kubectl apply -f components/default/media-migration/rsync-downloads-job.yaml

# Monitor completion
kubectl logs -n default -l app=media-migration -f

# Should complete quickly (only delta files)
```

2. **Comprehensive functionality test:**

```bash
# Test Jellyfin playback
# - Open Jellyfin UI
# - Play a TV show
# - Play a movie
# - Verify transcoding works (CPU/GPU usage spike)

# Test Sonarr
# - Browse series list
# - Trigger manual search for episode
# - Verify Sonarr can see files in Shows directory

# Test Radarr
# - Browse movie list
# - Trigger manual search for movie
# - Verify Radarr can see files in Movies directory

# Test download clients
# - qbittorrent: Add test torrent, verify writes to /downloads
# - sabnzbd: Add test download, verify writes to /downloads

# Test Bazarr
# - Browse series/movies
# - Trigger subtitle search
# - Verify can download and save subtitles
```

3. **Verify HA failover:**

```bash
# Test 1: Pod rescheduling (node drain)
# Drain k8s-1 (or whichever node runs Jellyfin)
kubectl drain k8s-1-nab9 --ignore-daemonsets --delete-emptydir-data

# Watch Jellyfin pod reschedule to another node
kubectl get pod -n default -l app.kubernetes.io/name=jellyfin -o wide -w

# Verify Jellyfin stays accessible during reschedule
while true; do curl -I https://jellyfin.${CLUSTER_DOMAIN}/health; sleep 2; done

# Uncordon node
kubectl uncordon k8s-1-nab9

# Test 2: NFS server resilience
# If k8s-4-dell goes down, NFS becomes unavailable
# Jellyfin pod stays up but media unplayable until k8s-4-dell recovers
# This is EXPECTED behavior with current NFS architecture
```

4. **Compare file checksums (sample):**

```bash
# Pick random files to checksum verify
# OMV:
ssh root@omv-baymx "md5sum /export/storage0/media/Shows/SomeShow/S01E01.mkv"

# Talos (via NFS pod):
kubectl exec -n default deploy/nfs-server -- \
  md5sum /exports/media/Shows/SomeShow/S01E01.mkv

# Checksums should match exactly
```

**Success Criteria:**
- [ ] All apps functional with Talos NFS
- [ ] Jellyfin playback working (shows + movies)
- [ ] Download clients can write to downloads directory
- [ ] Jellyfin pod can reschedule to any node (not tied to k8s-4-dell)
- [ ] Sample checksums match between OMV and Talos

---

### Phase 6: Cleanup & Documentation (30 min)

**Goal:** Remove old OMV media files, update docs

**Steps:**

1. **Monitor for 1 week before cleanup:**

```bash
# Daily checks (for 7 days):
# - Jellyfin accessible
# - No media playback errors
# - Download clients working
# - No NFS mount errors in pod logs
```

2. **After 1 week verification, archive OMV media:**

```bash
# Create tarball backup (optional, for safety)
ssh root@omv-baymx "tar czf /backup/media-archive-$(date +%F).tar.gz \
  /export/storage0/media/Shows \
  /export/storage0/media/Movies \
  /export/storage0/media/downloads"

# Move tarball to safe location (external drive, S3, etc.)
```

3. **Delete OMV media files:**

```bash
# After confirming backup exists and Talos media working
ssh root@omv-baymx "rm -rf /export/storage0/media/Shows"
ssh root@omv-baymx "rm -rf /export/storage0/media/Movies"
ssh root@omv-baymx "rm -rf /export/storage0/media/downloads"

# Verify deletion
ssh root@omv-baymx "du -sh /export/storage0/media"
# Should show minimal usage (only empty directories)
```

4. **Stop Jellyfin on OMV permanently:**

```bash
ssh root@omv-baymx "kubectl delete deploy jellyfin -n default"
ssh root@omv-baymx "kubectl delete svc jellyfin -n default"
ssh root@omv-baymx "kubectl delete pvc jellyfin -n default"
```

5. **Update documentation:**

- Update media infrastructure diagram
- Document NFS server pod location (k8s-4-dell)
- Add troubleshooting section for NFS issues
- Update disaster recovery procedures

**Success Criteria:**
- [ ] 7 days uptime with no media issues
- [ ] OMV media files backed up (optional)
- [ ] OMV media files deleted (frees 2.85TB)
- [ ] Jellyfin removed from OMV cluster
- [ ] Documentation updated

---

## Migration Timeline

| Phase | Duration | Downtime | Can Run In Parallel? |
|-------|----------|----------|----------------------|
| Phase 0: Verify | 10 min | 0 | No (prerequisite) |
| Phase 1: Deploy NFS | 30 min | 0 | No (must be first) |
| Phase 2: Rsync media | 2-3 hours | 0 | Yes (runs while OMV serves) |
| Phase 3: Jellyfin | 45 min | 30 min | No (after rsync) |
| Phase 4: Other apps | 30 min | ~5 min/app | No (sequential) |
| Phase 5: Verify | 1 hour | 0 | No (validation) |
| Phase 6: Cleanup | 30 min | 0 | After 1 week monitoring |
| **Total execution** | **~5 hours** | **30 min** | |

**Recommended schedule:**
- **Day 1:** Phases 0-2 (3.5 hours, zero downtime)
- **Day 2:** Phases 3-5 (2.5 hours, 30 min downtime) - Schedule during low-usage time
- **Day 9:** Phase 6 cleanup (after 1 week validation)

---

## Rollback Procedures

### If issues during Phase 3 (Jellyfin migration):

```bash
# 1. Stop Jellyfin on Talos
kubectl delete -k components/default/jellyfin/

# 2. Restart Jellyfin on OMV
ssh root@omv-baymx "kubectl scale deploy jellyfin -n default --replicas=1"

# 3. Verify OMV Jellyfin working
# Data loss: None (OMV media files unchanged)
```

### If issues during Phase 4 (other apps):

```bash
# Roll back affected app to OMV NFS server
# 1. Edit app values.yaml, revert NFS server to omv-baymx.a113.internal
# 2. kubectl apply -k components/default/<app>/
# 3. Other apps already migrated stay on Talos NFS
```

### If NFS server pod fails:

```bash
# NFS pod crash - Kubernetes will restart automatically
kubectl get pod -n default -l app.kubernetes.io/name=nfs-server -w

# Force restart if needed
kubectl delete pod -n default -l app.kubernetes.io/name=nfs-server

# Pod will reschedule on k8s-4-dell, mounts persist
```

### If k8s-4-dell node goes offline:

```bash
# Symptom: NFS mounts fail, media inaccessible
# Expected behavior: NFS server pod cannot reschedule (tied to k8s-4-dell)
# Media apps remain running but show "file not found" errors

# Resolution:
# 1. Fix k8s-4-dell hardware issue
# 2. Reboot k8s-4-dell (Talos recovery ~2 min)
# 3. Wait for NFS pod to restart
# 4. Media apps automatically reconnect

# Data loss: None (local disks persist through reboot)
```

---

## Future Improvements

### Phase 2: Expand Ceph Cluster (Post-Migration)

**Goal:** Add k8s-4-dell to Ceph for true HA

**Options:**
1. Add k8s-4-dell's 1TB NVMe (nvme1n1) as Ceph OSD
2. Add k8s-4-dell's 4TB HDD (sdc) as Ceph OSD (slower, more capacity)
3. Wait for k8s-3 conversion to Talos, add k8s-3's disks

**Implementation:**

```yaml
# Edit components/rook-ceph/rook-ceph-cluster/values.yaml
cephClusterSpec:
  storage:
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
      - name: "k8s-4-dell"  # NEW
        devices:
          - name: "nvme1n1"  # 1TB NVMe (fast)
          # OR
          # - name: "sdc"  # 4TB HDD (slow but more capacity)
```

**New Ceph capacity:**
- Current: 2.7TB raw (766GB usable with size=3)
- After adding k8s-4-dell 1TB NVMe: 3.7TB raw (~1.2TB usable)
- After adding k8s-4-dell 4TB HDD: 6.7TB raw (~2.2TB usable)

**Deploy CephFS:**

```yaml
# Edit components/rook-ceph/rook-ceph-cluster/values.yaml
cephFileSystems:
  - name: ceph-filesystem
    spec:
      metadataPool:
        replicated:
          size: 3
      dataPools:
        - name: data0
          failureDomain: host
          replicated:
            size: 3
      metadataServer:
        activeCount: 1
        activeStandby: true
    storageClass:
      enabled: true
      name: ceph-filesystem
      reclaimPolicy: Delete
      allowVolumeExpansion: true
      mountOptions: []
      parameters:
        csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
        csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
        csi.storage.k8s.io/controller-expand-secret-name: rook-csi-cephfs-provisioner
        csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
        csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
        csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
        csi.storage.k8s.io/fstype: ext4
```

### Phase 3: Migrate from NFS to CephFS

**Goal:** Replace NFS server pod with CephFS for true HA

**Steps:**

1. Create CephFS PVC for media:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media-cephfs
  namespace: default
spec:
  accessModes:
    - ReadWriteMany  # Multiple pods can mount
  storageClassName: ceph-filesystem
  resources:
    requests:
      storage: 3Ti  # Shows + Movies + growth
```

2. Rsync from NFS → CephFS:

```bash
# Run migration job (similar to Phase 2)
kubectl run cephfs-migration --rm -i --restart=Never --image=alpine:latest \
  --overrides='{...}' -- \
  sh -c "apk add rsync && rsync -avP /nfs/ /cephfs/"
```

3. Update app values.yaml:

```yaml
# Change from NFS to PVC
persistence:
  media:
    enabled: true
    type: persistentVolumeClaim
    existingClaim: media-cephfs  # CephFS PVC
    globalMounts:
      - path: /nfs-nas-pvc
```

4. Delete NFS server pod:

```bash
kubectl delete -k components/default/nfs-media-server/
```

**Benefits:**
- ✅ True HA - no single point of failure
- ✅ Survives any single node failure
- ✅ Data replicated across 3 nodes
- ✅ No NFS server pod to maintain

---

## Monitoring

**Daily health checks (automated alerts recommended):**

```bash
# NFS server pod health
kubectl get pod -n default -l app.kubernetes.io/name=nfs-server
# Should show Running

# Media apps health
kubectl get pods -n default -l 'app.kubernetes.io/name in (jellyfin,sonarr,radarr,bazarr,qbittorrent,sabnzbd)'
# All should show Running

# k8s-4-dell disk usage
kubectl run disk-check --rm -i --restart=Never --image=alpine \
  --overrides='{...hostPath mounts...}' -- df -h | grep "/mnt/"
# Monitor growth, alert if >90% full

# NFS mount status from client pod
kubectl exec -n default deploy/jellyfin -- mount | grep nfs
# Should show nfs-server.default.svc.cluster.local:/exports/media
```

**Prometheus metrics to monitor:**
- `kubelet_volume_stats_used_bytes{persistentvolumeclaim="jellyfin"}` - Config PVC usage
- `node_filesystem_avail_bytes{mountpoint="/var/mnt/media"}` - k8s-4-dell media disk
- `node_filesystem_avail_bytes{mountpoint="/var/mnt/downloads"}` - k8s-4-dell downloads disk
- `kube_pod_status_phase{pod=~"nfs-server.*"}` - NFS server pod health

---

## Troubleshooting

### Symptom: "Stale file handle" errors in pods

**Cause:** NFS mount became stale (NFS server restarted, network issue)

**Fix:**
```bash
# Restart affected pod to remount NFS
kubectl delete pod -n default <pod-name>
# Kubernetes will recreate pod with fresh NFS mount
```

### Symptom: Media files not visible in Jellyfin

**Cause:** Permission mismatch, NFS mount failed

**Diagnosis:**
```bash
# Check mount inside Jellyfin pod
kubectl exec -n default deploy/jellyfin -- mount | grep nfs

# Check permissions
kubectl exec -n default deploy/jellyfin -- ls -ld /nfs-nas-pvc/Shows

# Check NFS exports
kubectl exec -n default deploy/nfs-server -- showmount -e localhost
```

**Fix:**
```bash
# If mount missing, check NFS server pod logs
kubectl logs -n default deploy/nfs-server

# If permissions wrong, fix on k8s-4-dell:
talosctl -n 10.30.30.24 shell -- \
  chown -R 1000:1000 /var/mnt/media
```

### Symptom: k8s-4-dell disk full

**Cause:** Media library grew beyond 3.6TB capacity

**Short-term fix:**
```bash
# Delete old/unwatched content manually
# Expand to CephFS (see Future Improvements)
```

**Long-term fix:**
- Add k8s-4-dell to Ceph cluster
- Migrate to CephFS with more capacity

---

## Success Criteria

**Functional:**
- [ ] All media apps running on Talos cluster
- [ ] Jellyfin can play Shows and Movies
- [ ] Sonarr/Radarr can manage media libraries
- [ ] Download clients can write to downloads directory
- [ ] Bazarr can download and save subtitles

**Performance:**
- [ ] Jellyfin playback latency < 2 seconds
- [ ] No buffering during 1080p playback
- [ ] Download speeds match previous (OMV) performance

**Availability:**
- [ ] Jellyfin survives pod restarts (reschedules to any node)
- [ ] Media apps survive pod restarts
- [ ] k8s-4-dell reboot recovers within 5 minutes (Talos boot + NFS pod start)

**Operational:**
- [ ] Zero unplanned downtime during migration
- [ ] Actual downtime ≤ 30 minutes (Jellyfin only)
- [ ] OMV media files freed (2.85TB reclaimed)
- [ ] Documentation updated

---

## References

- **Talos User Volumes:** https://www.talos.dev/latest/reference/configuration/#userVolumeConfig
- **NFS Server in Kubernetes:** https://github.com/kubernetes-sigs/nfs-ganesha-server-and-external-provisioner
- **Rook-Ceph CephFS:** https://rook.io/docs/rook/latest/CRDs/Shared-Filesystem/ceph-filesystem-crd/
- **Original Garage Migration Design:** `docs/superpowers/specs/2026-06-08-garage-omv-to-talos-k8s5-design.md`

---

## Contact / Notes

**Migration Owner:** [Your Name]  
**Started:** 2026-06-08  
**Target Completion:** 2026-06-10 (including verification)  
**Cleanup Completion:** 2026-06-16 (after 1 week monitoring)

**Key Decisions Made:**
1. Use k8s-4-dell local storage (not k8s-5-1u Garage disks)
2. NFS server approach (not CephFS) for initial migration
3. Migrate Jellyfin from OMV to Talos for better HA
4. Keep Synology NFS mounts unchanged (audiobookshelf, paperless)
5. Future: Expand Ceph + migrate to CephFS for true HA
