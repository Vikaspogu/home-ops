# FileBrowser (Quantum) for media — design

Date: 2026-06-14

## Goal

A web UI to browse, search, preview, move, and delete files across the entire
media tree (`/var/mnt/media`), behind authenticated access.

## App

- **Image:** `ghcr.io/gtsteffaniak/filebrowser:v1.3.3-stable` (FileBrowser
  Quantum fork — SQLite indexed search, built-in user/auth management).
- **Why Quantum (vs classic filebrowser):** real-time indexed search across a
  large library, richer media thumbnails, single static binary, `config.yaml`
  driven. v1.3.x already defaults to non-root user `1000:1000`, matching the
  rest of the media stack.
- **Pattern:** standard bjw-s `app-template` v5.0.1, `default` namespace,
  ArgoCD sync-wave 20 — identical to radarr/sonarr/bazarr/jellyfin.

## Identity / permissions

- Runs as `1000:1000`, supplemental group `100` (`users`),
  `fsGroupChangePolicy: OnRootMismatch`. This matches the library ownership
  (`1000:users`) and the already-aligned *arr + download stack, so reads and
  writes (move/delete/rename) work without group-write workarounds.

## Storage

| Volume | Type | Mount | Notes |
|--------|------|-------|-------|
| config | ceph-block PVC `filebrowser`, 5Gi, VolSync-backed | `/home/filebrowser/data` | holds `database.db` + cache `tmp/` (search index can grow for a large library) |
| config-file | configMap `filebrowser-configmap` | `/home/filebrowser/data/config.yaml` (subPath) | declarative source/server config |
| media | hostPath `/var/mnt/media` | `/media` (read-write) | the browsable tree |

## Config (configMap `config.yaml`)

```yaml
server:
  port: 80
  database: /home/filebrowser/data/database.db
  cacheDir: /home/filebrowser/data/tmp
  sources:
    - path: /media
      config:
        defaultEnabled: true
auth:
  adminUsername: admin
```

Secrets (admin password, JWT signing key) come from env via ExternalSecret, not
the configMap:
- `FILEBROWSER_ADMIN_PASSWORD` → `auth.adminPassword`
- `FILEBROWSER_JWT_TOKEN_SECRET` → `auth.key` (stable key so sessions survive
  pod restarts)

## Secrets (1Password / ExternalSecret)

1Password item `filebrowser` with fields:
- `FILEBROWSER_ADMIN_PASSWORD`
- `FILEBROWSER_JWT_TOKEN_SECRET`

ExternalSecret → `filebrowser-secret`, injected via `envFrom`.

## Ingress

HTTPRoute `filebrowser.${CLUSTER_DOMAIN}`, Gateway API, homepage annotations
(group: Media, selfhst `filebrowser` icon).

## Health

httpGet `/health` on port 80 (liveness + readiness).

## Security context

- `allowPrivilegeEscalation: false`, `capabilities: drop [ALL]`.
- NOT `readOnlyRootFilesystem` — writes DB/cache under `/home/filebrowser/data`
  (on the PVC) and needs temp space.

## Out of scope (YAGNI)

- OIDC/LDAP SSO, OnlyOffice integration, multiple sources, sharing config —
  defaults are fine; can be added to `config.yaml` later.
