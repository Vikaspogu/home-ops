# Hermes Companion — OpenAI API key + Realtime model

The companion's voice relay (`components/ai/hermes-companion`) talks to the OpenAI
Realtime API with a **direct OpenAI platform key**. The household's chat-model access
runs through switchyard (NVIDIA iHub), which does NOT expose the Realtime WebSocket
API, and ChatGPT-subscription/Codex-login auth cannot call it either — so this key is
its own credential.

It is NOT the same token as Codex: if Codex inside Hermes uses `codex login`
(ChatGPT OAuth), that credential cannot reach Realtime at all. Even if Codex were
configured with a platform key, keep a **separate project + key** for the companion:
Realtime bills per session-minute, its spend limit must be its own, and rotating one
must never break the other.

## 1. Account + billing

1. **platform.openai.com** → Sign up (separate from the ChatGPT consumer account).
   Name the organization; create a project `hermes-companion`.
2. **Settings → Billing** → add a payment method, load a small prepaid balance ($5
   starts). New accounts get no free trial credits.
3. **Usage limits** → set a **hard monthly limit** (this is the design's cost ceiling;
   the gateway also self-limits: PTT default, idle hangup, 15-min max session, 1
   concurrent session) and a soft email alert at ~50%.

## 2. Create the key

**platform.openai.com/api-keys** → *Create new secret key* → Owned by **Project**
(`hermes-companion`), name `hermes-companion-cluster`. Copy the `sk-proj-...` value
immediately — it is shown exactly once and cannot be recovered, only rotated.

## 3. Request Zero Data Retention (privacy follow-up)

Voice calls egress household audio. Default: customer content lands in
abuse-monitoring logs kept up to **30 days**. Realtime/GPT-Live sessions ARE
ZDR-eligible — with ZDR approved, `store` is forced `false` and content is excluded
from abuse logs.

**Settings → Organization → Data controls** → request Zero Data Retention (or Modified
Abuse Monitoring). Eligibility is org-level; once approved a *Data Retention* tab
appears for org/project configuration. The gateway sets `store: false` regardless.

## 4. Pick the model

The pre-2026 `gpt-realtime` family is deprecated (removed 2027-01-20). Use the GA
family; the current deployment uses **`gpt-realtime-2.1-mini`** (latest generation:
tool use for `ask_hermes`, improved interruption/barge-in, silence handling, cost-
efficient). Confirm available slugs:

```bash
curl https://api.openai.com/v1/models -H "Authorization: Bearer $OPENAI_API_KEY" \
  | jq -r '.data[].id' | grep -E 'realtime|gpt-live'
```

When a **dated snapshot** of 2.1/2.1-mini appears, re-pin `REALTIME_MODEL` to it —
aliases silently move on revisions, dated slugs do not. If mini misrecognizes
household vocabulary or barge-in feels sticky, A/B against `gpt-realtime-2.1` (or
evaluate `gpt-live-1` against the cost ceiling) during the spike below.

## 5. 1Password (what the ExternalSecret reads)

Item **`hermes-companion`** in the vault behind the `onepassword-connect`
ClusterSecretStore — exactly these fields:

| Field | Value |
| --- | --- |
| `OPENAI_API_KEY` | the `sk-proj-...` from step 2 |
| `REALTIME_MODEL` | e.g. `gpt-realtime-2.1-mini` |
| `SMOKE_TOKEN` | `openssl rand -hex 32` |

`SMOKE_TOKEN_EXPIRES` is **not** in the vault — it is hardcoded in
`components/ai/hermes-companion/values.yaml` (GitOps kill-switch: extending the
window is a one-line commit; rotating the token value is a vault edit). Do not store
it in 1Password: explicit env beats `envFrom`, and two sources is drift bait.

## Verify in Kubernetes

```bash
kubectl -n ai get externalsecret hermes-companion
kubectl -n ai get secret hermes-companion-secret -o jsonpath='{.data.REALTIME_MODEL}' | base64 -d; echo
# key presence only — never print the OPENAI_API_KEY value:
kubectl -n ai get secret hermes-companion-secret -o jsonpath='{.data.OPENAI_API_KEY}' | wc -c
```

## Live validation (the 0.7 spike — the voice exit gate)

Runs inside the companion pod (key from env, script from git over stdin, never in the
image):

```bash
cd <agent-platform-custom checkout>
kubectl -n ai exec -i deploy/hermes-companion -c app -- \
  node --input-type=module - < images/hermes-companion/scripts/realtime-spike.mjs
```

Asserts server_vad session, function-call round trip, and `response.cancel`
mid-function-call against the live model. A quick key-level check without the pod:

```bash
curl https://api.openai.com/v1/models -H "Authorization: Bearer $OPENAI_API_KEY" \
  -s -o /dev/null -w '%{http_code}\n'   # expect 200
```
