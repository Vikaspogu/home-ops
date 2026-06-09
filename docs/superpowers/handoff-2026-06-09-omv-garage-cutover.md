# Handoff: OMV Garage Cutover — BLOCKED (OMV backups failing)

**Date:** Tue Jun 9, 2026 ~01:00 UTC
**Status:** 🔴 OMV `pg17-omv` WAL archiving is FAILING. Needs immediate action.
**Branch:** `main` (changes already pushed: commit `36af029e "update domain"`)

---

## TL;DR for next session

A previous change pointed the **OMV** postgres backup endpoint at `https://s3.a113.casa`,
which is **unreachable from the OMV cluster**. OMV WAL archiving is now failing
(database is online and healthy; only backups/archiving are broken).

**You must either revert OMV to `http://garage:3900` OR expose the new Garage via a
Talos NodePort.** DNS changes will NOT fix this — it is an L2/ARP reachability problem.

---

## What was completed successfully (do NOT redo)

### Talos Garage cutover — DONE & VERIFIED ✅ (commit `d7d1cba1`)
- `postgres17` and `pgvector17` (Talos clusters) backups cut over to the new Talos Garage.
- Endpoint: `http://garage-s3.default.svc.cluster.local:3900` (in-cluster, works fine).
- Verified: WAL archiving + on-demand backups land on new Garage, 0 errors.
- The `garage-access-keys` secret's `ACCESS_KEY_ID` (`GK1ef6ef65262a8e0cb0792bf2`)
  already matches the new Garage bucket's RW key — no credential change needed.

### Migration data — DONE ✅
- 103,072 objects / 1.827 TiB migrated OLD→NEW Garage (rclone, exit 0).
- New Talos Garage `postgres` bucket matches source exactly.

---

## What is BROKEN 🔴

### OMV `pg17-omv` backup endpoint (commit `36af029e`)
- File: `clusters/omv/apps/default/cloudnative-cluster/cluster.yaml` line 56
- Changed FROM `http://garage:3900` (old OMV Garage, WORKS)
  TO `https://s3.a113.casa` (new Talos Garage, **UNREACHABLE from OMV**)
- ArgoCD on OMV reconciled it (app at revision `36af029e`).
- **Result:** WAL archiving fails:
  ```
  wal-archive ERROR: barman-cloud-wal-archive: exit status 4
  archive command failed with exit code 1
  archiving WAL file "...000000C2" failed too many times, will try again later
  ```
- Database `pg17-omv` is still ONLINE and healthy. Only backups/archiving stopped.
  WAL accumulates locally on the OMV primary until this is fixed.

---

## ROOT CAUSE (fully diagnosed — do not re-investigate)

The new Talos Garage is only reachable via Cilium **L2-announced VIPs**, and those VIPs
are **not reachable from the OMV cluster** (different L2 announcement domain).

Verified reachability matrix from OMV (host AND pods):

| Target | IP | Type | Reachable from OMV? |
|---|---|---|---|
| `s3.a113.casa` (envoy-internal gateway) | `10.30.30.16` | Cilium L2 VIP | ❌ ARP INCOMPLETE / "No route to host" |
| `envoy-external` gateway | `10.30.30.18` | Cilium L2 VIP | ❌ Same |
| Talos LB pool (influxdb/mosquitto) | `.159/.162` | Cilium L2 VIP | ❌ Same |
| **Talos NODE IPs** | `10.30.30.21/.24/.25` | Real node NIC | ✅ TCP works (proven on :10250) |
| Old OMV Garage (`garage` svc) | ClusterIP | in-cluster | ✅ Works (current rollback target) |

**Why Gitea-on-OMV works the other direction but Garage-on-Talos doesn't:**
- OMV uses K3s **ServiceLB/klipper** → ingress published on the **real node host IP**
  `10.30.30.54`. Real interface IPs answer ARP universally → reachable from Talos pods.
- Talos uses **Cilium L2Announcement** → VIPs that float and are only ARP-answered inside
  Talos's L2 segment → unreachable from OMV.
- DNS resolves fine in both cases. The break is purely L2/ARP to the VIP.
  **Changing pod DNS does nothing**, because even the raw VIP IP is unreachable.

---

## DECISION NEEDED / OPTIONS

### Option A — Revert now (RECOMMENDED, stops the failure immediately)
Restore working archiving, then fix exposure properly as a follow-up.
```yaml
# clusters/omv/apps/default/cloudnative-cluster/cluster.yaml line 56
    endpointURL: http://garage:3900   # back to old OMV Garage
```
Then commit + push, refresh OMV ArgoCD app `cloudnative-cluster`, verify archiving recovers.

### Option B — Expose new Garage via NodePort (the real cross-cluster fix)
1. Add a NodePort service for `garage-s3` (S3 port 3900) in
   `components/default/garage-s3/` (Talos). Pick a fixed nodePort, e.g. `31900`.
2. Point OMV at a Talos NODE IP (proven reachable), e.g.:
   ```yaml
   endpointURL: http://10.30.30.25:31900
   ```
3. Verify auth: OMV `garage-access-keys` secret already has the correct key
   (`GK1ef6ef65262a8e0cb0792bf2`, region `garage`) — should work against new Garage.
4. Commit + push, reconcile both clusters, force a WAL switch on `pg17-omv-1`,
   confirm archiver logs show success against the node IP.

> A LoadBalancer will NOT help — it allocates another VIP from the same unreachable pool.

---

## Apps / Databases on `pg17-omv` (audit result)

Databases present in `pg17-omv` (excluding system DBs):

| Database | Owner | Size | Actively used? |
|---|---|---|---|
| `gitea` | `gitea-admin` | 93 MB | ✅ YES — only live consumer (2 active conns) |
| `blinko` | `blinkoadmin` | 8.7 MB | ⚠️ No repo component, no active conns (likely stale) |
| `mac` | `mac` | 7.6 MB | ⚠️ Stale — the `mac` app now points at Talos `postgres17-rw` |
| `memos` | `memosdb` | 8.1 MB | ⚠️ No repo component, no active conns (likely stale) |

**Only `gitea` actively uses `pg17-omv`** (confirmed via `pg_stat_activity` + manifest).
- Manifest: `components/default/gitea/external-secret.yaml`
  → `INIT_POSTGRES_HOST: pg17-omv-rw.default.svc.cluster.local`
  → `GITEA__database__HOST: pg17-omv-rw.default.svc.cluster.local:5432`, DB `gitea`.

All other postgres-consuming apps target the **Talos** clusters
(`postgres17-rw` / `pgvector17-rw`), NOT OMV. (atuin, authentik, home-assistant,
jellyseerr, paperless-ngx, piped, prowlarr, reactive-resume, ivan-personal-service,
mac, mem0, etc.)

> Implication: only `gitea`'s backups are affected by the OMV Garage endpoint.
> The `blinko`/`mac`/`memos` DBs in pg17-omv appear orphaned — worth confirming and
> dropping later, separately from this cutover.

---

## Verification commands

```bash
# Talos
export KUBECONFIG=/tmp/talos-kubeconfig

# OMV (NOTE: ssh hostname omv-baymx had intermittent DNS resolution failures this
# session — retry if "Could not resolve hostname")
ssh root@omv-baymx 'kubectl ...'

# Check OMV ObjectStore endpoint
ssh root@omv-baymx 'kubectl get objectstore pg17-omv-backup -n default \
  -o jsonpath="{.spec.configuration.endpointURL}{\"\n\"}"'

# Check OMV archiving health
ssh root@omv-baymx 'kubectl get clusters.postgresql.cnpg.io pg17-omv -n default \
  -o jsonpath="{range .status.conditions[?(@.type==\"ContinuousArchiving\")]}{.message}{\" / \"}{.status}{\"\n\"}{end}"'

# Force WAL switch to test archiving after any endpoint change
ssh root@omv-baymx 'kubectl exec -n default pg17-omv-1 -c postgres -- \
  psql -U postgres -c "SELECT pg_switch_wal();"'

# Watch archiver result
ssh root@omv-baymx 'kubectl logs -n default pg17-omv-1 -c postgres --tail=100 \
  | grep -iE "Archived WAL|endpoint-url|error|fail"'

# Force OMV ArgoCD to pull latest commit
ssh root@omv-baymx 'kubectl annotate application cloudnative-cluster -n argo-system \
  argocd.argoproj.io/refresh=hard --overwrite'
```

---

## Key files

- OMV backup config: `clusters/omv/apps/default/cloudnative-cluster/cluster.yaml` (line 56)
- Talos backup configs (DONE): `clusters/talos/apps/default/{cloudnative-cluster,pgvector-cluster}/cluster.yaml`
- New Garage component: `components/default/garage-s3/` (add NodePort here for Option B)
- Old OMV Garage component: `components/default/garage-app/` (the `garage` ClusterIP svc)
- Gitea DB consumer: `components/default/gitea/external-secret.yaml`

---

## Recommended next action

1. **Option A first** — revert OMV to `http://garage:3900`, confirm archiving recovers.
2. Then implement **Option B** (NodePort) cleanly for the eventual OMV→new-Garage cutover.
3. Separately, confirm + clean up orphaned `blinko`/`mac`/`memos` DBs in `pg17-omv`.
