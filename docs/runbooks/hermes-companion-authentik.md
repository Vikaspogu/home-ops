# Hermes Companion — Authentik (no Authentik changes needed)

Verified live (2026-10-04): the companion is covered by the household's
**domain-level forward-auth provider** already managed in homelab-orchestrator
(`terraform/authentik/applications.tf` → `authentik_provider_proxy.agent_farm_workspaces`,
`mode = "forward_domain"`, `cookie_domain = <cluster domain>`). That provider matches
every host under the cluster domain — including `companion.<cluster-domain>` — so
**no Authentik provider, outpost, or terraform change is required for the companion.**

Empirical check (from inside the cluster):

```
GET ak-outpost-agent-farm:9000/outpost.goauthentik.io/auth/envoy
  Host: companion.<cluster-domain>  X-Original-URL: https://companion.<cluster-domain>/
→ HTTP/1.1 302 Found
  location: https://id.<cluster-domain>/application/o/authorize/...   (login, with
            redirect-back-to-companion already encoded in the state JWT)
  set-cookie: authentik_proxy_*=...; Domain=<cluster-domain>; SameSite=Lax
```

So the login UX works out of the box: an unauthenticated browser is redirected to
Authentik and back, sharing the domain session with every other proxied app.

## The two gates (design §AuthN/Z)

1. **Outer gate** — Envoy Gateway `SecurityPolicy` extAuth on the HTTPRoute
   (`components/ai/hermes-companion/http-route.yaml`): forwards the cookie to
   `ak-outpost-agent-farm:9000` (`/outpost.goauthentik.io/auth/envoy`, the cross-ns
   backendRef is permitted by `components/agent-farm/app/reference-grant.yaml`),
   passes `X-Authentik-Username` to the app, and the route strips client-supplied
   `X-Authentik-*` headers via RequestHeaderModifier. Unauthenticated → 302 login.
2. **Inner gate** — the companion gateway itself validates the session cookie against
   the SAME outpost (`AUTH_OUTPOST_URL` in `values.yaml`), host-pinned, forwarding only
   the `Cookie` header, fail-closed on anything but a 200.

## Verified live (2026-10-04, before the companion deployed)

- Envoy extAuth **302 pass-through works**: hitting the live gateway (envoy-internal,
  `${GATEWAY_NAME}` resolved from the live httproutes) with any host behind the
  SecurityPolicy-extAuth pattern returns the outpost's 302 + Authentik login URL +
  domain session cookie to the client, redirect-back-to-app encoded.
- `https://companion.<domain>/` through envoy-internal already 302s to Authentik
  login today (the unclaimed-host catch-all), i.e. the exact post-deploy behavior.
- `http://companion.<domain>` (port 80) → **301** to the https URL — phones typing
  the domain land on TLS automatically.
- envoy-external 404s these hosts — nothing attaches there; the companion
  NetworkPolicy allows only envoy-internal.

## Verify in Kubernetes (re-check any time)

```bash
# The outpost is up (deployed by Authentik's k8s integration):
kubectl -n agent-farm get svc ak-outpost-agent-farm
kubectl -n agent-farm get pods -l app.kubernetes.io/name=authentik-outpost-proxy

# Unauthenticated → 302 to login (run from any in-cluster pod):
kubectl -n agent-farm run outpost-check --rm -i --restart=Never \
  --image=curlimages/curl:latest --quiet -- \
  curl -s -o /dev/null -w '%{http_code}\n' \
  http://ak-outpost-agent-farm:9000/outpost.goauthentik.io/auth/envoy \
  -H 'Host: companion.a113.casa' -H 'X-Original-URL: https://companion.a113.casa/'
# expect: 302
```

## End-to-end auth checks (after first sync)

```bash
# Unauthenticated browser → Authentik login redirect → back to the PWA shell.

# Forged X-Authentik-* headers must NOT authenticate (RequestHeaderModifier strips;
# the inner gate ignores client-supplied values anyway):
curl -s -o /dev/null -w '%{http_code}\n' "https://companion.${CLUSTER_DOMAIN}/api/history" \
  -H 'X-Authentik-Username: admin'   # expect 302/401, NOT 200

# Smoke credential (scoped: health + shell + one canned chat turn) bypasses neither gate:
curl -s "https://companion.${CLUSTER_DOMAIN}/api/health" \
  -H "X-Smoke-Token: $(kubectl -n ai get secret hermes-companion-secret -o jsonpath='{.data.SMOKE_TOKEN}' | base64 -d)"
```

## If isolation is ever wanted instead

The current setup deliberately REUSES the shared domain-level forward auth (one
session, one outpost, zero new Authentik state). If the companion ever needs its own
session/outpost lifecycle, add a dedicated `authentik_provider_proxy` (mode
`forward_single`, external_host `https://companion.<domain>`), attach it to a new
`authentik_outpost` deploying to the `ai` namespace in homelab-orchestrator terraform,
then update three things here: the SecurityPolicy backendRef (same-ns), `AUTH_OUTPOST_URL`,
and the Cilium egress namespace. Cookie-domain stays the cluster domain.

## Notes

- iOS PWA storage is separate from Safari: expect one extra Authentik login inside the
  installed app (documented in the image README).
- The agent-farm-workspaces provider injects an `X-Agent-Farm-Proxy-Token` header for
  authenticated requests — irrelevant to the companion: the SecurityPolicy's
  `headersToBackend` allowlist passes only `X-Authentik-Username` to the app, and the
  inner gate never trusts client-supplied headers regardless.
