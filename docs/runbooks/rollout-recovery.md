# Filebrowser, Kubechecks, and Renovate recovery

These changes prepare recovery from the October 11, 2026 alerts. Local manifest checks do not prove live recovery.

## Filebrowser

Filebrowser v2.0.0 exits with `old database path is set in the config, please migrate your database to SQLite`. Restore the exact prior image, `1.5.8-stable`, and retain the existing PVC and v1 configuration.

Before deployment, verify a current backup or snapshot of the Filebrowser PVC and confirm that the legacy database remains unconverted. Stop if the database was migrated or replaced. The crash logs show configuration rejection, but the PVC state has not been inspected.

After deployment, verify readiness, login, existing users, shares, and files. Do not accept another v2 update until a separate migration is ready. The [official migration guide](https://filebrowserquantum.com/en/docs/getting-started/v2/migration/) requires a backup, configuration conversion, and deliberate BoltDB-to-SQLite migration. This recovery does not perform those steps.

## Kubechecks

The failing pod receives literal `argo.${CLUSTER_DOMAIN}:443` and cannot resolve it. Its Argo CD Application must select the existing `setenv-cmp-plugin-v1.0` plugin. That plugin renders the component and substitutes cluster variables. One older pod was healthy during diagnosis.

After deployment, verify that the new pod is ready and the rollout completes. Check the live ConfigMap's Argo CD address and webhook URL. Check the HTTPRoute hostname, external DNS target, and gateway references. They must contain the real cluster values, with no unresolved placeholders. Verify a webhook delivery succeeds.

The local check uses restricted `envsubst '${CLUSTER_DOMAIN}'` to test the ConfigMap, route, and preserved ExternalSecret template. It does not run the production `envsub --greedy-defaults` command. Production substitution still needs live verification.

## Renovate

Both latest job attempts exited with code 134 after exhausting the JavaScript heap near 1 GiB. Set the heap limit to 1536 MiB while retaining the 2 GiB container memory limit. See [Renovate on Gitea](renovate-gitea.md) for scheduled-run verification and memory limits.

## Local checks

Run from the repository root:

```bash
bash scripts/test-rollout-recovery.sh filebrowser
bash scripts/test-rollout-recovery.sh kubechecks
bash scripts/test-rollout-recovery.sh renovate
bash clusters/talos/apps/test-rendered-manifest.sh
git diff --check
```

The render checks require `kustomize`, `helm`, `yq`, and `envsubst`, plus access to the chart registries when charts are not cached. A chart download failure is a test prerequisite failure, not evidence that a recovery assertion failed.
