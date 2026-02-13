# Home-Ops Project Guidelines

GitOps-driven Kubernetes home infrastructure managed with ArgoCD.

## Repository Structure

```
clusters/           # Cluster-specific configs (talos, omv)
  talos/apps/       # ArgoCD application manifests (sync-wave ordered)
  talos/bootstrap/  # Cluster bootstrap (OS, Helm, Kustomize)
components/         # Shared Kubernetes components by namespace
  default/          # Application deployments (~45 apps)
  kube-system/      # System components (Cilium, Traefik, etc.)
  network/          # Networking (Gateway API, DNS)
  observability/    # Monitoring stack
  volsync-system/   # Backup replication component
  external-secrets/ # ExternalSecrets operator
scripts/            # Bootstrap and utility scripts
helm/charts/        # Custom Helm charts
```

## Application Component Pattern

Each app in `components/<namespace>/<app>/` follows this structure:

| File | Required | Purpose |
|------|----------|---------|
| `kustomization.yaml` | Yes | Defines Helm chart, resources, VolSync component |
| `values.yaml` | Yes | bjw-s app-template Helm values |
| `http-route.yaml` | Yes | Gateway API HTTPRoute for ingress |
| `externalsecret.yaml` | If secrets needed | 1Password ExternalSecret |

### kustomization.yaml Template

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: default
resources:
  - ./externalsecret.yaml    # only if secrets needed
  - ./http-route.yaml
components:
  - ../../volsync-system/volsync-replication  # only if persistent data
helmCharts:
  - name: app-template
    releaseName: <app-name>
    namespace: default
    repo: oci://ghcr.io/bjw-s-labs/helm
    version: "4.6.2"          # bjw-s app-template version
    valuesFile: values.yaml
```

### values.yaml Pattern (bjw-s app-template)

```yaml
controllers:
  app:
    containers:
      app:
        image:
          repository: <image>
          tag: <version>
        env: {}
        resources:
          requests:
            cpu: 10m
            memory: 250Mi
          limits:
            memory: 500Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: { drop: ["ALL"] }
service:
  app:
    ports:
      http:
        port: 80
persistence:
  config:
    enabled: true
    existingClaim: <app-name>
    globalMounts:
      - path: /data
```

### HTTPRoute Pattern (Gateway API)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: &app <app-name>
  labels:
    app.kubernetes.io/instance: *app
    app.kubernetes.io/name: *app
  annotations:
    gethomepage.dev/href: "https://<app>.${CLUSTER_DOMAIN}"
    gethomepage.dev/enabled: "true"
    gethomepage.dev/group: <group>
    gethomepage.dev/icon: https://cdn.jsdelivr.net/gh/selfhst/icons/png/<icon>.png
spec:
  parentRefs:
    - name: ${GATEWAY_NAME}
      namespace: ${GATEWAY_NAMESPACE}
      sectionName: https
  hostnames: ["<app>.${CLUSTER_DOMAIN}"]
  rules:
    - backendRefs:
        - name: *app
          port: 80
```

### ExternalSecret Pattern (1Password)

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <app-name>
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-connect
  target:
    name: <app-name>-secret
    template:
      engineVersion: v2
      data:
        KEY: "{{ .FIELD }}"
  dataFrom:
    - extract:
        key: <1password-item-name>
```

## Key Technologies

- **Kubernetes**: Talos Linux (primary), K3s on OMV (secondary)
- **GitOps**: ArgoCD with sync-waves for ordering
- **Helm**: bjw-s app-template v4.6.2 for all apps
- **Ingress**: Gateway API with HTTPRoute (not Ingress objects)
- **Secrets**: ExternalSecrets Operator + 1Password Connect
- **Storage**: Rook-Ceph (ceph-block StorageClass), Longhorn (secondary)
- **Backups**: VolSync replication with csi-ceph-blockpool VolumeSnapshotClass
- **CNI**: Cilium
- **DNS/Certs**: cert-manager for TLS
- **Templates**: makejinja with custom delimiters (#{ }#, #% %#)
- **Task Runner**: go-task (Taskfile.yaml)
- **Dependency Updates**: Renovate Bot

## Conventions

- All apps deploy to `default` namespace unless they have a dedicated namespace
- YAML anchor `&app` on metadata.name for DRY label references
- Environment variables like `${CLUSTER_DOMAIN}`, `${GATEWAY_NAME}`, `${GATEWAY_NAMESPACE}` are substituted by ArgoCD plugin
- VolSync plugin env vars: `STORAGE_CLASS=ceph-block`, `VOLUME_SNAPSHOT_CLASS=csi-ceph-blockpool`, `VOLSYNC_CAPACITY=<size>`
- Commit messages use conventional format: `(fix):`, `(feat):`, `(chore):`
- Containers should set `readOnlyRootFilesystem: true` and drop all capabilities when possible
- Always set both resource requests and memory limits
- Use image tags (not `latest`) or SHA digests for reproducibility

## Adding a New Application

1. Create `components/<namespace>/<app-name>/` with the files above
2. Register in `clusters/talos/apps/20-applications.yaml` with sync-wave "20"
3. If persistent data needed, add VolSync component and plugin env vars
4. If secrets needed, create 1Password item and ExternalSecret

## Do Not

- Use Ingress objects (use Gateway API HTTPRoute instead)
- Store secrets in plain text (use ExternalSecrets + 1Password)
- Use `latest` image tags without a SHA digest pin
- Skip resource requests/limits on containers
- Modify cluster bootstrap files without understanding sync-wave ordering
