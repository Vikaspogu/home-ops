# Garage Offline Recovery Design

## Status

Approved design. Implementation remains gated on operator review of this written specification.

## Problem

The failed Garage primary node held 166 of 256 partitions in a replication-factor-1 layout. The surviving `k8s-3-4u` backup holds the other 90 partitions and about 2.02 TiB of Garage block data.

The preserved Garage metadata snapshots are not complete object catalogs:

| Snapshot | `object:table` | `version:table` | `block_ref:table` | `block_local_rc` |
|---|---:|---:|---:|---:|
| `2026-07-21T10:05:55Z` | 0 | 62,463 | 412,381 | 381,031 |
| `2026-07-21T16:55:08Z` | 0 | 62,082 | 412,182 | 381,105 |

Garage can list six bucket aliases after applying a standalone layout to a disposable clone, but every bucket reports zero objects because `object:table` is empty. Standard S3 and Garage CLI export therefore cannot enumerate recoverable objects.

Garage v2.3.0 `Version` records retain an object backlink containing `bucket_id` and `key`, plus an ordered map of block hashes and uncompressed sizes. This is sufficient to reconstruct block-backed versions without recreating the missing object index. The missing `Object` records contained latest-version state, timestamps, ETags, headers, encryption metadata, and inline object bytes; those values must not be guessed.

Relevant upstream schemas:

- [`Version`, `VersionBacklink`, `VersionBlockKey`, and `VersionBlock`](https://github.com/deuxfleurs-org/garage/blob/v2.3.0/src/model/s3/version_table.rs)
- [`Object`, `ObjectVersion`, and `ObjectVersionData`](https://github.com/deuxfleurs-org/garage/blob/v2.3.0/src/model/s3/object_table.rs)
- [Garage dead-node recovery procedure](https://garagehq.deuxfleurs.fr/documentation/operations/recovering/)

## Goal

Recover every decodable, non-deleted, block-backed object version present on the surviving node. Preserve original bucket IDs and keys in a machine-readable manifest. Never choose or label a version as the latest version.

## Non-goals

- Reconstruct the failed node's 166 missing partitions.
- Recover inline object bytes absent from `object:table`.
- Invent object timestamps, ETags, HTTP headers, encryption metadata, or version precedence.
- Treat incomplete multipart uploads as completed S3 objects.
- Repair or restart the production Garage cluster.
- Modify the original Btrfs source filesystem or its metadata.

## Source of Truth

Use the pristine `2026-07-21T16:55:08Z/db.lmdb` snapshot and the original eight COW-backed source devices. The source filesystem remains mounted read-only.

Do not use `recovery-2026-07-21/existing-store/meta/db.lmdb` as metadata input. Starting Garage against that clone changed it from 62,082 to 62,063 version rows and from 412,182 to 411,539 block-reference rows before the process was stopped.

## Safety Invariants

1. All eight physical source disks remain kernel read-only.
2. All device-mapper origins remain read-only; writes are allowed only to sparse COW snapshots.
3. The Btrfs source mount is read-only.
4. The extractor opens LMDB and Garage data paths read-only.
5. The output directory is outside the source filesystem.
6. Existing completed output files are never overwritten.
7. A failed object reconstruction never leaves a file that appears complete.
8. Extraction does not start unless expected output bytes fit in the destination with a safety reserve.

Any failed invariant aborts before content extraction.

## Architecture

### Exact-version recovery binary

Build a one-off Rust binary against the Garage v2.3.0 source and dependency lockfile. Reuse Garage's migration-aware metadata decoder and block-storage reader instead of duplicating its serialization, compression, encryption, or block-path logic.

The binary has one command with explicit paths for:

- the LMDB snapshot;
- the Garage data directories;
- the output root;
- the manifest path.

No service, API, reusable library, configuration framework, or repository dependency is added.

### Recovery pod

Run the binary in a pinned, one-shot pod on `k8s-3-4u`. The pod receives:

- the original COW-backed Garage source mounted read-only;
- `/var/mnt/backup-garage/recovery-2026-07-21/recovered-versions` as the only writable recovery destination;
- no Service and no network access during extraction.

Build tooling runs separately from the recovery mount. Only the resulting pinned binary enters the extraction pod.

### Output layout

Store reconstructed content by immutable identifiers:

```text
recovered-versions/
  objects/<bucket-id>/<version-uuid>.bin
  manifest.jsonl
  summary.json
```

The original object key remains in `manifest.jsonl`, not in a filesystem path. This avoids path traversal, invalid filenames, collisions, and component-length limits.

Each manifest row contains:

- bucket ID and known bucket alias;
- original object key;
- version UUID;
- version backlink type;
- deletion state;
- ordered block count;
- expected uncompressed byte count;
- output relative path when successful;
- SHA-256 of recovered bytes when successful;
- status: `recovered`, `missing-block`, `corrupt-block`, `metadata-only`, `multipart`, or `deleted`;
- failing block hash and error when applicable.

The manifest never contains credentials or Garage secret material.

## Data Flow

### Preflight

1. Recheck physical disks, mapper origins, and source mount read-only state.
2. Open the preserved LMDB snapshot read-only and decode all version rows with Garage v2.3.0 migration support.
3. Classify rows by backlink type, deletion state, and block presence.
   Assign exactly one terminal status in this order: `deleted`, `multipart`, `metadata-only`, then an extraction result.
4. Sum expected uncompressed bytes for selected object-backed versions.
5. Compare the total with destination free space while retaining at least 10% free space.
6. Emit a preflight summary and stop if capacity is insufficient.

### Extraction

For each non-deleted `VersionBacklink::Object` with blocks:

1. Resolve the bucket alias when available.
2. Sort block entries by `(part_number, offset)`.
3. Open a unique `.partial` output with create-new semantics.
4. Read each block through Garage's v2.3 block reader.
5. Validate the block against its recorded hash and decoded size.
6. Append decoded bytes while updating file SHA-256 and written-byte count.
7. Require written bytes to equal the sum of `VersionBlock.size` values.
8. Sync and atomically rename the file to `<version-uuid>.bin`.
9. Append and sync a `recovered` manifest row.

On a missing or corrupt block, close and remove the partial file, append a failed manifest row, and continue with the next version. Process-level failures abort the run; object-level data failures are isolated and counted.

Deleted rows, multipart-upload backlinks, and rows without recoverable blocks are recorded but not materialized as completed objects.

### Restart behavior

A rerun reads the existing manifest. A previously recovered file is skipped only when its path, size, and SHA-256 still match the completed manifest row. Stale partial files are removed before reconstruction. Failed rows are retried.

## Verification

The run is complete only when:

1. Every decoded version row has exactly one terminal manifest status.
2. `recovered + missing-block + corrupt-block + metadata-only + multipart + deleted` equals the decoded version count.
3. Every recovered file size equals its manifest expected size.
4. Every recovered file SHA-256 matches its manifest value.
5. An independent sample rehash matches the manifest.
6. Source read-only invariants still pass after extraction.
7. `summary.json` reports decoded rows, recovered versions and bytes, failures by reason, skipped metadata-only rows, and remaining destination capacity.

A successful process exit means the scan completed and the manifest is internally consistent. It does not mean every version was recoverable; partial recovery is reported explicitly by status counts.

## Known Limits

- The failed primary node's partitions are absent, so many versions will have missing blocks.
- Inline objects cannot be recovered because their bytes existed only in the missing `object:table`.
- Original content metadata and latest-version ordering cannot be reconstructed from `Version` records.
- Preserving every version can require substantially more space than the surviving deduplicated/compressed block store. Preflight capacity is therefore a hard gate.
