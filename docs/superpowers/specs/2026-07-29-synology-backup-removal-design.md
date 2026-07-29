# Synology backup removal

## Decision

Remove the `synology-photos-backup` Argo CD application registration and its complete component directory.

## Scope

- Delete the `synology-photos-backup` entry from `clusters/talos/apps/20-applications.yaml`.
- Delete `components/default/synology-photos-backup/`.
- Let Argo CD prune `default/synology-backup`, its ExternalSecret, and its generated Kubernetes Secret.

## Constraints

- Do not modify the 1Password source item.
- Do not modify Synology data, Garage buckets, or unrelated backup workloads.

## Verification

After reconciliation, the Argo CD Application and all resources created by this component are absent.
