# Phase 1 Deployment Checklist

**Date:** 2026-06-08  
**Task:** Deploy Garage S3 on k8s-5-1u with 8-HDD layout  
**Estimated Time:** 30-45 minutes  
**Downtime:** Node k8s-5-1u will reboot (~5-10 min)

---

## Pre-Flight Checks ✅

### 1. Files Ready
- [x] Talos patch created: `clusters/talos/bootstrap/os/patches/k8s-5-1u/garage-storage.yaml`
- [x] Component files: `components/default/garage-s3/`
- [x] ArgoCD app registered
- [ ] Files committed to git (do this first!)

### 2. Node Status
- [x] Node reachable via talosctl (v1.12.6)
- [ ] Check workloads on node (run command below)
- [ ] Notify team: k8s-5-1u will reboot

### 3. Prerequisites
- [ ] **CRITICAL:** Create 1Password secret `garage-s3` with field `GARAGE_ADMIN_TOKEN`
- [ ] Backup current Talos config (command below)

---

## Step-by-Step Deployment

### Step 0: Commit Files (DO THIS FIRST!)

```bash
cd /Users/vikaspogu/Documents/git-repos/home-ops

# Review changes
git status
git diff clusters/talos/apps/20-applications.yaml
git diff clusters/talos/bootstrap/os/talconfig.yaml

# Commit
git add clusters/talos/bootstrap/os/patches/k8s-5-1u/
git add components/default/garage-s3/
git add clusters/talos/apps/20-applications.yaml
git add clusters/talos/bootstrap/os/talconfig.yaml
git add docs/superpowers/specs/

git commit -m "(feat): add Garage S3 deployment on k8s-5-1u with 8-HDD multi-disk layout"

# Push
git push
```

---

### Step 1: Create 1Password Secret (CRITICAL!)

**Via 1Password UI or CLI:**
```bash
# Generate admin token
ADMIN_TOKEN=$(openssl rand -base64 32)
echo "Admin Token: $ADMIN_TOKEN"

# Add to 1Password:
# - Item name: garage-s3
# - Field name: GARAGE_ADMIN_TOKEN
# - Field value: <token from above>
# - Vault: homelab (or your vault name)

# Save this token somewhere safe - you'll need it later!
```

**Verify ExternalSecret will work:**
```bash
# After creating in 1Password, verify the secret store can access it
# (This will fail until after deployment, but good to check vault name is correct)
kubectl get clustersecretstore onepassword-connect -o yaml 2>&1 | grep -A5 "spec:"
```

---

### Step 2: Pre-Deployment Checks

```bash
# Check workloads on k8s-5-1u (should tolerate ~10min downtime)
KUBECONFIG=<your-kubeconfig> kubectl get pods -A --field-selector spec.nodeName=k8s-5-1u

# Backup current k8s-5-1u config
cp clusters/talos/bootstrap/os/clusterconfig/home-kubernetes-k8s-5-1u.yaml \
   /tmp/backup-k8s-5-1u-$(date +%Y%m%d-%H%M%S).yaml

# Verify disk devices exist
talosctl --talosconfig clusters/talos/bootstrap/os/clusterconfig/talosconfig \
  -n 10.30.30.25 get disks | grep -E "sdc|sdd|sde|sdf|sdg|sdh|sdi|sdj"

# Expected: 8 disks (sdc through sdj) each ~900GB
```

---

### Step 3: Apply Talos Configuration (15-20 min)

**⚠️ WARNING: Node will reboot! This will take 5-10 minutes.**

```bash
cd clusters/talos/bootstrap/os

# Regenerate Talos configs with new patch
talhelper genconfig

# Verify the generated config includes garage volumes
grep -A5 "garage-hdd" clusterconfig/home-kubernetes-k8s-5-1u.yaml

# Apply config to k8s-5-1u
talosctl --talosconfig clusterconfig/talosconfig apply-config \
  --nodes 10.30.30.25 \
  --file clusterconfig/home-kubernetes-k8s-5-1u.yaml

# Output should show: "applied configuration"
```

**Monitor reboot:**
```bash
# Watch node status (will disconnect during reboot)
watch -n 5 'talosctl --talosconfig clusters/talos/bootstrap/os/clusterconfig/talosconfig \
  -n 10.30.30.25 version --short 2>&1 | tail -3'

# After ~5-10 minutes, node should respond again
```

**Verify node is back:**
```bash
# Wait for Kubernetes node to be Ready (may take 2-3 min after Talos responds)
# Note: Use your actual kubeconfig path
KUBECONFIG=<your-kubeconfig> kubectl wait --for=condition=ready node/k8s-5-1u --timeout=600s

# Verify mounts exist
talosctl --talosconfig clusters/talos/bootstrap/os/clusterconfig/talosconfig \
  -n 10.30.30.25 get mounts | grep garage

# Expected output: 9 lines showing garage-hdd1 through garage-hdd8, plus garage-meta
```

---

### Step 4: Deploy Garage via ArgoCD (5 min)

**Option A: Via ArgoCD UI**
1. Open ArgoCD: `https://argocd.<your-domain>`
2. Find application: `garage-s3`
3. Click "Sync" → "Synchronize"
4. Monitor deployment

**Option B: Via kubectl**
```bash
# Trigger ArgoCD sync
kubectl annotate app garage-s3 -n argocd \
  argocd.argoproj.io/refresh=normal --overwrite

# OR apply the app definition
kubectl apply -f clusters/talos/apps/20-applications.yaml

# Wait for pod to be ready
KUBECONFIG=<your-kubeconfig> kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=garage-s3 \
  -n default --timeout=300s
```

**Monitor deployment:**
```bash
# Watch pod status
KUBECONFIG=<your-kubeconfig> watch -n 2 'kubectl get pods -n default -l app.kubernetes.io/name=garage-s3'

# Check events if pod fails to start
KUBECONFIG=<your-kubeconfig> kubectl get events -n default --sort-by='.lastTimestamp' | tail -20
```

---

### Step 5: Initialize Garage Cluster (5 min)

```bash
# Get pod name
POD=$(KUBECONFIG=<your-kubeconfig> kubectl get pod -n default \
  -l app.kubernetes.io/name=garage-s3 -o name | head -1)

# Check Garage status
KUBECONFIG=<your-kubeconfig> kubectl exec -n default $POD -c app -- /garage status

# Expected: Single-node cluster with 8 data directories
# Output should show:
# ==== HEALTHY NODES ====
# ID                Hostname  Address         Tags  Zone  Capacity
# <node-id>         garage    127.0.0.1:3901        1     ...

# Verify all 8 HDDs are visible
KUBECONFIG=<your-kubeconfig> kubectl exec -n default $POD -c app -- /garage status | grep -i "data"
```

---

### Step 6: Create S3 Access Key (SAVE OUTPUT!)

```bash
# Create main access key
KUBECONFIG=<your-kubeconfig> kubectl exec -n default $POD -c app -- \
  /garage key create main

# ⚠️ IMPORTANT: Save the output!
# You'll see:
#   Key ID: GKxxxxxxxxxxxxxxxxxxxxxxxx
#   Secret key: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#
# Save these credentials - you'll need them for Phase 2!
```

**Save credentials to a secure location:**
```bash
# Example (adjust path):
cat > /tmp/garage-s3-credentials.txt <<EOF
Access Key ID: <paste from above>
Secret Key: <paste from above>
Date: $(date)
EOF

chmod 600 /tmp/garage-s3-credentials.txt
```

---

### Step 7: Create S3 Buckets (2 min)

```bash
# Create 4 buckets
for bucket in reactive-resume obsidian-notes tofu-state postgres; do
  KUBECONFIG=<your-kubeconfig> kubectl exec -n default $POD -c app -- \
    /garage bucket create $bucket
done

# Grant permissions
for bucket in reactive-resume obsidian-notes tofu-state postgres; do
  KUBECONFIG=<your-kubeconfig> kubectl exec -n default $POD -c app -- \
    /garage bucket allow $bucket --read --write --key main
done

# Verify buckets created
KUBECONFIG=<your-kubeconfig> kubectl exec -n default $POD -c app -- \
  /garage bucket list
```

---

### Step 8: Verification (5 min)

**1. Check Garage health:**
```bash
KUBECONFIG=<your-kubeconfig> kubectl exec -n default $POD -c app -- /garage status
KUBECONFIG=<your-kubeconfig> kubectl exec -n default $POD -c app -- /garage bucket list
KUBECONFIG=<your-kubeconfig> kubectl exec -n default $POD -c app -- /garage stats -a
```

**2. Test S3 API access:**
```bash
# Replace <access-key> and <secret-key> with values from Step 6
KUBECONFIG=<your-kubeconfig> kubectl run aws-test --rm -i --image=amazon/aws-cli:latest \
  --restart=Never \
  --env AWS_ACCESS_KEY_ID=<access-key> \
  --env AWS_SECRET_ACCESS_KEY=<secret-key> -- \
  s3 ls --endpoint-url http://garage-s3.default.svc.cluster.local:3900

# Expected output: 4 buckets listed
# 2026-06-08 12:00:00 obsidian-notes
# 2026-06-08 12:00:00 postgres
# 2026-06-08 12:00:00 reactive-resume
# 2026-06-08 12:00:00 tofu-state
```

**3. Verify OMV Garage still running (zero impact):**
```bash
ssh root@omv-baymx 'kubectl get pod -n default -l app.kubernetes.io/name=garage'

# Should show: garage pod running
```

**4. Check logs for errors:**
```bash
KUBECONFIG=<your-kubeconfig> kubectl logs -n default $POD -c app --tail=50
KUBECONFIG=<your-kubeconfig> kubectl logs -n default $POD -c webui --tail=20
```

---

## Success Criteria ✅

After completing all steps, verify:

- [ ] Node k8s-5-1u is Ready
- [ ] 8 HDDs mounted: `/var/mnt/garage-hdd1` through `/var/mnt/garage-hdd8`
- [ ] Metadata mounted: `/var/mnt/garage-meta`
- [ ] Garage pod running with 2 containers (app + webui)
- [ ] Garage status shows 8 data directories
- [ ] 4 buckets created: reactive-resume, obsidian-notes, tofu-state, postgres
- [ ] S3 API test succeeds (can list buckets)
- [ ] S3 credentials saved securely
- [ ] OMV Garage still serving production traffic

---

## If Something Goes Wrong

### Pod fails to start

**Check:**
```bash
# Pod events
KUBECONFIG=<your-kubeconfig> kubectl describe pod -n default -l app.kubernetes.io/name=garage-s3

# ExternalSecret status
KUBECONFIG=<your-kubeconfig> kubectl get externalsecret garage-s3 -n default -o yaml

# Volume mounts
KUBECONFIG=<your-kubeconfig> kubectl get pod -n default -l app.kubernetes.io/name=garage-s3 \
  -o jsonpath='{.items[0].spec.volumes[*].name}' | tr ' ' '\n'
```

**Common issues:**
- ExternalSecret failing: Check 1Password item `garage-s3` exists with field `GARAGE_ADMIN_TOKEN`
- Volume mount errors: Verify Talos mounts exist (Step 3 verification)
- ImagePullBackOff: Check image tags in values.yaml

### Node won't reboot or mount volumes

**Rollback Talos config:**
```bash
# Apply backup config
talosctl --talosconfig clusters/talos/bootstrap/os/clusterconfig/talosconfig \
  apply-config \
  --nodes 10.30.30.25 \
  --file /tmp/backup-k8s-5-1u-*.yaml

# Wait for reboot
```

### Garage won't start

**Check Talos mounts:**
```bash
# List all mounts on node
talosctl --talosconfig clusters/talos/bootstrap/os/clusterconfig/talosconfig \
  -n 10.30.30.25 get mounts

# Check if disks are formatted
talosctl --talosconfig clusters/talos/bootstrap/os/clusterconfig/talosconfig \
  -n 10.30.30.25 ls /var/mnt/
```

---

## After Phase 1 Complete

**Before proceeding to Phase 2, ensure:**
1. ✅ Garage S3 pod running and healthy
2. ✅ S3 credentials saved
3. ✅ OMV Garage still serving traffic
4. ✅ Test S3 API works

**Then proceed to:** Phase 2 - Migrate small buckets (zero downtime)

---

## Quick Command Reference

```bash
# Useful commands during deployment:

# Check Talos version
talosctl --talosconfig <path> -n 10.30.30.25 version --short

# List mounts
talosctl --talosconfig <path> -n 10.30.30.25 get mounts | grep garage

# Get pod
KUBECONFIG=<path> kubectl get pod -n default -l app.kubernetes.io/name=garage-s3

# Logs
KUBECONFIG=<path> kubectl logs -n default <pod> -c app -f

# Garage status
KUBECONFIG=<path> kubectl exec -n default <pod> -c app -- /garage status
```

---

**Estimated Total Time:** 30-45 minutes  
**Impact:** k8s-5-1u reboot (~5-10 min), no production impact  
**Rollback Available:** Yes (restore Talos config backup)
