# Garage Backup Node Implementation Plan

> **For implementation:** Use the executing-plans workflow. Stop at each merge/live-cluster checkpoint and verify the stated gate before continuing.

**Goal:** Retire `garage-s3-node2`, remove the temporary Btrfs recovery setup from `k8s-5-1u`, provision eight generic Talos XFS user volumes, and run an independent Garage current mirror every day at 04:00 America/New_York.

**Architecture:** Talos owns eight independent XFS filesystems named `backup1` through `backup8`. A staged but initially unregistered `garage-s3-backup` component mounts them and exposes only an internal S3 service. An rclone CronJob uses one dedicated credential that is read-only on active Garage and read/write on backup Garage. Two GitOps activation stages prevent the backup workload from starting before the disks exist.

**Stack:** Talos v1.13.7, talhelper, Argo CD, Kustomize, bjw-s app-template 5.0.1, Garage v2.3.0, External Secrets, rclone 1.74.4.

**Approved design:** `docs/superpowers/specs/2026-07-22-garage-backup-node-design.md`

**Primary references:**

- Talos user volumes: https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/disk-management/user
- Talos disk selectors: https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/disk-management/common
- Talos Image Factory: https://docs.siderolabs.com/talos/v1.13/learn-more/image-factory
- rclone S3 backend: https://rclone.org/s3/
- rclone sync semantics: https://rclone.org/commands/rclone_sync/
- Existing repository patterns: `clusters/talos/bootstrap/os/patches/k8s-3-4u/storage-volumes.yaml:9-18`, `components/default/synology-photos-backup/cronjob.yaml:1-120`, and `components/default/garage-s3/values.yaml:2-100`.

## Preconditions and invariants

- Keep `k8s-5-1u` cordoned until the final health gate.
- Revalidate disk WWIDs immediately before every destructive command. Device names are observations, never identities.
- Never print or persist decoded Secret values. Secret creation/import uses an in-memory process.
- Never run the active and obsolete Garage components against the same storage.
- Do not register `garage-s3-backup` until all eight Talos mounts are ready.
- Suspend the mirror before any recovery or promotion action.

## Task 1: Stage the Talos user volumes

**Files:**

- Delete: `clusters/talos/bootstrap/os/patches/k8s-5-1u/btrfs-recovery.yaml`
- Replace/rename: `clusters/talos/bootstrap/os/patches/k8s-5-1u/garage-storage.yaml` to `clusters/talos/bootstrap/os/patches/k8s-5-1u/storage-volumes.yaml`
- Modify: `clusters/talos/bootstrap/os/talconfig.yaml:127-142`

**Step 1: Replace the legacy mount patch**

Create one multi-document file with eight `UserVolumeConfig` resources. Preserve the existing physical-disk numbering while changing the generic volume names:

```yaml
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: backup1
provisioning:
  diskSelector:
    match: disk.wwid == 'naa.5000cca02278736c'
  minSize: 800GB
  grow: true
filesystem:
  type: xfs
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: backup2
provisioning:
  diskSelector:
    match: disk.wwid == 'naa.5000cca07194d828'
  minSize: 800GB
  grow: true
filesystem:
  type: xfs
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: backup3
provisioning:
  diskSelector:
    match: disk.wwid == 'naa.5000cca0576b90f0'
  minSize: 800GB
  grow: true
filesystem:
  type: xfs
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: backup4
provisioning:
  diskSelector:
    match: disk.wwid == 'naa.5000cca0430361b0'
  minSize: 800GB
  grow: true
filesystem:
  type: xfs
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: backup5
provisioning:
  diskSelector:
    match: disk.wwid == 'naa.5000cca07111a7cc'
  minSize: 800GB
  grow: true
filesystem:
  type: xfs
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: backup6
provisioning:
  diskSelector:
    match: disk.wwid == 'naa.5000cca0719b81d8'
  minSize: 800GB
  grow: true
filesystem:
  type: xfs
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: backup7
provisioning:
  diskSelector:
    match: disk.wwid == 'naa.5000cca071478cf0'
  minSize: 800GB
  grow: true
filesystem:
  type: xfs
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: backup8
provisioning:
  diskSelector:
    match: disk.wwid == 'naa.5000cca07147a3c0'
  minSize: 800GB
  grow: true
filesystem:
  type: xfs
```

`grow: true` consumes the available 900 GB disk; `minSize` is only the selector/provisioning floor.

**Step 2: Remove temporary Btrfs configuration**

In the `k8s-5-1u` node entry:

- replace `@./patches/k8s-5-1u/btrfs-recovery.yaml` with `@./patches/k8s-5-1u/storage-volumes.yaml`;
- remove `siderolabs/btrfs` from `officialExtensions`;
- retain `i915`, `intel-ucode`, and `kata-containers`.

Run:

```bash
cd clusters/talos/bootstrap/os
talhelper genurl installer --node k8s-5-1u
```

Set `talosImageURL` to the returned installer URL. The URL must differ from the Btrfs-enabled schematic and still target Talos v1.13.7 through `talenv.yaml`.

**Step 3: Validate the Talos source**

```bash
cd clusters/talos/bootstrap/os
talhelper validate talconfig talconfig.yaml
talhelper genconfig
```

Inspect the generated `k8s-5-1u` node config and assert it contains exactly eight `UserVolumeConfig` documents named `backup1` through `backup8`, all with XFS and the expected WWIDs. It must contain no `btrfs` kernel module or Btrfs extension.

## Task 2: Replace the obsolete component with a staged backup component

**Files:**

- Move: `components/default/garage-s3-node2/` to `components/default/garage-s3-backup/`
- Modify: `components/default/garage-s3-backup/kustomization.yaml`
- Modify: `components/default/garage-s3-backup/values.yaml`
- Modify: `components/default/garage-s3-backup/resources/configuration.toml`
- Create: `components/default/garage-s3-backup/externalsecret.yaml`
- Create: `components/default/garage-s3-backup/sync-cronjob.yaml`

Do not register this component in Argo during this task.

**Step 1: Rename the Helm release and ConfigMap**

Use `garage-s3-backup` consistently for the release, controller, Service, ConfigMap, labels, and generated resource names. Add `externalsecret.yaml` and `sync-cronjob.yaml` to `resources`. Keep app-template `5.0.1`.

**Step 2: Mount all Talos volumes fail-closed**

Pin the Garage controller to `k8s-5-1u`. Define eight hostPath persistence entries:

```yaml
persistence:
  disk1:
    type: hostPath
    hostPath: /var/mnt/backup1
    hostPathType: Directory
    globalMounts:
      - path: /storage/disk1
```

Repeat through `disk8` and `/var/mnt/backup8`. Use `hostPathType: Directory`, not `DirectoryOrCreate`; a missing Talos mount must leave the Pod Pending instead of writing to the system disk.

Keep only the Garage app container and the internal rpc/s3/api Service ports. Do not add WebUI or HTTPRoute. Keep the existing pinned Garage image, security context, and resources.

**Step 3: Configure the independent Garage store**

Use:

```toml
metadata_dir = "/storage/disk1/meta"
data_dir = [
  { path = "/storage/disk1/data", capacity = "800GB" },
  { path = "/storage/disk2/data", capacity = "800GB" },
  { path = "/storage/disk3/data", capacity = "800GB" },
  { path = "/storage/disk4/data", capacity = "800GB" },
  { path = "/storage/disk5/data", capacity = "800GB" },
  { path = "/storage/disk6/data", capacity = "800GB" },
  { path = "/storage/disk7/data", capacity = "800GB" },
  { path = "/storage/disk8/data", capacity = "800GB" },
]
```

Retain LMDB, six-hour metadata snapshots, compression level 2, and replication factor 1. Set `rpc_public_addr` to `garage-s3-backup.default.svc.cluster.local:3901`.

**Step 4: Add an isolated ExternalSecret**

Create target Secret `garage-s3-backup-secret` from the existing `garage` 1Password item. Map:

- `RPC_SECRET` to `GARAGE_RPC_SECRET`;
- `ADMIN_TOKEN` to `GARAGE_ADMIN_TOKEN`;
- `METRICS_TOKEN` to `GARAGE_METRICS_TOKEN`;
- `BACKUP_ACCESS_KEY` to `RCLONE_S3_ACCESS_KEY_ID`;
- `BACKUP_SECRET_KEY` to `RCLONE_S3_SECRET_ACCESS_KEY`;
- `REGION` to `RCLONE_S3_REGION`.

The two backup-key fields are added to 1Password in Task 7 before activation.

**Step 5: Add the daily mirror CronJob**

Use `schedule: "0 4 * * *"`, `timeZone: America/New_York`, `concurrencyPolicy: Forbid`, and initially `suspend: true`. Pin `rclone/rclone:1.74.4` and configure two S3 remotes from the same Secret-backed key:

- `source`: `http://garage-s3.default.svc.cluster.local:3900`;
- `backup`: `http://garage-s3-backup.default.svc.cluster.local:3900`.

Both remotes use provider `Other`, region from the Secret, and path-style access. The shell command enumerates permitted source buckets and mirrors each one:

```sh
rclone lsf source: --dirs-only | while IFS= read -r bucket; do
  bucket=${bucket%/}
  rclone mkdir "backup:${bucket}"
  rclone sync "source:${bucket}" "backup:${bucket}" --checksum --fast-list
 done
```

Do not suppress sync errors. Use `restartPolicy: OnFailure`, non-root UID/GID 1000, RuntimeDefault seccomp, read-only root filesystem, dropped capabilities, `/tmp` and `/.cache/rclone` emptyDirs, 50m/128Mi requests, and a 512Mi memory limit. Pin the Job to `k8s-5-1u` so transfer enters the node once.

## Task 3: Remove the obsolete Argo application and validate stage A

**Files:**

- Modify: `clusters/talos/apps/20-applications.yaml:208-222`

Delete the `garage-s3-node2` entry. Do not add `garage-s3-backup` yet.

Run:

```bash
kustomize build --enable-helm components/default/garage-s3-backup \
  | kubeconform -strict -ignore-missing-schemas -summary
```

Then render JSON and assert:

- Deployment node affinity selects only `k8s-5-1u`;
- exactly eight hostPath volumes map `/var/mnt/backup1` through `/var/mnt/backup8`;
- every hostPath type is `Directory`;
- no HTTPRoute or external route exists;
- CronJob schedule and timezone are correct;
- source and destination endpoints differ;
- all Secret references name `garage-s3-backup-secret`;
- no rendered resource contains `garage-s3-node2`.

Run repository YAML validation for the changed manifests.

## Task 4: Review and merge stage A

Request code review after all stage-A changes. Address only findings tied to correctness, safety, security, or repository conventions. Commit with a conventional message explaining the cutover, push the branch, open a PR to `main`, wait for required checks, and merge.

After merge, hard-refresh only the generated `garage-s3-node2` Argo application and verify it is pruned. Confirm no `garage-s3-node2` Deployment, Pod, Service, ConfigMap, or Endpoint remains.

**Checkpoint:** Do not touch the disks until this prune is observed.

## Task 5: Remove recovery devices and files

Use kubeconfig `/Users/vikaspogu/.kube/configs/talos-cluster-config` explicitly.

**Step 1: Revalidate isolation**

Confirm:

- node `k8s-5-1u` is cordoned;
- only DaemonSets, Tuppr, and the two known recovery Pods run there;
- no Pod hostPath consumes `/var/mnt/garage-hdd*` or `/var/mnt/backup*`;
- the eight target WWIDs still map one-to-one to the observed non-system disks.

Abort on any mismatch.

**Step 2: Remove the COW stack**

Inside the privileged recovery Pod that owns the tools:

1. unmount any recovery Btrfs mount if one appears;
2. remove `garage-recovery-sdb` through `garage-recovery-sdi` with `dmsetup remove`;
3. detach only the loop devices whose backing files are under `/var/lib/cow-recovery`;
4. delete the COW files through the mounted hostPath;
5. delete `btrfs-recovery-k8s-5-1u` and `btrfs-cow-recovery-k8s-5-1u`.

Verify the mappings, loop-backed files, Pods, and `/var/lib/cow-recovery` content are absent.

## Task 6: Wipe and provision the eight disks

**Step 1: Revalidate device identity immediately before wipe**

Query Talos `Disks`/`DiscoveredVolumes` and construct the device list by matching the eight approved WWIDs. Assert that:

- exactly eight devices match;
- none is the Talos system disk;
- every device is approximately 900 GB;
- no matched device is mounted or open by device mapper.

**Step 2: Wipe the matched disks**

Use `talosctl wipe disk <verified-device-names> --method FAST` against node `10.30.30.25`. Device names may be passed only after the WWID assertions in the same execution path.

**Step 3: Apply the generated node configuration**

From the merged repository state:

```bash
task talos:generate-config
task talos:apply-node IP=10.30.30.25
```

Wait until `backup1` through `backup8` report ready. Verify each is XFS, mounted at `/var/mnt/backupN`, and backed by its expected WWID.

**Step 4: Remove the Btrfs extension from the running image**

Run the same-version image upgrade using the newly generated schematic:

```bash
task talos:upgrade-node IP=10.30.30.25
```

Wait for reboot and Kubernetes readiness. Verify Talos remains v1.13.7 and `siderolabs/btrfs`, the loaded `btrfs` module, all recovery devices, and recovery files are absent.

**Checkpoint:** Keep the node cordoned. Continue only when all eight mounts are healthy after reboot.

## Task 7: Create the dedicated backup credential

Create one Garage key named `garage-backup` on the active Garage. Grant read-only permission to every current source bucket:

- `ivan-plugin-images`;
- `kopia-backup`;
- `obsidian-notes`;
- `postgres`;
- `reactive-resume`;
- `synology-backup`.

Do not grant write, owner, or create-bucket permission on the active Garage.

Add the generated access ID and secret to the existing `garage` 1Password item as `BACKUP_ACCESS_KEY` and `BACKUP_SECRET_KEY`. Perform the create-and-store operation as one in-memory transaction: if the 1Password update fails, delete the Garage key before returning. Never print either value.

Confirm only metadata: the key exists, its secret is valid length, and all six read grants are present.

## Task 8: Activate the backup application

Create a fresh branch from current `origin/main` after Task 6. Modify only `clusters/talos/apps/20-applications.yaml` to register:

```yaml
garage-s3-backup:
  annotations:
    argocd.argoproj.io/sync-wave: "20"
  destination:
    namespace: default
  source:
    path: components/default/garage-s3-backup
```

Validate the app-of-apps render, request focused review, open a second PR, wait for checks, and merge.

Refresh only the `garage-s3-backup` Argo application. Wait for the ExternalSecret, Deployment, Service, and suspended CronJob. The Deployment must schedule on `k8s-5-1u`; confirm no scheduled mirror Job can start before layout initialization.

## Task 9: Initialize the backup Garage

Use `/garage` inside the backup app container, matching the repository's pinned image entrypoint.

1. Read the fresh node ID from `garage status`.
2. Assign the single node to zone `homelab` with 6.4 TB staged capacity.
3. Apply layout version 1.
4. Import the dedicated backup access ID/secret from the Kubernetes Secret without printing them.
5. Grant that key create-bucket permission on the backup Garage. Buckets it creates receive the required destination access.
6. Verify Garage reports one healthy node, replication factor 1, layout version 1, and expected capacity.

If any bootstrap step fails, keep the mirror suspended and preserve the initialized metadata for diagnosis.

## Task 10: Establish and verify the baseline

Create one Job from the CronJob with a unique baseline name. Wait for completion; do not start duplicate database, Kopia, or Synology backup jobs while it runs.

Verify:

- the Job exits successfully with no skipped/error objects;
- all six source buckets exist on the backup;
- source and backup object counts and total bytes match per bucket;
- sampled object checksums match for every non-empty bucket;
- the active Garage logs show only reads from the backup key;
- the backup Garage logs show writes from that key.

Restart the `garage-s3-backup` Pod. Confirm the same node ID, layout version, key metadata, bucket counts, and sampled reads remain available.

After the baseline and restart checks pass, change only `components/default/garage-s3-backup/sync-cronjob.yaml` from `suspend: true` to `suspend: false`. Validate, review, merge the focused change, and refresh `garage-s3-backup`. Confirm the CronJob is unsuspended and next scheduled for 04:00 America/New_York.

## Task 11: Final health and cleanup

Run focused Kubernetes and Argo checks:

- `garage-s3` remains healthy on `k8s-3-4u`;
- `garage-s3-backup` is healthy on `k8s-5-1u`;
- `garage-s3-node2` is absent;
- all eight Talos volumes are ready and XFS-backed;
- no Btrfs recovery artifact remains;
- active PostgreSQL, pgvector, Kopia, and Synology jobs retain their prior schedules and state;
- no unexpected workload uses `/var/mnt/backup*`.

Uncordon `k8s-5-1u`. Recheck node readiness and both Garage deployments after scheduling resumes.

Run `graphify update .` after repository changes and commit only graph files produced by the accepted code changes if repository policy tracks them.

## Recovery guardrail

Before any future promotion, suspend `garage-s3-backup-sync`. Never run a current mirror from an empty or unhealthy source. Automatic failover and historical version retention remain out of scope.
