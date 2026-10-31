# Honcho Hermes Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy self-hosted Honcho internally in the Talos `ai` namespace and configure Hermes Agent to use Honcho as its external memory provider.

**Architecture:** Honcho runs as two GitOps applications: a PVC-backed `pgvector` Postgres component and a stateless API/deriver component that reuses shared Valkey. Hermes keeps its normal PVC-backed live config and gains a seeded `/opt/data/honcho.json` plus `memory.provider: honcho`.

**Tech Stack:** Kubernetes, ArgoCD app-of-apps, Gateway API avoided for internal-only service, ExternalSecrets with 1Password Connect, bjw-s app-template `4.6.2`, VolSync, `pgvector/pgvector:pg15`, `ghcr.io/plastic-labs/honcho`, NVIDIA Inference Hub.

---

## File Map

- Create `components/ai/honcho-postgres/kustomization.yaml`: kustomize and Helm chart entry for the dedicated Honcho Postgres app.
- Create `components/ai/honcho-postgres/configmap.yaml`: database init SQL for `pgvector`.
- Create `components/ai/honcho-postgres/externalsecret.yaml`: renders Postgres database credentials from 1Password item `honcho`.
- Create `components/ai/honcho-postgres/values.yaml`: bjw-s app-template values for the `pgvector` database.
- Create `components/ai/honcho/kustomization.yaml`: kustomize and Helm chart entry for Honcho API and deriver.
- Create `components/ai/honcho/externalsecret.yaml`: renders Honcho runtime, DB, cache, model, and embedding env vars.
- Create `components/ai/honcho/values.yaml`: bjw-s app-template values for Honcho API and deriver controllers.
- Modify `clusters/talos/apps/20-applications.yaml`: add Argo apps for `honcho-postgres` and `honcho`, then move Hermes to the next sync wave.
- Modify `components/ai/hermes-agent/configmap.yaml`: add `memory.provider: honcho` to the seed config and add a seeded `honcho.json`.
- Modify `components/ai/hermes-agent/values.yaml`: copy `honcho.json` into the Hermes PVC on first boot.

## Manual Secret Prerequisite

Before applying the manifests, the 1Password item `honcho` must exist with an alphanumeric field named `HONCHO_POSTGRES_PASSWORD`. Use an alphanumeric password so it is safe in the PostgreSQL URI rendered by ExternalSecrets.

- [ ] **Step 1: Generate a database password**

Run:

```bash
openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48; printf '\n'
```

Expected: one 48-character alphanumeric password.

- [ ] **Step 2: Create or update the 1Password item**

Use the 1Password UI or CLI to create item `honcho` with this exact field:

```text
HONCHO_POSTGRES_PASSWORD=paste-the-generated-48-character-password
```

Expected: `honcho` exists in the vault used by `onepassword-connect`, and ExternalSecrets can extract `HONCHO_POSTGRES_PASSWORD` from it.

---

### Task 1: Add Honcho Postgres Component

**Files:**
- Create: `components/ai/honcho-postgres/kustomization.yaml`
- Create: `components/ai/honcho-postgres/configmap.yaml`
- Create: `components/ai/honcho-postgres/externalsecret.yaml`
- Create: `components/ai/honcho-postgres/values.yaml`

- [ ] **Step 1: Create the component directory**

Run:

```bash
mkdir -p components/ai/honcho-postgres
```

Expected: directory exists.

- [ ] **Step 2: Add `kustomization.yaml`**

Create `components/ai/honcho-postgres/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ai
resources:
  - ./configmap.yaml
  - ./externalsecret.yaml
components:
  - ../../volsync-system/volsync-replication

helmCharts:
  - name: app-template
    releaseName: honcho-postgres
    namespace: ai
    repo: oci://ghcr.io/bjw-s-labs/helm
    version: "4.6.2"
    valuesFile: values.yaml
```

- [ ] **Step 3: Add the init SQL ConfigMap**

Create `components/ai/honcho-postgres/configmap.yaml`:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: honcho-postgres-init
data:
  init.sql: |-
    CREATE EXTENSION IF NOT EXISTS vector;
```

- [ ] **Step 4: Add the Postgres ExternalSecret**

Create `components/ai/honcho-postgres/externalsecret.yaml`:

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: honcho-postgres
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: honcho-postgres-secret
    template:
      engineVersion: v2
      data:
        POSTGRES_DB: honcho
        POSTGRES_USER: honcho
        POSTGRES_PASSWORD: "{{ .HONCHO_POSTGRES_PASSWORD }}"
  dataFrom:
    - extract:
        key: honcho
```

- [ ] **Step 5: Add Postgres app-template values**

Create `components/ai/honcho-postgres/values.yaml`:

```yaml
---
defaultPodOptions:
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    runAsGroup: 999
    fsGroup: 999
    fsGroupChangePolicy: OnRootMismatch
    seccompProfile:
      type: RuntimeDefault

controllers:
  app:
    replicas: 1
    strategy: Recreate
    annotations:
      reloader.stakater.com/auto: "true"
    containers:
      app:
        image:
          repository: pgvector/pgvector
          tag: pg15@sha256:7f5681e45237acdf546cf7cdc0dfc0ed7752ede857fda6e54f6ea21b936f8742
        args:
          - postgres
          - -c
          - max_connections=200
        env:
          PGDATA: /var/lib/postgresql/data/pgdata
        envFrom:
          - secretRef:
              name: honcho-postgres-secret
        resources:
          requests:
            cpu: 50m
            memory: 512Mi
          limits:
            memory: 2Gi
        probes:
          startup:
            enabled: true
            custom: true
            spec:
              exec:
                command:
                  - sh
                  - -c
                  - pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
              initialDelaySeconds: 10
              periodSeconds: 5
              failureThreshold: 30
          readiness:
            enabled: true
            custom: true
            spec:
              exec:
                command:
                  - sh
                  - -c
                  - pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
              periodSeconds: 10
          liveness:
            enabled: true
            custom: true
            spec:
              exec:
                command:
                  - sh
                  - -c
                  - pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
              periodSeconds: 30
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
              - ALL

service:
  app:
    controller: app
    ports:
      postgres:
        port: 5432

persistence:
  data:
    existingClaim: honcho-postgres
    globalMounts:
      - path: /var/lib/postgresql/data
  init:
    type: configMap
    name: honcho-postgres-init
    advancedMounts:
      app:
        app:
          - path: /docker-entrypoint-initdb.d/init.sql
            subPath: init.sql
            readOnly: true
```

- [ ] **Step 6: Render the component locally**

Run:

```bash
export ARGOCD_APP_NAME=honcho-postgres
export ARGOCD_ENV_STORAGE_CLASS=ceph-block
export ARGOCD_ENV_VOLUME_SNAPSHOT_CLASS=csi-ceph-blockpool
export ARGOCD_ENV_VOLSYNC_CAPACITY=10Gi
export ARGOCD_ENV_VOLSYNC_CACHE_CAPACITY=8Gi
kustomize build --enable-helm components/ai/honcho-postgres | envsubst > /tmp/honcho-postgres.yaml
```

Expected: command exits 0 and `/tmp/honcho-postgres.yaml` contains a `Deployment`, `Service`, `ExternalSecret`, `PersistentVolumeClaim`, `ReplicationSource`, and `ReplicationDestination`.

- [ ] **Step 7: Validate the rendered manifest against the cluster API**

Run:

```bash
KUBECONFIG=kubeconfig kubectl apply --dry-run=server -f /tmp/honcho-postgres.yaml
```

Expected: command exits 0 with server-side dry-run output.

- [ ] **Step 8: Commit the Postgres component**

Run:

```bash
git add components/ai/honcho-postgres
git commit -m "(feat): add honcho postgres component"
```

Expected: commit contains only the four `components/ai/honcho-postgres` files.

---

### Task 2: Add Honcho API and Deriver Component

**Files:**
- Create: `components/ai/honcho/kustomization.yaml`
- Create: `components/ai/honcho/externalsecret.yaml`
- Create: `components/ai/honcho/values.yaml`

- [ ] **Step 1: Create the component directory**

Run:

```bash
mkdir -p components/ai/honcho
```

Expected: directory exists.

- [ ] **Step 2: Add `kustomization.yaml`**

Create `components/ai/honcho/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ai
resources:
  - ./externalsecret.yaml

helmCharts:
  - name: app-template
    releaseName: honcho
    namespace: ai
    repo: oci://ghcr.io/bjw-s-labs/helm
    version: "4.6.2"
    valuesFile: values.yaml
```

- [ ] **Step 3: Add Honcho runtime ExternalSecret**

Create `components/ai/honcho/externalsecret.yaml`:

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: honcho
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: honcho-secret
    template:
      engineVersion: v2
      data:
        LOG_LEVEL: INFO
        PYTHONUNBUFFERED: "1"
        PYTHON_DOTENV_DISABLED: "1"
        NAMESPACE: honcho
        AUTH_USE_AUTH: "false"
        DB_CONNECTION_URI: "postgresql+psycopg://honcho:{{ .HONCHO_POSTGRES_PASSWORD }}@honcho-postgres.ai.svc.cluster.local:5432/honcho"
        CACHE_ENABLED: "true"
        CACHE_URL: "redis://valkey.default.svc.cluster.local:6379/6?suppress=true"
        TELEMETRY_ENABLED: "false"
        METRICS_ENABLED: "false"
        LLM_OPENAI_API_KEY: "{{ .INFERENCE_HUB_CODING_KEY }}"
        EMBEDDING_MODEL_CONFIG__TRANSPORT: openai
        EMBEDDING_MODEL_CONFIG__MODEL: azure/openai/text-embedding-3-small
        EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL: "{{ trimSuffix \"/\" .INFERENCE_HUB_BASE_URL }}/v1"
        EMBEDDING_MODEL_CONFIG__OVERRIDES__API_KEY_ENV: LLM_OPENAI_API_KEY
        EMBEDDING_VECTOR_DIMENSIONS: "1536"
        VECTOR_STORE_TYPE: pgvector
        VECTOR_STORE_DIMENSIONS: "1536"
        DERIVER_MODEL_CONFIG__TRANSPORT: openai
        DERIVER_MODEL_CONFIG__MODEL: openai/openai/gpt-5.4-mini
        DERIVER_MODEL_CONFIG__OVERRIDES__BASE_URL: "{{ trimSuffix \"/\" .INFERENCE_HUB_BASE_URL }}/v1"
        DERIVER_MODEL_CONFIG__OVERRIDES__API_KEY_ENV: LLM_OPENAI_API_KEY
        SUMMARY_MODEL_CONFIG__TRANSPORT: openai
        SUMMARY_MODEL_CONFIG__MODEL: openai/openai/gpt-5.4-mini
        SUMMARY_MODEL_CONFIG__OVERRIDES__BASE_URL: "{{ trimSuffix \"/\" .INFERENCE_HUB_BASE_URL }}/v1"
        SUMMARY_MODEL_CONFIG__OVERRIDES__API_KEY_ENV: LLM_OPENAI_API_KEY
        DREAM_DEDUCTION_MODEL_CONFIG__TRANSPORT: openai
        DREAM_DEDUCTION_MODEL_CONFIG__MODEL: openai/openai/gpt-5.4-mini
        DREAM_DEDUCTION_MODEL_CONFIG__OVERRIDES__BASE_URL: "{{ trimSuffix \"/\" .INFERENCE_HUB_BASE_URL }}/v1"
        DREAM_DEDUCTION_MODEL_CONFIG__OVERRIDES__API_KEY_ENV: LLM_OPENAI_API_KEY
        DREAM_INDUCTION_MODEL_CONFIG__TRANSPORT: openai
        DREAM_INDUCTION_MODEL_CONFIG__MODEL: openai/openai/gpt-5.4-mini
        DREAM_INDUCTION_MODEL_CONFIG__OVERRIDES__BASE_URL: "{{ trimSuffix \"/\" .INFERENCE_HUB_BASE_URL }}/v1"
        DREAM_INDUCTION_MODEL_CONFIG__OVERRIDES__API_KEY_ENV: LLM_OPENAI_API_KEY
        DIALECTIC_LEVELS__minimal__MODEL_CONFIG__TRANSPORT: openai
        DIALECTIC_LEVELS__minimal__MODEL_CONFIG__MODEL: openai/openai/gpt-5.4-mini
        DIALECTIC_LEVELS__minimal__MODEL_CONFIG__OVERRIDES__BASE_URL: "{{ trimSuffix \"/\" .INFERENCE_HUB_BASE_URL }}/v1"
        DIALECTIC_LEVELS__minimal__MODEL_CONFIG__OVERRIDES__API_KEY_ENV: LLM_OPENAI_API_KEY
        DIALECTIC_LEVELS__low__MODEL_CONFIG__TRANSPORT: openai
        DIALECTIC_LEVELS__low__MODEL_CONFIG__MODEL: openai/openai/gpt-5.4-mini
        DIALECTIC_LEVELS__low__MODEL_CONFIG__OVERRIDES__BASE_URL: "{{ trimSuffix \"/\" .INFERENCE_HUB_BASE_URL }}/v1"
        DIALECTIC_LEVELS__low__MODEL_CONFIG__OVERRIDES__API_KEY_ENV: LLM_OPENAI_API_KEY
        DIALECTIC_LEVELS__medium__MODEL_CONFIG__TRANSPORT: openai
        DIALECTIC_LEVELS__medium__MODEL_CONFIG__MODEL: openai/openai/gpt-5.4-mini
        DIALECTIC_LEVELS__medium__MODEL_CONFIG__OVERRIDES__BASE_URL: "{{ trimSuffix \"/\" .INFERENCE_HUB_BASE_URL }}/v1"
        DIALECTIC_LEVELS__medium__MODEL_CONFIG__OVERRIDES__API_KEY_ENV: LLM_OPENAI_API_KEY
        DIALECTIC_LEVELS__high__MODEL_CONFIG__TRANSPORT: openai
        DIALECTIC_LEVELS__high__MODEL_CONFIG__MODEL: openai/openai/gpt-5.4-mini
        DIALECTIC_LEVELS__high__MODEL_CONFIG__OVERRIDES__BASE_URL: "{{ trimSuffix \"/\" .INFERENCE_HUB_BASE_URL }}/v1"
        DIALECTIC_LEVELS__high__MODEL_CONFIG__OVERRIDES__API_KEY_ENV: LLM_OPENAI_API_KEY
        DIALECTIC_LEVELS__max__MODEL_CONFIG__TRANSPORT: openai
        DIALECTIC_LEVELS__max__MODEL_CONFIG__MODEL: openai/openai/gpt-5.4-mini
        DIALECTIC_LEVELS__max__MODEL_CONFIG__OVERRIDES__BASE_URL: "{{ trimSuffix \"/\" .INFERENCE_HUB_BASE_URL }}/v1"
        DIALECTIC_LEVELS__max__MODEL_CONFIG__OVERRIDES__API_KEY_ENV: LLM_OPENAI_API_KEY
  dataFrom:
    - extract:
        key: inference-hub
    - extract:
        key: honcho
```

- [ ] **Step 4: Add Honcho app-template values**

Create `components/ai/honcho/values.yaml`:

```yaml
---
defaultPodOptions:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault

controllers:
  api:
    replicas: 1
    strategy: Recreate
    annotations:
      reloader.stakater.com/auto: "true"
    containers:
      app:
        image:
          repository: ghcr.io/plastic-labs/honcho
          tag: latest@sha256:a8c4a8dcead76ef9b580559469db4f140eae2c51510ee7d7d3a1485576fee554
        command:
          - sh
          - docker/entrypoint.sh
        envFrom: &envFrom
          - secretRef:
              name: honcho-secret
        resources:
          requests:
            cpu: 100m
            memory: 512Mi
          limits:
            memory: 2Gi
        probes:
          startup:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: /health
                port: &httpPort 8000
              initialDelaySeconds: 20
              periodSeconds: 10
              failureThreshold: 30
          readiness:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: /health
                port: *httpPort
              periodSeconds: 10
          liveness:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: /health
                port: *httpPort
              periodSeconds: 30
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
              - ALL
  deriver:
    replicas: 1
    strategy: Recreate
    annotations:
      reloader.stakater.com/auto: "true"
    containers:
      app:
        image:
          repository: ghcr.io/plastic-labs/honcho
          tag: latest@sha256:a8c4a8dcead76ef9b580559469db4f140eae2c51510ee7d7d3a1485576fee554
        command:
          - /app/.venv/bin/python
          - -m
          - src.deriver
        envFrom: *envFrom
        resources:
          requests:
            cpu: 100m
            memory: 512Mi
          limits:
            memory: 2Gi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
              - ALL

service:
  app:
    controller: api
    ports:
      http:
        port: 8000
```

- [ ] **Step 5: Verify there is no HTTPRoute**

Run:

```bash
rg -n "HTTPRoute|hostnames|gethomepage" components/ai/honcho
```

Expected: command exits 1 and prints no matches.

- [ ] **Step 6: Render the component locally**

Run:

```bash
kustomize build --enable-helm components/ai/honcho > /tmp/honcho.yaml
```

Expected: command exits 0 and `/tmp/honcho.yaml` contains two workload controllers, one service, and one ExternalSecret.

- [ ] **Step 7: Validate the rendered manifest against the cluster API**

Run:

```bash
KUBECONFIG=kubeconfig kubectl apply --dry-run=server -f /tmp/honcho.yaml
```

Expected: command exits 0 with server-side dry-run output.

- [ ] **Step 8: Commit the Honcho app component**

Run:

```bash
git add components/ai/honcho
git commit -m "(feat): add honcho service component"
```

Expected: commit contains only the three `components/ai/honcho` files.

---

### Task 3: Register Honcho Apps in Talos

**Files:**
- Modify: `clusters/talos/apps/20-applications.yaml`

- [ ] **Step 1: Add the Honcho Argo applications**

In `clusters/talos/apps/20-applications.yaml`, place these blocks before the existing `hermes-agent` block:

```yaml
  honcho-postgres:
    annotations:
      argocd.argoproj.io/sync-wave: "19"
    destination:
      namespace: ai
    source:
      path: components/ai/honcho-postgres
      plugin:
        env:
          - name: STORAGE_CLASS
            value: ceph-block
          - name: VOLUME_SNAPSHOT_CLASS
            value: csi-ceph-blockpool
          - name: VOLSYNC_CAPACITY
            value: 10Gi
          - name: VOLSYNC_CACHE_CAPACITY
            value: 8Gi

  honcho:
    annotations:
      argocd.argoproj.io/sync-wave: "20"
    destination:
      namespace: ai
    source:
      path: components/ai/honcho
```

- [ ] **Step 2: Move Hermes after Honcho**

In the existing `hermes-agent` block, change the sync wave:

```yaml
  hermes-agent:
    annotations:
      argocd.argoproj.io/sync-wave: "21"
```

Expected: `honcho-postgres` syncs first, `honcho` syncs second, and Hermes syncs after both.

- [ ] **Step 3: Verify app blocks exist once**

Run:

```bash
rg -n "honcho-postgres:|  honcho:|hermes-agent:" clusters/talos/apps/20-applications.yaml
```

Expected: each app key appears once.

- [ ] **Step 4: Commit Argo registration**

Run:

```bash
git add clusters/talos/apps/20-applications.yaml
git commit -m "(feat): register honcho talos apps"
```

Expected: commit contains only `clusters/talos/apps/20-applications.yaml`.

---

### Task 4: Wire Hermes Seed Config to Honcho

**Files:**
- Modify: `components/ai/hermes-agent/configmap.yaml`
- Modify: `components/ai/hermes-agent/values.yaml`

- [ ] **Step 1: Add the Hermes memory seed block**

In `components/ai/hermes-agent/configmap.yaml`, add this block under the existing `stt` block and before `terminal`:

```yaml
    memory:
      memory_enabled: true
      user_profile_enabled: true
      memory_char_limit: 2200
      user_char_limit: 1375
      provider: honcho
```

- [ ] **Step 2: Add `honcho.json` to the same ConfigMap**

In `components/ai/hermes-agent/configmap.yaml`, add a second data key at the same indentation level as `config.yaml`:

```yaml
  honcho.json: |-
    {
      "baseUrl": "http://honcho.ai.svc.cluster.local:8000",
      "workspace": "hermes",
      "peerName": "vikas",
      "pinPeerName": true,
      "timeout": 20,
      "hosts": {
        "hermes": {
          "enabled": true,
          "aiPeer": "hermes",
          "recallMode": "hybrid",
          "sessionStrategy": "per-session",
          "contextTokens": 1200,
          "contextCadence": 1,
          "dialecticCadence": 5,
          "dialecticDepth": 1,
          "dialecticReasoningLevel": "low",
          "writeFrequency": "async",
          "observationMode": "directional"
        }
      }
    }
```

- [ ] **Step 3: Update the Hermes seed init script**

In `components/ai/hermes-agent/values.yaml`, change the `seed-config` args block to:

```yaml
        args:
          - |
            mkdir -p /opt/data/workspace
            if [ ! -f /opt/data/config.yaml ]; then
              cp /opt/bootstrap/config.yaml /opt/data/config.yaml
            fi
            if [ ! -f /opt/data/honcho.json ]; then
              cp /opt/bootstrap/honcho.json /opt/data/honcho.json
            fi
```

- [ ] **Step 4: Mount `honcho.json` into the init container**

In `components/ai/hermes-agent/values.yaml`, under `persistence.config.advancedMounts.app.seed-config`, add:

```yaml
          - path: /opt/bootstrap/honcho.json
            subPath: honcho.json
            readOnly: true
```

Expected: the configMap volume mounts both `/opt/bootstrap/config.yaml` and `/opt/bootstrap/honcho.json` into the `seed-config` init container.

- [ ] **Step 5: Render Hermes locally**

Run:

```bash
export ARGOCD_APP_NAME=hermes-agent
export ARGOCD_ENV_STORAGE_CLASS=ceph-block
export ARGOCD_ENV_VOLUME_SNAPSHOT_CLASS=csi-ceph-blockpool
export ARGOCD_ENV_VOLSYNC_CAPACITY=5Gi
export ARGOCD_ENV_VOLSYNC_CACHE_CAPACITY=8Gi
kustomize build --enable-helm components/ai/hermes-agent | envsubst > /tmp/hermes-agent.yaml
```

Expected: command exits 0 and `/tmp/hermes-agent.yaml` contains `honcho.json` in `hermes-agent-config`.

- [ ] **Step 6: Verify Hermes manifest against the cluster API**

Run:

```bash
KUBECONFIG=kubeconfig kubectl apply --dry-run=server -f /tmp/hermes-agent.yaml
```

Expected: command exits 0 with server-side dry-run output.

- [ ] **Step 7: Commit Hermes config wiring**

Run:

```bash
git add components/ai/hermes-agent/configmap.yaml components/ai/hermes-agent/values.yaml
git commit -m "(feat): configure hermes honcho memory"
```

Expected: commit contains only the two Hermes files.

---

### Task 5: Deploy and Verify Honcho

**Files:**
- No repository files changed.

- [ ] **Step 1: Push the implementation branch**

Run:

```bash
git status --short --branch
git push
```

Expected: branch pushes to `origin/main`, with only the planned commits ahead of origin before push.

- [ ] **Step 2: Wait for Argo to create the applications**

Run:

```bash
KUBECONFIG=kubeconfig kubectl get applications -n argo-system honcho-postgres honcho hermes-agent
```

Expected: all three applications exist.

- [ ] **Step 3: Wait for Honcho Postgres**

Run:

```bash
KUBECONFIG=kubeconfig kubectl rollout status -n ai deploy/honcho-postgres --timeout=10m
```

Expected: rollout completes successfully.

- [ ] **Step 4: Verify `vector` is installed**

Run:

```bash
KUBECONFIG=kubeconfig kubectl exec -n ai deploy/honcho-postgres -c app -- sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select extname from pg_extension where extname = '\''vector'\'';"'
```

Expected output:

```text
vector
```

- [ ] **Step 5: Wait for Honcho API and deriver**

Run:

```bash
KUBECONFIG=kubeconfig kubectl rollout status -n ai deploy/honcho-api --timeout=10m
KUBECONFIG=kubeconfig kubectl rollout status -n ai deploy/honcho-deriver --timeout=10m
```

Expected: both rollouts complete successfully.

- [ ] **Step 6: Verify Honcho health through the cluster service**

Run from the Hermes pod:

```bash
KUBECONFIG=kubeconfig kubectl exec -n ai deploy/hermes-agent -c app -- /opt/hermes/.venv/bin/python -c 'import urllib.request; print(urllib.request.urlopen("http://honcho.ai.svc.cluster.local:8000/health", timeout=10).read().decode())'
```

Expected output contains:

```json
{"status":"ok"}
```

- [ ] **Step 7: Check Honcho logs for model and migration errors**

Run:

```bash
KUBECONFIG=kubeconfig kubectl logs -n ai deploy/honcho-api -c app --tail=200
KUBECONFIG=kubeconfig kubectl logs -n ai deploy/honcho-deriver -c app --tail=200
```

Expected: API logs include database provisioning and no traceback. Deriver logs show the queue processor running and no model, embedding, or database configuration traceback.

---

### Task 6: Update Hermes Live PVC Config

**Files:**
- No repository files changed.

- [ ] **Step 1: Patch live Hermes config and write live `honcho.json`**

Run:

```bash
KUBECONFIG=kubeconfig kubectl exec -i -n ai deploy/hermes-agent -c app -- /opt/hermes/.venv/bin/python - <<'PY'
import json
from pathlib import Path
import yaml

home = Path("/opt/data")
config_path = home / "config.yaml"
honcho_path = home / "honcho.json"

config = yaml.safe_load(config_path.read_text()) or {}
config["memory"] = {
    "memory_enabled": True,
    "user_profile_enabled": True,
    "memory_char_limit": 2200,
    "user_char_limit": 1375,
    "provider": "honcho",
}
config_path.write_text(yaml.safe_dump(config, sort_keys=False))

honcho = {
    "baseUrl": "http://honcho.ai.svc.cluster.local:8000",
    "workspace": "hermes",
    "peerName": "vikas",
    "pinPeerName": True,
    "timeout": 20,
    "hosts": {
        "hermes": {
            "enabled": True,
            "aiPeer": "hermes",
            "recallMode": "hybrid",
            "sessionStrategy": "per-session",
            "contextTokens": 1200,
            "contextCadence": 1,
            "dialecticCadence": 5,
            "dialecticDepth": 1,
            "dialecticReasoningLevel": "low",
            "writeFrequency": "async",
            "observationMode": "directional",
        }
    },
}
honcho_path.write_text(json.dumps(honcho, indent=2) + "\n")
PY
```

Expected: command exits 0.

- [ ] **Step 2: Restart Hermes**

Run:

```bash
KUBECONFIG=kubeconfig kubectl rollout restart -n ai deploy/hermes-agent
KUBECONFIG=kubeconfig kubectl rollout status -n ai deploy/hermes-agent --timeout=10m
```

Expected: Hermes restarts successfully.

- [ ] **Step 3: Verify Hermes memory provider status**

Run:

```bash
KUBECONFIG=kubeconfig kubectl exec -n ai deploy/hermes-agent -c app -- /opt/hermes/.venv/bin/hermes memory status
```

Expected output includes:

```text
Provider:  honcho
Plugin:    installed
Status:    available
```

- [ ] **Step 4: Verify Hermes can still reach Honcho**

Run:

```bash
KUBECONFIG=kubeconfig kubectl exec -n ai deploy/hermes-agent -c app -- /opt/hermes/.venv/bin/python -c 'import urllib.request; print(urllib.request.urlopen("http://honcho.ai.svc.cluster.local:8000/health", timeout=10).read().decode())'
```

Expected output contains:

```json
{"status":"ok"}
```

---

### Task 7: Final Repository Check

**Files:**
- No repository files changed unless verification found a defect that required a targeted fix.

- [ ] **Step 1: Check git state**

Run:

```bash
git status --short --branch
git log --oneline origin/main..HEAD
```

Expected: branch is clean after commits, or only intentional implementation commits are ahead before the final push.

- [ ] **Step 2: Re-run render checks after all edits**

Run:

```bash
export ARGOCD_APP_NAME=honcho-postgres
export ARGOCD_ENV_STORAGE_CLASS=ceph-block
export ARGOCD_ENV_VOLUME_SNAPSHOT_CLASS=csi-ceph-blockpool
export ARGOCD_ENV_VOLSYNC_CAPACITY=10Gi
export ARGOCD_ENV_VOLSYNC_CACHE_CAPACITY=8Gi
kustomize build --enable-helm components/ai/honcho-postgres | envsubst > /tmp/honcho-postgres.yaml

kustomize build --enable-helm components/ai/honcho > /tmp/honcho.yaml

export ARGOCD_APP_NAME=hermes-agent
export ARGOCD_ENV_STORAGE_CLASS=ceph-block
export ARGOCD_ENV_VOLUME_SNAPSHOT_CLASS=csi-ceph-blockpool
export ARGOCD_ENV_VOLSYNC_CAPACITY=5Gi
export ARGOCD_ENV_VOLSYNC_CACHE_CAPACITY=8Gi
kustomize build --enable-helm components/ai/hermes-agent | envsubst > /tmp/hermes-agent.yaml

KUBECONFIG=kubeconfig kubectl apply --dry-run=server -f /tmp/honcho-postgres.yaml
KUBECONFIG=kubeconfig kubectl apply --dry-run=server -f /tmp/honcho.yaml
KUBECONFIG=kubeconfig kubectl apply --dry-run=server -f /tmp/hermes-agent.yaml
```

Expected: all commands exit 0.

- [ ] **Step 3: Verify no route was added for Honcho**

Run:

```bash
rg -n "HTTPRoute|honcho\\.\\$\\{CLUSTER_DOMAIN\\}|gethomepage" components/ai/honcho components/ai/honcho-postgres
```

Expected: command exits 1 and prints no matches.

- [ ] **Step 4: Report deployment status**

Include these facts in the handoff:

```text
Honcho Postgres rollout:
Honcho API rollout:
Honcho deriver rollout:
Honcho /health result:
Hermes memory provider:
Live Hermes PVC config updated:
Pushed commits:
```
