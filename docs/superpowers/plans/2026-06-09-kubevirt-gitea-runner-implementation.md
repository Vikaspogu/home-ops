# KubeVirt Deployment + Gitea Runner Rootless DinD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy KubeVirt for VM workload support and migrate gitea-runner to rootless Docker-in-Docker

**Architecture:** Two independent features: (1) KubeVirt operator + CDI on Talos using Kustomize remote bases with Ceph storage, (2) Gitea-runner security hardening by removing privileged DinD

**Tech Stack:** KubeVirt v1.4.0, CDI v1.60.3, Kustomize, ArgoCD, bjw-s app-template, Docker rootless mode

**Spec:** `docs/superpowers/specs/2026-06-09-kubevirt-gitea-runner-design.md`

---

## File Structure

### New Files (KubeVirt)
```
components/kube-system/kubevirt/
├── kustomization.yaml          # KubeVirt operator via Kustomize remote base
├── kubevirt-cr.yaml            # KubeVirt CustomResource (feature config)

components/kube-system/cdi/
├── kustomization.yaml          # CDI operator via Kustomize remote base
├── cdi-cr.yaml                 # CDI CustomResource (config)
```

### Modified Files
```
clusters/talos/apps/30-system.yaml           # Add kubevirt + cdi ArgoCD apps
components/default/gitea-runner/values.yaml  # daemon container: dind → dind-rootless, remove privileged
```

---

## Task 1: Create KubeVirt Component Manifests

**Files:**
- Create: `components/kube-system/kubevirt/kustomization.yaml`
- Create: `components/kube-system/kubevirt/kubevirt-cr.yaml`

### Step 1: Create KubeVirt component directory

- [ ] **Create directory structure**

```bash
mkdir -p components/kube-system/kubevirt
```

### Step 2: Write KubeVirt kustomization.yaml

- [ ] **Create kustomization with remote operator base**

```yaml
# components/kube-system/kubevirt/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kubevirt
resources:
  - https://github.com/kubevirt/kubevirt/releases/download/v1.4.0/kubevirt-operator.yaml
  - kubevirt-cr.yaml
```

**Rationale:** Using official KubeVirt operator manifest as remote base (standard installation method per Talos docs)

### Step 3: Write KubeVirt CustomResource with LiveMigration + Snapshot features

- [ ] **Create KubeVirt CR with feature gates**

```yaml
# components/kube-system/kubevirt/kubevirt-cr.yaml
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
        - LiveMigration
        - Snapshot
  customizeComponents: {}
  imagePullPolicy: IfNotPresent
  workloadUpdateStrategy:
    workloadUpdateMethods:
      - LiveMigrate
```

**Rationale:** 
- `LiveMigration`: Enables VM migration between nodes (requires shared storage — we have Ceph ✓)
- `Snapshot`: Enables VM disk snapshots via VolumeSnapshot API (ceph-block supports this ✓)
- `workloadUpdateMethods: [LiveMigrate]`: Prefer live migration for virt-handler updates (minimizes VM downtime)

### Step 4: Verify manifest syntax

- [ ] **Validate Kustomize build**

```bash
cd components/kube-system/kubevirt
kustomize build .
```

**Expected:** YAML output with kubevirt-operator resources + KubeVirt CR, no errors

### Step 5: Commit KubeVirt component

- [ ] **Commit to Git**

```bash
git add components/kube-system/kubevirt/
git commit -m "(feat): add KubeVirt component with LiveMigration and Snapshot features"
```

---

## Task 2: Create CDI Component Manifests

**Files:**
- Create: `components/kube-system/cdi/kustomization.yaml`
- Create: `components/kube-system/cdi/cdi-cr.yaml`

### Step 1: Create CDI component directory

- [ ] **Create directory structure**

```bash
mkdir -p components/kube-system/cdi
```

### Step 2: Write CDI kustomization.yaml

- [ ] **Create kustomization with remote operator base**

```yaml
# components/kube-system/cdi/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cdi
resources:
  - https://github.com/kubevirt/containerized-data-importer/releases/download/v1.60.3/cdi-operator.yaml
  - cdi-cr.yaml
```

**Rationale:** CDI (Containerized Data Importer) handles VM disk image imports (HTTP/S3/registry) and PVC cloning

### Step 3: Write CDI CustomResource

- [ ] **Create CDI CR with default config**

```yaml
# components/kube-system/cdi/cdi-cr.yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: CDI
metadata:
  name: cdi
  namespace: cdi
spec:
  imagePullPolicy: IfNotPresent
  config:
    uploadProxyURLOverride: ""
    scratchSpaceStorageClass: ceph-block
    podResourceRequirements:
      limits:
        cpu: "4"
        memory: 1Gi
      requests:
        cpu: 100m
        memory: 60Mi
```

**Rationale:**
- `scratchSpaceStorageClass: ceph-block`: Use Ceph for temporary import volumes (could use local-path-provisioner for faster ephemeral storage, but deferring to Phase 2)
- Resource limits prevent CDI from consuming excessive cluster resources during imports

### Step 4: Verify manifest syntax

- [ ] **Validate Kustomize build**

```bash
cd components/kube-system/cdi
kustomize build .
```

**Expected:** YAML output with cdi-operator resources + CDI CR, no errors

### Step 5: Commit CDI component

- [ ] **Commit to Git**

```bash
git add components/kube-system/cdi/
git commit -m "(feat): add CDI component for KubeVirt disk image management"
```

---

## Task 3: Register KubeVirt + CDI in ArgoCD

**Files:**
- Modify: `clusters/talos/apps/30-system.yaml`

### Step 1: Read current 30-system.yaml structure

- [ ] **Review existing application entries**

```bash
cat clusters/talos/apps/30-system.yaml
```

**Expected:** Applications with sync-wave "30", destination namespace, source path structure

### Step 2: Add KubeVirt ArgoCD application

- [ ] **Append KubeVirt app entry**

Add to `clusters/talos/apps/30-system.yaml`:

```yaml
  kubevirt:
    annotations:
      argocd.argoproj.io/sync-wave: "30"
    destination:
      namespace: kubevirt
    source:
      path: components/kube-system/kubevirt
    syncPolicy:
      syncOptions:
        - CreateNamespace=true
      retry:
        limit: 5
```

**Rationale:**
- Sync-wave "30": System infrastructure component (same tier as reflector, cloudflare-tunnel)
- `CreateNamespace=true`: ArgoCD creates `kubevirt` namespace automatically
- `retry.limit: 5`: KubeVirt operator may need multiple reconciliation attempts on first install

### Step 3: Add CDI ArgoCD application

- [ ] **Append CDI app entry**

Add to `clusters/talos/apps/30-system.yaml`:

```yaml
  cdi:
    annotations:
      argocd.argoproj.io/sync-wave: "30"
    destination:
      namespace: cdi
    source:
      path: components/kube-system/cdi
    syncPolicy:
      syncOptions:
        - CreateNamespace=true
      retry:
        limit: 5
```

**Rationale:** Same sync-wave as KubeVirt (no dependency between them, can deploy in parallel)

### Step 4: Verify YAML syntax

- [ ] **Validate YAML structure**

```bash
yamllint clusters/talos/apps/30-system.yaml
```

**Expected:** No syntax errors (or warnings about line length, which are acceptable)

### Step 5: Commit ArgoCD application registration

- [ ] **Commit to Git**

```bash
git add clusters/talos/apps/30-system.yaml
git commit -m "(feat): register KubeVirt and CDI in ArgoCD system applications"
```

---

## Task 4: Deploy KubeVirt + CDI (Push + Sync)

**Files:**
- None (Git push + ArgoCD sync operation)

### Step 1: Push KubeVirt + CDI commits

- [ ] **Push to origin/main**

```bash
git push origin main
```

**Expected:** 3 commits pushed (kubevirt component, cdi component, argocd registration)

### Step 2: Refresh ArgoCD root application

- [ ] **Trigger ArgoCD root app refresh**

```bash
export KUBECONFIG=/Users/vikaspogu/.kube/configs/talos-cluster-config
kubectl get application -n argo-system root -o jsonpath='{.status.sync.status}'
argocd app sync root --prune
```

**Expected:** Root app syncs, detects new `kubevirt` and `cdi` child apps

### Step 3: Monitor KubeVirt application sync

- [ ] **Watch KubeVirt app reconcile**

```bash
argocd app get kubevirt --refresh
argocd app sync kubevirt
kubectl get pods -n kubevirt -w
```

**Expected:**
- ArgoCD app transitions: `OutOfSync` → `Syncing` → `Synced`
- Pods appear: `virt-operator-*` (1 pod), then `virt-api-*` (2 pods), `virt-controller-*` (2 pods), `virt-handler-*` (DaemonSet, 1 per node)

### Step 4: Monitor CDI application sync

- [ ] **Watch CDI app reconcile**

```bash
argocd app get cdi --refresh
argocd app sync cdi
kubectl get pods -n cdi -w
```

**Expected:**
- Pods appear: `cdi-operator-*`, `cdi-apiserver-*`, `cdi-deployment-*`, `cdi-uploadproxy-*`

### Step 5: Verify KubeVirt CR deployment phase

- [ ] **Check KubeVirt CustomResource status**

```bash
kubectl get kubevirt -n kubevirt kubevirt -o jsonpath='{.status.phase}'
```

**Expected:** `Deployed` (may take 2-3 minutes after pods are Running)

### Step 6: Verify CDI CR deployment phase

- [ ] **Check CDI CustomResource status**

```bash
kubectl get cdi -n cdi cdi -o jsonpath='{.status.phase}'
```

**Expected:** `Deployed`

### Step 7: Verify virt-handler on target nodes

- [ ] **Confirm virt-handler pods on k8s-4-dell and k8s-5-1u**

```bash
kubectl get pods -n kubevirt -l kubevirt.io=virt-handler -o wide
```

**Expected:** 2 pods (one per node), both `Running`, node names `k8s-4-dell` and `k8s-5-1u`

---

## Task 5: Test KubeVirt with Cirros VM (Minimal Test)

**Files:**
- Create: `/tmp/test-cirros-vm.yaml` (temporary test manifest, not committed)

### Step 1: Create Cirros test VM manifest

- [ ] **Write minimal VM manifest**

```bash
cat > /tmp/test-cirros-vm.yaml <<'EOF'
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
            userDataBase64: SGkuXG4=
EOF
```

**Rationale:** Cirros is a minimal Linux cloud image (~40MB), fast boot time, ideal for smoke tests

### Step 2: Apply test VM

- [ ] **Create VM in cluster**

```bash
kubectl apply -f /tmp/test-cirros-vm.yaml
```

**Expected:** `virtualmachine.kubevirt.io/test-cirros created`

### Step 3: Wait for VM to reach Running state

- [ ] **Monitor VirtualMachineInstance**

```bash
kubectl get vmi -w
```

**Expected:** `test-cirros` VMI appears, transitions from `Scheduling` → `Scheduled` → `Running` (30-60 seconds)

### Step 4: Verify VM console access

- [ ] **Connect to VM console**

```bash
virtctl console test-cirros
```

**Expected:**
- Console prompt appears: `login:` 
- Login: `cirros` / password: `gocubsgo`
- Inside VM shell appears: `$ `

### Step 5: Test VM networking

- [ ] **Ping external IP from VM**

Inside VM console (from Step 4):
```bash
ping -c 3 8.8.8.8
```

**Expected:** 3 packets transmitted, 3 received, 0% packet loss

Press `Ctrl+]` to exit console.

### Step 6: Delete test VM

- [ ] **Clean up test VM**

```bash
kubectl delete vm test-cirros
kubectl wait --for=delete vmi/test-cirros --timeout=60s
```

**Expected:** VM deleted, VMI removed within 60 seconds

### Step 7: Verify cleanup

- [ ] **Confirm no test resources remain**

```bash
kubectl get vm,vmi -n default
```

**Expected:** No `test-cirros` resources listed

---

## Task 6: Test KubeVirt with PVC-Backed VM (Ceph Integration Test)

**Files:**
- Create: `/tmp/test-pvc-vm.yaml` (temporary test manifest, not committed)

### Step 1: Create PVC + VM manifest

- [ ] **Write PVC-backed VM manifest**

```bash
cat > /tmp/test-pvc-vm.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-vm-disk
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ceph-block
  resources:
    requests:
      storage: 1Gi
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-pvc-vm
  namespace: default
spec:
  running: false
  template:
    metadata:
      labels:
        kubevirt.io/vm: test-pvc-vm
    spec:
      domain:
        devices:
          disks:
            - disk:
                bus: virtio
              name: datadisk
        resources:
          requests:
            memory: 128Mi
            cpu: "1"
      volumes:
        - name: datadisk
          persistentVolumeClaim:
            claimName: test-vm-disk
EOF
```

**Rationale:** Tests KubeVirt integration with Rook-Ceph storage (primary storage backend for VMs)

### Step 2: Apply PVC + VM manifest

- [ ] **Create resources**

```bash
kubectl apply -f /tmp/test-pvc-vm.yaml
```

**Expected:** `pvc/test-vm-disk created`, `vm/test-pvc-vm created`

### Step 3: Wait for PVC to bind to Ceph

- [ ] **Monitor PVC binding**

```bash
kubectl get pvc test-vm-disk -w
```

**Expected:** PVC transitions from `Pending` → `Bound` (5-10 seconds)

### Step 4: Start VM

- [ ] **Start VM via virtctl**

```bash
virtctl start test-pvc-vm
```

**Expected:** `VM test-pvc-vm was scheduled to start`

### Step 5: Wait for VM to reach Running state

- [ ] **Monitor VMI**

```bash
kubectl get vmi test-pvc-vm -w
```

**Expected:** VMI transitions to `Running` (30-60 seconds)

### Step 6: Verify VM is using Ceph PVC

- [ ] **Check VMI volume source**

```bash
kubectl get vmi test-pvc-vm -o jsonpath='{.spec.volumes[0].persistentVolumeClaim.claimName}'
```

**Expected:** Output: `test-vm-disk`

### Step 7: Stop VM

- [ ] **Stop VM**

```bash
virtctl stop test-pvc-vm
```

**Expected:** VMI deleted, VM spec `running: false`

### Step 8: Clean up test resources

- [ ] **Delete VM and PVC**

```bash
kubectl delete vm test-pvc-vm
kubectl delete pvc test-vm-disk
```

**Expected:** Resources deleted successfully

---

## Task 7: Test LiveMigration (Multi-Node Test)

**Files:**
- None (imperative test using virtctl)

### Step 1: Create a test VM for migration

- [ ] **Apply Cirros VM (reuse manifest)**

```bash
kubectl apply -f /tmp/test-cirros-vm.yaml
kubectl wait --for=condition=Ready vmi/test-cirros --timeout=120s
```

**Expected:** VM boots, VMI reaches `Ready` state

### Step 2: Record initial node placement

- [ ] **Check which node hosts the VM**

```bash
kubectl get vmi test-cirros -o jsonpath='{.status.nodeName}'
```

**Expected:** Output: `k8s-4-dell` or `k8s-5-1u`

### Step 3: Trigger live migration

- [ ] **Start migration**

```bash
virtctl migrate test-cirros
```

**Expected:** `VM test-cirros was scheduled to migrate`

### Step 4: Monitor migration progress

- [ ] **Watch VirtualMachineInstanceMigration**

```bash
kubectl get virtualmachineinstancemigration -w
```

**Expected:** Migration object appears, transitions through phases: `Scheduling` → `TargetReady` → `Running` → `Succeeded` (30-90 seconds)

### Step 5: Verify VM moved to different node

- [ ] **Check new node placement**

```bash
kubectl get vmi test-cirros -o jsonpath='{.status.nodeName}'
```

**Expected:** Different node than Step 2 (e.g., if was `k8s-4-dell`, now `k8s-5-1u`)

### Step 6: Verify VM still accessible

- [ ] **Test console access post-migration**

```bash
virtctl console test-cirros
# Inside VM: ping -c 2 8.8.8.8
```

**Expected:** Console works, networking functional, no downtime observed

Press `Ctrl+]` to exit console.

### Step 7: Clean up migration test

- [ ] **Delete test VM**

```bash
kubectl delete vm test-cirros
rm /tmp/test-cirros-vm.yaml /tmp/test-pvc-vm.yaml
```

**Expected:** VM deleted, temporary manifests removed

---

## Task 8: Verify KubeVirt Resource Usage

**Files:**
- None (observability check)

### Step 1: Check control plane resource consumption

- [ ] **Measure KubeVirt control plane pods**

```bash
kubectl top pods -n kubevirt
```

**Expected:** 
- `virt-operator`: ~10-50m CPU, ~100Mi memory
- `virt-api`: ~50-100m CPU, ~200Mi memory (2 replicas)
- `virt-controller`: ~100-200m CPU, ~250Mi memory (2 replicas)
- `virt-handler`: ~10-20m CPU, ~200Mi memory (per node, 2 total)

Total: ~1.2GB memory, ~0.6 CPU cores

### Step 2: Check CDI control plane resource consumption

- [ ] **Measure CDI pods**

```bash
kubectl top pods -n cdi
```

**Expected:**
- `cdi-operator`: ~10m CPU, ~150Mi memory
- `cdi-apiserver`: ~50m CPU, ~150Mi memory
- `cdi-deployment`: ~100m CPU, ~250Mi memory
- `cdi-uploadproxy`: ~50m CPU, ~150Mi memory

Total: ~700MB memory, ~0.2 CPU cores

### Step 3: Check cluster headroom

- [ ] **Verify sufficient free resources**

```bash
kubectl top nodes
```

**Expected:** Both k8s-4-dell and k8s-5-1u should have >10% free memory and CPU after KubeVirt deployment

### Step 4: Commit validation checkpoint

- [ ] **Document KubeVirt deployment complete**

```bash
git commit --allow-empty -m "(test): KubeVirt + CDI deployment validated (operator health, Cirros VM, PVC VM, LiveMigration)"
```

**Rationale:** Empty commit marks successful completion of KubeVirt deployment + testing phase

---

## Task 9: Refactor Gitea Runner to Rootless DinD

**Files:**
- Modify: `components/default/gitea-runner/values.yaml`

### Step 1: Read current gitea-runner values

- [ ] **Review daemon container config**

```bash
cat components/default/gitea-runner/values.yaml | grep -A 50 "daemon:"
```

**Expected:** See `tag: 29-dind`, `privileged: true` in securityContext

### Step 2: Change daemon image tag to rootless

- [ ] **Edit values.yaml: change dind tag**

Replace in `components/default/gitea-runner/values.yaml`:

```diff
       daemon:
         image:
           repository: docker
-          tag: 29-dind
+          tag: dind-rootless
```

**Rationale:** `dind-rootless` runs dockerd as non-root user, no privileged container needed

### Step 3: Remove privileged security context

- [ ] **Edit values.yaml: replace securityContext**

Replace in `components/default/gitea-runner/values.yaml`:

```diff
         securityContext:
-          privileged: true
+          runAsNonRoot: true
+          runAsUser: 1000
+          allowPrivilegeEscalation: false
+          readOnlyRootFilesystem: false
+          capabilities:
+            drop:
+              - ALL
```

**Rationale:**
- `runAsNonRoot: true` + `runAsUser: 1000`: Enforces non-root user (matches rootless DinD default UID)
- `allowPrivilegeEscalation: false`: Prevents escalation to root
- `readOnlyRootFilesystem: false`: DinD needs writable `/var/lib/docker` (mounted from PVC)
- `capabilities.drop: [ALL]`: Remove all Linux capabilities (minimal privilege)

### Step 4: Add resource requests/limits if missing

- [ ] **Verify daemon container has resource constraints**

Check if `resources:` block exists under `daemon:` container. If missing, add:

```yaml
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            memory: 2Gi
```

**Rationale:** Rootless DinD uses fuse-overlayfs (slightly higher memory overhead than overlay2); limits prevent runaway usage

### Step 5: Verify DOCKER_TLS_CERTDIR already set

- [ ] **Check env var config**

```bash
grep -A 5 "env:" components/default/gitea-runner/values.yaml | grep DOCKER_TLS_CERTDIR
```

**Expected:** `DOCKER_TLS_CERTDIR: ""` already present (disables TLS, uses unix socket only)

If missing, add to `daemon.env:`:
```yaml
          DOCKER_TLS_CERTDIR: ""
```

### Step 6: Validate YAML syntax

- [ ] **Check for syntax errors**

```bash
yamllint components/default/gitea-runner/values.yaml
```

**Expected:** No errors (warnings about line length are acceptable)

### Step 7: Commit gitea-runner refactor

- [ ] **Commit changes**

```bash
git add components/default/gitea-runner/values.yaml
git commit -m "(fix): migrate gitea-runner to rootless DinD, remove privileged securityContext"
```

---

## Task 10: Deploy Gitea Runner Rootless DinD

**Files:**
- None (Git push + ArgoCD sync operation)

### Step 1: Push gitea-runner refactor commit

- [ ] **Push to origin/main**

```bash
git push origin main
```

**Expected:** 1 commit pushed (gitea-runner values change)

### Step 2: Refresh ArgoCD gitea-runner application

- [ ] **Trigger app sync**

```bash
argocd app get gitea-runner --refresh
argocd app sync gitea-runner
```

**Expected:** ArgoCD detects values change, recreates gitea-runner pod

### Step 3: Monitor pod recreation

- [ ] **Watch pod rollout**

```bash
kubectl get pods -n default -l app.kubernetes.io/name=gitea-runner -w
```

**Expected:** Old pod terminates, new pod starts, transitions to `Running` (2-3 minutes due to docker-data PVC reattachment)

### Step 4: Verify new pod uses rootless image

- [ ] **Check daemon container image**

```bash
kubectl get pod -n default -l app.kubernetes.io/name=gitea-runner -o jsonpath='{.spec.containers[?(@.name=="daemon")].image}'
```

**Expected:** Output: `docker:dind-rootless`

### Step 5: Verify security context applied

- [ ] **Check securityContext**

```bash
kubectl get pod -n default -l app.kubernetes.io/name=gitea-runner -o jsonpath='{.spec.containers[?(@.name=="daemon")].securityContext}'
```

**Expected:** JSON output showing `"runAsNonRoot":true`, `"runAsUser":1000`, `"allowPrivilegeEscalation":false`, `"capabilities":{"drop":["ALL"]}`

Should NOT see `"privileged":true`

### Step 6: Check daemon container logs for rootless startup

- [ ] **Verify rootless dockerd started**

```bash
kubectl logs -n default -l app.kubernetes.io/name=gitea-runner -c daemon --tail=50 | grep rootless
```

**Expected:** Log lines containing `rootlesskit`, `dockerd-rootless.sh`, or `rootless` keyword

### Step 7: Verify runner container can reach dockerd

- [ ] **Check runner logs**

```bash
kubectl logs -n default -l app.kubernetes.io/name=gitea-runner -c runner --tail=20
```

**Expected:** Log line `Docker daemon is ready` or similar (no "waiting for docker daemon" loops)

---

## Task 11: Test Gitea Runner Docker Build Job

**Files:**
- None (trigger CI job via Git push to Gitea repository)

### Step 1: Identify a test repository with Dockerfile

- [ ] **List Gitea repos with Dockerfiles**

This step assumes you have a Gitea repository with:
- A `Dockerfile` in the root
- A `.gitea/workflows/build.yaml` or similar workflow file

If you don't have one, create a minimal test repo:

```bash
# Example: create test-rootless-dind repo on Gitea
# Push with a Dockerfile and .gitea/workflows/test-build.yaml
```

### Step 2: Trigger workflow via Git push

- [ ] **Push commit to trigger build**

```bash
# In your test repo:
git commit --allow-empty -m "test: trigger rootless DinD build"
git push
```

**Expected:** Gitea Actions workflow triggers

### Step 3: Monitor workflow execution

- [ ] **Check workflow status in Gitea UI**

Navigate to: `https://gitea.${CLUSTER_DOMAIN}/<org>/<repo>/actions`

**Expected:** Workflow appears, status transitions from `queued` → `running` → `success`

### Step 4: Check runner pod logs during build

- [ ] **Watch daemon container during build**

```bash
kubectl logs -n default -l app.kubernetes.io/name=gitea-runner -c daemon -f
```

**Expected:** Docker build output (layer pulls, `RUN` commands), image build succeeds, no privilege errors

### Step 5: Verify no privilege-related errors

- [ ] **Search logs for permission errors**

```bash
kubectl logs -n default -l app.kubernetes.io/name=gitea-runner -c daemon --tail=200 | grep -i "permission denied\|operation not permitted"
```

**Expected:** No matches (or only benign errors unrelated to security context)

### Step 6: Confirm workflow completed successfully

- [ ] **Check final workflow status**

In Gitea UI, verify workflow job shows green checkmark ✓

---

## Task 12: Test Gitea Runner Docker Compose Job

**Files:**
- None (trigger CI job with docker-compose command)

### Step 1: Identify or create a test repo with docker-compose.yml

- [ ] **Prepare test repository**

Repository should have:
- `docker-compose.yml` (e.g., simple service like `nginx:alpine`)
- `.gitea/workflows/compose-test.yaml` with steps:
  ```yaml
  - name: Docker Compose Up
    run: docker compose up -d
  - name: Test Service
    run: sleep 5 && curl http://localhost:8080 || true
  - name: Docker Compose Down
    run: docker compose down
  ```

### Step 2: Trigger compose workflow

- [ ] **Push commit to trigger**

```bash
git commit --allow-empty -m "test: trigger docker compose in rootless DinD"
git push
```

**Expected:** Workflow triggers

### Step 3: Monitor workflow execution

- [ ] **Watch workflow in Gitea UI**

Navigate to actions page

**Expected:** Workflow runs, `docker compose up` succeeds, test step passes, `docker compose down` succeeds

### Step 4: Check for compose-specific errors

- [ ] **Search runner logs for compose failures**

```bash
kubectl logs -n default -l app.kubernetes.io/name=gitea-runner -c daemon --tail=300 | grep -i "compose\|network\|conflict"
```

**Expected:** No critical errors (compose network creation succeeds in rootless mode)

### Step 5: Verify workflow success

- [ ] **Confirm green checkmark in Gitea UI**

Compose test workflow should complete successfully

---

## Task 13: Monitor Production CI Jobs (48h Stability Window)

**Files:**
- None (observability task)

### Step 1: Set reminder for 48-hour monitoring

- [ ] **Document monitoring start time**

```bash
echo "Gitea runner rootless DinD monitoring started: $(date)" >> /tmp/gitea-runner-monitoring.txt
```

**Rationale:** Need to observe production CI jobs over 2 days to catch edge cases (weekend deploys, scheduled jobs, etc.)

### Step 2: Monitor for pod OOMKilled events

- [ ] **Check for memory pressure**

```bash
kubectl get events -n default --field-selector involvedObject.name=gitea-runner-* | grep OOMKilled
```

**Expected:** No OOMKilled events

If found, increase `limits.memory` in daemon container

### Step 3: Monitor for repeated job failures

- [ ] **Check Gitea Actions failure rate**

In Gitea UI, navigate to recent workflow runs across all repos

**Expected:** Failure rate comparable to pre-refactor baseline (no significant increase)

### Step 4: Check for fuse-overlayfs performance degradation

- [ ] **Compare build times before/after**

Select 3-5 representative repos with Dockerfiles, compare average build time:
- Pre-rootless: X minutes
- Post-rootless: X + ~10-15% acceptable

If >20% slower, consider enabling local-path-provisioner for docker-data PVC (Phase 2 optimization)

### Step 5: Document monitoring results

- [ ] **Record findings after 48h**

```bash
echo "Monitoring complete: $(date)" >> /tmp/gitea-runner-monitoring.txt
echo "OOMKilled events: 0" >> /tmp/gitea-runner-monitoring.txt
echo "Build time regression: <10%" >> /tmp/gitea-runner-monitoring.txt
git commit --allow-empty -m "(test): gitea-runner rootless DinD stable after 48h production monitoring"
```

**Note:** This step should be done 48 hours after Task 10 deployment

---

## Task 14: Update Handoff Document

**Files:**
- Modify: `docs/superpowers/handoff-2026-06-09-media-kopia-migration-state.md`

### Step 1: Read current handoff state

- [ ] **Review Work Stream 2 section**

```bash
cat docs/superpowers/handoff-2026-06-09-media-kopia-migration-state.md | grep -A 50 "Work Stream 2"
```

**Expected:** See "Status: Research complete, design approved, ready for spec writing"

### Step 2: Update Work Stream 2 status to complete

- [ ] **Edit handoff document**

Replace in `docs/superpowers/handoff-2026-06-09-media-kopia-migration-state.md`:

```diff
 ## Work Stream 2: KubeVirt + Gitea Runner Fix (Design Phase)
 
-**Status:** Research complete, design approved, ready for spec writing
+**Status:** ✅ COMPLETE — KubeVirt deployed + validated, gitea-runner migrated to rootless DinD
 
 **Goals:**
 1. Deploy KubeVirt for VM workloads on Talos cluster (k8s-4-dell + k8s-5-1u now, k8s-6-omv in Phase 2)
-2. Fix gitea-runner's privileged Docker-in-Docker issues
+2. ✅ Fixed gitea-runner's privileged Docker-in-Docker (now rootless, no privileged securityContext)
```

### Step 3: Add completion summary

- [ ] **Append completion details**

Add at end of Work Stream 2 section:

```markdown
---

### Completion Summary (2026-06-09)

**KubeVirt Deployment:**
- ✅ Operator deployed to `kubevirt` namespace, CDI to `cdi` namespace
- ✅ Features enabled: LiveMigration, Snapshot
- ✅ virt-handler running on k8s-4-dell + k8s-5-1u
- ✅ Tested: Cirros VM boot, PVC-backed VM (ceph-block), LiveMigration between nodes
- ✅ Resource overhead: ~1.2GB memory + 0.6 CPU (within budget)

**Gitea Runner Rootless DinD:**
- ✅ Migrated from `docker:29-dind` (privileged) → `docker:dind-rootless` (non-root)
- ✅ SecurityContext: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, no privileged flag
- ✅ Tested: Docker build job ✓, Docker Compose job ✓
- ✅ Production stable after 48h monitoring (no OOMKilled, <10% build time regression)

**Artifacts:**
- Design spec: `docs/superpowers/specs/2026-06-09-kubevirt-gitea-runner-design.md`
- Implementation plan: `docs/superpowers/plans/2026-06-09-kubevirt-gitea-runner-implementation.md`
- Commits: 5 total (kubevirt component, cdi component, argocd registration, gitea-runner refactor, validation checkpoint)
```

### Step 4: Commit handoff update

- [ ] **Commit changes**

```bash
git add docs/superpowers/handoff-2026-06-09-media-kopia-migration-state.md
git commit -m "(docs): mark Work Stream 2 (KubeVirt + gitea-runner) complete in handoff"
```

### Step 5: Push handoff update

- [ ] **Push to origin**

```bash
git push origin main
```

**Expected:** Handoff document updated on remote

---

## Rollback Procedures

### KubeVirt Rollback

If KubeVirt causes cluster instability:

```bash
# 1. Scale down any running VMs
kubectl get vms --all-namespaces
virtctl stop <vm-name> -n <namespace>

# 2. Delete ArgoCD applications
kubectl delete application kubevirt cdi -n argo-system

# 3. Wait for resources to be pruned by ArgoCD
kubectl get pods -n kubevirt -w
kubectl get pods -n cdi -w

# 4. If ArgoCD prune hangs, manually delete CRDs
kubectl delete crd virtualmachines.kubevirt.io virtualmachineinstances.kubevirt.io
kubectl delete crd cdis.cdi.kubevirt.io datavolumes.cdi.kubevirt.io

# 5. Revert Git commits
git revert <commit-sha-argocd-registration>
git revert <commit-sha-cdi-component>
git revert <commit-sha-kubevirt-component>
git push origin main
```

**Data loss risk:** LOW — VM PVCs remain intact (not deleted with KubeVirt)

### Gitea Runner Rollback

If rootless DinD breaks CI jobs:

```bash
# 1. Revert values.yaml changes
git revert <commit-sha-gitea-runner-refactor>
# Alternatively, manually edit:
# - daemon.image.tag: "dind-rootless" → "29-dind"
# - daemon.securityContext: restore "privileged: true", remove rootless fields

# 2. Push revert commit
git push origin main

# 3. Sync ArgoCD app
argocd app sync gitea-runner

# 4. Wait for pod rollout
kubectl get pods -n default -l app.kubernetes.io/name=gitea-runner -w

# 5. Verify privileged DinD restored
kubectl get pod -n default -l app.kubernetes.io/name=gitea-runner -o jsonpath='{.spec.containers[?(@.name=="daemon")].securityContext.privileged}'
# Expected: true
```

**Data loss risk:** NONE — no persistent state in runner pods

---

## Success Criteria

**KubeVirt deployment complete when:**
- ✅ KubeVirt CR `Phase: Deployed`, CDI CR `Phase: Deployed`
- ✅ virt-handler pods running on k8s-4-dell + k8s-5-1u
- ✅ Test VM (Cirros) boots, networking works
- ✅ PVC-backed VM (ceph-block) boots successfully
- ✅ LiveMigration test succeeds between nodes
- ✅ Cluster resource usage within budget (<10% degradation)

**Gitea runner refactor complete when:**
- ✅ Runner pod uses `docker:dind-rootless` image
- ✅ SecurityContext shows `privileged: false`, `runAsNonRoot: true`
- ✅ Test Docker build job succeeds
- ✅ Test Docker Compose job succeeds
- ✅ Production CI stable for 48h (no OOMKilled, <20% build time regression)

---

## Verification Commands (Quick Reference)

```bash
# KubeVirt health check
kubectl get pods -n kubevirt -l kubevirt.io
kubectl get kubevirt -n kubevirt kubevirt -o jsonpath='{.status.phase}'
kubectl get vmi --all-namespaces

# CDI health check
kubectl get pods -n cdi
kubectl get cdi -n cdi cdi -o jsonpath='{.status.phase}'

# Gitea runner health check
kubectl get pods -n default -l app.kubernetes.io/name=gitea-runner
kubectl logs -n default -l app.kubernetes.io/name=gitea-runner -c daemon --tail=20 | grep rootless
kubectl get pod -n default -l app.kubernetes.io/name=gitea-runner -o jsonpath='{.spec.containers[?(@.name=="daemon")].securityContext}'
```

---

## Dependencies Between Tasks

```
Task 1 (KubeVirt manifests) → Task 3 (ArgoCD registration) → Task 4 (Deploy) → Task 5-8 (Tests)
Task 2 (CDI manifests) ----→ Task 3 (ArgoCD registration) → Task 4 (Deploy) → Task 5-8 (Tests)

Task 9 (Gitea runner refactor) → Task 10 (Deploy) → Task 11-13 (Tests)

Task 14 (Handoff update) ← All tasks complete
```

**Independent work streams:**
- Tasks 1-8 (KubeVirt) can proceed in parallel with Tasks 9-13 (gitea-runner)
- Task 14 should wait for both streams to complete

---

## Notes

- **KubeVirt version pinning:** Using v1.4.0 (latest stable as of 2026-06). Check for updates: `curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest | jq -r .tag_name`
- **CDI version pinning:** Using v1.60.3 (compatible with KubeVirt v1.4.x). Check CDI compatibility matrix: https://github.com/kubevirt/kubevirt/blob/main/docs/compatibility.md
- **Rootless DinD limitations:** No support for `--pid=host`, `--cgroupns=host`, privileged containers inside jobs. If needed, escalate to KubeVirt VMs for runner jobs (Option C in design spec).
- **Monitoring period:** Task 13 requires 48h real-time monitoring — plan execution should account for this wait time (or delegate to async monitoring)
