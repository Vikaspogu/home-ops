# TREK deployment design

## Goal

Deploy TREK v3.3.0 as a protected, backed-up `default` namespace application at `https://trek.${CLUSTER_DOMAIN}`, with Authentik OIDC sign-in and its built-in MCP endpoint enabled after deployment.

## Scope

- Create a standard application component and Argo CD registration.
- Persist TREK's SQLite database and uploaded files through the existing VolSync component.
- Configure Authentik OIDC while retaining one local TREK administrator for recovery.
- Make the MCP service available at TREK's built-in `/mcp` endpoint.

Not in scope:

- Modifying Authentik itself through GitOps. This repository has no Authentik blueprint/provider-management convention.
- Deploying an MCP proxy, OAuth gateway, or a second external route.
- SSO-only login. `OIDC_ONLY` remains unset to prevent an IdP failure from locking operators out of TREK's Admin Panel.

## Selected deployment

Use the existing bjw-s `app-template` convention rather than TREK's upstream Helm chart.

TREK requires separate writable paths at `/app/data` and `/app/uploads`; both contain durable state. The component will use a single Ceph-backed PVC supplied by `volsync-replication`, with an init container creating `data/` and `uploads/` at the PVC root. The main container mounts those paths with `subPath`. One replicated claim therefore protects both state categories without adding a second VolSync implementation.

The controller will run one replica with `Recreate`, which is appropriate for TREK's SQLite database on a ReadWriteOnce volume. It will use `mauriceboe/trek:3.3.0`, expose port 3000, and probe `/api/health`. TREK's entrypoint starts as root to `chown` both mounted paths, then drops to `node` (UID 1000). The container must therefore retain that image-required exception: `runAsNonRoot: false`, `allowPrivilegeEscalation: true`, a writable root filesystem, and only the `CHOWN`, `SETUID`, and `SETGID` capabilities after dropping all others. It will mount an `emptyDir` at `/tmp`.

## Component contract

`components/default/trek/` will contain:

- `kustomization.yaml`: app-template v5.0.1, ExternalSecret, HTTPRoute, and VolSync component.
- `values.yaml`: TREK image, controller and storage mounts, health checks, resource limits, container security, and non-secret runtime configuration.
- `externalsecret.yaml`: materializes `trek-secret` from 1Password.
- `http-route.yaml`: routes `trek.${CLUSTER_DOMAIN}` to service port 3000 and exposes the homepage metadata.

`clusters/talos/apps/20-applications.yaml` will register `trek` at sync wave 20 with `ceph-block`, `csi-ceph-blockpool`, a 5 Gi VolSync primary claim, and the standard cache capacity.

The single HTTPRoute covers HTTP, TREK's `/ws` realtime connection, and `/mcp`; Envoy Gateway routes WebSocket upgrades through the regular backend route. No dedicated route is required.

## Runtime configuration

Non-secret environment values:

- `APP_URL=https://trek.${CLUSTER_DOMAIN}`
- `ALLOWED_ORIGINS=https://trek.${CLUSTER_DOMAIN}`
- `TRUST_PROXY=1`
- `FORCE_HTTPS=true`
- `OIDC_ISSUER=https://id.${CLUSTER_DOMAIN}/application/o/trek/`
- `OIDC_DISCOVERY_URL=https://id.${CLUSTER_DOMAIN}/application/o/trek/.well-known/openid-configuration`
- `OIDC_DISPLAY_NAME=Authentik`
- `OIDC_SCOPE=openid email profile groups`
- `OIDC_ADMIN_CLAIM=groups`
- `OIDC_ADMIN_VALUE=trek-admins`

The 1Password item named `trek` must provide `ENCRYPTION_KEY`, `ADMIN_EMAIL`, `ADMIN_PASSWORD`, `OIDC_CLIENT_ID`, and `OIDC_CLIENT_SECRET`. The bootstrap local administrator exists for recovery; the credentials are never placed in Git.

## Authentik setup

Create an Authentik OAuth2/OpenID provider and application for TREK. Configure:

- Redirect URI: `https://trek.${CLUSTER_DOMAIN}/api/auth/oidc/callback`
- Client ID and generated client secret: the `trek` 1Password item
- Scopes: `openid`, `email`, `profile`, and `groups`
- A dedicated `trek-admins` group emitted in the `groups` claim

The configured group, rather than first login, establishes TREK administrators. Local login stays available if the OIDC provider, callback, or forwarded HTTPS configuration is wrong.

## MCP setup

After both local and Authentik login work, a TREK administrator enables the MCP addon in the Admin Panel. This exposes `https://trek.${CLUSTER_DOMAIN}/mcp`.

TREK, not Authentik, is the MCP OAuth 2.1 authorization server. An MCP client uses dynamic client registration and TREK's consent screen. The browser authentication step uses the authenticated TREK session, which may have been established through Authentik. Static MCP API tokens are excluded because TREK documents them as deprecated.

## Verification

1. Add a focused rendered-manifest test following `scripts/test-ntfy-rendered-manifest.sh`. It must assert the TREK Deployment, Service, HTTPRoute, image, health endpoints, root-entrypoint compatibility (UID 0, writable root filesystem, and exactly the three required capabilities), proxy/CORS environment values, OIDC configuration references, and PVC subpath mounts.
2. Render the component with `kustomize build --enable-helm` and run that test.
3. After Argo CD sync, confirm `/api/health` through the public hostname and verify `/ws` realtime updates from two browser sessions.
4. Verify Authentik redirects to the callback, a member can sign in, and the `trek-admins` group creates a TREK administrator while local recovery login still works.
5. Enable MCP from the TREK Admin Panel and connect an OAuth 2.1 MCP client to `/mcp`; verify its consent flow and least-privilege scope behavior.

## Sources

- TREK README: https://github.com/mauriceboe/TREK
- TREK MCP guide: https://github.com/mauriceboe/TREK/blob/main/MCP.md
- TREK v3.3.0 OIDC callback implementation: https://github.com/mauriceboe/TREK/blob/v3.3.0/server/src/nest/oidc/oidc.controller.ts
- TREK v3.3.0 container startup contract: https://github.com/mauriceboe/TREK/blob/v3.3.0/Dockerfile
- Local Authentik client example: `components/default/paperless-ngx/externalsecret.yaml`
- Local VolSync PVC contract: `components/volsync-system/volsync-replication/pvc.yaml`
- Local rendered-manifest test convention: `scripts/test-ntfy-rendered-manifest.sh`
