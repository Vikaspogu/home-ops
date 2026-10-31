# Honcho Memory for Hermes

Date: 2026-05-08

## Goal

Deploy self-hosted Honcho in the Talos cluster `ai` namespace and configure Hermes Agent to use Honcho as its external memory provider. Honcho must be internal-only at first: Hermes talks to it through a Kubernetes service, with no public HTTPRoute and no homepage discovery.

## Source Findings

Honcho's Docker deployment is a multi-process service stack, not a single stateless web container. The upstream compose file runs:

- `api`, started through `docker/entrypoint.sh`, which provisions the database before starting FastAPI.
- `deriver`, the background worker started with `python -m src.deriver`.
- Postgres with the `pgvector` extension.
- Redis-compatible cache.

Honcho requires a PostgreSQL connection string using the `postgresql+psycopg://` prefix, a Redis-compatible cache URL if cache is enabled, and an LLM provider. Its defaults use OpenAI transport with `gpt-5.4-mini` for text-generation features and `text-embedding-3-small` for embeddings. Models used by Honcho need tool/function calling.

Hermes already bundles the Honcho memory provider. With `HERMES_HOME=/opt/data`, Hermes checks `/opt/data/honcho.json` first, then `~/.hermes/honcho.json`, then `~/.honcho/config.json`.

References:

- https://github.com/plastic-labs/honcho/blob/main/docker-compose.yml.example
- https://github.com/plastic-labs/honcho/blob/main/.env.template
- https://github.com/plastic-labs/honcho/blob/main/docker/entrypoint.sh
- https://github.com/plastic-labs/honcho/blob/main/database/init.sql
- https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers/
- https://hermes-agent.nousresearch.com/docs/user-guide/features/honcho/

## Validation Results

The existing NVIDIA Inference Hub secret is enough for the first pass.

Validated from the running Hermes pod:

- `openai/openai/gpt-5.5` supports tool calls.
- `openai/openai/gpt-5.4-mini` supports tool calls.
- `azure/openai/text-embedding-3-small` works through the embeddings endpoint and returns 1536 dimensions.

The current CNPG `postgres17` image does not expose the `vector` extension, so Honcho should not use the shared CNPG cluster directly.

The public GHCR package for `ghcr.io/plastic-labs/honcho` currently exposes `latest` and older `v2.*` tags, but no `v3.*` image tag. The implementation should use the public image only with a digest pin. Current inspected digest for `latest` is:

```text
ghcr.io/plastic-labs/honcho:latest@sha256:a8c4a8dcead76ef9b580559469db4f140eae2c51510ee7d7d3a1485576fee554
```

## Architecture

Create two Talos applications:

1. `components/ai/honcho-postgres`
   - Runs `pgvector/pgvector:pg15`, pinned by digest during implementation.
   - Creates database `honcho`.
   - Mounts an init SQL ConfigMap with `CREATE EXTENSION IF NOT EXISTS vector;`.
   - Uses a PVC and VolSync replication for persistent database state.
   - Exposes only a ClusterIP service on port 5432.

2. `components/ai/honcho`
   - Runs two controllers from the same pinned Honcho image:
     - `api`: `sh docker/entrypoint.sh`
     - `deriver`: `/app/.venv/bin/python -m src.deriver`
   - Exposes only a ClusterIP service on port 8000.
   - Does not create an HTTPRoute.
   - Reuses the existing shared Valkey service at `valkey.default.svc.cluster.local:6379`, using database `6`.

Register both in `clusters/talos/apps/20-applications.yaml`:

- `honcho-postgres` at sync wave `19`.
- `honcho` at sync wave `20`.

## Secrets

Create an ExternalSecret for Honcho that extracts:

- Existing `inference-hub` item:
  - `INFERENCE_HUB_CODING_KEY`
  - `INFERENCE_HUB_BASE_URL`
- Existing `hermes` 1Password item:
  - `HONCHO_POSTGRES_PASSWORD`

Rendered Kubernetes secret data should include:

- `POSTGRES_DB=honcho`
- `POSTGRES_USER=honcho`
- `POSTGRES_PASSWORD`, rendered from the 1Password `HONCHO_POSTGRES_PASSWORD` field
- `DB_CONNECTION_URI`, rendered as a `postgresql+psycopg://` URI for `honcho-postgres.ai.svc.cluster.local:5432/honcho`
- `CACHE_ENABLED=true`
- `CACHE_URL=redis://valkey.default.svc.cluster.local:6379/6?suppress=true`
- `AUTH_USE_AUTH=false`
- `INFERENCE_HUB_CODING_KEY`, rendered from the `inference-hub` 1Password item
- `EMBEDDING_MODEL_CONFIG__TRANSPORT=openai`
- `EMBEDDING_MODEL_CONFIG__MODEL=azure/openai/text-embedding-3-small`
- `EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL`, rendered from `INFERENCE_HUB_BASE_URL` with `/v1`
- `EMBEDDING_MODEL_CONFIG__OVERRIDES__API_KEY_ENV=INFERENCE_HUB_CODING_KEY`
- `EMBEDDING_VECTOR_DIMENSIONS=1536`
- `VECTOR_STORE_TYPE=pgvector`
- `VECTOR_STORE_DIMENSIONS=1536`

Text generation modules should use OpenAI transport against NVIDIA Inference Hub:

- `DERIVER_MODEL_CONFIG`
- `SUMMARY_MODEL_CONFIG`
- `DREAM_DEDUCTION_MODEL_CONFIG`
- `DREAM_INDUCTION_MODEL_CONFIG`
- `DIALECTIC_LEVELS__minimal__MODEL_CONFIG`
- `DIALECTIC_LEVELS__low__MODEL_CONFIG`
- `DIALECTIC_LEVELS__medium__MODEL_CONFIG`
- `DIALECTIC_LEVELS__high__MODEL_CONFIG`
- `DIALECTIC_LEVELS__max__MODEL_CONFIG`

Each should set:

- `TRANSPORT=openai`
- `MODEL=openai/openai/gpt-5.4-mini`
- `OVERRIDES__BASE_URL`, rendered from `INFERENCE_HUB_BASE_URL` with `/v1`
- `OVERRIDES__API_KEY_ENV=INFERENCE_HUB_CODING_KEY`

## Hermes Configuration

Update the Hermes seed `config.yaml`:

```yaml
memory:
  memory_enabled: true
  user_profile_enabled: true
  memory_char_limit: 2200
  user_char_limit: 1375
  provider: honcho
```

Seed `/opt/data/honcho.json` on the Hermes PVC if it does not already exist:

```json
{
  "baseUrl": "http://honcho.ai.svc.cluster.local:8000",
  "workspace": "hermes",
  "peerName": "vikas",
  "pinPeerName": true,
  "timeout": 20,
  "hosts": {
    "hermes": {
      "enabled": true,
      "aiPeer": "hermes",
      "recallMode": "hybrid",
      "sessionStrategy": "per-session",
      "contextTokens": 1200,
      "contextCadence": 1,
      "dialecticCadence": 5,
      "dialecticDepth": 1,
      "dialecticReasoningLevel": "low",
      "writeFrequency": "async",
      "observationMode": "directional"
    }
  }
}
```

Because Hermes keeps live config in the PVC, implementation should also update the current live `/opt/data/config.yaml` and `/opt/data/honcho.json` after Honcho is deployed, then restart Hermes.

## Error Handling

- Honcho API readiness should use `/health`.
- API startup runs database provisioning. If Postgres is unavailable, the API pod should fail startup and retry.
- Deriver should start only after the API and database are ready enough for queue work; Kubernetes readiness and restart behavior handles transient dependency failures.
- Hermes Honcho client should use a bounded `timeout` of 20 seconds so memory provider failures do not block normal gateway replies indefinitely.

## Verification Plan

After implementation:

1. Render manifests with the repo's normal kustomize/Argo plugin path.
2. Confirm `honcho-postgres` starts and the `vector` extension exists in database `honcho`.
3. Confirm Honcho API returns `{"status":"ok"}` from `/health`.
4. Confirm Honcho logs show DB provisioning success.
5. Confirm deriver stays running without model or embedding config errors.
6. Restart Hermes and run memory status from the pod.
7. Confirm Hermes shows provider `honcho` and can reach `http://honcho.ai.svc.cluster.local:8000`.

## Out of Scope

- Public `honcho.${CLUSTER_DOMAIN}` routing.
- Honcho auth and JWT setup.
- Honcho Cloud.
- Replacing shared Valkey with a dedicated Redis or Valkey instance.
- Building and publishing a private Honcho image from `v3.0.6`.
