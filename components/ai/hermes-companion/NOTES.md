# hermes-companion — deploy prerequisites + checklist

Phase 1 of the companion plan (design + implementation plan live in
agent-platform-custom `docs/superpowers/specs/2026-10-03-hermes-companion-*.md`).
Everything below must exist before ArgoCD sync can go green.

## 1Password items (before first sync)

Create item **`hermes-companion`** (referenced by `externalsecret.yaml`):

| Field | Notes |
| --- | --- |
| `OPENAI_API_KEY` | Direct OpenAI key — NOT the switchyard proxy (it does not expose Realtime WS). Request **Zero Data Retention** for the org (preflight §0.5: `/v1/realtime` is ZDR-eligible; default is 30-day abuse-monitoring retention). |
| `REALTIME_MODEL` | A **dated snapshot** of the GA Realtime family — `gpt-realtime-2.1-mini-<date>` (cheap) or `gpt-realtime-2.1-<date>`; confirm exact snapshot slugs with `curl https://api.openai.com/v1/models -H "Authorization: Bearer $OPENAI_API_KEY" | jq -r '.data[].id' | grep realtime`. Never a floating alias, never the pre-2026 `gpt-realtime` (deprecated, shuts down 2027-01-20). |
| `SMOKE_TOKEN` | Long random string. Scoped by the gateway to `/api/health`, the static shell, and ONE canned chat turn. Rotation = edit this item. |
| ~~`SMOKE_TOKEN_EXPIRES`~~ | Lives in `values.yaml` env, hardcoded in Git (kill-switch = one-line commit; deploy extends instantly). Do NOT also store it in 1Password — the explicit env wins, and two sources is drift bait. |

`HERMES_API_SERVER_KEY` is reused from the existing `hermes` item.

## Authentik — NO ACTION NEEDED

The household's domain-level forward-auth provider (homelab-orchestrator terraform,
`agent_farm_workspaces`, mode=forward_domain, cookie_domain=cluster domain) already
covers `companion.${CLUSTER_DOMAIN}` — verified live: unauthenticated requests 302 to
the Authentik login with redirect-back encoded, domain session cookie included.
See `docs/runbooks/hermes-companion-authentik.md` for the two-gate explanation and
verification steps. The only git-side prerequisite is the ReferenceGrant
(`components/agent-farm/app/reference-grant.yaml`) permitting the companion's
SecurityPolicy to reference the agent-farm outpost Service.

## Hermes-agent amendments (same PR)

The upstream api_server platform binds **localhost only** by default — verified live
(preflight). Two one-line changes ship with this component:

1. `components/ai/hermes-agent/configmap.yaml` — `platforms.api_server.extra.host: "0.0.0.0"`
   (documented upstream knob, `listen_address()`; no patch).
2. `components/ai/hermes-agent/values.yaml` — service port `api: 8642`.

## ArgoCD registration

`clusters/talos/apps/20-applications.yaml` gains a `hermes-companion` entry
(sync-wave 24, namespace `ai`, `STORAGE_CLASS=ceph-block` for the PVC).

## Post-deploy checklist (plan task 1.9)

### 0. Realtime live spike FIRST (plan task 0.7 — the voice exit gate)

Runs INSIDE the companion pod (key from env, script from git over stdin, never in the image):

```bash
cd <agent-platform-custom checkout>
kubectl -n ai exec -i deploy/hermes-companion -c app -- \
  node --input-type=module - < images/hermes-companion/scripts/realtime-spike.mjs
```

Asserts against the live model: server_vad session accepted, function-call round trip,
response.cancel mid-function-call. Record the model + date in the preflight doc
(agent-platform-custom) when it passes. The voice relay must not be considered
deployable until this is green.

```bash
# 1. TTFC + inter-chunk-gap + canned chat turn through the LIVE route (same assertion
#    the image smoke runs — a mock upstream cannot catch ingress buffering):
node scripts/hermes-companion-smoke-test.mjs  # with base overridden to https://companion.<domain> + SMOKE_TOKEN set

# 2. Forged X-Authentik-* rejection against the live route:
curl -s -o /dev/null -w '%{http_code}\n' https://companion.<domain>/api/history \
  -H 'X-Authentik-Username: admin'   # must NOT authenticate (outer gate extAuth + inner gate)

# 3. Real phone: install PWA, login, streaming chat, PTT voice turn, approval from
#    the card (chat- and voice-initiated), screen-lock-mid-reply resync.
```

Gateway timeouts: the cluster-global Envoy `BackendTrafficPolicy` already sets
`http.requestTimeout: 0s` (SSE-safe) and `tcpKeepalive` — the WS 20s ping stays well
inside any idle budget. Watch the first sync for the compression caveat in preflight
§0.4: gateway-wide response compression is ON; if the post-deploy TTFC assertion fails,
exclude `text/event-stream` from compression on this route.
