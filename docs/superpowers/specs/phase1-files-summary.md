# Phase 1 Files Created - Summary

**Date:** 2026-06-08  
**Status:** Ready for deployment (NOT committed)  
**Phase:** Phase 1 - Deploy New Garage on k8s-5-1u

---

## Files Created (7 new files, 2 modified)

### New Files:

1. **`clusters/talos/bootstrap/os/patches/k8s-5-1u/garage-storage.yaml`**
   - Talos UserVolumeConfig for 9 volumes (8 HDDs + 1 metadata)
   - Configures: sdc, sdd, sde, sdf, sdg, sdh, sdi, sdj as XFS filesystems
   - Mounts: `/var/mnt/garage-hdd1` through `/var/mnt/garage-hdd8`
   - Metadata: `/var/mnt/garage-meta` on system disk (50GB)

2. **`components/default/garage-s3/kustomization.yaml`**
   - Kustomize configuration
   - References Helm chart: bjw-s app-template v5.0.1
   - Includes ConfigMap generator for garage config
   - Resources: externalsecret.yaml, http-route.yaml

3. **`components/default/garage-s3/values.yaml`**
   - Helm values for app-template
   - 2 containers: garage (app) + garage-webui
   - 8 hostPath volumes for data + 1 for metadata
   - Node affinity pinned to k8s-5-1u
   - Resources: 200m CPU, 512Mi-2Gi memory (garage), 10m CPU, 128Mi-256Mi (webui)

4. **`components/default/garage-s3/resources/configuration.toml`**
   - Garage S3 configuration
   - Multi-HDD: 8x 800GB capacity
   - db_engine: lmdb
   - replication_factor: 1
   - compression_level: 2
   - S3 API port: 3900
   - Admin API port: 3903

5. **`components/default/garage-s3/externalsecret.yaml`**
   - ExternalSecret from 1Password
   - Retrieves: GARAGE_ADMIN_TOKEN
   - Target secret: garage-s3-secret
   - References ClusterSecretStore: onepassword-connect

6. **`components/default/garage-s3/http-route.yaml`**
   - 2 HTTPRoutes:
     - S3 API: `s3.${CLUSTER_DOMAIN}` → port 3900
     - Web UI: `garage.${CLUSTER_DOMAIN}` → port 3909
   - Homepage integration annotations
   - Gateway API v1

7. **`docs/superpowers/specs/phase1-files-summary.md`**
   - This file (documentation)

### Modified Files:

1. **`clusters/talos/bootstrap/os/talconfig.yaml`**
   - Added patch reference for k8s-5-1u:
     ```yaml
     patches:
       - "@./patches/k8s-5-1u/garage-storage.yaml"
     ```

2. **`clusters/talos/apps/20-applications.yaml`**
   - Added garage-s3 application entry between govee2mqtt and home-assistant
   - Sync wave: 20
   - Path: components/default/garage-s3

---

## Pre-Deployment Checklist

Before running deployment commands, ensure:

- [ ] **1Password secret exists**: Create `garage-s3` item in 1Password with field `GARAGE_ADMIN_TOKEN`
  - Generate token: `openssl rand -base64 32`
  - Add to 1Password vault referenced by onepassword-connect

- [ ] **Verify disk devices**: Confirm k8s-5-1u has devices sdc-sdj
  ```bash
  talosctl --talosconfig clusters/talos/bootstrap/os/clusterconfig/talosconfig \
    -n 10.30.30.25 get disks
  ```

- [ ] **Backup talconfig**: The node will reboot after applying config
  ```bash
  cp clusters/talos/bootstrap/os/clusterconfig/home-kubernetes-k8s-5-1u.yaml \
     /tmp/backup-k8s-5-1u-config.yaml
  ```

- [ ] **Check node workloads**: Ensure no critical pods on k8s-5-1u before reboot
  ```bash
  kubectl get pods -A -o wide --field-selector spec.nodeName=k8s-5-1u
  ```

---

## Deployment Order (NOT EXECUTED YET)

### Step 1: Apply Talos Config (15-20 min)
```bash
cd clusters/talos/bootstrap/os
talhelper genconfig
talosctl --talosconfig clusterconfig/talosconfig apply-config \
  --nodes 10.30.30.25 \
  --file clusterconfig/home-kubernetes-k8s-5-1u.yaml

# Node will reboot (~5-10 minutes)

# Wait for node ready
kubectl wait --for=condition=ready node/k8s-5-1u --timeout=600s

# Verify mounts
talosctl --talosconfig clusterconfig/talosconfig -n 10.30.30.25 get mounts | grep garage
```

**Expected output:** 9 mounts visible (garage-hdd1 through hdd8, garage-meta)

### Step 2: Create 1Password Secret (if not exists)
```bash
# Via 1Password UI or CLI:
# - Login: garage-s3
# - Field: GARAGE_ADMIN_TOKEN = <generated token>
# - Vault: homelab (or whichever vault onepassword-connect uses)
```

### Step 3: Deploy Garage via ArgoCD (5 min)
```bash
# Commit and push files first, then:
kubectl apply -f clusters/talos/apps/20-applications.yaml

# OR use ArgoCD UI to sync the app

# Wait for pod ready
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=garage-s3 \
  -n default --timeout=300s
```

### Step 4: Initialize Garage (5 min)
```bash
POD=$(kubectl get pod -n default -l app.kubernetes.io/name=garage-s3 -o name | head -1)

# Check status
kubectl exec -n default $POD -c app -- /garage status

# Create S3 key (SAVE THE OUTPUT!)
kubectl exec -n default $POD -c app -- /garage key create main

# Create buckets
kubectl exec -n default $POD -c app -- /garage bucket create reactive-resume
kubectl exec -n default $POD -c app -- /garage bucket create obsidian-notes
kubectl exec -n default $POD -c app -- /garage bucket create tofu-state
kubectl exec -n default $POD -c app -- /garage bucket create postgres

# Grant permissions
for bucket in reactive-resume obsidian-notes tofu-state postgres; do
  kubectl exec -n default $POD -c app -- \
    /garage bucket allow $bucket --read --write --key main
done
```

### Step 5: Verification (5 min)
```bash
# Verify Garage health
kubectl exec -n default $POD -c app -- /garage status
kubectl exec -n default $POD -c app -- /garage bucket list
kubectl exec -n default $POD -c app -- /garage stats -a

# Test S3 API (replace with actual keys from step 4)
kubectl run aws-test --rm -i --image=amazon/aws-cli:latest \
  --restart=Never \
  --env AWS_ACCESS_KEY_ID=<key> \
  --env AWS_SECRET_ACCESS_KEY=<secret> -- \
  s3 ls --endpoint-url http://garage-s3.default.svc.cluster.local:3900

# Should list: reactive-resume, obsidian-notes, tofu-state, postgres
```

---

## Success Criteria

- [x] All 7 files created successfully
- [x] All 2 files modified successfully
- [ ] **NOT YET:** 1Password secret created
- [ ] **NOT YET:** Talos config applied (node rebooted)
- [ ] **NOT YET:** 8 HDDs mounted on k8s-5-1u
- [ ] **NOT YET:** Garage pod running
- [ ] **NOT YET:** 4 buckets created
- [ ] **NOT YET:** S3 API accessible

---

## Next Steps

1. **Review files** in git diff
2. **Create 1Password secret** for GARAGE_ADMIN_TOKEN
3. **Commit and push** when ready
4. **Execute deployment steps** above
5. **Proceed to Phase 2** (migrate small buckets)

---

## Important Notes

- **Node reboot required**: k8s-5-1u will reboot when Talos config is applied
- **Save S3 keys**: Output from `garage key create main` is needed for Phase 2
- **No production impact**: OMV Garage continues serving during Phase 1
- **Rollback available**: If deployment fails, node can be reconfigured with old config

---

## Files Status

```
NEW:
  clusters/talos/bootstrap/os/patches/k8s-5-1u/garage-storage.yaml
  components/default/garage-s3/kustomization.yaml
  components/default/garage-s3/values.yaml
  components/default/garage-s3/resources/configuration.toml
  components/default/garage-s3/externalsecret.yaml
  components/default/garage-s3/http-route.yaml
  docs/superpowers/specs/phase1-files-summary.md

MODIFIED:
  clusters/talos/bootstrap/os/talconfig.yaml
  clusters/talos/apps/20-applications.yaml
```

All files ready for review and deployment.
