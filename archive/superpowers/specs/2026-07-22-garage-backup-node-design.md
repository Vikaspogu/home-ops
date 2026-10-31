# Garage Backup Node Design

**Date:** 2026-07-22
**Status:** Approved

## Goal

Replace the failed Btrfs recovery setup on `k8s-5-1u` with eight Talos-managed XFS volumes and use those volumes for an independent Garage copy of the active `garage-s3` data.

The copy protects against loss of the active Garage node or its storage. It is not an active-passive Garage member and does not protect against cluster-wide loss or deletions that reach the next mirror run.

## Current State

- `k8s-5-1u` has eight 900 GB Garage disks with stable WWIDs.
- The disks retain one failed multi-device Btrfs filesystem signature.
- Two temporary recovery Pods, eight COW device-mapper mappings, loop devices, and `/var/lib/cow-recovery` files remain from salvage work.
- The node configuration includes a temporary Btrfs kernel patch and the `siderolabs/btrfs` system extension.
- `garage-s3-node2` is an obsolete second Garage deployment and is not part of the active Garage cluster.
- The canonical `garage-s3` deployment runs on `k8s-3-4u` and uses its existing single backup volume.

## Talos Storage Layout

Remove the legacy disk-mount patch and define eight `UserVolumeConfig` resources. Each resource:

- is named `backup1` through `backup8`;
- selects exactly one disk by its observed `disk.wwid`;
- provisions XFS;
- consumes the available disk;
- is mounted by Talos at `/var/mnt/backup1` through `/var/mnt/backup8`.

The generic host names keep the disks reusable for another backup workload. The backup Garage container maps them to `/storage/disk1` through `/storage/disk8`.

The volumes remain independent. There is no Btrfs, LVM, software RAID, or hardware RAID change. Garage uses replication factor 1 because the backup cluster has one node.

## Recovery Cleanup

Cleanup is destructive and runs only after revalidating all eight WWID-to-device mappings and confirming that no workload uses the disks.

1. Remove the eight recovery device-mapper mappings.
2. Detach the recovery loop devices backed by `/var/lib/cow-recovery`.
3. Delete both temporary Btrfs recovery Pods.
4. Delete `/var/lib/cow-recovery` files.
5. Wipe the failed Btrfs signatures from the eight verified disks.
6. Remove the Btrfs kernel patch and `siderolabs/btrfs` extension from the Talos source configuration.
7. Regenerate the `k8s-5-1u` image schematic, apply the revised machine configuration, and reboot on the existing Talos v1.13.7 release.
8. Confirm the Btrfs extension, mounts, mappings, loop files, and recovery Pods are absent.

## Backup Garage

Delete the `garage-s3-node2` Argo application and component. Add one `garage-s3-backup` application with:

- a single replica pinned to `k8s-5-1u`;
- one internal ClusterIP service and no HTTPRoute;
- persistent mounts from `/var/mnt/backup1` through `/var/mnt/backup8`;
- metadata on disk 1 and object data distributed across all eight disks;
- conservative per-disk capacity below the 900 GB physical size;
- the existing ExternalSecret-backed Garage RPC, admin, and S3 credentials;
- read-only root filesystem, dropped capabilities, and repository-standard resource requests and memory limit.

The backup Garage remains a separate one-node cluster. Its layout and existing S3 key are initialized once after deployment and retained in its metadata volume.

## Mirror Job

A Kubernetes CronJob runs daily at `04:00` with `concurrencyPolicy: Forbid`.

It performs an S3-to-S3 copy from the active `garage-s3` service to `garage-s3-backup` using Secret-backed credentials. It copies all source buckets and mirrors object deletion within those buckets. It never copies Garage data or LMDB files directly.

The job uses a pinned image, restricted security context, resource requests, and a memory limit. Secret values are injected as environment variables and are never written to Git or command output.

This is a current mirror only. An object deleted from the active Garage before the next run is deleted from the backup during that run.

## Rollout

1. Merge the GitOps removal of `garage-s3-node2` and confirm Argo prunes it.
2. Perform the recovery cleanup and disk wipe while `k8s-5-1u` remains cordoned.
3. Apply the Talos storage and image changes, reboot, and verify all eight XFS mounts.
4. Deploy `garage-s3-backup` and initialize its one-node layout and S3 key.
5. Trigger one manual mirror Job to establish the baseline.
6. Compare source and destination bucket/object totals and sample object checksums.
7. Restart the backup Garage Pod and verify the same layout, key, and objects remain available.
8. Confirm the 04:00 CronJob is enabled, then uncordon `k8s-5-1u` after all checks pass.

The existing PostgreSQL, pgvector, Kopia, and Synology backup jobs continue independently. Long-running jobs are observed rather than duplicated.

## Recovery

Before using the backup copy, suspend the mirror CronJob so an unhealthy or empty source cannot delete destination objects. Confirm `garage-s3-backup` is healthy and object checks pass. Promotion is an explicit GitOps service-routing change after the active Garage is stopped; automatic failover is out of scope.

## Verification

- Talos reports `backup1` through `backup8` ready and mounted at the expected paths.
- Each mount is XFS and resolves to the intended WWID.
- No Btrfs extension, loaded Btrfs module, recovery mapping, loop-backed COW file, recovery Pod, or `/var/lib/cow-recovery` content remains.
- Argo reports no `garage-s3-node2` application or workload.
- Backup Garage reports one healthy node, layout version 1, replication factor 1, and the expected usable capacity.
- The baseline mirror Job completes successfully.
- Every source bucket exists on the destination with matching object totals; sampled object checksums match.
- The backup Garage remains readable after a Pod restart.
- Kubernetes and Argo report healthy state before the node is uncordoned.

## Explicit Non-goals

- Joining the backup node to the active Garage cluster.
- Active-passive or automatic failover.
- Retaining deleted or historical object versions.
- Adding RAID, Btrfs, LVM, or another storage abstraction.
- Copying live Garage filesystem data directly.
