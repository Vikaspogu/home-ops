# Kubechecks GitHub Webhook Setup Guide

**Last Updated:** 2026-06-10  
**Security Level:** Production-ready with IP whitelisting + webhook secret validation

## 📋 Overview

Kubechecks is configured for **direct GitHub webhook integration** with two layers of security:

1. **IP Whitelisting** - Only GitHub's webhook IP ranges can reach kubechecks
2. **Webhook Secret Validation** - GitHub signs webhook payloads with a shared secret

This setup replaces the previous architecture:
- ❌ **Old:** GitHub Actions → webhook-relay → kubechecks (complex, high latency)
- ✅ **New:** GitHub → kubechecks (direct, secure, low latency)

---

## 🔐 Security Architecture

### Layer 1: Envoy Gateway SecurityPolicy

**File:** `components/argo-system/kubechecks/security-policy.yaml`

Restricts access to kubechecks webhook endpoint to GitHub's official IP ranges:

```yaml
authorization:
  defaultAction: Deny  # Deny all traffic by default
  rules:
    - name: allow-github-webhooks
      action: Allow
      principal:
        clientCIDRs:
          - "192.30.252.0/22"   # GitHub hooks
          - "185.199.108.0/22"  # GitHub Pages/hooks
          - "140.82.112.0/20"   # GitHub services
          - "143.55.64.0/20"    # GitHub services
          - "2a0a:a440::/29"    # GitHub IPv6
          - "2606:50c0::/32"    # GitHub IPv6
```

**Update frequency:** GitHub IP ranges change occasionally. Update from:
```bash
curl -s https://api.github.com/meta | jq -r '.hooks[]'
```

### Layer 2: Webhook Secret Validation

**Configuration:** `components/argo-system/kubechecks/values.yaml`

```yaml
KUBECHECKS_VCS_WEBHOOK_SECRET_KEY: "KUBECHECKS_WEBHOOK_SECRET"
```

Kubechecks validates the `X-Hub-Signature-256` header in each webhook payload against the shared secret.

---

## 🚀 Setup Instructions

### 1. Generate Webhook Secret

```bash
# Generate a strong random secret (32 bytes, hex-encoded)
openssl rand -hex 32
```

**Example output:**
```
a7f3b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1
```

### 2. Store Secret in 1Password

Add the webhook secret to your `kubechecks` 1Password item:

```yaml
Item Name: kubechecks
Fields:
  - K8S_TOKEN: <github-personal-access-token>
  - KUBECHECKS_WEBHOOK_SECRET: <secret-from-step-1>
```

**Using 1Password CLI:**
```bash
op item edit kubechecks KUBECHECKS_WEBHOOK_SECRET=<your-secret>
```

### 3. Verify ExternalSecret Sync

After committing and ArgoCD syncs:

```bash
# Check ExternalSecret status
kubectl get externalsecret -n argo-system kubechecks

# Verify secret was created with webhook secret
kubectl get secret -n argo-system kubechecks -o jsonpath='{.data.KUBECHECKS_WEBHOOK_SECRET}' | base64 -d
```

### 4. Configure GitHub Repository Webhook

#### A. Navigate to Repository Settings

1. Go to your GitHub repository: `https://github.com/<owner>/home-ops`
2. Click **Settings** → **Webhooks** → **Add webhook**

#### B. Configure Webhook

| Field | Value |
|-------|-------|
| **Payload URL** | `https://kubechecks.${CLUSTER_DOMAIN}/hooks/github` |
| **Content type** | `application/json` |
| **Secret** | `<paste-secret-from-step-1>` |
| **SSL verification** | ✅ Enable SSL verification |

#### C. Select Events

Choose **Let me select individual events:**

- ✅ `Pull requests`
- ✅ `Pull request reviews`
- ✅ `Pull request review comments`
- ✅ `Issue comments`
- ✅ `Pushes` (optional, for post-merge cleanup)

#### D. Save Webhook

- ✅ Check **Active**
- Click **Add webhook**

### 5. Test Webhook

#### A. Trigger Test Event

GitHub automatically sends a `ping` event when you create the webhook. Check the webhook's **Recent Deliveries** tab:

- ✅ Green checkmark = Success (200 OK)
- ❌ Red X = Failure

#### B. Test with Real PR

```bash
# Create a test branch
git checkout -b test/kubechecks-webhook

# Make a trivial change
echo "# Test" >> README.md
git add README.md
git commit -m "test: kubechecks webhook validation"
git push origin test/kubechecks-webhook

# Create PR on GitHub
# Check PR for kubechecks comments
```

Expected behavior:
- Kubechecks posts a comment on the PR within 5-10 seconds
- Comment shows ArgoCD diff for changed applications
- Security Policy allows traffic (GitHub IPs pass filter)
- Webhook signature validates successfully

---

## 🔍 Verification & Troubleshooting

### Check Kubechecks Logs

```bash
# Watch kubechecks logs in real-time
kubectl logs -n argo-system -l app.kubernetes.io/name=kubechecks -f

# Look for webhook events
kubectl logs -n argo-system -l app.kubernetes.io/name=kubechecks | grep "webhook"
```

### Verify Security Policy

```bash
# Check SecurityPolicy is applied
kubectl get securitypolicy -n argo-system kubechecks-github-ip-whitelist

# View policy details
kubectl describe securitypolicy -n argo-system kubechecks-github-ip-whitelist
```

### Test IP Whitelisting

```bash
# This should FAIL (your IP is not in GitHub's range)
curl -X POST https://kubechecks.${CLUSTER_DOMAIN}/hooks/github \
  -H "Content-Type: application/json" \
  -d '{"test": "data"}'

# Expected: 403 Forbidden or connection timeout
```

### Test from GitHub IP Range (requires proxy)

If you have access to a server in GitHub's IP range:

```bash
# This should reach kubechecks (but fail signature validation)
curl -X POST https://kubechecks.${CLUSTER_DOMAIN}/hooks/github \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: ping" \
  -d '{"zen": "test"}'

# Expected: 400 Bad Request (invalid signature)
```

### Common Issues

#### Issue 1: Webhook Deliveries Show 403 Forbidden

**Cause:** GitHub IP ranges have changed and SecurityPolicy is outdated

**Solution:**
```bash
# Fetch current GitHub IP ranges
curl -s https://api.github.com/meta | jq -r '.hooks[]'

# Update components/argo-system/kubechecks/security-policy.yaml
# with new IP ranges, commit, and sync
```

#### Issue 2: Webhook Deliveries Show 401 Unauthorized

**Cause:** Webhook secret mismatch

**Solution:**
```bash
# Verify secret in 1Password matches GitHub webhook configuration
op item get kubechecks --fields KUBECHECKS_WEBHOOK_SECRET

# Regenerate secret if needed:
openssl rand -hex 32 | tee >(op item edit kubechecks KUBECHECKS_WEBHOOK_SECRET[concealed]=-)

# Update GitHub webhook secret in repository settings
```

#### Issue 3: Kubechecks Not Posting Comments

**Cause:** Insufficient GitHub token permissions

**Solution:**
```bash
# GitHub PAT needs these scopes:
# - repo (Full control of private repositories)
# - write:discussion (Write access to discussions)

# Regenerate token with correct scopes and update 1Password:
op item edit kubechecks K8S_TOKEN[concealed]=<new-token>
```

---

## 📊 Monitoring

### Prometheus Metrics

Kubechecks exposes metrics at `:8080/metrics`:

```promql
# Webhook request rate
rate(kubechecks_webhook_requests_total[5m])

# Webhook error rate
rate(kubechecks_webhook_errors_total[5m])

# Comment posting latency
histogram_quantile(0.95, kubechecks_comment_post_duration_seconds_bucket)
```

### Alerting (Optional)

```yaml
# Add to kube-prometheus-stack
- alert: KubechecksWebhookFailureRate
  expr: |
    rate(kubechecks_webhook_errors_total[5m]) > 0.1
  for: 5m
  annotations:
    summary: "Kubechecks webhook failure rate > 10%"
```

---

## 🔄 Maintenance

### Update GitHub IP Ranges (Quarterly)

```bash
# 1. Fetch latest IPs
curl -s https://api.github.com/meta | jq -r '.hooks[]'

# 2. Compare with security-policy.yaml
diff <(curl -s https://api.github.com/meta | jq -r '.hooks[]' | sort) \
     <(yq '.spec.authorization.rules[0].principal.clientCIDRs[]' \
        components/argo-system/kubechecks/security-policy.yaml | sort)

# 3. Update security-policy.yaml if changed
# 4. Commit and ArgoCD will sync
```

### Rotate Webhook Secret (Annually)

```bash
# 1. Generate new secret
NEW_SECRET=$(openssl rand -hex 32)

# 2. Update 1Password
echo $NEW_SECRET | op item edit kubechecks KUBECHECKS_WEBHOOK_SECRET[concealed]=-

# 3. Wait for ExternalSecret to sync (~1 minute)
kubectl get secret -n argo-system kubechecks -o yaml | grep -A1 KUBECHECKS_WEBHOOK_SECRET

# 4. Update GitHub webhook secret (no downtime during this step)
# Settings → Webhooks → Edit → Update Secret field → Update webhook

# 5. Verify webhook deliveries succeed
```

---

## 🏗️ Architecture Comparison

### Before (Multi-Cluster with Relay)

```
GitHub Actions Workflow
        ↓ (webhook POST)
  webhook-relay Pod
        ↓ (forward to cluster-specific kubechecks)
  kubechecks-omv OR kubechecks-talos
        ↓ (ArgoCD API call)
  ArgoCD
        ↓ (render manifests)
  PR Comment
```

**Issues:**
- Complex: 3-component chain
- Slow: ~10-15 second latency
- Fragile: Any component failure breaks checks

### After (Single Cluster Direct)

```
GitHub Webhook
        ↓ (direct HTTPS POST)
  Envoy Gateway (IP whitelist)
        ↓ (if IP allowed)
  kubechecks (validate secret)
        ↓ (ArgoCD API call)
  ArgoCD
        ↓ (render manifests)
  PR Comment
```

**Benefits:**
- ✅ Simple: 2-component chain
- ✅ Fast: ~3-5 second latency
- ✅ Secure: Two-layer validation (IP + secret)
- ✅ Reliable: Fewer failure points

---

## 📝 Configuration Files Reference

### Components Changed

| File | Change | Purpose |
|------|--------|---------|
| `components/argo-system/kubechecks/http-route.yaml` | Use external gateway | Expose publicly |
| `components/argo-system/kubechecks/security-policy.yaml` | **NEW** | IP whitelist |
| `components/argo-system/kubechecks/values.yaml` | Add webhook secret env | Enable validation |
| `components/argo-system/kubechecks/externalsecret.yaml` | Add secret field | Inject from 1Password |
| `clusters/talos/apps/argo-system/kubechecks/kustomization.yaml` | Remove patch | Single cluster = no patch needed |

### Components Removed

| Component | Reason |
|-----------|--------|
| `.github/workflows/pr-webhook.yaml` | Direct webhooks = no GitHub Actions needed |
| `components/default/webhook-relay/` | No longer needed (direct integration) |
| Application registration in `20-applications.yaml` | Component removed |

---

## 🔗 External References

- **Kubechecks Documentation:** https://github.com/zapier/kubechecks
- **GitHub Webhook IPs:** https://api.github.com/meta → `hooks[]`
- **Envoy Gateway SecurityPolicy:** https://gateway.envoyproxy.io/latest/api/extension_types/#securitypolicy
- **GitHub Webhook Events:** https://docs.github.com/webhooks/webhook-events-and-payloads

---

## ✅ Post-Deployment Checklist

After committing and ArgoCD syncs:

- [ ] Verify ExternalSecret synced: `kubectl get externalsecret -n argo-system kubechecks`
- [ ] Verify secret contains webhook secret: `kubectl get secret -n argo-system kubechecks -o yaml`
- [ ] Verify SecurityPolicy applied: `kubectl get securitypolicy -n argo-system`
- [ ] Verify HTTPRoute uses external gateway: `kubectl get httproute -n argo-system kubechecks -o yaml`
- [ ] Configure GitHub webhook in repository settings
- [ ] Test webhook with `ping` event (should succeed)
- [ ] Create test PR (should get kubechecks comment within 10s)
- [ ] Verify IP whitelist blocks non-GitHub IPs
- [ ] Remove webhook-relay from GitHub secrets (no longer needed)

---

**Status:** Ready for production deployment 🚀
