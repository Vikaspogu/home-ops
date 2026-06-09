# Renovate on Gitea

Renovate runs as a suspended Kubernetes CronJob in the OMV cluster and targets the self-hosted Gitea API at `https://gitea.a113.casa/api/v1/`.

## Secrets

The deployment expects an ExternalSecret backed by the 1Password item `renovate` with field `RENOVATE_TOKEN`. The token must belong to the `renovate-bot` Gitea account and have write access to the target `vpogu/*` repositories.

No token value belongs in Git, ArgoCD application values, logs, or merge request text.

## Initial rollout

The CronJob is intentionally committed with `suspend: true` so the first live run can be started manually after the ExternalSecret is healthy.

After the GitOps change is synced and the ExternalSecret is healthy:

```bash
kubectl -n default get externalsecret renovate
kubectl -n default get secret renovate-secret
kubectl -n default get cronjob renovate
kubectl -n default create job --from=cronjob/renovate renovate-run-$(date +%Y%m%d%H%M)
kubectl -n default logs -l app.kubernetes.io/instance=renovate --tail=200
```

Expected first-run evidence:

- logs show `platform=gitea` and the Gitea endpoint
- repository discovery is limited to `vpogu/*`
- onboarding or update pull requests are created for eligible repositories
- no repositories outside the autodiscovery filter are processed

## Enable scheduled writes

Only after reviewing the first live run:

1. Set `controllers.app.cronjob.suspend` to `false`.
2. Merge and sync the GitOps change.
3. Watch the next scheduled run logs and onboarding/update pull requests.

The deployment keeps write volume conservative at both the CronJob and Renovate levels:

- CronJob schedule: `0 3 * * *` in `America/New_York`
- `concurrencyPolicy: Forbid`
- Renovate timezone: `America/New_York`
- top-level `prHourlyLimit: 2`
- top-level `prConcurrentLimit: 5`
- onboarding schedule for new repo configs: `after 10pm and before 6am every weekday` plus `every weekend`
- onboarding labels: `dependencies`, `renovate`

## Inspect operations

```bash
kubectl -n default get cronjob renovate
kubectl -n default get jobs --sort-by=.metadata.creationTimestamp | grep renovate
kubectl -n default logs job/<job-name> --tail=200
kubectl -n default describe job/<job-name>
```

## Pause or disable

Preferred pause:

1. Set `controllers.app.cronjob.suspend` to `true` in `components/default/renovate/values.yaml`.
2. Merge and sync.

Emergency pause:

```bash
kubectl -n default patch cronjob renovate -p '{"spec":{"suspend":true}}'
```

Revoke or rotate the Gitea bot token if Renovate must be disabled immediately.

## Rollback

Revert the GitOps commit or remove the `renovate` application registration from `clusters/omv/apps/20-applications.yaml`. Then close any unwanted Renovate onboarding/update pull requests and revoke the bot token if needed.
