# Gitea OMV → Talos Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `gitea` and `gitea-runner` from the OMV (K3s) cluster to the Talos cluster, relocating gitea's Postgres database from `pg17-omv` into the Talos `postgres17` CNPG cluster and restoring the gitea PVC from the shared Kopia VolSync backend.

**Architecture:** Both clusters already share the same Kopia repository (OMV NFS export `omv-baymx.a113.internal:/storage0/VolsyncKopia`), so the gitea PVC is restored on Talos via a VolSync `ReplicationDestination` with `sourceIdentity`. The ~93 MB Postgres `gitea` DB is moved with `pg_dump -Fc` → `pg_restore` (no dependency on the broken OMV→Garage S3 path). App registrations move from `clusters/omv/apps/20-applications.yaml` to `clusters/talos/apps/20-applications.yaml`.

**Tech Stack:** Kubernetes (Talos + K3s), ArgoCD, CNPG (CloudNativePG), VolSync + Kopia, bjw-s app-template, Gateway API, ExternalSecrets + 1Password.

**Reference spec:** `docs/superpowers/specs/2026-06-09-gitea-omv-to-talos-migration-design.md`

---

## Conventions used in this plan

- **Talos kubectl:** `KUBECONFIG=kubeconfig kubectl ...` run from the repo root. (Repo default per `.mise.toml`; if that file is absent use `/tmp/talos-kubeconfig`.)
- **OMV kubectl:** `ssh root@omv-baymx 'kubectl ...'`. If ssh fails with "Could not resolve hostname", retry (intermittent DNS noted in the handoff).
- **Git commits:** conventional format (`(feat):`, `(fix):`, `(chore):`) per `AGENTS.md`.
- ArgoCD substitutes `${ARGOCD_APP_NAME}`, `${ARGOCD_ENV_*}`, `${CLUSTER_DOMAIN}`, `${GATEWAY_NAME}`, `${GATEWAY_NAMESPACE}`.

## Pre-flight facts (already verified — do not re-investigate)

- Gitea currently runs on OMV; registered in `clusters/omv/apps/20-applications.yaml` (`gitea` lines 60–85, `gitea-runner` lines 87–105).
- Gitea PVC `/var/lib/gitea` was pruned to ~3.1 GB (was 11.5 GB).
- Talos `postgres17` cluster is healthy, backing up to in-cluster Garage S3.
- OMV gitea DB host today: `pg17-omv-rw.default.svc.cluster.local`. Target: `postgres17-rw.default.svc.cluster.local`.
- The `volsync-mover` MutatingAdmissionPolicy on Talos injects the shared NFS repo into every mover; no per-app NFS wiring needed.
- Postgres creds come from 1Password item `cloudnative-pg`; gitea app creds + `RUNNER_TOKEN` from item `gitea`.

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `components/default/gitea/external-secret.yaml` | Modify | Repoint DB host OMV→Talos (`postgres17-rw`) |
| `components/default/gitea-runner/pvc-docker.yaml` | Modify | Change hardcoded `longhorn-volsync` → `ceph-block` |
| `clusters/talos/apps/20-applications.yaml` | Modify | Register `gitea` + `gitea-runner` (ceph-block storage) |
| `clusters/omv/apps/20-applications.yaml` | Modify | Remove `gitea` + `gitea-runner` (post-cutover) |

Runtime-only artifacts (not committed): the `pg_dump` file, the manual `ReplicationDestination` trigger, a fresh runner registration token.

---

## Task 1: Repoint gitea database host to Talos postgres17

**Files:**
- Modify: `components/default/gitea/external-secret.yaml:17` and `:21`

- [ ] **Step 1: Edit the DB host fields**

In `components/default/gitea/external-secret.yaml`, change:

```yaml
        INIT_POSTGRES_HOST: "pg17-omv-rw.default.svc.cluster.local"
```
to:
```yaml
        INIT_POSTGRES_HOST: "postgres17-rw.default.svc.cluster.local"
```

and change:

```yaml
        GITEA__database__HOST: "pg17-omv-rw.default.svc.cluster.local:5432"
```
to:
```yaml
        GITEA__database__HOST: "postgres17-rw.default.svc.cluster.local:5432"
```

Leave all other keys (`INIT_POSTGRES_DBNAME: "gitea"`, user/pass/super-pass, `GITEA__database__NAME: "gitea"`) unchanged.

- [ ] **Step 2: Verify only those two lines changed**

Run: `git diff components/default/gitea/external-secret.yaml`
Expected: exactly two lines changed, both `pg17-omv-rw` → `postgres17-rw`.

- [ ] **Step 3: Commit**

```bash
git add components/default/gitea/external-secret.yaml
git commit -m "(feat): point gitea db at talos postgres17"
```

---

## Task 2: Fix gitea-runner docker PVC storage class for Talos

**Why:** `pvc-docker.yaml` hardcodes `storageClassName: longhorn-volsync`, which does not exist on Talos. It must be `ceph-block` (the Talos default per `AGENTS.md`). The `gitea-runner` (`/data`) and `gitea-runner-docker` PVCs hold only caches, so no restore is needed — they start empty.

**Files:**
- Modify: `components/default/gitea-runner/pvc-docker.yaml:9`

- [ ] **Step 1: Edit the storage class**

In `components/default/gitea-runner/pvc-docker.yaml`, change:

```yaml
  storageClassName: longhorn-volsync
```
to:
```yaml
  storageClassName: ceph-block
```

- [ ] **Step 2: Verify the diff**

Run: `git diff components/default/gitea-runner/pvc-docker.yaml`
Expected: single line changed, `longhorn-volsync` → `ceph-block`.

- [ ] **Step 3: Commit**

```bash
git add components/default/gitea-runner/pvc-docker.yaml
git commit -m "(feat): use ceph-block for gitea-runner docker pvc on talos"
```

> Note: `pvc-docker.yaml` is a static PVC (not the VolSync `${ARGOCD_APP_NAME}` PVC). Because the OMV app currently uses this same file with `longhorn-volsync`, do NOT register gitea-runner on OMV after this commit. Task 6 removes the OMV registration; this change only takes effect on Talos where the file is rendered next.

---

## Task 3: Register gitea and gitea-runner on Talos

**Files:**
- Modify: `clusters/talos/apps/20-applications.yaml` (append two application entries under `applications:`)

- [ ] **Step 1: Add the `gitea` application entry**

Append to `clusters/talos/apps/20-applications.yaml` (keep alphabetical-ish grouping near other `default`-namespace apps; exact position does not affect ArgoCD):

```yaml
  gitea:
    annotations:
      argocd.argoproj.io/sync-wave: "20"
    ignoreDifferences:
      - group: ""
        kind: PersistentVolumeClaim
        name: gitea
        jsonPointers:
          - /spec/dataSource
          - /spec/dataSourceRef
    destination:
      namespace: default
    source:
      path: components/default/gitea
      plugin:
        env:
          - name: STORAGE_CLASS
            value: ceph-block
          - name: VOLUME_SNAPSHOT_CLASS
            value: csi-ceph-blockpool
          - name: VOLSYNC_CAPACITY
            value: 20Gi
          - name: VOLSYNC_CACHE_CAPACITY
            value: 30Gi
          - name: VOLSYNC_SCHEDULE
            value: "20 */6 * * *"
```

- [ ] **Step 2: Add the `gitea-runner` application entry**

Append:

```yaml
  gitea-runner:
    annotations:
      argocd.argoproj.io/sync-wave: "20"
    destination:
      namespace: default
    source:
      path: components/default/gitea-runner
      plugin:
        env:
          - name: STORAGE_CLASS
            value: ceph-block
          - name: VOLUME_SNAPSHOT_CLASS
            value: csi-ceph-blockpool
          - name: VOLSYNC_CAPACITY
            value: 2Gi
          - name: VOLSYNC_CACHE_CAPACITY
            value: 8Gi
          - name: VOLSYNC_SCHEDULE
            value: "40 */6 * * *"
```

- [ ] **Step 3: Verify YAML validity**

Run: `KUBECONFIG=kubeconfig kubectl apply --dry-run=client -f clusters/talos/apps/20-applications.yaml 2>&1 | tail -5`
Expected: no YAML parse errors. (This file is consumed by an ApplicationSet/Helm values generator; a client dry-run just validates syntax. If the file is a values document rather than a manifest and dry-run errors on `kind`, instead validate with: `python3 -c "import yaml,sys; yaml.safe_load(open('clusters/talos/apps/20-applications.yaml')); print('ok')"` — expected `ok`.)

- [ ] **Step 4: Commit**

```bash
git add clusters/talos/apps/20-applications.yaml
git commit -m "(feat): register gitea and gitea-runner on talos"
```

- [ ] **Step 5: Do NOT push yet**

The cutover (Tasks 4–5) must run before Talos ArgoCD brings gitea up, otherwise gitea starts against an empty DB/PVC. Hold the push until Task 5 Step 1.

> If your repo auto-syncs ArgoCD on push, the push in Task 5 is the controlled trigger. If ArgoCD requires manual sync, you may push now and sync manually in Task 5.

---

## Task 4: Quiesce OMV gitea and dump the database

**Files:** none (runtime operations).

- [ ] **Step 1: Scale OMV gitea to 0 to stop writes**

Run:
```bash
ssh root@omv-baymx 'kubectl scale deploy -n default -l app.kubernetes.io/name=gitea --replicas=0'
```
Expected: `deployment.apps/gitea-... scaled`.

- [ ] **Step 2: Confirm no active gitea DB connections on OMV**

Run:
```bash
ssh root@omv-baymx 'kubectl exec -n default pg17-omv-1 -c postgres -- psql -U postgres -d gitea -tAc "SELECT count(*) FROM pg_stat_activity WHERE datname='\''gitea'\'' AND pid <> pg_backend_pid();"'
```
Expected: `0` (or near-zero; re-run until `0`).

- [ ] **Step 3: Dump the gitea database (custom format) to a local file**

Run:
```bash
ssh root@omv-baymx 'kubectl exec -n default pg17-omv-1 -c postgres -- pg_dump -U postgres -Fc -d gitea' > /tmp/gitea.dump
ls -lh /tmp/gitea.dump
```
Expected: a `/tmp/gitea.dump` file on the order of tens of MB (DB is ~93 MB uncompressed).

- [ ] **Step 4: Sanity-check the dump is readable**

Run:
```bash
ssh root@omv-baymx 'kubectl exec -n default pg17-omv-1 -c postgres -- pg_dump -U postgres -Fc -d gitea' > /tmp/gitea.dump
pg_restore -l /tmp/gitea.dump | head -5
```
Expected: a table-of-contents listing (lines beginning with `;` and TOC entries). If `pg_restore` is not installed locally, instead verify size > 1 MB: `test $(stat -f%z /tmp/gitea.dump) -gt 1000000 && echo ok`.

> Non-destructive: OMV `pg17-omv` and the OMV gitea PVC remain intact. This is the rollback anchor.

---

## Task 5: Bring gitea up on Talos, restore DB and PVC

**Files:** none (runtime + the controlled push).

- [ ] **Step 1: Push the committed Talos registration**

Run:
```bash
git push
```
Then trigger/confirm ArgoCD picks it up (manual-sync repos):
```bash
KUBECONFIG=kubeconfig kubectl annotate application gitea -n argo-system argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true
KUBECONFIG=kubeconfig kubectl annotate application gitea-runner -n argo-system argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true
```
Expected: ArgoCD creates the `gitea` and `gitea-runner` Applications.

- [ ] **Step 2: Let the gitea PVC + ReplicationDestination materialize, then verify snapshot freshness**

Run:
```bash
KUBECONFIG=kubeconfig kubectl get replicationdestination gitea-dst -n default -o jsonpath='{.status.latestImage.name}{"\n"}'
KUBECONFIG=kubeconfig kubectl get replicationsource gitea -n default -o jsonpath='{.status.lastManualSync}{" "}{.status.lastSyncTime}{"\n"}' 2>/dev/null
```
Expected: `gitea-dst` exists. Confirm the latest available Kopia snapshot for source `gitea` predates Task 4 Step 1 quiesce (it is the last OMV-created snapshot). If the most recent OMV snapshot is stale, note it — repos changed since then would be lost. (Acceptable per design; the bulk of repo data is static.)

- [ ] **Step 3: Trigger the VolSync restore into the Talos gitea PVC**

Run:
```bash
KUBECONFIG=kubeconfig kubectl patch replicationdestination gitea-dst -n default --type merge -p '{"spec":{"trigger":{"manual":"restore-once"}}}'
KUBECONFIG=kubeconfig kubectl wait --for=jsonpath='{.status.latestMoverStatus.result}'=Successful replicationdestination/gitea-dst -n default --timeout=900s
```
Expected: restore Job runs and completes; `latestMoverStatus.result` = `Successful`. The `gitea` PVC binds from the restored snapshot.

> If `gitea-dst` was already restored on first sync, re-running `restore-once` with a new value is required to re-trigger. If the PVC is already bound from the initial restore, skip the patch and just confirm `kubectl get pvc gitea -n default` is `Bound`.

- [ ] **Step 4: Ensure the gitea role/DB exist on Talos postgres17**

The gitea pod's `postgres-init` initContainer creates the `gitea` role + database using `INIT_POSTGRES_SUPER_PASS`. Confirm:
```bash
KUBECONFIG=kubeconfig kubectl exec -n default postgres17-1 -c postgres -- psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='gitea';"
```
Expected: `1`. If empty, the gitea pod hasn't run init yet — wait for the pod to start (it will create it), then proceed. (Primary pod name may differ; resolve with `KUBECONFIG=kubeconfig kubectl get pods -n default -l cnpg.io/cluster=postgres17,cnpg.io/instanceRole=primary -o name`.)

- [ ] **Step 5: Restore the dump into Talos postgres17**

Copy the dump into the primary and restore as superuser, remapping ownership to `gitea`:
```bash
PRIMARY=$(KUBECONFIG=kubeconfig kubectl get pods -n default -l cnpg.io/cluster=postgres17,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
KUBECONFIG=kubeconfig kubectl cp /tmp/gitea.dump default/$PRIMARY:/tmp/gitea.dump -c postgres
KUBECONFIG=kubeconfig kubectl exec -n default $PRIMARY -c postgres -- \
  pg_restore -U postgres --no-owner --role=gitea --clean --if-exists -d gitea /tmp/gitea.dump
```
Expected: `pg_restore` completes. Warnings about non-existent objects during `--clean` on a fresh DB are benign. Errors mentioning missing `gitea` role mean Step 4 wasn't satisfied — fix and re-run.

- [ ] **Step 6: Verify the restored data row counts**

Run:
```bash
KUBECONFIG=kubeconfig kubectl exec -n default $PRIMARY -c postgres -- psql -U postgres -d gitea -tAc "SELECT (SELECT count(*) FROM \"user\"), (SELECT count(*) FROM repository);"
```
Expected: non-zero user and repository counts matching OMV. Cross-check against OMV:
```bash
ssh root@omv-baymx 'kubectl exec -n default pg17-omv-1 -c postgres -- psql -U postgres -d gitea -tAc "SELECT (SELECT count(*) FROM \"user\"), (SELECT count(*) FROM repository);"'
```
Expected: counts match.

- [ ] **Step 7: Restart gitea on Talos so it connects to the freshly-restored DB**

Run:
```bash
KUBECONFIG=kubeconfig kubectl rollout restart deploy -n default -l app.kubernetes.io/name=gitea
KUBECONFIG=kubeconfig kubectl rollout status deploy -n default -l app.kubernetes.io/name=gitea --timeout=300s
```
Expected: gitea pod `Running`, `1/1` ready.

- [ ] **Step 8: Remove the local dump**

Run: `rm -f /tmp/gitea.dump`

---

## Task 6: Verify the Talos gitea instance

**Files:** none.

- [ ] **Step 1: Web UI reachable**

Run:
```bash
KUBECONFIG=kubeconfig kubectl run gitea-check --rm -i --restart=Never --image=ghcr.io/home-operations/busybox:1.38.0 -- \
  sh -c 'wget -qO- http://gitea.default.svc.cluster.local:3000/api/healthz; echo'
```
Expected: a JSON health response with `"status":"pass"` (or HTTP 200 body).

- [ ] **Step 2: External route resolves**

In a browser or via curl from a host that can reach the Talos gateway:
```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://gitea.${CLUSTER_DOMAIN}/
```
Expected: `200` (or `302` to login). Login as the admin user and confirm repos/orgs are present (PVC + DB restore OK).

- [ ] **Step 3: Confirm a known repo's git data is present**

In the gitea UI, open a repository known to exist and verify commit history loads. (Validates `/var/lib/gitea/git` restored.)

- [ ] **Step 4: Re-register the runner with a fresh token**

In gitea UI → Admin → Actions → Runners → "Create new Runner", copy the registration token. Update the 1Password item `gitea` field `RUNNER_TOKEN` with it. Then force the secret + runner to refresh:
```bash
KUBECONFIG=kubeconfig kubectl annotate externalsecret gitea-runner -n default force-sync=$(date +%s) --overwrite
KUBECONFIG=kubeconfig kubectl rollout restart deploy -n default -l app.kubernetes.io/name=gitea-runner
KUBECONFIG=kubeconfig kubectl rollout status deploy -n default -l app.kubernetes.io/name=gitea-runner --timeout=300s
```
Expected: runner shows `idle`/online in gitea Admin → Actions → Runners.

- [ ] **Step 5: Confirm runner executes a job**

Trigger any repo's Actions workflow (or push a trivial commit to a repo with a workflow). 
Expected: the job is picked up by the Talos runner and completes.

- [ ] **Step 6: Confirm a new VolSync backup succeeds from Talos**

Run:
```bash
KUBECONFIG=kubeconfig kubectl patch replicationsource gitea -n default --type merge -p '{"spec":{"trigger":{"manual":"verify-once"}}}'
KUBECONFIG=kubeconfig kubectl wait --for=jsonpath='{.status.latestMoverStatus.result}'=Successful replicationsource/gitea -n default --timeout=900s
```
Expected: `Successful`. (Confirms Talos writes to the shared Kopia repo with 0 errors.)

---

## Task 7: Decommission gitea on OMV

**Files:**
- Modify: `clusters/omv/apps/20-applications.yaml` (remove `gitea` and `gitea-runner` entries, lines 60–105)

**Only proceed after Task 6 passes.**

- [ ] **Step 1: Remove both entries from the OMV applications file**

In `clusters/omv/apps/20-applications.yaml`, delete the `gitea:` block (currently lines 60–85) and the `gitea-runner:` block (currently lines 87–105). Leave the surrounding entries (`homepage`, `renovate`) intact.

- [ ] **Step 2: Verify YAML validity**

Run: `python3 -c "import yaml; yaml.safe_load(open('clusters/omv/apps/20-applications.yaml')); print('ok')"`
Expected: `ok`.

- [ ] **Step 3: Confirm the two entries are gone**

Run: `git diff clusters/omv/apps/20-applications.yaml`
Expected: only the `gitea` and `gitea-runner` blocks removed; no other changes.

- [ ] **Step 4: Commit and push**

```bash
git add clusters/omv/apps/20-applications.yaml
git commit -m "(chore): remove gitea and gitea-runner from omv after talos cutover"
git push
```

- [ ] **Step 5: Let OMV ArgoCD prune, then confirm removal**

```bash
ssh root@omv-baymx 'kubectl annotate application cloudnative-apps -n argo-system argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true'
ssh root@omv-baymx 'kubectl get deploy -n default -l app.kubernetes.io/name=gitea; kubectl get deploy -n default -l app.kubernetes.io/name=gitea-runner'
```
Expected: no gitea/gitea-runner deployments remain on OMV. (The OMV gitea PVC and `pg17-omv` `gitea` DB are left in place as a rollback anchor; clean them up later, separately.)

> The exact OMV ArgoCD Application name for the apps set may differ from `cloudnative-apps`; resolve with `ssh root@omv-baymx 'kubectl get applications -n argo-system'` and refresh the one whose source generates these app entries.

---

## Rollback (if Task 6 fails)

1. Scale Talos gitea to 0: `KUBECONFIG=kubeconfig kubectl scale deploy -n default -l app.kubernetes.io/name=gitea --replicas=0`.
2. Scale OMV gitea back up: `ssh root@omv-baymx 'kubectl scale deploy -n default -l app.kubernetes.io/name=gitea --replicas=1'`.
3. OMV `pg17-omv` and the OMV gitea PVC are unchanged, so OMV gitea resumes its prior state.
4. Revert the Task 1–3 commits if abandoning the migration; do NOT run Task 7.

---

## Out of scope

- Fixing/decommissioning the OMV `pg17-omv` → Garage S3 backup endpoint (handoff Option A/B).
- Dropping orphaned `blinko` / `mac` / `memos` DBs in `pg17-omv`.
- Cleaning up the leftover OMV gitea PVC and `gitea` DB (do after a confidence window).
- SSH-on-2222 VIP cutover for `ssh.${CLUSTER_DOMAIN}` (see spec Open Items) — confirm DNS/consumers separately if SSH cloning is used.
