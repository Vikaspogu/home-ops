# Authentik Kubernetes State Backend Design

## Goal

Replace the Authentik OpenTofu configuration's Garage S3 backend with the Kubernetes backend, using the existing home Kubernetes cluster for remote state and locking.

## Scope

This design creates the target namespace through Home Ops GitOps and changes only the Authentik Terraform backend configuration.

It does not repair Garage, provision a separate credential system, change Authentik resources, or modify unrelated Terraform roots.

## Existing Contract

- The Garage bucket is empty, so no remote state needs migration.
- The Garage S3 endpoint currently rejects OpenTofu's signed `accept-encoding` header, but this does not block a fresh backend initialization.
- `home-ops` deploys cluster components from `clusters/talos/apps/20-applications.yaml`; each default component lives at `components/default/<name>/`.
- The selected durable kubeconfig context is `admin@home-kubernetes` in the Talos cluster configuration.
- The Authentik Terraform root does not configure the Kubernetes provider, so it does not create the Kubernetes control plane that will host its state.

## Decision

Add a minimal Home Ops component at `components/default/tofu-state/` containing only a `tofu-state` Namespace. Register it in `clusters/talos/apps/20-applications.yaml` as an Argo CD application that targets the same namespace.

Configure the Authentik root's native `kubernetes` backend with:

- `namespace = "tofu-state"`
- `secret_suffix = "authentik"`

The backend obtains its cluster access from `KUBE_CONFIG_PATH`; no host-specific kubeconfig path, token, certificate, or credential is committed.

OpenTofu stores the default workspace state in the Secret named `tfstate-default-authentik` and serializes concurrent state changes through a Kubernetes Lease.

## Alternatives Rejected

- Dedicated ServiceAccount: local OpenTofu currently uses a cluster-admin kubeconfig. Adding a ServiceAccount without a durable, rotating local authentication mechanism does not constrain that client and adds token lifecycle work.
- A new S3 service: retains the protocol compatibility boundary that failed with Garage.
- PostgreSQL: viable, but introduces a separate database lifecycle when the existing cluster control plane already provides Secret storage and Lease locking.

## Fresh Initialization Guard

Garage contains no state to migrate. The Kubernetes backend starts empty.

Before the first apply:

1. Confirm Argo CD has synchronized the `tofu-state` namespace.
2. Change the backend and run `tofu init -reconfigure`; do not use `-migrate-state`.
3. Run `tofu plan` and reconcile every proposed create against the Authentik server.
4. Import any object that already exists in Authentik; do not apply through an `already exists` error.

## Verification

1. Argo CD reports the `tofu-state` application synchronized and Kubernetes reports the Namespace active.
2. `tofu init -reconfigure` completes with the Kubernetes backend.
3. The expected state Secret exists in `tofu-state`.
4. A second concurrent OpenTofu process cannot acquire the Lease while the first holds it.
5. `tofu plan` reports only intentional creates; existing Authentik objects are imported before the first apply.

## Security and Limits

Terraform state may contain sensitive provider values. Kubernetes Secrets are only base64-encoded and are unencrypted in etcd by default. The cluster must enforce encryption at rest, least-privilege Secret access, and encrypted backups.

The Kubernetes backend stores state in a single Secret, with a 1 MiB maximum size. Monitor state size before it approaches that limit.

## Sources

- Home Ops application registration: `clusters/talos/apps/20-applications.yaml`
- Home Ops component convention: `components/ai/holmesgpt/kustomization.yaml`
- OpenTofu Kubernetes backend: https://opentofu.org/docs/language/settings/backends/kubernetes/
- Kubernetes Secret security: https://kubernetes.io/docs/concepts/configuration/secret/
