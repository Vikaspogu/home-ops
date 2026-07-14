#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly TREK_COMPONENT="${ROOT_DIR}/components/default/trek"
umask 077
readonly manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

resource_count() {
    local kind="$1"

    yq ea -r "[select(.kind == \"${kind}\" and .metadata.name == \"trek\")] | length" "${manifest}"
}

app_container() {
    yq ea -r '
        select(.kind == "Deployment" and .metadata.name == "trek")
        | .spec.template.spec.containers[]?
        | select(.image == "mauriceboe/trek:3.3.0")
    ' "${manifest}"
}
app_container_count() {
  app_container | yq -r '.image'
}


assert_env() {
    local name="$1"
    local expected="$2"
    local actual

    actual="$(NAME="${name}" yq ea -r '
        select(.kind == "Deployment" and .metadata.name == "trek")
        | .spec.template.spec.containers[]
        | select(.image == "mauriceboe/trek:3.3.0")
        | .env[]
        | select(.name == env(NAME))
        | .value
    ' "${manifest}")"
    [[ "${actual}" == "${expected}" ]] || fail "${name} must be ${expected}"
}

kustomize build --enable-helm "${TREK_COMPONENT}" >"${manifest}"

[[ "$(resource_count Deployment)" == "1" ]] || fail "rendered trek Deployment is missing or ambiguous"
[[ "$(resource_count Service)" == "1" ]] || fail "rendered trek Service is missing or ambiguous"
[[ "$(resource_count HTTPRoute)" == "1" ]] || fail "rendered trek HTTPRoute is missing or ambiguous"
[[ "$(resource_count ExternalSecret)" == "1" ]] || fail "rendered trek ExternalSecret is missing or ambiguous"
[[ "$(app_container_count | wc -l | tr -d ' ')" == "1" ]] || fail "rendered trek container is missing or ambiguous"

assert_env APP_URL 'https://trek.${CLUSTER_DOMAIN}'
assert_env ALLOWED_ORIGINS 'https://trek.${CLUSTER_DOMAIN}'
assert_env TRUST_PROXY '1'
assert_env FORCE_HTTPS 'true'
assert_env OIDC_DISCOVERY_URL 'https://id.${CLUSTER_DOMAIN}/application/o/trek/.well-known/openid-configuration'
assert_env OIDC_ADMIN_CLAIM groups
assert_env OIDC_ADMIN_VALUE trek-admins

[[ "$(app_container | yq -r '.securityContext.runAsUser')" == "0" ]] || fail "TREK must start as UID 0"
[[ "$(app_container | yq -r '.securityContext.allowPrivilegeEscalation')" == "true" ]] || fail "TREK must permit its gosu handoff"
[[ "$(app_container | yq -r '.securityContext.readOnlyRootFilesystem')" == "false" ]] || fail "TREK must retain a writable root filesystem"
[[ "$(app_container | yq -r '.securityContext.capabilities.drop | join(",")')" == "ALL" ]] || fail "TREK must drop all capabilities first"
[[ "$(app_container | yq -r '.securityContext.capabilities.add | sort | join(",")')" == "CHOWN,SETGID,SETUID" ]] || fail "TREK must retain only chown and gosu capabilities"
[[ "$(app_container | yq -r '.livenessProbe.httpGet.path')" == "/api/health" ]] || fail "TREK liveness probe must use /api/health"
[[ "$(app_container | yq -r '.readinessProbe.httpGet.path')" == "/api/health" ]] || fail "TREK readiness probe must use /api/health"
[[ "$(app_container | yq -r '.volumeMounts[] | select(.mountPath == "/app/data") | .subPath')" == "data" ]] || fail "TREK data mount must use data subpath"
[[ "$(app_container | yq -r '.volumeMounts[] | select(.mountPath == "/app/uploads") | .subPath')" == "uploads" ]] || fail "TREK uploads mount must use uploads subpath"
[[ "$(yq ea -r 'select(.kind == "HTTPRoute" and .metadata.name == "trek") | .spec.rules[0].backendRefs[0].port' "${manifest}")" == "3000" ]] || fail "TREK HTTPRoute must target port 3000"

printf 'PASS: rendered TREK deployment, storage, security, OIDC, routing, and probes are consistent\n'
