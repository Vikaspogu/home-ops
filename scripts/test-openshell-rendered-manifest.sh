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
  || fail "rendered OpenShell config must use combined topology"
[[ "$(gateway_config_matches '(?m)^policy_validation_failure_mode\s*=\s*"fail_closed"$')" == "true" ]] \
  || fail "rendered OpenShell config must fail closed on invalid policies"
[[ "$(gateway_config_matches '(?m)^workspace_mode\s*=\s*"shared"$')" == "true" ]] \
  || fail "rendered OpenShell config must use shared Kubernetes workspaces"
[[ "$(gateway_config_matches '(?m)^supervisor_topology\s*=')" == "false" ]] \
  || fail "rendered OpenShell config must not use the removed supervisor_topology field"

[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "openshell" and .metadata.labels."app.kubernetes.io/version" == "0.0.111")] | length' "${manifest}")" == "1" ]] \
  || fail "rendered OpenShell Deployment must use chart 0.0.111"
[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "openshell") | .spec.template.spec.containers[] | select(.name == "openshell-gateway") | .env[] | select(.name == "OPENSHELL_GATEWAY_CREDENTIAL_KEY_ENCRYPTION_KEY" and .valueFrom.secretKeyRef.name == "openshell-db-secret" and .valueFrom.secretKeyRef.key == "key-encryption-key")] | length' "${manifest}")" == "1" ]] \
  || fail "OpenShell must read its credential-encryption key from openshell-db-secret"
[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "openshell") | .spec.template.spec.containers[] | select(.name == "openshell-gateway") | .env[] | select(.name == "OPENSHELL_TELEMETRY_ENABLED" and .value == "false")] | length' "${manifest}")" == "1" ]] \
  || fail "OpenShell anonymous telemetry must be disabled"
[[ "$(yq ea -r '[select(.kind == "Secret" and .metadata.name == "openshell-credential-storage-key-encryption-key")] | length' "${manifest}")" == "0" ]] \
  || fail "OpenShell must not render a nondeterministic credential-encryption Secret"
[[ "$(yq ea -r 'select(.kind == "ExternalSecret" and .metadata.name == "openshell-db") | .spec.target.template.data."key-encryption-key"' "${manifest}")" == "{{ .OPENSHELL_CREDENTIAL_KEY_ENCRYPTION_KEY }}" ]] \
  || fail "OpenShell ExternalSecret must project the credential-encryption key"

printf 'PASS: rendered OpenShell 0.0.111 config and stable credential storage are consistent\n'
