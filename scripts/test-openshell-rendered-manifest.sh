#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly OPENSHELL_COMPONENT="${ROOT_DIR}/components/ai/openshell"
umask 077
readonly manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

gateway_config_matches() {
  local pattern="$1"

  pattern="${pattern}" yq ea -r '
    select(.kind == "ConfigMap" and .metadata.name == "openshell-config")
    | .data["gateway.toml"]
    | test(strenv(pattern))
  ' "${manifest}"
}

kustomize build --enable-helm "${OPENSHELL_COMPONENT}" >"${manifest}"

[[ "$(gateway_config_matches '(?m)^topology\s*=\s*"combined"$')" == "true" ]] \
  || fail "rendered OpenShell config must use the gateway 0.0.83 topology field"
[[ "$(gateway_config_matches '(?m)^supervisor_topology\s*=')" == "false" ]] \
  || fail "rendered OpenShell config must not use the removed supervisor_topology field"

printf 'PASS: rendered OpenShell gateway config matches the pinned gateway schema\n'
