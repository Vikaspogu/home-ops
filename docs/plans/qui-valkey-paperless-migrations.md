# Qui, Valkey and Paperless migrations

Goal: HOMEOPS-MIGRATIONS-20261123 | Version: 5 | Status: agreed

Agreement ref: user message “use llm concil for plan revew and proceed” in this permanent execution thread | Review ref: council rounds 1–3 complete; execution-detail panel revisions pending

Prepared 2026-11-23. The user selected council review followed by proceeding. That selection authorizes preparation and migration subject to the stated recovery/review gates, without another routine confirmation. It does not waive blockers or authorize destructive recovery. Detailed maintenance manifests and commands must be independently reviewed before the affected slice becomes ready. No migration, backup mutation, restore, commit or deployment has occurred as of this revision.

## Problem

Three pending updates change persisted data or behavior. Green CI does not prove that their data can be recovered. The current backups have not been demonstrated to restore these upgrades safely.

| PR | Reviewed head | Current → proposed | Main risk |
| --- | --- | --- | --- |
| [Qui #2585](https://github.com/Vikaspogu/home-ops/pull/2585) | `68eafb6405551efd7943773c5eacf95071772da3` | 1.35.0 → 1.36.1 | Security exposure on the current version, destructive database migrations, API and workflow changes |
| [Valkey #2565](https://github.com/Vikaspogu/home-ops/pull/2565) | `35c31c244be0303e141257731cd08878c8b1c78d` | 9.1.3-alpine → 9.2.0-alpine | RDB format 80 → 81 prevents safe image-only downgrade |
| [Paperless #2541](https://github.com/Vikaspogu/home-ops/pull/2541) | `2b8480174d808c031d8c1a551a27259df154c976` | 3.4.2 → 3.5.1 | Database migration plus separate database, PVC and NFS recovery requirements |

Evidence baseline: exact main `cf91064d3466ea0b01d523d52372f7f3fb431acf`, corresponding PR diffs, live resource specifications and read-only persistence/client metadata. All three PRs were open at these heads on 2026-11-23. Recheck heads, diffs, release guidance, reviews and checks before implementation. A changed head invalidates affected analysis.

Hindsight search, list and initiative capture returned HTTP 401 during this planning effort. No memory-derived facts are assumed. Recheck access when next needed rather than treating the outage as permanent.

## Solution

Use separate maintenance windows in this order:

1. S1, Qui: address the known security issue first, after proving a matching configuration/database restore and checking changed automation behavior.
2. S2, Valkey: establish and test recovery for all logical databases, identify every writer, then upgrade the shared service with producers paused.
3. S3, Paperless: prove recovery of its own PostgreSQL database, application data and NFS media as one consistent checkpoint before migrating.

Each window includes inventory, isolated rehearsal, a fresh final checkpoint, an exact-head GitOps merge, service/data verification and a controlled return to normal traffic. A failed prerequisite holds that migration only. Qui is independent of the other two. Paperless needs a healthy compatible Valkey endpoint, not necessarily Valkey 9.2. If Valkey is blocked, reconsider Paperless against the unchanged version as a separately reviewed schedule change rather than combining upgrades.

Proposed recovery policy: no accepted loss of source documents, configuration, persistent application state or queued work. Downtime estimates remain pending until restore rehearsals measure the actual recovery time. After writes resume, restoring an earlier checkpoint can lose new work. Do not promise lossless rollback or perform that restore without an explicit reconciliation decision.

For every new Qui, Valkey and Paperless recovery artifact, document its access controls, at-rest protection, retention, identity, timestamp and successful decryption/restore test. This includes SQLite/WAL/configuration, RDB, PostgreSQL dumps, PVC snapshots and media copies. Use encrypted off-volume storage for portable backups. Verify storage-level protection for snapshots and restored PVCs rather than assuming CSI implies encryption. Block artifact creation if a suitable protected destination is unavailable. Retain pre-upgrade checkpoints through functional acceptance and at least the next successful normal backup; retain longer for unresolved incidents. Expiry must be recorded, not an automatic deletion of the last usable checkpoint. Never log secrets, key names/values, document titles or document contents.

## Variables & Scope Boundaries

- `PROJECT_ROOT`: `/home/agent/git-repos/home-ops`.
- `PLAN_FILE`: `docs/plans/qui-valkey-paperless-migrations.md`.
- `WORKING_DIR`: the permanent shared checkout for read-only inspection and this plan only. Any future corrective implementation uses an explicitly recorded job-owned temporary worktree at the exact reviewed revision. Preserve the shared branch and user files.
- `KUBECONFIG`: `/home/agent/.kube/config`.
- `CONTEXT`: `admin@home-kubernetes`, verified against cluster `home-kubernetes` and server `https://10.30.30.150:6443` on this date. Reconfirm safe metadata before every window.
- `READ_ONLY_DIRS`: other application components, bootstrap configuration and repository instructions, except consumer paths specifically included below for necessary maintenance changes after review.
- `ALLOWED_PATHS` now: `PLAN_FILE` only. Proposed implementation scope: `components/downloads/qui/`, `components/default/valkey/`, `components/default/paperless-ngx/`; narrowly necessary producer-pause changes under `components/ai/ivan-personal-service/` and `components/default/authentik/` only if active dependency is established. Any new maintenance resource and registration path must be named in the reviewed execution revision before creating it.
- `FORBIDDEN_PATHS` for modification: unrelated applications and user files, bootstrap, shared PostgreSQL cluster recovery configuration, unrelated NAS exports and the entire consume/Documents tree. Never read credential-bearing kubeconfig contents or Kubernetes Secrets into output. Approved runtime secret injection must use provider references without exposing values.

### Relevant Files

Existing files to inspect or update within the reviewed scope:

- Each app's `values.yaml` and `kustomization.yaml`: image, persistence, rendering and maintenance behavior.
- Qui and Paperless `http-route.yaml` and `externalsecret.yaml`: service checks, credentials and matching recovery configuration.
- `components/default/valkey/externalsecret.yaml`: existing credential/configuration references.
- `components/default/authentik/{values.yaml,externalsecret.yaml}` and `components/ai/ivan-personal-service/values.yaml`: declared Valkey dependencies, subject to runtime verification.
- `clusters/talos/apps/20-applications.yaml`: read-only source-path and plugin-variable reference. Any necessary change requires inclusion in the reviewed execution revision.

New file now: this draft only. Future rehearsal/backup manifests must be minimal, reviewed GitOps resources with explicit names, destinations, retention and cleanup rules. Do not install tools or improvise direct cluster mutations to fill missing capabilities.

## Workflow

1. Agree the human proposal. The plan skill requires “human agreement → independent review → ready”. Derive exact commands, paths and maintenance resources after agreement. Record the real agreement and review references. Ready does not select execution.
2. Before an explicitly selected window, confirm no concurrent merge/deployment run, correct origin/authentication/context, clean assigned workspace, available validation tools and current exact revisions. Capture current nodes, Argo CD state, workload readiness, restart counts, events and meaningful service checks.
3. Rehearse with separate PVCs/databases and private hostnames. Use a supported snapshot restore or encrypted backup restore, accounting for namespace restrictions. Confirm network isolation before starting restored workloads. They must not consume production queues, write production NFS, send email/notifications, contact real torrent clients or execute remote SSH operations. Do not copy Secrets into source control or evidence.
4. Complete each selected slice end to end. Use `[ ]`, `[wip]`, `[x]`, `[f]` for tasks and slice headers. Do not mark complete while a required check fails or lacks evidence. A held slice can be skipped only with an explicit updated schedule and independent prerequisites verified.
5. Any local corrective commit must pass the repository's required staged Pi review. Use GitOps PRs, required CI/reviews and exact-head squash merges without admin bypass. Recheck merge eligibility immediately before merge. Normal reconciliation only, without direct apply, force sync or workload restarts outside GitOps.
6. Observe up to 15 minutes from each final cutover commit for initial reconciliation. If unhealthy or unreconciled, start diagnosis and the reviewed recovery procedure. Do not abandon an active regression when the observation window ends.
7. Verify the deployed commit or proven descendant, intended image/config, rollout, readiness, service behavior and data integrity before resuming producers. Evaluate warning events by timing and current service impact. Preserve checkpoints until the migration is accepted.
8. Remove only isolated resources and job-owned worktrees proven safe to remove. Never delete production volumes, snapshots needed for recovery, unique work or branches as routine cleanup. Record all retained recovery material and any pending normal scheduled verification.

### Merge coordination and rehearsal isolation

The GitHub API confirmed `main` is unprotected (protection endpoint 404) with no rulesets on 2026-11-23. Do not claim GitHub enforces approval or serialize collaborators through a local lock alone. Keep these three upgrade merges held in this workflow until their selected windows. Check for concurrent runs and re-read remote main, PR head, reviews, unresolved threads and CI immediately before each exact-head merge. Compare main to the revision used to render/rehearse. If it moved, assess every intervening relevant change and repeat affected validation before proceeding. A Renovate rebase invalidates head-specific evidence and requires re-review. Do not disable Renovate, alter protection or post a repository-wide freeze without a separate concrete need. Residual concurrent-collaborator risk must be recorded.

The reviewed `.github/renovate.json5` enables digest automerge and branch automerge, with no version-update automerge rule found for these packages. Qui's GitHub `autoMergeRequest` was null. Recheck effective configuration and all three GitHub auto-merge states before each window; do not infer a permanent merge freeze from today's configuration.

Create a dedicated, reviewed NetworkPolicy selecting each rehearsal's unique labels, with `policyTypes: [Ingress, Egress]`, no ingress and no egress, before starting any clone. The live `garage-recovery-isolated-deny-all` policy demonstrates the shape, not permission to reuse its selector or change its resources. Inspect all applicable NetworkPolicies and Cilium policies because allow rules are additive. No `hostNetwork`, privileged containers or host paths. Test denial of production database, Valkey, clients/SSH and external endpoints from the actual selected workload. Add only narrowly reviewed allowances to private rehearsal dependencies. A policy's existence alone is insufficient evidence. Restore movers may need a separate identity and minimal backup-store access. Do not give the restored app that access.

NetworkPolicy does not prevent kubelet volume mounts. Before creating a clone, restore mover or copy job, validate its rendered pod specification: no production NFS media/consume export, no hostPath and no reference to a production PVC. Permit only named private rehearsal claims and approved protected backup-store sources; if the available backup method needs a forbidden mount, stop and review a scoped alternative. The separate read-only inventory step below is deliberately not a clone/restore/copy job and has one explicit, reviewed production-PVC read-only exception. It must not be reused as a restore mechanism.

Record a rehearsal-measured cutover budget and recovery decision deadline before pausing production. Include checkpoint, migration, validation and restore duration with margin. If the planned recovery cannot fit the available window, do not start. The 15-minute initial observation bound remains in force and triggers diagnosis, not premature failure or an extended blind wait. Paperless completion additionally requires explicit successful migration state and application/data checks, regardless of elapsed time.

## Vertical Slices

These are draft human-level phases. Exact mutating commands, workload identities and recovery resource paths remain a requirement for the agreed and reviewed execution revision.

| Slice | Purpose | Done when |
| --- | --- | --- |
| S1 | Qui security and behavior migration | Isolated recovery works, changed automation is understood, production 1.36.1 is healthy |
| S2 | Recoverable shared Valkey upgrade | All data/writers accounted for, old checkpoint restores, 9.2 clients and persistence verified |
| S3 | Consistent Paperless migration | App-only database plus file recovery works, document integrity and ingestion verified on 3.5.1 |

### [ ] S1: Qui

Purpose: upgrade without losing configuration or allowing changed automation to act unexpectedly. No dependency on S2/S3.

Observed: 10Gi Ceph PVC `qui` in `downloads`, mounted at `/config`. It holds SQLite database/WAL files and configuration. Normal VolSync last reported success at 2026-11-23 17:52:12 UTC. That is backup evidence, not restore evidence. The container lacks SQLite/Python inspection tools. Use a reviewed maintenance image or supported application export without installing into production or printing database contents.

[GHSA-9c3v-4vv2-9wrf](https://github.com/autobrr/qui/security/advisories/GHSA-9c3v-4vv2-9wrf) affects 1.35.0 when API keys exist and is fixed in 1.36.1. API key existence, leakage or compromise is unverified. API key holders on the affected version may access or damage files available to Qui. Do not describe a 1.36-only log-path workaround as protection for 1.35.0.

- [ ] Inventory API-key consumers, workflows, client/SSH integrations, orphan-scan roots and ignored media paths through safe supported interfaces. No secrets in evidence.
- [ ] Expedite read-only exposure triage before other migration preparation: establish whether API keys exist, what routes are reachable and which integrations depend on them. Inspect counts/permissions and safe ingress metadata only, never key values or configuration dumps. No key existence or compromise is assumed. If authenticated inventory is unavailable, record that exact access blocker rather than treating keys as absent.
- [ ] Record the interim exposure decision while rehearsal is pending. If keys exist or exposure cannot be bounded, prepare a separately reviewed, reversible restriction of API access or revocation of affected keys, accounting for integration impact. Do not silently revoke keys or rotate sessions. Confirmed compromise requires incident handling. Keep S1 expedited without skipping restore or review gates and never use the 1.36-only log-path workaround on 1.35.0.
- [ ] Record this triage decision before any rehearsal begins. The executing agent may conclude low exposure only from complete evidence, not from HTTP 403 or missing credentials. If inventory remains inaccessible or a restriction would interrupt unknown integrations, hold rehearsal and present the concrete restriction/impact decision to the user. Use the runtime secret-input tool if an operator credential is truly required; never ask for credentials in chat.
- [ ] Review browser-only administrator endpoints rejecting API keys, combined workflow conditions, `scanPaths` becoming `scanPathCount`, and hardlink orphan handling. Prepare necessary compatible integration changes separately for review. No real deletion/transfer/scan as a test.
- [ ] Preserve a quiesced SQLite-consistent database/configuration checkpoint and matching session-secret provider version. An arbitrary live copy of `qui.db` without its WAL is insufficient.
- [ ] Restore a clone into isolation. Start old 1.35.0 to prove recovery, then migrate that clone to 1.36.1. Record effects of migrations 118 and 122, including removed settings and discarded orphan feed rows. These changes cannot be reversed by replacing the image.
- [ ] Verify UI login, stored credential usability without plaintext output, intended API allow/reject behavior and workflow inventory. Prove restored automations cannot reach real clients.
- [ ] Take a fresh final checkpoint, then merge the reviewed exact-head update. Verify Argo CD, deployed image, readiness, UI/API behavior and integration compatibility before releasing maintenance restrictions.

Gate: restore evidence and all checks above pass. Stop for credential decryption failure, unexplained missing state, uncontrolled destructive automation or suspected compromise. Suspected compromise requires a separately scoped key/session rotation and incident response decision, not an upgrade-only claim of repair.

Recovery: prefer a forward fix. Before normal work resumes, restore matching pre-upgrade database, configuration and secret-provider version with 1.35.0 through the reviewed GitOps procedure. Record that doing so restores the vulnerable version. After writes resume, preserve new state and obtain a reconciliation decision before checkpoint recovery.

### [ ] S2: Valkey

Purpose: preserve all databases and queued work while upgrading the shared store. Schedule after S1 unless revised independently.

Observed: 1Gi RWO Ceph PVC `valkey`, `/data`, RDB saves configured at `300 1` and `60 100`. AOF is disabled. Read-only persistence status was healthy with no unsaved changes at observation. No configured VolSync source or named Valkey snapshot was found. DB0 contained 19 persistent keys, DB5 contained 11 keys including nine expiring keys, and DB6 contained 13 persistent keys. Counts are a point-in-time baseline only.

Declared clients: Paperless DB5, Ivan personal service DB6, Authentik DB3. Active Paperless DB5 connections were observed. No Ivan/Authentik connection at one instant does not prove no dependency. DB0 ownership remains unknown.

- [ ] Identify every producer and DB0 owner, including intermittent/scheduled clients. Verify whether current Authentik still uses Valkey despite its declared configuration. Record aggregate inventories without logging key names or values.
- [ ] Map pre-pause client addresses to current pods and inspect deployed Authentik version behavior/upstream guidance. Observe through a representative normal activity period and identify scheduled clients. One empty client-list sample cannot establish non-use. If Authentik has no runtime dependency, explicitly remove it from this slice's producer-pause scope and do not change its configuration.
- [ ] Prepare reviewed GitOps maintenance and encrypted off-volume backup coverage. A same-volume RDB alone is not disaster recovery. Include all databases, relevant server/ACL configuration and secret-provider references.
- [ ] Record actual authentication/configuration behavior. Desired arguments currently show the two RDB save rules and no `--requirepass` or explicit ACL setup, despite a mounted secret. Verify live effective settings and whether clients authenticate through safe metadata. Do not claim the mounted password file enforces authentication or expand this migration into unrelated hardening.
- [ ] Pause verified producers, stop new ingestion and drain or safely preserve queued work. Do not purge queues or assume every database is disposable cache.
- [ ] In the selected maintenance window, perform and verify a durable save after writers are quiesced. Capture an immutable pre-upgrade RDB backup and PVC checkpoint.
- [ ] Restore separate isolated storage with 9.1.3 to prove old-version recovery. Upgrade the clone to 9.2 and validate loading/persistence status, all databases, client compatibility and representative list/stream/sorted-set operations using synthetic clone data. Account for natural TTL expiry instead of requiring exact expiring-key counts.
- [ ] Verify stricter sorted-set bound validation from the [9.2 release notes](https://github.com/valkey-io/valkey/releases/tag/9.2.0) against actual client usage.
- [ ] Take a fresh final checkpoint with writes paused, merge the exact reviewed head and verify image, readiness, persistence and isolated/safe client checks. Resume producers only after this gate passes. Confirm Paperless and other verified clients recover without lost/duplicated work.

Gate: known writers, tested encrypted restore, explained data inventory, healthy persistence and passing clients. Unknown DB0 ownership, an unexpected writer or unexplained persistent-data mismatch blocks this slice.

Recovery: while writes remain paused, restore the pre-upgrade RDB/PVC and 9.1.3. Never boot 9.1.3 against a 9.2-written RDB. After writes resume, prefer forward repair. Restoring the old checkpoint needs an explicit decision covering post-cutover writes and queued work. Do not wipe databases to make the upgrade pass.

### [ ] S3: Paperless

Purpose: migrate documents and tag relationships with a verified app-specific restore. Requires a healthy Valkey service and no concurrent Valkey maintenance.

Observed: database `paperless` at `postgres17-rw.default.svc.cluster.local`, on a shared PostgreSQL 17.6 cluster. Its 10Gi Ceph PVC mounts `/usr/src/paperless/data`. Media mounts the separate Synology NFS export `synology.a113.internal:/volume1/media/k8s-data/paperless`. Consume mounts `/volume1/homes/vikaspogu/Documents`, with recursive polling. Never restore, rewind or delete that whole user Documents export.

Normal PVC VolSync reported success at 2026-11-23 15:15:21 UTC and shared PostgreSQL backup reported Completed on this date. Neither proves an NFS media backup or a consistent app checkpoint. NAS backup/clone capability and media restore evidence remain unverified.

- [ ] Establish NAS media backup and restore capability. Preserve UID/GID, ownership, filenames, OIDC/application configuration and provider references. Confirm matching PostgreSQL 17 dump/restore tools are already available or use a reviewed existing workload image, without installing tools.
- [ ] Stop new ingestion and safely drain/account for Celery DB5 work. Pause all Paperless writers through reviewed GitOps maintenance configuration. Preserve new consume arrivals and an ingestion/queue checkpoint without rewinding Documents.
- [ ] Capture one consistent checkpoint: app-specific PostgreSQL logical dump of `paperless`, data PVC, NFS media copy/snapshot, configuration and secret-provider references. Do not use a whole shared-cluster restore as the app rollback plan.
- [ ] Use verified PostgreSQL 17 `pg_dump`/`pg_restore` for the logical checkpoint and isolated app-only restore. The exact reviewed main and live deployment use postgres-init 19.0.0, correcting the round-1 review's 18.7.0 reference. Neither reference proves matching backup tools. A CNPG restore of the shared cluster would copy unrelated databases and credentials, so it is not the default rehearsal method. Consider it only if app-only restore is technically unsuitable and its expanded data scope is explicitly reviewed and authorized.
- [ ] Restore into a separate private PostgreSQL database, separate data PVC and private copied media/export. Prove the old 3.4.2 restore before testing 3.5.1. Disable real ingestion, outbound mail, scanner integrations and other production side effects.
- [ ] Inspect and test the full 3.4.2 → 3.5.1 migration set. Migration [0028](https://github.com/paperless-ngx/paperless-ngx/blob/v3.5.1/src/documents/migrations/0028_replace_tag_tree_fields.py) removes derived tree fields. Verify document IDs/counts, tag parent relationships, document-tag associations and original/archive hashes, rather than comparing removed derived columns.
- [ ] Check search, representative original/archive downloads, authentication and synthetic-document OCR/ingestion in the isolated clone. The upstream [administration guide](https://github.com/paperless-ngx/paperless-ngx/blob/v3.5.1/docs/administration.md) documents an exporter containing documents and metadata. An optional export is supplementary and must not overwrite existing directories or substitute for a tested consistent recovery checkpoint.
- [ ] Time the restore, then select the maintenance window. Take a fresh consistent final checkpoint, merge the reviewed exact head and verify migration completion, image, Argo CD, readiness, document/tag integrity, search and downloads before resuming ingestion. Observe queued work and newly arriving documents afterward.

The execution-detail revision must identify the actual Django migration command and working directory in the 3.5.1 image, then require its migration check to exit 0 with no unapplied migrations. A successful deployment or absence of log errors is not that signal. Do not run a mutating migration command manually against production to manufacture completion evidence.

Gate: demonstrated matching database/PVC/NFS restore, successful clone migration, correct document integrity and working services. Missing NAS recovery evidence or inconsistent checkpoint blocks this slice.

Recovery: prefer a forward fix. If required before resuming writes, restore only Paperless's database, preferably into a new dedicated database while preserving the failed database, plus matching data/media/config and old 3.4.2 image. Use a scoped reviewed connection change. Never rewind the shared PostgreSQL cluster or user Documents export. After ingestion resumes, checkpoint recovery requires explicit treatment of new documents and metadata.

## Definition Of Done

### Planning and workflow

- [ ] Human agreement and independent correctness, quality and security review are recorded against the current plan identity before status becomes ready.
- [ ] Exact implementation/maintenance paths and verification/recovery commands are resolved before execution. No unresolved decision is hidden in an execution slice.
- [x] Execution selection is the user message “use llm concil for plan revew and proceed”. Per-slice maintenance budgets, tested recovery and review remain required before production mutations. Do not ask again for this same selection.
- [ ] Every selected slice has its own measured restore evidence, final checkpoint and passing deployment/data/service gate. Held slices remain explicitly pending.
- [ ] Changes stay within reviewed scope, repository-required review and GitHub protections pass, and the shared checkout's branch and pre-existing files are preserved.

### App outcomes

- [ ] S1: Qui 1.36.1 is healthy with usable saved configuration, understood API/workflow changes and a tested matching old-state recovery.
- [ ] S2: Valkey 9.2 is healthy, all writers/databases are accounted for, persistence succeeds and clients process work correctly with a tested old-RDB recovery.
- [ ] S3: Paperless 3.5.1 is healthy, originals/archives and document/tag relationships are preserved, and app-only database plus PVC/media recovery is demonstrated.
- [ ] Post-cutover observations distinguish merge, deployment and functional completion. No data-loss or image-only rollback claim exceeds the evidence.

### Read-only validation commands available now

Run from the assigned checkout. These checks do not prove restore or application correctness by themselves. Namespace/application names and deployment selectors must be resolved from current specifications before later rollout commands.

```bash
git remote get-url origin
git status --short
kubectl --kubeconfig=/home/agent/.kube/config config get-contexts
kubectl --kubeconfig=/home/agent/.kube/config --context=admin@home-kubernetes get nodes
kubectl --kubeconfig=/home/agent/.kube/config --context=admin@home-kubernetes get applications.argoproj.io -A
gh pr view 2585 --repo Vikaspogu/home-ops --json headRefOid,mergeable,mergeStateStatus,reviews,statusCheckRollup
gh pr view 2565 --repo Vikaspogu/home-ops --json headRefOid,mergeable,mergeStateStatus,reviews,statusCheckRollup
gh pr view 2541 --repo Vikaspogu/home-ops --json headRefOid,mergeable,mergeStateStatus,reviews,statusCheckRollup
```

Expected: intended origin and Talos context, no unexpected workspace changes, available healthy cluster, fresh PR heads and protection/check information. Missing tools or inaccessible evidence are explicit unverified gates. Do not poll checks when a PR is awaiting them. Follow the runtime PR watch procedure instead.

## How You're Graded

Success means measured recovery and preserved application behavior, not just successful image starts. Every solution maps to S1/S2/S3 and its data/service checks. Keep all task and slice statuses honest, report exact commands/results, and preserve recovery evidence without secrets.

Failure includes untested restores, accepting unexplained data loss, starting a clone with production side effects, unsafe image-only downgrade, whole-cluster PostgreSQL rewind, modifying unrelated user files or bypassing review/protection. Stop the affected slice, preserve evidence and report the precise blocker. Independent safe work need not stop.

### Change and review record

- v1: human proposal, author Codex `gpt-6.1-sol`.
- User agreement/execution selection: “use llm concil for plan revew and proceed”.
- Council round 1 on v1: Kimi, provider `openrouter`, model `moonshotai/kimi-k3.1-pro`, high reasoning, score 8.5/10, changes requested. Run/task `e7e78695-6c3a-4e9f-b6ec-9fb5d10525f2`. Accepted F1 protected artifacts/decryption tests and F2 interim Qui exposure triage.
- Council round 1 on v1: Sonnet, provider `nvidia-inference`, model `azure/anthropic/claude-sonnet-5-5`, high reasoning, score 8/10, approved as draft with conditions. Run/task `edd3f8c6-2c5e-4c62-a220-be197de4d8a0`.
- v2: accepted merge coordination/main freshness, concrete isolation, Authentik dependency gate, actual Valkey authentication inventory and measured recovery deadline. No branch-protection or Renovate configuration change is needed. Rejected making whole shared-cluster CNPG recovery the preferred Paperless rehearsal because it expands sensitive-data scope unnecessarily. Retained the user's 15-minute initial observation bound and added explicit migration completion signals instead of replacing the bound. These are targeted resolutions, not waived findings.
- Revised council review and exact execution-detail panel remain pending. No production mutation is selected until its slice's gates pass.
- Council round 2 on v2: Kimi `openrouter/moonshotai/kimi-k3.1-pro`, high, 9.5/10, approved for deriving execution details, no remaining plan findings; task `4e4e5ad4-ba9f-4101-b982-9f137ddb95d7`. Sonnet `nvidia-inference/azure/anthropic/claude-sonnet-5-5`, high, 8.5/10, approved human plan with final corrections; task `c7587dd4-4cc3-4949-9834-3828f7c6d108`.
- v3 resolves Sonnet's volume-mount isolation gap, explicit pre-rehearsal Qui decision timing, Renovate/auto-merge recheck and review-record freshness. Corrected the init image from source/live evidence. First execution step below is proposed, not ready; later restores/cutovers remain blocked pending their exact reviewed details and evidence.

### Proposed first execution step: S1-I0, aggregate Qui exposure inventory

This narrowly scoped preparation step does not upgrade, restore, copy or quiesce production. It reads three aggregate counts from the live SQLite database. The existing authenticated key-inventory endpoint returned HTTP 403 without credentials; that was not evidence of no keys. Qui `/health` returned HTTP 200. The production configuration occupied about 1 MiB at inspection.

Proposed paths, all in a job-owned temporary worktree at exact current main, to be added to `ALLOWED_PATHS` only after this step passes independent review:

- `components/downloads/qui/migration-inventory/{kustomization.yaml,networkpolicy.yaml,job.yaml,inventory.py}`.
- `components/downloads/qui/migration-inventory/{synthetic-job.yaml,synthetic.py}` for isolated validation before introducing a live-PVC Job.
- `components/downloads/qui/kustomization.yaml`, adding only the inventory subdirectory resource.

No changes to Qui's Deployment, image, Secret, production PVC definition, replicas or route. No new persistent storage, backup copy or secret injection. Python's SQLite module is optional, so absence fails the Job rather than prompting installation. The Docker registry resolved `python:3.15.2-alpine` to manifest digest `sha256:0f9552bb28711333da16915ec146f5e6bb44a7fdac9ced15dc17c2e0206346dd`; verify resolution again before review/publication.

Resource contract:

1. A ConfigMap generated from `inventory.py`, hash suffix enabled, mounted read-only at `/script`.
2. A dedicated deny-all NetworkPolicy at sync-wave `-10`, selecting only `home-ops-migration-role: qui-inventory`. Both ingress and egress empty. No downloads namespace NetworkPolicies/Cilium policies or cluster-wide Cilium policies existed at inspection; recheck before launch.
3. Use two reviewed GitOps changes without a suspended Job: first add only the deny-all policy, generated ConfigMap and child Kustomization; verify reconciliation and policy selection. Second add runnable Job `qui-migration-inventory-v1`, `backoffLimit: 0`, `activeDeadlineSeconds: 120`, `restartPolicy: Never`, no TTL-based deletion before evidence capture. This avoids a suspended Job affecting Argo CD health and root application waves. Before the second merge, verify no concurrent inventory/backup run, correct live affinity labels, exact Service ClusterIPs and ready EndpointSlices for Valkey and PostgreSQL. If anything differs, update and re-review affected inputs before launch. Do not patch or create a Job directly.
4. Its pod has only the unique migration label, no Qui Service selector labels, `automountServiceAccountToken: false`, `enableServiceLinks: false`, no env/envFrom or credentials, no host networking/PID/IPC, `runAsNonRoot: true`, UID/GID 1000, RuntimeDefault seccomp. Do not set fsGroup, avoiding recursive ownership changes on production storage.
5. Use the pinned Python image, `command: [python3, -B, /script/inventory.py]`, requests `cpu: 10m, memory: 32Mi`, limits `cpu: 100m, memory: 128Mi`, read-only root filesystem, no privilege escalation, all capabilities dropped.
6. Only two volume sources: ConfigMap and PVC `qui` with `persistentVolumeClaim.readOnly: true`, mounted `/source` with `volumeMount.readOnly: true`. No subPath, hostPath, NFS, extra claims or writable volume. Require pod affinity on hostname to the currently running Qui pod using `app.kubernetes.io/instance: qui` and `app.kubernetes.io/controller: qui`. RWO permits multiple pods on the same node, not arbitrary cross-node mounts. If Qui moves or the mount cannot be safely established, the Job stays blocked; never force-detach a volume.
7. Before SQL, the process tests TCP denial to current Valkey, PostgreSQL and a public endpoint. Unexpected connectivity aborts before opening SQLite. The executing agent owns the immediate pre-launch ClusterIP/ready-endpoint recheck and must hold launch on a mismatch. A Cilium drop is expected to time out; timeout alone does not prove policy enforcement, so require the independently inspected policy/selector, absence of additive allowances and healthy endpoints as well. ECONNREFUSED, EHOSTUNREACH and other unapproved errors fail closed with exit 1. SQL uses `mode=ro`, explicit transaction control, `PRAGMA query_only=ON` and a bounded read transaction, never `immutable=1` or `nolock`. Missing WAL/shared-memory support or missing tables is a failure, never a reason to copy the live database or enable writes. If it cannot safely read the live WAL, hold this step and prepare a separately reviewed authenticated read-only inventory method with explicit network/credential rules. Never inject a credential into this inventory Job. Request a credential using the runtime secret-input tool only if genuinely needed by that separately reviewed method. Do not change SQLite permissions, force checkpoints or bypass locking to make inventory succeed.
8. The three TCP checks are limited canaries for this no-credential, read-only inventory exception. They are not the full database/client/SSH/API isolation proof required before any restored clone. Do not reuse this Job's success line as rehearsal network-isolation approval. A transient lock/protocol/mount failure is preserved as failed evidence; retry only with a newly reviewed Job identity, such as `qui-migration-inventory-v2`, after diagnosis. Never rerun or delete/recreate the same Job in a loop.

Proposed script, to extract verbatim after review:

```python
import errno
import json
import socket
import sqlite3
import sys
from pathlib import Path

stage = "startup"

def main():
    global stage
    stage = "network"
    targets = (("valkey", "10.96.64.206", 6379), ("postgresql", "10.96.20.181", 5432), ("external", "1.1.1.1", 443))
    for label, host, port in targets:
        try:
            with socket.create_connection((host, port), timeout=2):
                print(json.dumps({"network_denial_failed": label}))
                return 2
        except TimeoutError:
            pass
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.EPERM):
                raise
    stage = "sqlite_open"
    connection = sqlite3.connect("file:/source/qui.db?mode=ro", uri=True, timeout=3, autocommit=True)
    try:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("BEGIN")
        counts = {}
        for label, query in (
            ("api_keys", "SELECT COUNT(*) FROM api_keys"),
            ("client_api_keys", "SELECT COUNT(*) FROM client_api_keys"),
            ("instances", "SELECT COUNT(*) FROM instances"),
        ):
            stage = "schema_" + label
            if connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (label,)).fetchone() is None:
                print(json.dumps({"schema_missing": label}))
                return 3
            stage = "count_" + label
            counts[label] = connection.execute(query).fetchone()[0]
        connection.execute("ROLLBACK")
        print(json.dumps({"inventory": counts, "schema_checked": 3, "network_denial_checks": 3}))
        return 0
    finally:
        connection.close()

if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({
            "inventory_failed": type(error).__name__,
            "stage": stage,
            "sqlite_errorname": getattr(error, "sqlite_errorname", None),
            "errno": getattr(error, "errno", None),
            "source_files_present": {name: Path("/source", name).exists() for name in ("qui.db", "qui.db-wal", "qui.db-shm")},
        }))
        sys.exit(1)
```

Before implementation, independently review the one-production-PVC read-only exception, SQL/WAL behavior and network checks. Source contracts: [Python SQLite URI handling](https://docs.python.org/3/library/sqlite3.html#how-to-work-with-sqlite-uris), [SQLite read-only URI](https://www.sqlite.org/uri.html), [SQLite read-only WAL](https://www.sqlite.org/wal.html#read_only_databases), [Kubernetes RWO semantics](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#access-modes). Physical table names are verified from Qui v1.35.0 models and [migration 010](https://github.com/autobrr/qui/blob/v1.35.0/internal/database/migrations/010_add_files_cache_and_string_interning.sql). Use physical table counts to avoid inner-join views hiding orphaned rows. The live schema assertion emits only a missing allowlisted table label, never names discovered from arbitrary database content.

Meaningful checks before publication: execute the exact pinned image's Python/SQLite script against a synthetic live writer with WAL auto-checkpoint disabled, a committed row present only in WAL and existing `-wal`/`-shm` files. The reader must see that row with a kernel read-only bind mount, reject SQL writes and emit only counts, never sentinel credential fields. Where local container/mount tooling is unavailable, do not install it or claim that check passed: record it as unavailable and review an explicitly isolated synthetic Kubernetes test before the live inventory. A permissions-only unprivileged test is useful but not a substitute for the kernel-mount check. Define the synthetic test resources in the reviewed implementation before deploying them. Missing or unreadable WAL/shared-memory must fail safely. Test a missing database exits 1 without creating it, and unexpected real TCP connectivity exits 2 with aggregate failure JSON before SQLite access. Compare synthetic fixture bytes/metadata before and after the reader while the writer holds its connection open but makes no concurrent writes during that comparison; separately exercise concurrent commits to test bounded reader behavior. Do not require unchanged production database hashes while the real app is actively writing. Production non-mutation evidence is the rendered and live read-only PVC/mount, URI/query-only controls and absence of any writable filesystem mount. Then render using installed Kustomize/Helm, run kubeconform with repository schema configuration and inspect every pod-spec field above. Required staged Pi review precedes each local commit. A generic lint pass is not evidence of read-only behavior.

Live completion commands after the reviewed activation merge:

```bash
kubectl --kubeconfig=/home/agent/.kube/config --context=admin@home-kubernetes get pods -n downloads -l app.kubernetes.io/instance=qui --show-labels
kubectl --kubeconfig=/home/agent/.kube/config --context=admin@home-kubernetes get pods -n downloads -l app.kubernetes.io/instance=qui -o jsonpath='{range .items[*]}{.metadata.uid}{" ready="}{.status.conditions[?(@.type=="Ready")].status}{" restarts="}{.status.containerStatuses[*].restartCount}{"\n"}{end}'
kubectl --kubeconfig=/home/agent/.kube/config --context=admin@home-kubernetes get service -n default valkey postgres17-rw -o custom-columns=NAME:.metadata.name,IP:.spec.clusterIP
kubectl --kubeconfig=/home/agent/.kube/config --context=admin@home-kubernetes get endpointslice -n default -l kubernetes.io/service-name=valkey -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}'
kubectl --kubeconfig=/home/agent/.kube/config --context=admin@home-kubernetes get endpointslice -n default -l kubernetes.io/service-name=postgres17-rw -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}'
kubectl --kubeconfig=/home/agent/.kube/config --context=admin@home-kubernetes wait -n downloads --for=condition=complete job/qui-migration-inventory-v1 --timeout=150s
kubectl --kubeconfig=/home/agent/.kube/config --context=admin@home-kubernetes logs -n downloads job/qui-migration-inventory-v1
kubectl --kubeconfig=/home/agent/.kube/config --context=admin@home-kubernetes get job -n downloads qui-migration-inventory-v1 -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" reason="}{.reason}{"\n"}{end}'
kubectl --kubeconfig=/home/agent/.kube/config --context=admin@home-kubernetes get pods -n downloads -l job-name=qui-migration-inventory-v1 -o jsonpath='{range .items[*]}{.status.containerStatuses[*].state.terminated.exitCode}{"\n"}{end}'
curl --silent --show-error --max-time 15 --output /dev/null --write-out '%{http_code}\n' https://qui.a113.casa/health
kubectl --kubeconfig=/home/agent/.kube/config --context=admin@home-kubernetes get pods -n downloads -l app.kubernetes.io/instance=qui -o jsonpath='{range .items[*]}{.metadata.uid}{" ready="}{.status.conditions[?(@.type=="Ready")].status}{" restarts="}{.status.containerStatuses[*].restartCount}{"\n"}{end}'
```

Run the first four commands immediately before the activation merge and retain that baseline. Require ready endpoints, exact reviewed IPs and matching live affinity labels. After activation run the wait/log/exit/health commands and repeat readiness/restart capture; a changed pod UID requires an explained replacement rather than comparing restart counters across different pods. Expected: Job Complete, process exit 0, aggregate JSON only and Qui health 200 with no worsened readiness/restarts. Timeout is a failed observation requiring pod condition diagnosis, not a rerun loop. This is an intentional migration inventory workload, not an ad hoc CronJob verification Job. If keys exist, record and review the interim restriction decision before any clone starts. Treat zero counts as a point-in-time transaction and corroborate with complete application/integration inventory, not proof of no historical compromise. This Job does not prove backup integrity, encryption or migration readiness. Capture aggregate logs before a narrowly scoped GitOps removal of the inventory directory resource and its now-unreferenced directory; never delete PVC `qui` or its data. Pin `tag@digest` and do not merge subsequent Renovate updates to this temporary inventory image as routine upgrades.

v4 review resolutions: council round 3 approved S1-I0 implementation, Kimi 9.5/10 (task `5f8cf562-b84e-4d2c-96d7-9c266e05715d`), Sonnet 9/10 (task `48696063-26e7-4156-8425-ba1e97f36ba3`). The execution panel on v3 requested changes and two terminal verdicts were marked incomplete by its harness. Accepted stronger WAL/read-only-image validation, explicit fallback, pre/post readiness, pre-launch Service endpoint checks, longer observation timeout, retry identity and limited-canary scope. Rejected an invariant production-file hash requirement under a concurrent real writer because legitimate application writes make it misleading. Rejected widening the errno whitelist to treat refused/unreachable services as proof of policy denial; safe inconclusive failure is intentional. Configured panel routes for author GPT/infra are correctness `openrouter/moonshotai/kimi-k3.1-pro`, quality `nvidia-inference/nvidia/zai-org/glm-5.3`, security `nvidia-inference/azure/anthropic/claude-opus-5-5`, as defined in installed `review-router/table.ts`; these are configuration, not runtime attestation. A fresh complete panel is required before readiness. No production mutation occurred.


#### S1-I0 synthetic validation stage

Local container engines are absent. An unprivileged private mount-namespace probe failed with `unshare: write failed /proc/self/uid_map: Operation not permitted`. No tool installation or privilege expansion is authorized to bypass that limitation. The five host-Python logic tests passed on v3, but they do not satisfy the pinned-image/kernel-mount gate.

Before introducing any production-PVC mount, prepare a separately reviewed synthetic Job `qui-migration-synthetic-v1`, with the pinned Python image, no Secrets, service-account token, host mounts, NFS or PVCs. Use only bounded memory-backed emptyDir volumes, fresh synthetic data, a separate unique selector and deny-all policy. Its writer and reader containers run UID/GID 1000, read-only root filesystems, dropped capabilities and resource limits. The fixture volume is writable only in the writer and kernel read-only in the reader. Set `activeDeadlineSeconds: 120`, `backoffLimit: 0` and a 150-second observation timeout on the synthetic Job. A second bounded memory-backed signals volume is writable in both containers and contains only synchronization markers. These writable synthetic volumes are never permitted on the production inventory Job.

The writer creates the three expected tables containing sentinel fake credential fields, enables WAL, disables auto-checkpoint, commits a row known to remain in WAL and keeps the SQLite connection open. The reader verifies its fixture mount is read-only, sees the committed WAL row through the exact inventory connection/queries, verifies attempted SQL and filesystem writes are rejected, and checks that output contains no sentinel. A marker handshake pauses fixture commits with the writer connection open for a before/after fixture hash/metadata comparison. Then resume controlled concurrent commits, inserting exactly one row in each table in a single transaction per known batch. Each reader snapshot must have equal counts across all three tables within the known committed-batch bounds, and the final count after all batches must match the exact expected total. This tests transaction consistency without claiming to detect every possible locking defect statistically. No `immutable`, `nolock`, file-copy workaround or permission changes. Both containers have a finite shared deadline; reader failure is propagated to Job failure, and its finally path signals the writer to exit. Retain aggregate results only.

Before any live inventory PR, require synthetic Job Complete, both container exit codes 0, pinned-image Python/SQLite version recorded, successful kernel-RO/WAL/no-leak/write-rejection assertions and no effect on Qui readiness. Synthetic failure holds only inventory and is diagnosed, not retried in a loop. Use a newly reviewed synthetic Job name for a justified retry. After evidence is captured, remove only these synthetic resources via GitOps. The exact manifests and synthetic program must pass staged review before this stage is merged. This is validation of the selected inventory preparation, not permission to create a production recovery clone.


v5 panel resolutions: accepted exact label capture, allowlisted schema checks, staged safe SQLite/network diagnostics, post-wait Job conditions, fixed synthetic deadline and deterministic committed-batch assertions. All three v4 panel reviews completed; correctness/quality requested changes and security returned LGTM with nits. These changes resolve those findings without exposing credentials or widening production actions. The source check verified persistent physical tables; joined views are unnecessary for aggregate existence inventory. The authenticated fallback now requires its own reviewed credential/network method. Production implementation remains pending a complete passing panel.


Implementation record: v5 execution-contract panel round 3 completed 3/3: correctness LGTM, quality/security LGTM with nits, no blocking findings. Reviewed SHA256 `a2b61c7265de9f821edc78d368b4490a0531c78a77ef88cb7c97fec629231727`. S1-I0 is cleared to write and locally validate synthetic preparation resources only. Its live-PVC launch and all production upgrades remain gated. Resolve implementation nits with equal seeds, one explicit transaction per snapshot, exact inventory script invocation, concrete namespace/resources, deadline backstop, explicit synthetic ConfigMap/policy placement and resource staging. Worktree `/tmp/home-ops-qui-migration-20261123-q2xwdmz0`, branch `eff/qui-migration-inventory-20261123-q2xwdmz0`, is job-owned; retain while its work is outstanding.


Staged implementation review round 1: correctness LGTM; security LGTM with nits; quality requested negative-path coverage (MED). Added exact-entry-point checks for exit 2 with a real loopback listener before SQLite, exit 3 with a private missing-schema fixture, and exit 1 with a genuine missing read-only database. Host execution passed all three, with no sentinel in output. Missing-role diagnostics fixed; unused future inventory ConfigMap deferred until its Job is added. Synthetic resources are in downloads, requests 10m/32Mi and limits 100m/128Mi per container. fsGroup is intentionally limited to memory-backed synthetic volumes and forbidden on the future live-PVC Job. Every deployed script/template change must use a fresh Job identity; no automatic replacement/retry is enabled. Static canary IPs are retained because DNS/API egress is denied; the reviewed immediate pre-launch Service/IP/endpoint hold remains mandatory. The live pinned-image/kernel-read-only test remains pending GitOps execution.


Staged review round 2: added explicit real-entry-point checks for refused/unreachable network errors (exit 1 before SQLite), plus permission-denial errno acceptance; host checks pass without exception-message sentinel leakage. Writer now requires a reader-success marker before exit 0. Correctness text had no issues but its terminal verdict was rejected by the harness, so no commit was made. Rejected the unused-inventory.py finding because the synthetic reader executes that exact file in both a real subprocess and runpy negative-path checks. Policy-before-synthetic-Job enforcement lag remains a safe synthetic-only failure with a new reviewed identity required after diagnosis. No active live Job is included; script/template changes must change its future Job identity, and static IPs retain the explicit immediate pre-launch validation gate. A complete third staged review is required before commit.


### Verified execution: synthetic stage, 2026-11-23

[PR #2602](https://github.com/Vikaspogu/home-ops/pull/2602) merged as `a384e1378f88d0466954e7c96f4b3eed42cb6811` at about 20:54:35 UTC. All three GitHub checks passed, no review objections/threads were unresolved, exact-head squash used `17a54a89ee340a9f7bdb5930ac1588c4fa4b11d4`. Main's reviewed files matched that head after merge.

Argo CD reconciled that exact squash commit. `qui-migration-synthetic-v1` completed at 20:57:14 UTC; reader and writer each exited 0 at 20:57:11 UTC. Live pod inspection confirmed the pinned image, UID/GID 1000, no token/env credentials, no production PVC/NFS/host mounts and the dedicated deny-all selector. Result:

```json
{"synthetic_validation":"passed","python":"3.15.2","sqlite":"3.53.4","kernel_read_only":true,"wal_row_visible":true,"fixture_unchanged_during_idle_reader":true,"concurrent_snapshots":41,"final_rows_per_table":21,"failure_exit_codes_verified":[1,2,3],"network_error_contract_verified":true}
```

Qui returned to Synced/Healthy at the squash commit; HTTP /health returned 200. Production pod UID `fa4fbaf3-2a09-49a3-ba14-69e4d56547da` remained Ready with zero restarts and no Qui Warning events. Existing Envoy/root degradation and onstar2mqtt drift remained baseline. Five Talos nodes were Ready. This proves the synthetic read-only/WAL test only, not backup restore or upgrade completion.

The live-tested ConfigMap's inventory.py exactly matched repository content, SHA256 `7fb27d2a77cf1ea90de8a50464e65fec45d8a7543e2bd885956254b2c751f683`. The next change keeps that script and image unchanged and introduces only the bounded read-only live inventory Job/ConfigMap. The existing qui-inventory deny-all policy already reconciled. The completed synthetic Job, its now-unused policy/ConfigMap and synthetic-only source files can be removed through that same scoped GitOps change; this result and source commit preserve the evidence. No production PVC is deleted.

Current job-owned worktree remains `/tmp/home-ops-qui-migration-20261123-q2xwdmz0`; active continuation branch is `eff/qui-live-inventory-20261123`, based on the exact squash commit. Before merging its PR, recheck the unchanged script hash, current Qui affinity labels/node/readiness, canary Service IPs and ready endpoints, no additive policy allowances, no concurrent inventory/backup mover and the VolSync schedule (`25 5,11,17,23 * * *` UTC at inspection). Last completed backup was 17:52:12 UTC; this is not permission to overlap the next backup window. A moved/restarting Qui pod or active backup holds launch. If safe mounting fails, never force-detach or add fsGroup/write permissions. All three upgrade PRs and the protected recovery prerequisites remain pending.

### Verified live inventory, 2026-11-24

[PR #2604](https://github.com/Vikaspogu/home-ops/pull/2604) merged as `b12fabc6b884f149c9ba3c36b4be22f36b037039`. Argo CD reconciled that revision and reported Qui Synced and Healthy. The inventory Job completed at 09:33:59 UTC with exit 0. Its read-only count found zero API keys, zero client API keys and one configured instance. This is a point-in-time observation. The Qui pod stayed Ready with zero restarts and the health endpoint returned HTTP 200. No Qui warning event was observed.

This change removes the temporary Job, ConfigMap and dedicated inventory policy from desired state after capturing the result. The existing Qui PVC and deployment remain declared. Before upgrading, still verify a matching restore and check the configured instance and workflows against the target version.
