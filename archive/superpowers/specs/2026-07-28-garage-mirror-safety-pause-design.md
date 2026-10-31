# Garage mirror safety pause

## Decision

Set `spec.suspend: true` on `garage-s3-backup-sync` in GitOps.

## Reason

Garage detected a checksum-corrupted block immediately after writing it to the source storage volume. The backup mirror uses `rclone sync`; leaving it active could propagate source deletion or corruption to the backup Garage.

## Scope

- Keep Garage available for read-only diagnosis.
- Do not wipe disks, buckets, or unrelated objects.
- Resume the mirror only after the MegaRAID/XFS storage path is remediated and restored objects pass download-and-hash verification.
