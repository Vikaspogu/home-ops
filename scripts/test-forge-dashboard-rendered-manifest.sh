#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly GRAFANA_COMPONENT="${ROOT_DIR}/components/observability/grafana"
umask 077
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
  local panel_id="$1"
  local title="$2"
  local service_name="$3"

  PANEL_ID="${panel_id}" PANEL_TITLE="${title}" SERVICE_NAME="${service_name}" yq ea -r '
    [
      select(.kind == "ConfigMap" and .metadata.name == "forge-dashboard")
      | .data["forge.json"]
      | from_json
      | .panels[]?
      | select(
          .id == (strenv(PANEL_ID) | tonumber)
          and .type == "traces"
          and .title == strenv(PANEL_TITLE)
          and .datasource.type == "tempo"
          and .datasource.uid == "tempo"
          and (.targets | length) == 1
          and .targets[0].refId == "A"
          and .targets[0].queryType == "traceql"
          and .targets[0].query == "{resource.service.name=\"" + strenv(SERVICE_NAME) + "\"}"
          and .targets[0].limit == 20
        )
    ]
    | length
  ' "${manifest}"
}

trace_query_panel_count() {
  local service_name="$1"

  SERVICE_NAME="${service_name}" yq ea -r '
    [
      select(.kind == "ConfigMap" and .metadata.name == "forge-dashboard")
      | .data["forge.json"]
      | from_json
      | .panels[]?
      | select(
          .type == "traces"
          and .datasource.type == "tempo"
          and .datasource.uid == "tempo"
          and [
            .targets[]?
            | select(.query == "{resource.service.name=\"" + strenv(SERVICE_NAME) + "\"}")
          ] | length > 0
        )
    ]
    | length
  ' "${manifest}"
}

kustomize build --enable-helm "${GRAFANA_COMPONENT}" >"${manifest}"

[[ "$(resource_count ConfigMap forge-dashboard)" == "1" ]] || fail "rendered Forge dashboard ConfigMap missing or ambiguous"
[[ "$(trace_panel_count 5 "Recent forge task traces" "forge-orchestrator")" == "1" ]] || fail "rendered Forge orchestrator trace panel missing or changed"
[[ "$(trace_query_panel_count "forge-orchestrator")" == "1" ]] || fail "rendered Forge orchestrator trace query missing or duplicated"
[[ "$(trace_panel_count 6 "Recent sandbox agent traces" "forge-sandbox-agent")" == "1" ]] || fail "rendered Forge sandbox-agent trace panel missing or changed"
[[ "$(trace_query_panel_count "forge-sandbox-agent")" == "1" ]] || fail "rendered Forge sandbox-agent trace query missing or duplicated"

printf 'Forge dashboard rendered-manifest contract passed.\n'
