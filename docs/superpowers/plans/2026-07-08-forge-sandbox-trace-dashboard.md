# Forge Sandbox Trace Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the existing Forge Grafana dashboard show recent sandbox-agent traces separately from Forge orchestrator traces.

**Architecture:** The existing `forge-dashboard` ConfigMap continues to provision one Grafana dashboard. A new Tempo traces panel targets only the sandbox Relay resource identity, while the existing control-plane panel remains unchanged. A shell contract test renders the Grafana Kustomization and inspects the embedded JSON, preventing either identity from being lost or combined.

**Tech Stack:** Kubernetes Kustomize with Helm enabled, Grafana dashboard JSON, Tempo TraceQL, Bash, yq.

## Global Constraints

- Do not modify `components/ai/forge/values.yaml`, sandbox images, OTLP endpoints, Grafana datasources, Helm values, or routing.
- Preserve panel `id: 5`, title `Recent forge task traces`, and its `forge-orchestrator` TraceQL query.
- Add exactly one `forge-sandbox-agent` Tempo traces panel using `{resource.service.name="forge-sandbox-agent"}` and a limit of `20`.
- Render only resource metadata and dashboard JSON in tests; never print rendered ExternalSecret data.
- Keep the approved design specification at `docs/superpowers/specs/2026-07-05-forge-sandbox-nemo-relay-telemetry-design.md` aligned with the delivered contract.

---

### Task 1: Add the sandbox-agent trace panel with a rendered-manifest contract

**Files:**
- Create: `scripts/test-forge-dashboard-rendered-manifest.sh`
- Modify: `components/observability/grafana/dashboards/forge.yaml:115-129`
- Verify: `docs/superpowers/specs/2026-07-05-forge-sandbox-nemo-relay-telemetry-design.md:60,73,91`

**Interfaces:**
- Consumes: the existing `forge-dashboard` ConfigMap provisioned by `components/observability/grafana/kustomization.yaml`.
- Produces: a `Recent sandbox agent traces` Grafana panel backed by the `tempo` datasource and a repeatable renderer contract script.
- Preserves: the existing `Recent forge task traces` panel for `forge-orchestrator`.

- [ ] **Step 1: Write the failing renderer contract**

Create `scripts/test-forge-dashboard-rendered-manifest.sh` with this complete content, then mark it executable:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly GRAFANA_COMPONENT="${ROOT_DIR}/components/observability/grafana"
readonly manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

resource_count() {
  local kind="$1"
  local name="$2"
  yq ea -r "[select(.kind == \"${kind}\" and .metadata.name == \"${name}\")] | length" "${manifest}"
}

trace_panel_count() {
  local title="$1"
  local service_name="$2"
  PANEL_TITLE="${title}" SERVICE_NAME="${service_name}" yq ea -r '
    [
      select(.kind == "ConfigMap" and .metadata.name == "forge-dashboard")
      | .data["forge.json"]
      | from_json
      | .panels[]?
      | select(
          .type == "traces"
          and .title == strenv(PANEL_TITLE)
          and .datasource.type == "tempo"
          and .datasource.uid == "tempo"
          and (
            [
              .targets[]?
              | select(
                  .queryType == "traceql"
                  and .query == "{resource.service.name=\"" + strenv(SERVICE_NAME) + "\"}"
                  and .limit == 20
                )
            ]
            | length == 1
          )
        )
    ]
    | length
  ' "${manifest}"
}

kustomize build --enable-helm "${GRAFANA_COMPONENT}" >"${manifest}"

[[ "$(resource_count ConfigMap forge-dashboard)" == "1" ]] || fail "rendered Forge dashboard ConfigMap is missing or ambiguous"
[[ "$(trace_panel_count "Recent forge task traces" "forge-orchestrator")" == "1" ]] || fail "rendered Forge orchestrator trace panel is missing or changed"
[[ "$(trace_panel_count "Recent sandbox agent traces" "forge-sandbox-agent")" == "1" ]] || fail "rendered Forge sandbox-agent trace panel is missing or changed"

printf 'Forge dashboard rendered-manifest contract passed.\n'
```

Run:

```bash
chmod +x scripts/test-forge-dashboard-rendered-manifest.sh
bash scripts/test-forge-dashboard-rendered-manifest.sh
```

Expected: the command fails with `rendered Forge sandbox-agent trace panel is missing or changed`. The existing dashboard intentionally lacks this panel before implementation.

- [ ] **Step 2: Add the minimum dashboard JSON**

In `components/observability/grafana/dashboards/forge.yaml`, append this object after the existing panel `id: 5`. Add a comma after the existing panel’s closing brace so the JSON array remains valid:

```json
{
  "id": 6,
  "type": "traces",
  "title": "Recent sandbox agent traces",
  "gridPos": { "h": 10, "w": 24, "x": 0, "y": 26 },
  "datasource": { "type": "tempo", "uid": "tempo" },
  "targets": [
    {
      "refId": "A",
      "queryType": "traceql",
      "query": "{resource.service.name=\"forge-sandbox-agent\"}",
      "limit": 20
    }
  ]
}
```

Do not alter panel `id: 5` or any other dashboard panel.

- [ ] **Step 3: Verify the contract passes**

Run:

```bash
bash scripts/test-forge-dashboard-rendered-manifest.sh
```

Expected: exit status `0` and exactly this output:

```text
Forge dashboard rendered-manifest contract passed.
```

- [ ] **Step 4: Confirm the documented contract**

Review `docs/superpowers/specs/2026-07-05-forge-sandbox-nemo-relay-telemetry-design.md` and confirm it still describes the delivered panel name, both service identities, Tempo datasource, exact TraceQL query, and renderer-contract test. Modify it only if the implementation necessarily diverged from the approved specification.

- [ ] **Step 5: Commit the cohesive change**

Stage only the implementation files and the already-updated specification, then commit:

```bash
git add components/observability/grafana/dashboards/forge.yaml scripts/test-forge-dashboard-rendered-manifest.sh docs/superpowers/specs/2026-07-05-forge-sandbox-nemo-relay-telemetry-design.md
git commit -m "feat: expose Forge sandbox traces in Grafana"
```

Expected: one commit containing the dashboard panel, its renderer contract, and the aligned specification. Do not include the pre-existing `components/ai/forge/values.yaml` comment-only change.
