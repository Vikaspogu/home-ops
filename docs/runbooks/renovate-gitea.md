# Renovate on Gitea

Renovate runs as a Kubernetes CronJob in the Talos cluster and targets the self-hosted Gitea API at `https://gitea.${CLUSTER_DOMAIN}/api/v1/`.

## Configuration

- Component: `components/default/renovate`
- Argo CD registration: `clusters/talos/apps/20-applications.yaml`
- Schedule: `0 3 * * *` in `America/New_York`
- Concurrency policy: `Forbid`
- Repository discovery: `vpogu/*`
- Pull-request limits: 2 per hour and 5 concurrent

The ExternalSecret reads:

- `RENOVATE_TOKEN` from the 1Password item `renovate`
- `GHCR_TOKEN` from the 1Password item `Github`

The Gitea token belongs to the `renovate-bot` account and requires write access only to the repositories Renovate manages. No token value belongs in Git, logs, or pull-request text.

## Validate the deployment

```bash
kubectl -n default get externalsecret renovate
kubectl -n default get secret renovate-secret
kubectl -n default get cronjob renovate
kubectl -n default get jobs --sort-by=.metadata.creationTimestamp | grep renovate
```

Inspect a completed or running job:

```bash
kubectl -n default logs job/<job-name> --tail=200
kubectl -n default describe job/<job-name>
```

Expected logs show `platform=gitea`, the configured endpoint, and repository discovery limited to `vpogu/*`.

## Run Renovate manually

```bash
kubectl -n default create job \
  --from=cronjob/renovate \
  renovate-run-$(date +%Y%m%d%H%M)
```

Review its logs and created pull requests before changing schedules, limits, or repository filters.

## Pause or resume

Preferred GitOps pause:

1. Set `controllers.app.cronjob.suspend: true` in `components/default/renovate/values.yaml`.
2. Commit, merge, and let Argo CD sync.

Resume by setting the value to `false` or removing it.

Emergency pause:

```bash
kubectl -n default patch cronjob renovate -p '{"spec":{"suspend":true}}'
```

Follow an emergency patch with the equivalent Git change so Argo CD does not undo it.

## Rollback or disable

Revert the relevant GitOps change or remove the `renovate` registration from `clusters/talos/apps/20-applications.yaml`. Close unwanted Renovate pull requests and revoke the Gitea token if writes must stop immediately.
