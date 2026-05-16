# Garage OMV to Synology Staging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Copy the current OMV-hosted Garage S3 data and metadata to Synology as a verified staging/backup copy without changing the active S3 endpoint.

**Architecture:** Keep Garage running on OMV during the long bulk data copy, then use a short maintenance window to stop Garage and perform a final `--delete` sync of both data and LMDB metadata. Synology is the staging target in this plan, not the new Garage runtime; the later Talos/storage-worker Garage cutover remains a separate plan.

**Tech Stack:** Garage v2.3.0, OMV/K3s, Talos Kubernetes, Synology DSM over SSH, `rsync`, Garage CLI, CNPG scheduled backups.

---

## Context

Current Garage config:
- Image: `dxflrs/garage:v2.3.0`
- Data path on OMV: `/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage`
- Metadata path on OMV: `/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage-meta`
- Config: `metadata_dir = "/meta"`, `data_dir = "/data"`, `db_engine = "lmdb"`, `metadata_auto_snapshot_interval = "6h"`, `replication_factor = 1`

Synology staging targets:
- Data: `/volume1/staging/garage`
- Metadata: `/volume1/staging/garage-meta`
- Logs/manifests: `/volume1/staging/garage-migration`

Connection variables used by the commands below:

```bash
export OMV_SSH=vikaspogu@omv-baymx.a113.internal
export SYNO_SSH=vikaspogu@10.30.10.100
export SYNO_SSH_PORT=24
```

Important constraints:
- Do not final-sync `garage-meta` while Garage is running. LMDB metadata must be copied cold or from a valid Garage snapshot.
- Do not change `s3.omv.a113.casa` during this staging plan.
- `omv.kubeconfig` is currently unauthorized from this workstation; use SSH to OMV and `sudo k3s kubectl` for OMV cluster commands.
- Run `rsync` on OMV and push to Synology. Do not invoke rsync with both source and destination as remote SSH endpoints; normal rsync cannot copy that way.
- `replication_factor = 1` means OMV is the only live copy before this migration. Do not delete or alter OMV source data until the Synology staging copy has checksum verification and a restore smoke test.

References:
- Garage config separates `metadata_dir` and `data_dir`, and supports metadata snapshots through `metadata_auto_snapshot_interval`: https://garagehq.deuxfleurs.fr/documentation/reference-manual/configuration/
- Garage CLI uses `garage status`, `garage bucket list`, and layout commands from inside the running node: https://garagehq.deuxfleurs.fr/documentation/quick-start/
- Garage multi-HDD docs explain data block placement and later storage-worker migration behavior: https://garagehq.deuxfleurs.fr/documentation/operations/multi-hdd/
- Garage recovery docs describe metadata snapshot restore locations under `<metadata_dir>/snapshots`: https://garagehq.deuxfleurs.fr/documentation/operations/recovering/

---

## Task 1: Access and Inventory

**Files:**
- No repo changes.

- [ ] **Step 1: Verify SSH access**

Run from the workstation:

```bash
ssh "$OMV_SSH" 'hostname && id'
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'hostname && id'
```

Expected:
- OMV responds.
- Synology responds on `10.30.10.100:24`.

- [ ] **Step 2: Verify Garage pod access from OMV**

Run from the workstation:

```bash
ssh "$OMV_SSH" 'sudo k3s kubectl -n default get deploy,pod,svc -l app.kubernetes.io/instance=garage -o wide'
ssh "$OMV_SSH" 'sudo k3s kubectl -n default exec deploy/garage -c app -- /garage status'
ssh "$OMV_SSH" 'sudo k3s kubectl -n default exec deploy/garage -c app -- /garage bucket list'
ssh "$OMV_SSH" 'sudo k3s kubectl -n default exec deploy/garage -c app -- /garage key list'
```

Expected:
- Garage deployment and pod are present on OMV.
- `garage status` shows the current node healthy.
- Bucket/key lists render without errors.

- [ ] **Step 3: Measure source and target capacity**

Run from the workstation:

```bash
ssh "$OMV_SSH" 'sudo du -sh /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage-meta'
ssh "$OMV_SSH" 'df -h /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0'
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'df -h /volume1'
```

Expected:
- Synology free space is greater than Garage data + metadata size, with room for growth.

---

## Task 2: Prepare Synology Staging Directories

**Files:**
- No repo changes.

- [ ] **Step 1: Create staging directories**

Run from the workstation:

```bash
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'mkdir -p /volume1/staging/garage /volume1/staging/garage-meta /volume1/staging/garage-migration'
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'chmod 700 /volume1/staging/garage /volume1/staging/garage-meta /volume1/staging/garage-migration'
```

Expected:
- Directories exist and are writable by `vikaspogu`.

- [ ] **Step 2: Create a dedicated OMV-to-Synology migration key**

Run from the workstation:

```bash
ssh "$OMV_SSH" 'install -d -m 700 ~/.ssh && test -f ~/.ssh/garage-migration || ssh-keygen -t ed25519 -f ~/.ssh/garage-migration -N "" -C garage-omv-to-synology'
ssh "$OMV_SSH" 'cat ~/.ssh/garage-migration.pub' | ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'install -d -m 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

Expected:
- OMV has `~/.ssh/garage-migration`.
- Synology has the public key in `~/.ssh/authorized_keys`.

- [ ] **Step 3: Confirm OMV can push to Synology**

Run from the workstation:

```bash
ssh "$OMV_SSH" "printf 'garage migration ssh test\n' > /tmp/garage-migration-test.txt && rsync -av -e 'ssh -p 24 -i ~/.ssh/garage-migration -o IdentitiesOnly=yes' /tmp/garage-migration-test.txt $SYNO_SSH:/volume1/staging/garage-migration/"
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'cat /volume1/staging/garage-migration/garage-migration-test.txt'
```

Expected:
- Synology prints `garage migration ssh test`.

---

## Task 3: Online Bulk Copy

**Files:**
- No repo changes.

- [ ] **Step 1: Take a Garage metadata snapshot**

Run from the workstation:

```bash
ssh "$OMV_SSH" 'sudo k3s kubectl -n default exec deploy/garage -c app -- /garage meta snapshot'
ssh "$OMV_SSH" 'sudo find /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage-meta/snapshots -maxdepth 1 -mindepth 1 -printf "%T@ %p\n" | sort -n | tail'
```

Expected:
- Snapshot command exits successfully.
- The metadata snapshots directory contains recent entries.

- [ ] **Step 2: Start online data copy from OMV to Synology**

Run inside a tmux session on OMV:

```bash
OMV_GARAGE_DATA=/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage
SYNO_SSH=vikaspogu@10.30.10.100
SYNO_GARAGE_DATA=/volume1/staging/garage
RSYNC_BWLIMIT_KB=0

rsync -aH --numeric-ids --info=progress2 --info=stats2 --partial --bwlimit="$RSYNC_BWLIMIT_KB" \
  -e 'ssh -p 24 -i ~/.ssh/garage-migration -o IdentitiesOnly=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=20' \
  "$OMV_GARAGE_DATA/" \
  "$SYNO_SSH:$SYNO_GARAGE_DATA/"
```

Expected:
- Long-running copy completes.
- Do not use `--delete` in this online pass.

- [ ] **Step 3: Copy metadata snapshots only**

Run inside a tmux session on OMV:

```bash
OMV_GARAGE_META=/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage-meta
SYNO_SSH=vikaspogu@10.30.10.100
SYNO_GARAGE_META=/volume1/staging/garage-meta
RSYNC_BWLIMIT_KB=0

rsync -aHS --numeric-ids --info=progress2 --info=stats2 --partial --bwlimit="$RSYNC_BWLIMIT_KB" \
  -e 'ssh -p 24 -i ~/.ssh/garage-migration -o IdentitiesOnly=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=20' \
  "$OMV_GARAGE_META/snapshots/" \
  "$SYNO_SSH:$SYNO_GARAGE_META/snapshots/"
```

Expected:
- Snapshot copy completes.
- The live LMDB database itself is not treated as authoritative until the cold final sync.

`RSYNC_BWLIMIT_KB=0` means unlimited. Set it to a KiB/s value, for example `25000`, if the online copy needs to leave bandwidth for other workloads.

---

## Task 4: Final Freeze and Cold Sync

**Files:**
- No repo changes.

- [ ] **Step 1: Suspend scheduled CNPG base backups**

Run from the workstation against the Talos cluster:

```bash
kubectl -n default patch scheduledbackup postgres17 --type=merge -p '{"spec":{"suspend":true}}'
kubectl -n default get scheduledbackup postgres17 -o jsonpath='{.spec.suspend}{"\n"}'
```

Expected:
- Output is `true`.

Note: CNPG WAL archiving can still retry while Garage is unavailable. Keep the Garage outage short and verify CNPG after resuming.

- [ ] **Step 2: Check CNPG WAL headroom and force a checkpoint**

Run from the workstation against the Talos cluster:

```bash
PRIMARY=$(kubectl -n default get pods -l cnpg.io/cluster=postgres17,role=primary -o jsonpath='{.items[0].metadata.name}')
kubectl -n default exec "$PRIMARY" -c postgres -- psql -U postgres -d postgres -c 'CHECKPOINT;'
kubectl -n default exec "$PRIMARY" -c postgres -- sh -c 'du -sh "$PGDATA/pg_wal"; df -h "$PGDATA"'
```

Expected:
- `CHECKPOINT` succeeds.
- The Postgres volume has enough free space to tolerate a short Garage outage while WAL archiving retries.

- [ ] **Step 3: Inventory active S3 writers**

Run from the workstation:

```bash
rg -n 's3\\.omv|AWS_ENDPOINT_URL|STORAGE_ENDPOINT|garage-access-keys' clusters components
kubectl get deploy -A -o name | rg 'ivan|reactive-resume' || true
kubectl get cronjob -A -o name | rg 'volsync|kopia|backup|s3|garage' || true
```

Expected:
- Current Talos deployment inventory includes `deployment.apps/reactive-resume`.
- If this command shows additional running S3 writers, stop and add explicit scale/suspend commands before stopping Garage.

- [ ] **Step 4: Stop known app-level S3 writers**

Run from the workstation against the Talos cluster:

```bash
kubectl -n default scale deploy/reactive-resume --replicas=0
kubectl -n default wait --for=delete pod -l app.kubernetes.io/instance=reactive-resume --timeout=180s
kubectl get deploy -A | rg 'ivan|reactive-resume' || true
```

Expected:
- `reactive-resume` is scaled down.
- No additional running S3 writer is left unhandled from Step 3.

- [ ] **Step 5: Stop Garage on OMV**

Run from the workstation:

```bash
ssh "$OMV_SSH" 'sudo k3s kubectl -n default get pods --show-labels | grep garage'
ssh "$OMV_SSH" 'sudo k3s kubectl -n default scale deploy/garage --replicas=0'
ssh "$OMV_SSH" 'sudo k3s kubectl -n default wait --for=delete pod -l app.kubernetes.io/instance=garage --timeout=180s || sudo k3s kubectl -n default wait --for=delete pod -l app.kubernetes.io/name=garage --timeout=180s'
ssh "$OMV_SSH" 'sudo k3s kubectl -n default get pods -l app.kubernetes.io/instance=garage'
```

Expected:
- No Garage pods remain.

- [ ] **Step 6: Final cold sync data with delete**

Run inside a tmux session on OMV:

```bash
OMV_GARAGE_DATA=/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage
SYNO_SSH=vikaspogu@10.30.10.100
SYNO_GARAGE_DATA=/volume1/staging/garage
RSYNC_BWLIMIT_KB=0

rsync -aH --numeric-ids --delete --info=progress2 --info=stats2 --partial --bwlimit="$RSYNC_BWLIMIT_KB" \
  -e 'ssh -p 24 -i ~/.ssh/garage-migration -o IdentitiesOnly=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=20' \
  "$OMV_GARAGE_DATA/" \
  "$SYNO_SSH:$SYNO_GARAGE_DATA/"
```

Expected:
- Final data delta completes while Garage is stopped.

- [ ] **Step 7: Final cold sync metadata with delete**

Run inside a tmux session on OMV:

```bash
OMV_GARAGE_META=/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage-meta
SYNO_SSH=vikaspogu@10.30.10.100
SYNO_GARAGE_META=/volume1/staging/garage-meta
RSYNC_BWLIMIT_KB=0

rsync -aHS --numeric-ids --delete --info=progress2 --info=stats2 --partial --bwlimit="$RSYNC_BWLIMIT_KB" \
  -e 'ssh -p 24 -i ~/.ssh/garage-migration -o IdentitiesOnly=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=20' \
  "$OMV_GARAGE_META/" \
  "$SYNO_SSH:$SYNO_GARAGE_META/"
```

Expected:
- Final metadata delta completes while Garage is stopped.
- Synology now has the authoritative cold copy of live metadata plus the copied `snapshots/` tree. Keep both; use the cold copy for a direct restore rehearsal and the snapshots tree as the fallback Garage-supported metadata restore source.

---

## Task 5: Verify Synology Copy

**Files:**
- No repo changes.

- [ ] **Step 1: Run dry-run checksum comparison for data**

Run inside a tmux session on OMV:

```bash
OMV_GARAGE_DATA=/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage
SYNO_SSH=vikaspogu@10.30.10.100
SYNO_GARAGE_DATA=/volume1/staging/garage

rsync -aHni --checksum --delete \
  -e 'ssh -p 24 -i ~/.ssh/garage-migration -o IdentitiesOnly=yes' \
  "$OMV_GARAGE_DATA/" \
  "$SYNO_SSH:$SYNO_GARAGE_DATA/"
```

Expected:
- No itemized file changes.

- [ ] **Step 2: Run dry-run checksum comparison for metadata**

Run inside a tmux session on OMV:

```bash
OMV_GARAGE_META=/srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage-meta
SYNO_SSH=vikaspogu@10.30.10.100
SYNO_GARAGE_META=/volume1/staging/garage-meta

rsync -aHSni --checksum --delete \
  -e 'ssh -p 24 -i ~/.ssh/garage-migration -o IdentitiesOnly=yes' \
  "$OMV_GARAGE_META/" \
  "$SYNO_SSH:$SYNO_GARAGE_META/"
```

Expected:
- No itemized file changes.

- [ ] **Step 3: Record size and file count manifests**

Run from the workstation:

```bash
ssh "$OMV_SSH" 'sudo du -sh /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage-meta'
ssh "$OMV_SSH" 'sudo du -s --apparent-size /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage-meta'
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'du -sh /volume1/staging/garage /volume1/staging/garage-meta'
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'du -s --apparent-size /volume1/staging/garage /volume1/staging/garage-meta'
ssh "$OMV_SSH" 'sudo find /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage -type f | wc -l'
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'find /volume1/staging/garage -type f | wc -l'
ssh "$OMV_SSH" 'sudo find /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage-meta -type f | wc -l'
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'find /volume1/staging/garage-meta -type f | wc -l'
ssh "$OMV_SSH" 'sudo find /srv/dev-disk-by-uuid-9d2e4cb9-8825-4168-8153-e020ee524474/storage0/garage -type d | wc -l'
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'find /volume1/staging/garage -type d | wc -l'
```

Expected:
- Source and destination sizes are close.
- Source and destination file counts match.

---

## Task 6: Staging Restore Smoke Test

**Files:**
- No repo changes.

- [ ] **Step 1: Create an isolated metadata copy for the smoke test**

Run from the workstation:

```bash
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'mkdir -p /volume1/staging/garage-meta-smoke'
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'rsync -aHS --delete /volume1/staging/garage-meta/ /volume1/staging/garage-meta-smoke/'
```

Expected:
- `/volume1/staging/garage-meta-smoke` exists as a disposable copy of the staged metadata.
- The authoritative staged metadata at `/volume1/staging/garage-meta` remains untouched by the smoke test.

- [ ] **Step 2: Create a temporary Garage config on Synology**

Run from the workstation:

```bash
GARAGE_RPC_SECRET=$(ssh "$OMV_SSH" 'sudo k3s kubectl -n default get secret garage-secret -o jsonpath="{.data.GARAGE_RPC_SECRET}"' | base64 -d)
GARAGE_ADMIN_TOKEN=$(ssh "$OMV_SSH" 'sudo k3s kubectl -n default get secret garage-secret -o jsonpath="{.data.GARAGE_ADMIN_TOKEN}"' | base64 -d)
GARAGE_METRICS_TOKEN=$(ssh "$OMV_SSH" 'sudo k3s kubectl -n default get secret garage-secret -o jsonpath="{.data.GARAGE_METRICS_TOKEN}"' | base64 -d)

ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'cat > /volume1/staging/garage-migration/garage-smoke.toml' <<EOF
metadata_dir = "/meta"
data_dir = "/data"
db_engine = "lmdb"
metadata_auto_snapshot_interval = "6h"

replication_factor = 1

compression_level = 2

rpc_bind_addr = "127.0.0.1:13901"
rpc_public_addr = "127.0.0.1:13901"
rpc_secret = "$GARAGE_RPC_SECRET"

[s3_api]
s3_region = "garage"
api_bind_addr = "127.0.0.1:13900"

[admin]
api_bind_addr = "127.0.0.1:13903"
admin_token = "$GARAGE_ADMIN_TOKEN"
metrics_token = "$GARAGE_METRICS_TOKEN"
EOF
```

Expected:
- The temporary config exists only under `/volume1/staging/garage-migration`.
- It binds only to `127.0.0.1` on alternate ports and does not conflict with production Garage.

- [ ] **Step 3: Start a disposable Garage container against staging**

Run from the workstation:

```bash
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'docker rm -f garage-staging-smoke 2>/dev/null || true'
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'docker run -d --name garage-staging-smoke --network host -v /volume1/staging/garage-migration/garage-smoke.toml:/etc/garage.toml:ro -v /volume1/staging/garage:/data:ro -v /volume1/staging/garage-meta-smoke:/meta dxflrs/garage:v2.3.0 /garage -c /etc/garage.toml server'
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'sleep 15 && docker exec garage-staging-smoke /garage -c /etc/garage.toml status'
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'docker exec garage-staging-smoke /garage -c /etc/garage.toml bucket list'
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'docker logs --tail 80 garage-staging-smoke'
```

Expected:
- The temporary Garage server starts.
- `garage status` and `garage bucket list` work against the staged metadata.
- Logs do not show LMDB open errors, permission errors, or missing data directory errors.

- [ ] **Step 4: Verify S3 list through the disposable server**

Run from the workstation:

```bash
ACCESS_KEY_ID=$(kubectl -n default get secret garage-access-keys -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)
ACCESS_SECRET_KEY=$(kubectl -n default get secret garage-access-keys -o jsonpath='{.data.ACCESS_SECRET_KEY}' | base64 -d)
REGION=$(kubectl -n default get secret garage-access-keys -o jsonpath='{.data.REGION}' | base64 -d)

ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" "docker run --rm --network host -e AWS_ACCESS_KEY_ID='$ACCESS_KEY_ID' -e AWS_SECRET_ACCESS_KEY='$ACCESS_SECRET_KEY' -e AWS_DEFAULT_REGION='$REGION' amazon/aws-cli s3 ls --endpoint-url http://127.0.0.1:13900"
```

Expected:
- The command lists Garage buckets through the disposable Synology-hosted Garage server.

- [ ] **Step 5: Stop the disposable Garage container**

Run from the workstation:

```bash
ssh -p "$SYNO_SSH_PORT" "$SYNO_SSH" 'docker rm -f garage-staging-smoke'
```

Expected:
- The smoke-test container is removed.
- Production Garage on OMV is still stopped until Task 7 resumes it.

If Synology Docker/Container Manager is unavailable, stop here. The copy may be checksum-verified, but it is not restore-verified; perform this smoke test on the eventual Garage runtime before any DNS or S3 endpoint cutover.

---

## Task 7: Resume Services

**Files:**
- No repo changes.

- [ ] **Step 1: Start Garage on OMV**

Run from the workstation:

```bash
ssh "$OMV_SSH" 'sudo k3s kubectl -n default scale deploy/garage --replicas=1'
ssh "$OMV_SSH" 'sudo k3s kubectl -n default rollout status deploy/garage --timeout=180s'
ssh "$OMV_SSH" 'sudo k3s kubectl -n default exec deploy/garage -c app -- /garage status'
ssh "$OMV_SSH" 'sudo k3s kubectl -n default exec deploy/garage -c app -- /garage bucket list'
```

Expected:
- Garage is healthy.
- Bucket list still renders.

- [ ] **Step 2: Resume Talos S3 clients**

Run from the workstation against the Talos cluster:

```bash
kubectl -n default patch scheduledbackup postgres17 --type=merge -p '{"spec":{"suspend":false}}'
kubectl -n default get scheduledbackup postgres17 -o jsonpath='{.spec.suspend}{"\n"}'
kubectl -n default scale deploy/reactive-resume --replicas=1
kubectl -n default rollout status deploy/reactive-resume --timeout=180s
```

Expected:
- Scheduled backup suspend value is `false`.
- Reactive Resume is running again.

- [ ] **Step 3: Verify S3-facing workloads recover**

Run from the workstation against the Talos cluster:

```bash
kubectl -n default get pods | rg 'postgres17|reactive-resume'
kubectl -n default get backups --sort-by=.metadata.creationTimestamp | tail -n 10
kubectl -n default describe scheduledbackup postgres17 | tail -n 40

ACCESS_KEY_ID=$(kubectl -n default get secret garage-access-keys -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)
ACCESS_SECRET_KEY=$(kubectl -n default get secret garage-access-keys -o jsonpath='{.data.ACCESS_SECRET_KEY}' | base64 -d)
REGION=$(kubectl -n default get secret garage-access-keys -o jsonpath='{.data.REGION}' | base64 -d)
AWS_ACCESS_KEY_ID="$ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$ACCESS_SECRET_KEY" AWS_DEFAULT_REGION="$REGION" \
  aws s3 ls --endpoint-url https://s3.omv.a113.casa
```

Expected:
- Postgres pods remain running.
- Reactive Resume pod is running.
- CNPG scheduled backup is no longer suspended.
- The production S3 endpoint lists buckets after Garage is resumed.

---

## Task 8: Rollback and Follow-Up Decisions

**Files:**
- No repo changes.

- [ ] **Step 1: Roll back if validation fails**

Run only if Task 5 or Task 6 fails:

```bash
ssh "$OMV_SSH" 'sudo k3s kubectl -n default scale deploy/garage --replicas=1'
kubectl -n default patch scheduledbackup postgres17 --type=merge -p '{"spec":{"suspend":false}}'
kubectl -n default scale deploy/reactive-resume --replicas=1
```

Expected:
- Active S3 service remains OMV Garage.
- Synology staging copy can be deleted and rebuilt later.

- [ ] **Step 2: Decide final Garage runtime separately**

Keep this staging copy until the final runtime is chosen:
- Recommended GitOps path: future Talos storage worker with Garage hostPaths and Gateway API.
- Alternative non-GitOps path: run Garage container directly on Synology and repoint `s3.omv.a113.casa`.

Do not repoint DNS or update app S3 endpoints in this staging plan.

---

## Self-Review

- Spec coverage: covers current OMV Garage hostPaths, Synology staging paths, no DNS cutover, and the current `k8s-3-pxm`/`k8s-4-dell` additive state by avoiding storage-worker assumptions.
- Placeholder scan: commands use concrete OMV/Synology paths and current host/user values.
- Risk review: final metadata copy happens only while Garage is stopped; rollback keeps OMV Garage as source of truth.
