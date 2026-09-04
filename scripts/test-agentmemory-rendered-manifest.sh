#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly AGENTMEMORY_COMPONENT="${ROOT_DIR}/components/ai/agentmemory"
umask 077
readonly manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

app_probe() {
  local probe="$1"

  PROBE="${probe}" yq ea -r '
    select(.kind == "Deployment" and .metadata.name == "agentmemory")
    | .spec.template.spec.containers[]?
    | select(.name == "app")
    | .[env(PROBE)]
    | [.tcpSocket.port, has("httpGet")] | @tsv
  ' "${manifest}"
}

kustomize build --enable-helm "${AGENTMEMORY_COMPONENT}" >"${manifest}"

for probe in startupProbe readinessProbe livenessProbe; do
  [[ "$(app_probe "${probe}")" == $'3111\tfalse' ]] || fail "AgentMemory ${probe} must use TCP port 3111"
done

printf 'PASS: AgentMemory app probes use TCP port 3111\n'
