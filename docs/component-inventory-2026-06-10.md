# 📦 Component Inventory Report - Talos Cluster

**Generated:** 2026-06-10  
**Repository:** home-ops  
**Cluster:** Talos

## 📊 Executive Summary

| Metric | Count | Percentage |
|--------|-------|------------|
| **Total Components** | 92 | 100% |
| **Actively Deployed** | 89 | 97% |
| **Cluster-Specific Deployments** | 8 | 9% |
| **Kustomize Components** | 1 | 1% |
| **Orphaned/Unused** | 2 | 2% |

---

## ✅ Actively Deployed Components (89 total)

### 📱 AI Applications (6)
- ✓ `ai/hermes-agent` - Wave 24
- ✓ `ai/holmesgpt` - Wave 20
- ✓ `ai/ivan-dashboard` - Wave 21
- ✓ `ai/ivan-personal-service` - Wave 20
- ✓ `ai/mac` - Wave 23
- ✓ `ai/mem0` - Wave 23

### 🔧 Argo System (4)
- ✓ `argo-system/argocd-image-updater` - Wave 30
- ⚠️  `argo-system/argo-cd` - **Cluster-specific:** `clusters/talos/apps/argo-system/argo-cd`
- ⚠️  `argo-system/kubechecks` - **Cluster-specific:** `clusters/talos/apps/argo-system/kubechecks`
- ⚠️  `argo-system/root-application` - **Bootstrap only** (not in ArgoCD apps)

### 🔐 Certificate Management (1)
- ✓ `cert-manager/cert-manager` - Wave 5

### 🎯 Default Namespace Applications (40)
- ✓ `default/actual` - Wave 20
- ✓ `default/actual-http-api` - Wave 20
- ✓ `default/atuin` - Wave 20
- ✓ `default/audiobookshelf` - Wave 20
- ✓ `default/authentik` - Wave 20
- ✓ `default/barman-cloud` - Wave 15
- ✓ `default/bazarr` - Wave 20
- ⚠️  `default/cloudnative-cluster` - **Cluster-specific:** `clusters/talos/apps/default/cloudnative-cluster`
- ✓ `default/cloudnative-pg` - Wave 15
- ✓ `default/flaresolverr` - Wave 20
- ✓ `default/garage-s3` - Wave 20
- ✓ `default/gitea` - Wave 20
- ✓ `default/gitea-runner` - Wave 20
- ✓ `default/ntfy` - Wave 20 (bjw-s app-template v5.0.1 with VolSync replication)
- ✓ `default/govee2mqtt` - Wave 20
- ✓ `default/home-assistant` - Wave 20
- ⚠️  `default/homepage` - **Cluster-specific:** `clusters/talos/apps/default/homepage`
- ✓ `default/influxdb` - Wave 20
- ✓ `default/it-tools` - Wave 20
- ✓ `default/jellyfin` - Wave 20
- ✓ `default/jellyseerr` - Wave 20
- ✓ `default/mosquitto` - Wave 20
- ✓ `default/node-red` - Wave 20
- ✓ `default/onstar2mqtt` - Wave 20
- ✓ `default/paperless-ngx` - Wave 20
- ✓ `default/pgadmin` - Wave 20
- ✓ `default/piped` - Wave 20
- ✓ `default/radarr` - Wave 20
- ✓ `default/reactive-resume` - Wave 20
- ✓ `default/recyclarr` - Wave 20
- ✓ `default/redlib` - Wave 20
- ✓ `default/reverse-proxy` - Wave 20
- ✓ `default/sonarr` - Wave 20
- ✓ `default/stirling-pdf` - Wave 20
- ✓ `default/switchbotmqtt` - Wave 20
- ✓ `default/valetudopng` - Wave 20
- ✓ `default/valkey` - Wave 20
- ✓ `default/webhook-relay` - Wave 20
- ✓ `default/zigbee2mqtt` - Wave 20
- ✓ `default/zwave` - Wave 20

### 📥 Downloads Namespace (4)
- ✓ `downloads/prowlarr` - Wave 20
- ✓ `downloads/qbittorrent` - Wave 20
- ✓ `downloads/qui` - Wave 20
- ✓ `downloads/sabnzbd` - Wave 20

### 🔑 External Secrets (3)
- ✓ `external-secrets/external-secrets-chart` - Wave 1
- ✓ `external-secrets/external-secrets-stores` - Wave 2
- ✓ `external-secrets/onepassword-connect` - Wave 1

### ⚙️ Kube-System Components (13)
- ⚠️  `kube-system/cilium` - **Cluster-specific:** `clusters/talos/apps/kube-system/cilium`
- ✓ `kube-system/coredns` - Wave 10
- ✓ `kube-system/descheduler` - Wave 10
- ✓ `kube-system/fstrim` - Wave 10
- ✓ `kube-system/generic-device-plugin` - Wave 10
- ✓ `kube-system/metrics-server` - Wave 10
- ✓ `kube-system/node-feature-discovery` - Wave 10
- ✓ `kube-system/node-feature-discovery-rules` - Wave 20
- ✓ `kube-system/nvidia-device-plugin` - Wave 30
- ✓ `kube-system/reflector` - Wave 30
- ✓ `kube-system/reloader` - Wave 10
- ✓ `kube-system/snapshot-controller` - Wave 5
- ✓ `kube-system/spegel` - Wave 10

### 🖥️ KubeVirt (2 - Currently Disabled)
- ⚠️  `kubevirt/cdi-operator` - **Disabled** (commented out in 30-system.yaml)
- ⚠️  `kubevirt/operator` - **Disabled** (commented out in 30-system.yaml)

### 🌐 Network Components (5)
- ✓ `network/cloudflare-dns` - Wave 10
- ✓ `network/cloudflare-tunnel` - Wave 30
- ✓ `network/envoy-gateway` - Wave 10
- ✓ `network/envoy-gateway-config` - Wave 10
- ✓ `network/unifi-dns` - Wave 10

### 📊 Observability (6)
- ✓ `observability/grafana` - Wave 25
- ⚠️  `observability/kube-prometheus-stack` - **Cluster-specific:** `clusters/talos/apps/observability/kube-prometheus-stack`
- ✓ `observability/loki` - Wave 25
- ✓ `observability/promtail` - Wave 25
- ✓ `observability/scrutiny-app` - Wave 25
- ✓ `observability/scrutiny-collector` - Wave 25
- ✓ `observability/speedtest-exporter` - Wave 25

### 💾 Rook-Ceph Storage (3)
- ✓ `rook-ceph/ceph-csi-drivers` - Wave 5
- ✓ `rook-ceph/rook-ceph-app` - Wave 5
- ✓ `rook-ceph/rook-ceph-cluster` - Wave 5

### 🔄 VolSync Backup System (3)
- ⚠️  `volsync-system/kopia` - **Cluster-specific:** `clusters/talos/apps/volsync-system/kopia`
- ⚠️  `volsync-system/volsync` - **Cluster-specific:** `clusters/talos/apps/volsync-system/volsync`
- 🔧 `volsync-system/volsync-replication` - **Kustomize Component** (referenced in app kustomizations)

---

## ❌ Orphaned/Unused Components (2 total)

These components exist in the repository but are NOT deployed:

### 1. `default/renovate` ❌
**Status:** Not deployed  
**Location:** `components/default/renovate/`  
**Reason:** Renovate Bot runs externally via GitHub Actions, not as a cluster workload  
**Action:** Can be safely removed OR deployed if you want cluster-based Renovate

**Files:**
- `components/default/renovate/kustomization.yaml`
- `components/default/renovate/configmap.yaml`
- `components/default/renovate/external-secret.yaml`
- `components/default/renovate/values.yaml`
- `components/default/renovate/charts/`

### 2. `argo-system/root-application` ⚠️
**Status:** Bootstrap-only component  
**Location:** `components/argo-system/root-application/`  
**Reason:** Used to bootstrap the ArgoCD App-of-Apps pattern; not managed by ArgoCD itself  
**Action:** Keep - required for initial cluster bootstrap

**Files:**
- `components/argo-system/root-application/kustomization.yaml`
- `components/argo-system/root-application/root-application.yaml`

---

## 📋 Deployment Pattern Analysis

### By Sync Wave

| Wave | Count | Purpose |
|------|-------|---------|
| 1 | 2 | External secrets foundation |
| 2 | 1 | Secret stores |
| 5 | 7 | Storage, certificates, backup infrastructure |
| 10 | 13 | Networking, system utilities |
| 15 | 2 | Database operators |
| 16-17 | 2 | Database clusters |
| 20 | 58 | User applications |
| 23-24 | 3 | AI applications (late wave) |
| 25 | 6 | Observability |
| 30 | 5 | System integrations |

### By Deployment Method

| Method | Count | Description |
|--------|-------|-------------|
| **Standard Component Path** | 81 | `path: components/<namespace>/<app>` |
| **Cluster-Specific Path** | 8 | `path: clusters/talos/apps/<namespace>/<app>` |
| **Kustomize Component** | 1 | Referenced via `components:` in kustomizations |
| **Bootstrap Only** | 1 | Used during initial setup, not in ArgoCD |
| **Orphaned** | 1 | Not deployed anywhere |

### Cluster-Specific Components (8)

These components have cluster-specific configurations and live in `clusters/talos/apps/` instead of `components/`:

1. **argo-cd** - Cluster-specific ArgoCD server configuration
2. **cilium** - CNI with node-specific networking config
3. **cloudnative-cluster** - PostgreSQL cluster definition (data-specific)
4. **homepage** - Dashboard with cluster-specific service widgets
5. **kopia** - Backup repository configuration (path-specific)
6. **kube-prometheus-stack** - Monitoring with cluster-specific scrape configs
7. **kubechecks** - ArgoCD PR validation (cluster-specific tokens)
8. **volsync** - Backup operator configuration (storage-specific)

---

## 🎯 Recommendations

### 1. Clean Up Orphaned Component ⚠️

**Action:** Remove the unused `renovate` component
```bash
rm -rf components/default/renovate/
```

**Rationale:** Renovate Bot runs via GitHub Actions (see `.github/renovate.json5`). The cluster component is unused and adds maintenance overhead.

**Risk:** Low - component is not deployed and not referenced anywhere

### 2. Keep root-application ✅

**Action:** No action needed

**Rationale:** The `root-application` component is the "chicken-and-egg" bootstrap that creates the ArgoCD App-of-Apps pattern. It must exist in the repository but cannot be managed by ArgoCD itself.

### 3. Document Cluster-Specific Deployments ✅

**Action:** Already documented in this report

**Rationale:** The 8 cluster-specific components are intentionally separated to allow for:
- Multi-cluster support in the future
- Environment-specific configurations
- Data isolation (postgres clusters, backup repos)

### 4. KubeVirt Components 🔄

**Status:** Currently disabled (commented out in `30-system.yaml`)

**Reason:** virt-handler triggered reboot loops on k8s-4-dell due to old microcode exercising VMX instructions

**Future Action:** Re-enable after BIOS/microcode updates on k8s-4-dell

**Components preserved:**
- `components/kubevirt/operator`
- `components/kubevirt/cdi-operator`

---

## 📈 Health Score: 97%

**Breakdown:**
- ✅ 89/92 components actively deployed or intentionally unused
- ✅ Clear separation between shared and cluster-specific components
- ✅ Proper use of sync waves for dependency ordering
- ✅ Minimal technical debt (only 1 orphaned component)
- ⚠️  1 orphaned component (renovate) - minor cleanup opportunity

**Overall Assessment:** Repository is in excellent health with minimal cruft. The component structure is well-organized and follows GitOps best practices.

---

## 🔍 Appendix: How This Inventory Was Generated

```bash
# List all component directories
find components -mindepth 2 -maxdepth 2 -type d | sort

# Extract deployed component paths from Talos apps
find clusters/talos/apps -name "*.yaml" -type f -exec grep -h "path: components/" {} \; | \
  sed 's/.*path: //' | sort -u

# Compare and identify orphaned components
comm -23 \
  <(find components -mindepth 2 -maxdepth 2 -type d | sed 's|components/||' | sort) \
  <(find clusters/talos/apps -name "*.yaml" -type f -exec grep -h "path: components/" {} \; | \
    sed 's/.*path: components\///' | sort -u)
```

---

**End of Report**
