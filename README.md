# Home Operations

GitOps configuration for a single Talos Linux Kubernetes cluster managed by Argo CD.

## Platform

- **Kubernetes:** Talos Linux
- **GitOps:** Argo CD app-of-apps with explicit sync waves
- **Packaging:** Kustomize with pinned Helm charts
- **Networking:** Cilium, Traefik, and Gateway API `HTTPRoute` resources
- **Secrets:** External Secrets Operator with 1Password Connect
- **Storage:** Rook Ceph (`ceph-block`) with Longhorn as secondary storage
- **Backups:** VolSync with Ceph CSI snapshots
- **Certificates and DNS:** cert-manager and external-dns
- **Updates:** Renovate

## Repository layout

```text
clusters/talos/
  apps/                 Argo CD application registrations and sync waves
  bootstrap/            Talos, Helmfile, and bootstrap configuration
components/             Kubernetes applications grouped by namespace
helm/charts/             Repository-owned Helm charts
scripts/                 Bootstrap, validation, and contract-test scripts
.taskfiles/              go-task definitions
Taskfile.yaml            Task entry point
```

Application components normally contain:

```text
components/<namespace>/<app>/
  kustomization.yaml
  values.yaml
  http-route.yaml        when ingress is required
  externalsecret.yaml    when secrets are required
```

Persistent applications also reference the shared VolSync component and declare storage capacity through the Argo CD plugin environment.

## Prerequisites

Common local tools:

```bash
brew install kubernetes-cli helm kustomize kubeconform yq gettext
brew install argoproj/tap/argocd go-task/tap/go-task
brew install siderolabs/tap/talosctl budimanjojo/tap/talhelper
brew install sops age 1password/tap/1password-cli
```

Configure access to the Talos cluster, 1Password, and the SOPS age key before running bootstrap or secret-management commands. Do not commit credentials or generated kubeconfigs.

## Bootstrap

```bash
task bootstrap:apps CLUSTER_NAME=talos
```

Inspect available tasks with:

```bash
task --list
```

## Validation

Run the same core checks used by CI:

```bash
bash scripts/kubeconform.sh

for test in scripts/test-*-rendered-manifest.sh; do
  bash "$test"
done

bash scripts/audit-app-template-policy.sh
pre-commit run --all-files
```

`kubeconform.sh` renders Helm-backed Kustomizations before schema validation. Rendered-manifest scripts enforce workload-specific contracts. The app-template policy audit rejects unpinned images; resource and security-context findings remain report-only until reviewed exceptions are recorded.

## Common operations

```bash
# List Argo CD applications
argocd app list

# Reconcile applications
task reconcile

# Inspect cluster health
kubectl get nodes
kubectl get pods --all-namespaces
```

## Adding an application

1. Create `components/<namespace>/<app>/` using the existing neighboring applications as the template.
2. Pin chart and image versions; use an image digest where available.
3. Set CPU and memory requests, a memory limit, and the strongest compatible container security context.
4. Use an `HTTPRoute`, not an Ingress, for inbound traffic.
5. Use an `ExternalSecret` backed by 1Password for credentials.
6. Add the explicit application registration and sync wave to `clusters/talos/apps/`.
7. Add a rendered-manifest contract test when the workload has an operational contract not covered by schema validation.
8. Run the validation commands above.

## GitOps workflow

1. Change declarative configuration in this repository.
2. Render and validate locally.
3. Review the manifest diff, especially for chart upgrades and storage changes.
4. Commit and push the change.
5. Argo CD detects the revision and applies applications according to their sync waves and policies.

Renovate configuration for this GitHub repository is in [`.github/renovate.json5`](.github/renovate.json5). The in-cluster Gitea Renovate deployment is documented in [`docs/runbooks/renovate-gitea.md`](docs/runbooks/renovate-gitea.md).

## Security notes

- Never store plaintext secrets in Git.
- Prefer non-root containers, read-only root filesystems, no privilege escalation, and dropped Linux capabilities.
- Keep intentional privileged or writable-root exceptions explicit and narrowly scoped.
- Review changes to bootstrap ordering, persistent volumes, backup policy, and cluster-wide RBAC carefully.
