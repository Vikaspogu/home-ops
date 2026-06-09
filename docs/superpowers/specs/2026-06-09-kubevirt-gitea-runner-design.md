# KubeVirt Deployment + Gitea Runner Rootless DinD Design

**Created:** 2026-06-09  
**Status:** Approved (verbal) — ready for implementation planning  
**Related:** Research notes at `/tmp/kubevirt-sysbox-research/research-notes.md` (local)

---

## Executive Summary

Deploy KubeVirt on Talos cluster for VM workload support and fix gitea-runner's privileged Docker-in-Docker security issues by migrating to rootless DinD.

**Goals:**
1. Enable VM workloads on Talos cluster (k8s-4-dell + k8s-5-1u initially, k8s-6-omv in Phase 2 post-OMV-migration)
2. Remove privileged security context from gitea-runner by switching to rootless Docker-in-Docker

**Non-Goals (deferred to later phases):**
- KubeVirt bridge networking (requires Talos machine config changes)
- Multus CNI integration
- VM migration automation
- KubeVirt VMs for gitea-runner jobs (Option C — only if rootless DinD proves insufficient)

---

## Background

### Problem 1: No VM Workload Support

The Talos cluster currently has no mechanism to run VM-based workloads. KubeVirt enables running traditional VMs alongside containers, which is useful for:
- Workloads requiring full OS isolation
- Testing OS-level configurations
- Running software incompatible with containerization
- Future potential: isolated CI/CD job environments (if rootless DinD proves insufficient)

Hardware verification confirmed both k8s-4-dell and k8s-5-1u have VT-x and `/dev/kvm` support.

### Problem 2: Gitea Runner Privileged DinD

Current gitea-runner deployment uses privileged Docker-in-Docker (`docker:29-dind` sidecar with `privileged: true`) for CI/CD jobs that build container images. This creates security risks:
- Privileged containers can escape to the host
- No isolation between concurrent jobs
- Violates principle of least privilege

**Sysbox investigation:** Sysbox (unprivileged system containers) was explored as an alternative but is **NOT supported on Talos** — requires containerd config patching and systemd services incompatible with Talos's immutable OS model. Zero community precedent for Talos integration.

**Selected solution:** Migrate to rootless Docker-in-Docker (`docker:dind-rootless`), which removes the privileged requirement while maintaining Docker Compose and `docker run` support needed by existing Gitea Actions workflows.

---

## Design

### 1. KubeVirt Deployment Architecture

**Components:**
1. **KubeVirt Operator** — manages KubeVirt lifecycle, installs VirtualMachine and VirtualMachineInstance CRDs
2. **KubeVirt CR** — cluster-wide configuration for KubeVirt features (CustomResources, API server, controllers)
3. **CDI Operator** (Containerized Data Importer) — handles VM disk image imports from HTTP/S3/registry sources, PVC cloning

**Storage Strategy:**
- **Primary:** Existing Rook-Ceph `ceph-block` StorageClass for VM PVCs (supports RWO, snapshots, cloning)
- **Optional (Phase 2):** `local-path-provisioner` for CDI scratch space (temporary import volumes) — not strictly required (CDI can use ceph-block, but local storage is faster for ephemeral imports)

**Node Selection:**
- **Phase 1 (this spec):** Target nodes `k8s-4-dell` and `k8s-5-1u` (both have VT-x + `/dev/kvm` verified)
- **Phase 2 (post-OMV-migration):** Add `k8s-6-omv` once ex-OMV hardware is reimaged as Talos worker

**Talos-Specific Considerations:**
- Talos v1.13 officially supports KubeVirt ([docs](https://docs.siderolabs.com/talos/v1.13/advanced-guides/install-kubevirt))
- No OS-level config changes needed for basic pod-network VMs
- **Bridge networking (deferred):** Requires Talos machine config `network.interfaces` changes + Multus CNI — not in scope for Phase 1

**Networking:**
- VMs use pod network (Cilium CNI) by default — VM gets a pod IP, accessible via K8s Services
- External access via Gateway API HTTPRoutes (same as containerized apps)
- **No bridge mode networking in Phase 1** (would require Talos machine config + Multus)

**Features Enabled:**
- `LiveMigration` — allows VM migration between nodes (requires shared storage ✓ we have Ceph)
- `Snapshot` — VM disk snapshots via VolumeSnapshot API (ceph-block supports this ✓)
- **Not enabled:** `NetworkBindingPlugins` (requires Multus for bridge/SR-IOV)

---

### 2. Gitea Runner Rootless DinD Refactor

**Current State:**
```yaml
# components/gitea/gitea-runner/values.yaml (simplified)
containers:
  dind:
    image:
      repository: docker
      tag: 29-dind        # ← privileged DinD
    securityContext:
      privileged: true     # ← SECURITY RISK
```

**Target State:**
```yaml
containers:
  dind:
    image:
      repository: docker
      tag: dind-rootless   # ← rootless DinD
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    env:
      DOCKER_TLS_CERTDIR: ""  # disable TLS (unix socket only)
```

**Key Changes:**
1. **Image tag:** `29-dind` → `dind-rootless`
2. **Security context:** Remove `privileged: true`, add non-root user constraints
3. **Storage driver:** Rootless DinD defaults to `fuse-overlayfs` (not `overlay2`) — slower but works without privilege
4. **Filesystem requirements:** Rootless DinD requires cgroupv2 ✓ (Talos has this by default)

**Trade-offs:**
- **Pro:** No privileged containers, better job isolation, smaller attack surface
- **Con:** ~10-15% slower image builds (fuse-overlayfs vs overlay2), some Docker features unavailable (e.g. `--pid=host`, cgroup manipulation)
- **Acceptable:** Gitea Actions workflows don't use advanced Docker features; slight build slowdown is acceptable for security gain

**Rollback Plan:**
If rootless DinD proves insufficient (e.g., workflows fail due to missing features), we can:
1. Revert to privileged DinD (short-term)
2. Implement Option C (KubeVirt VMs for runner jobs) once KubeVirt is stable — full isolation, no privilege escalation

---

### 3. Component Manifest Structure (KubeVirt)

Following home-ops conventions, KubeVirt components will be organized as:

```
components/kube-system/kubevirt/
├── kustomization.yaml          # Kustomize remote base + patches
├── kubevirt-cr.yaml            # KubeVirt CustomResource (features config)
└── operator-patch.yaml         # Node selector patches if needed

components/kube-system/cdi/
├── kustomization.yaml          # CDI operator remote base
└── cdi-cr.yaml                 # CDI CustomResource (config)
```

**ArgoCD Application Registration:**
```yaml
# clusters/talos/apps/10-kube-system.yaml (new entries)
- name: kubevirt
  namespace: argo-system
  project: default
  source:
    path: components/kube-system/kubevirt
    repoURL: https://github.com/vikaspogu/home-ops
    targetRevision: main
  destination:
    namespace: kubevirt
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5

- name: cdi
  namespace: argo-system
  project: default
  source:
    path: components/kube-system/cdi
    repoURL: https://github.com/vikaspogu/home-ops
    targetRevision: main
  destination:
    namespace: cdi
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
```

**Sync-wave:** These are cluster infrastructure components (same tier as Cilium, Traefik) → register in `10-kube-system.yaml` sync-wave (not `20-applications.yaml`).

---

### 4. Testing Strategy

#### KubeVirt Validation

**Test 1: Operator Health**
```bash
kubectl get pods -n kubevirt
kubectl get pods -n cdi
kubectl get kubevirt -n kubevirt
kubectl get cdi -n cdi
```
Expected: All pods `Running`, KubeVirt CR shows `Phase: Deployed`, CDI CR shows `Phase: Deployed`

**Test 2: Basic VM (Cirros minimal Linux)**
Create a test VM using Cirros cloud image (minimal footprint, fast boot):
```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-cirros
  namespace: default
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/vm: test-cirros
    spec:
      domain:
        devices:
          disks:
          - disk:
              bus: virtio
            name: containerdisk
          - disk:
              bus: virtio
            name: cloudinitdisk
        resources:
          requests:
            memory: 128Mi
            cpu: "1"
      volumes:
      - name: containerdisk
        containerDisk:
          image: quay.io/kubevirt/cirros-container-disk-demo
      - name: cloudinitdisk
        cloudInitNoCloud:
          userDataBase64: SGkuXG4=  # "Hi.\n"
```

Validation:
```bash
kubectl get vms
kubectl get vmis
virtctl console test-cirros   # login: cirros / gocubsgo
# Inside VM: ping 8.8.8.8 (verify networking)
kubectl delete vm test-cirros
```
Expected: VM boots, network works, deletion succeeds.

**Test 3: PVC-backed VM (Ceph storage)**
Create a VM with a PVC disk (tests Ceph integration):
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-vm-disk
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-block
  resources:
    requests:
      storage: 1Gi
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-pvc-vm
spec:
  running: false
  template:
    spec:
      domain:
        devices:
          disks:
          - disk: {bus: virtio}
            name: datadisk
        resources:
          requests:
            memory: 128Mi
      volumes:
      - name: datadisk
        persistentVolumeClaim:
          claimName: test-vm-disk
```

Validation:
```bash
kubectl get pvc test-vm-disk  # should be Bound to Ceph RBD
virtctl start test-pvc-vm
kubectl get vmi test-pvc-vm   # should show Running
virtctl stop test-pvc-vm
kubectl delete vm test-pvc-vm
kubectl delete pvc test-vm-disk
```
Expected: PVC binds to Ceph, VM boots from PVC disk, cleanup succeeds.

**Test 4: LiveMigration (if >1 node available)**
```bash
virtctl migrate test-cirros
kubectl get virtualmachineinstancemigration
```
Expected: VM migrates to another node without downtime (requires shared Ceph storage ✓).

#### Gitea Runner Validation

**Test 1: Deployment Health**
```bash
kubectl get pods -n gitea -l app.kubernetes.io/name=gitea-runner
kubectl logs -n gitea <runner-pod> -c dind   # check for rootless DinD startup logs
```
Expected: Pod `Running`, dind container logs show `dockerd-rootless.sh` startup, no privilege warnings.

**Test 2: Security Context Verification**
```bash
kubectl get pod -n gitea <runner-pod> -o jsonpath='{.spec.containers[?(@.name=="dind")].securityContext}'
```
Expected: `privileged: false` (or absent), `runAsNonRoot: true`, `capabilities.drop: [ALL]`.

**Test 3: Functional CI Job (Docker Build)**
Trigger a Gitea Actions workflow that builds a container image (e.g., any repo with a Dockerfile and `.gitea/workflows/build.yaml`):
```yaml
# Example workflow
name: Test Rootless Build
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Build image
        run: docker build -t test:latest .
      - name: Run container
        run: docker run --rm test:latest echo "Success"
```

Validation:
- Workflow completes successfully ✓
- Check runner pod logs for build output
- Confirm no privilege-related errors

**Test 4: Docker Compose Workflow**
Trigger a workflow using Docker Compose (validates multi-container scenarios):
```yaml
# .gitea/workflows/compose-test.yaml
name: Test Compose
on: [push]
jobs:
  compose:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Docker Compose Up
        run: docker compose up -d
      - name: Test Service
        run: curl http://localhost:8080/health
      - name: Docker Compose Down
        run: docker compose down
```

Expected: Compose stack starts, health check passes, teardown succeeds.

---

### 5. Deployment Order & Dependencies

**Phase 1: KubeVirt Infrastructure (can proceed immediately)**
1. Create `components/kube-system/kubevirt/` manifests
2. Create `components/kube-system/cdi/` manifests
3. Register ArgoCD applications in `clusters/talos/apps/10-kube-system.yaml`
4. Commit + push → ArgoCD syncs
5. Run validation tests (operator health → Cirros VM → PVC VM → migration)

**Phase 2: Gitea Runner Refactor (independent, can run in parallel)**
1. Edit `components/gitea/gitea-runner/values.yaml` (image tag + securityContext changes)
2. Commit + push → ArgoCD syncs gitea-runner
3. Run validation tests (pod health → security context → build job → compose job)
4. Monitor production CI jobs for 24-48h for failures

**Dependencies:**
- KubeVirt and gitea-runner refactor are **independent** — can be deployed in parallel or sequential order
- No shared state between the two features
- If gitea-runner rootless DinD fails, we can revert independently of KubeVirt

---

### 6. Resource Requirements

#### KubeVirt Control Plane (estimated)
- **virt-operator:** 1 replica, ~100Mi memory, ~10m CPU
- **virt-api:** 2 replicas (HA), ~200Mi memory each, ~100m CPU each
- **virt-controller:** 2 replicas (HA), ~250Mi memory each, ~200m CPU each
- **virt-handler:** DaemonSet (1 per KubeVirt-enabled node), ~200Mi memory, ~10m CPU
  - Phase 1: 2 nodes (dell + 1u) → 2 virt-handler pods
  - Phase 2: 3 nodes (+ ex-OMV) → 3 virt-handler pods

**Total overhead (Phase 1):** ~1.2GB memory, ~0.6 CPU cores (control plane + 2 handlers)

#### CDI Control Plane (estimated)
- **cdi-operator:** 1 replica, ~150Mi memory, ~10m CPU
- **cdi-apiserver:** 1 replica, ~150Mi memory, ~50m CPU
- **cdi-deployment:** 1 replica, ~250Mi memory, ~100m CPU
- **cdi-uploadproxy:** 1 replica, ~150Mi memory, ~50m CPU

**Total overhead:** ~700MB memory, ~0.2 CPU cores

#### VM Workloads (user-defined)
- VMs consume resources per their spec (e.g., `memory: 2Gi, cpu: 2` → 2GB memory, 2 CPU cores)
- Overhead: ~100Mi memory + 10-20% CPU per VM for QEMU/libvirt processes

#### Gitea Runner DinD (no change)
- Current DinD sidecar: ~500Mi memory, ~1 CPU (spikes during builds)
- Rootless DinD: Same resource profile (fuse-overlayfs adds ~5-10% CPU overhead)

**Cluster headroom check (pre-deployment):**
```bash
kubectl top nodes
kubectl describe nodes k8s-4-dell k8s-5-1u | grep -A5 "Allocated resources"
```
Expected: Sufficient free memory (~2GB+) and CPU (~1 core+) for KubeVirt + CDI control plane.

---

### 7. Monitoring & Observability

#### KubeVirt Metrics (Prometheus)
KubeVirt exports metrics to Prometheus (if `prometheus-operator` ServiceMonitor CRDs exist):
- `kubevirt_vmi_phase_count{phase="Running"}` — count of running VMs
- `kubevirt_vmi_vcpu_seconds` — CPU usage per VM
- `kubevirt_vmi_memory_resident_bytes` — memory usage per VM
- `kubevirt_vmi_storage_*` — disk I/O metrics

**Action (optional):** Create ServiceMonitor for virt-handler if Prometheus Operator is installed.

#### Gitea Runner Logs
- **Pre-change:** `kubectl logs -n gitea <runner-pod> -c dind` shows privileged dockerd logs
- **Post-change:** Should show `dockerd-rootless.sh` startup, rootlesskit messages

**Alert on:** Repeated job failures, OOMKilled dind containers (would indicate fuse-overlayfs memory leak)

---

### 8. Security Considerations

#### KubeVirt
- **Isolation:** VMs run in QEMU processes within pods, leveraging kernel namespaces + cgroups (same as containers)
- **Attack surface:** QEMU has a larger attack surface than containerized apps; keep KubeVirt version updated
- **Network policies:** VMs respect K8s NetworkPolicies (Cilium enforces at pod level)
- **Multi-tenancy:** If running untrusted VMs, consider dedicated nodes or RuntimeClass segregation (out of scope for Phase 1)

#### Gitea Runner Rootless DinD
- **Privilege removed:** No `privileged: true`, no CAP_SYS_ADMIN
- **Remaining risk:** fuse-overlayfs kernel module bugs (rare but possible) — keep kernel updated
- **Job isolation:** Still shared kernel (not as strong as VMs) — malicious workflows could potentially escape via kernel exploit
  - Mitigation (future): Move to KubeVirt VMs for runner jobs (Option C) if this becomes a concern

---

### 9. Rollback Plans

#### KubeVirt Rollback
If KubeVirt causes cluster instability or resource exhaustion:
1. Scale down any user-created VMs: `kubectl get vms --all-namespaces` → `virtctl stop <vm-name>`
2. Delete ArgoCD apps: `kubectl delete application kubevirt cdi -n argo-system`
3. Manually delete CRDs if ArgoCD prune fails: `kubectl delete crd virtualmachines.kubevirt.io ...`
4. Revert Git commits for `components/kube-system/{kubevirt,cdi}/` and `clusters/talos/apps/10-kube-system.yaml`

**Data loss risk:** LOW — deleting KubeVirt does NOT delete PVCs; VM disks (if on PVCs) remain intact.

#### Gitea Runner Rollback
If rootless DinD breaks CI jobs:
1. Revert `components/gitea/gitea-runner/values.yaml` changes:
   - `tag: dind-rootless` → `tag: 29-dind`
   - Restore `privileged: true`, remove rootless securityContext
2. Commit + push → ArgoCD syncs
3. Verify existing CI jobs resume working

**Data loss risk:** NONE — no persistent state in runner pods.

---

### 10. Success Criteria

**KubeVirt Deployment Complete When:**
- ✅ KubeVirt operator running, KubeVirt CR `Phase: Deployed`
- ✅ CDI operator running, CDI CR `Phase: Deployed`
- ✅ virt-handler pods running on k8s-4-dell and k8s-5-1u
- ✅ Test VM (Cirros) boots successfully, network works
- ✅ PVC-backed VM (ceph-block) boots successfully
- ✅ LiveMigration test succeeds (if multi-node)
- ✅ No cluster resource exhaustion (CPU/memory headroom remains >10%)

**Gitea Runner Refactor Complete When:**
- ✅ Runner pod running with `dind-rootless` image
- ✅ SecurityContext shows `privileged: false`, `runAsNonRoot: true`
- ✅ Test Docker build job succeeds
- ✅ Test Docker Compose job succeeds
- ✅ Production CI jobs run successfully for 48h with no privilege-related failures
- ✅ No performance regression >20% (acceptable fuse-overlayfs overhead)

---

## Open Questions / Decisions Needed

**Q1: Do we create a dedicated ServiceAccount for KubeVirt VMs?**
- **Default:** VMs run with `default` ServiceAccount in their namespace
- **Recommendation:** Use default for Phase 1; add dedicated SA if multi-tenancy becomes a concern

**Q2: Should we enable KubeVirt's experimental features (e.g., GPU passthrough, CPU pinning)?**
- **Recommendation:** NO — not needed for initial use cases, can enable later via KubeVirt CR patch

**Q3: Do we need separate node pools for VMs (taints/tolerations)?**
- **Recommendation:** NO — VMs can coexist with containerized workloads; use nodeSelector to target specific nodes if needed

**Q4: Should gitea-runner have resource limits increased to account for fuse-overlayfs overhead?**
- **Current limits:** Memory ~2Gi, CPU ~2
- **Recommendation:** Keep current limits, monitor for OOMKilled events; increase only if observed

**Q5: Should we deploy `local-path-provisioner` for CDI scratch space now or defer to Phase 2?**
- **Recommendation:** DEFER — ceph-block works fine for CDI imports, local-path is an optimization (faster ephemeral volumes)

---

## Related Documentation

- **Research notes:** `/tmp/kubevirt-sysbox-research/research-notes.md` (local, not committed — contains web fetches, compatibility tables, Sysbox investigation details)
- **KubeVirt on Talos guide:** https://docs.siderolabs.com/talos/v1.13/advanced-guides/install-kubevirt
- **KubeVirt docs:** https://kubevirt.io/user-guide/
- **CDI docs:** https://github.com/kubevirt/containerized-data-importer/blob/main/doc/basic_pv_pvc_dv.md
- **Docker rootless mode:** https://docs.docker.com/engine/security/rootless/

---

## Revision History

| Date | Change | Author |
|------|--------|--------|
| 2026-06-09 | Initial design (KubeVirt + gitea-runner rootless DinD) | SRE Agent |

---

## Appendix A: KubeVirt Feature Flags (KubeVirt CR Spec)

```yaml
# components/kube-system/kubevirt/kubevirt-cr.yaml (example)
apiVersion: kubevirt.io/v1
kind: KubeVirt
metadata:
  name: kubevirt
  namespace: kubevirt
spec:
  certificateRotateStrategy: {}
  configuration:
    developerConfiguration:
      featureGates:
        - LiveMigration       # Enable VM live migration
        - Snapshot            # Enable VM disk snapshots
        # - CPUManager        # (optional) CPU pinning
        # - GPU               # (optional) GPU passthrough
  customizeComponents: {}
  imagePullPolicy: IfNotPresent
  workloadUpdateStrategy:
    workloadUpdateMethods:
    - LiveMigrate            # Prefer live migration for virt-handler updates
```

---

## Appendix B: Gitea Runner Values Diff

```diff
# components/gitea/gitea-runner/values.yaml

 controllers:
   app:
     containers:
       dind:
         image:
           repository: docker
-          tag: 29-dind
+          tag: dind-rootless
         securityContext:
-          privileged: true
+          runAsNonRoot: true
+          runAsUser: 1000
+          allowPrivilegeEscalation: false
+          readOnlyRootFilesystem: false  # DinD needs writable /var/lib/docker
+          capabilities:
+            drop: ["ALL"]
         env:
           DOCKER_TLS_CERTDIR: ""
+        resources:
+          requests:
+            cpu: 500m
+            memory: 512Mi
+          limits:
+            memory: 2Gi
```

**Note:** If resource limits were not previously set, add them as shown above (prevents runaway fuse-overlayfs memory usage).

---

## Appendix C: Node Hardware Verification (Reference)

```bash
# Verify VT-x + /dev/kvm on target nodes
kubectl debug node/k8s-4-dell -it --image=alpine -- sh -c 'grep -E "vmx|svm" /proc/cpuinfo && ls -l /dev/kvm'
kubectl debug node/k8s-5-1u -it --image=alpine -- sh -c 'grep -E "vmx|svm" /proc/cpuinfo && ls -l /dev/kvm'
```

**Expected output:**
- `vmx` (Intel) or `svm` (AMD) flags present in `/proc/cpuinfo`
- `/dev/kvm` character device exists

**Verified:** ✅ Both k8s-4-dell and k8s-5-1u confirmed during research phase.
