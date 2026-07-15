#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly NTFY_COMPONENT="${ROOT_DIR}/components/default/ntfy"
umask 077
readonly manifest="$(mktemp)"
readonly template="$(mktemp)"
trap 'rm -f -- "${manifest}" "${template}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

resource_count() {
    local kind="$1"

    yq ea -r "[select(.kind == \"${kind}\" and .metadata.name == \"ntfy\")] | length" "${manifest}"
}

ntfy_container_count() {
    yq ea -r '
        [
            select(.kind == "Deployment" and .metadata.name == "ntfy")
            | .spec.template.spec.containers[]?
            | select(.image | test("^binwiederhier/ntfy([:@]|$)"))
        ] | length
    ' "${manifest}"
}

kustomize build --enable-helm "${NTFY_COMPONENT}" >"${manifest}"

service_count="$(resource_count Service)"
deployment_count="$(resource_count Deployment)"
http_route_count="$(resource_count HTTPRoute)"

[[ "${service_count}" == "1" ]] || fail "rendered ntfy Service is missing or ambiguous"
[[ "${deployment_count}" == "1" ]] || fail "rendered ntfy Deployment is missing or ambiguous"
[[ "${http_route_count}" == "1" ]] || fail "rendered ntfy HTTPRoute is missing or ambiguous"
[[ "$(ntfy_container_count)" == "1" ]] || fail "rendered ntfy container is missing or ambiguous"

[[ "$(
    yq ea -r '
        select(.kind == "Deployment" and .metadata.name == "ntfy")
        | .spec.template.spec.containers[]?
        | select(.image | test("^binwiederhier/ntfy([:@]|$)"))
        | .env[]?
        | select(.name == "NTFY_LISTEN_HTTP")
        | .value
    ' "${manifest}"
)" == ":8080" ]] || fail "rendered ntfy Deployment must set NTFY_LISTEN_HTTP to :8080"
[[ "$(
    yq ea -r '
        select(.kind == "Deployment" and .metadata.name == "ntfy")
        | .spec.template.spec.securityContext.runAsNonRoot
    ' "${manifest}"
)" == "true" ]] || fail "rendered ntfy Deployment pod security context must set runAsNonRoot to true"

[[ "$(
    yq ea -r '
        select(.kind == "HTTPRoute" and .metadata.name == "ntfy")
        | .spec.rules[]?.backendRefs[]?
        | [.name, .port]
        | @tsv
    ' "${manifest}"
)" == $'ntfy\t80' ]] || fail "rendered ntfy HTTPRoute backend must target ntfy Service port 80"


[[ "$(
    yq ea -r '
        select(.kind == "Service" and .metadata.name == "ntfy")
        | .spec.ports[]?
        | select(.name == "http")
        | [.port, .targetPort]
        | @tsv
    ' "${manifest}"
)" == $'80\t8080' ]] || fail "rendered ntfy Service must expose port 80 and target port 8080"

[[ "$(
    yq ea -r '
        select(.kind == "Deployment" and .metadata.name == "ntfy")
        | .spec.template.spec.containers[]?
        | select(.image | test("^binwiederhier/ntfy([:@]|$)"))
        | .livenessProbe.httpGet.port
    ' "${manifest}"
)" == "8080" ]] || fail "rendered ntfy liveness HTTP probe must target port 8080"

[[ "$(
    yq ea -r '
        select(.kind == "Deployment" and .metadata.name == "ntfy")
        | .spec.template.spec.containers[]?
        | select(.image | test("^binwiederhier/ntfy([:@]|$)"))
        | .readinessProbe.httpGet.port
    ' "${manifest}"
)" == "8080" ]] || fail "rendered ntfy readiness HTTP probe must target port 8080"

printf 'PASS: rendered ntfy listener, Service, HTTPRoute, pod security context, and probe ports are consistent\n'

ntfy_template="$(yq ea -r '
  select(.kind == "ConfigMap" and .metadata.name == "ntfy-templates")
  | .data["infra-alerts.yml"]
' "${manifest}")"

printf '%s\n' "${ntfy_template}" >"${template}"
yq e '.message' "${template}" >/dev/null || fail "rendered ntfy template must be valid YAML"
[[ "$(yq e -r '.message' "${template}")" != "null" ]] || fail "rendered ntfy template message must not be empty"

[[ "${ntfy_template}" == *"len .alerts"* ]] || fail "rendered ntfy template must report grouped alert count"
[[ "${ntfy_template}" != *"range .alerts"* ]] || fail "rendered ntfy template must not repeat every grouped alert"
[[ "${ntfy_template}" != *".generatorURL"* ]] || fail "rendered ntfy template must not include unbounded generator URLs"
