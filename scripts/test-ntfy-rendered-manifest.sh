#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly NTFY_COMPONENT="${ROOT_DIR}/components/default/ntfy"
manifest="$(mktemp)"
trap 'rm -f "${manifest}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

extract_resource() {
    local kind="$1"

    awk -v kind="${kind}" '
        /^---$/ {
            if (index(document, "kind: " kind "\n") && index(document, "\n  name: ntfy\n")) {
                printf "%s", document
            }
            document = ""
            next
        }
        { document = document $0 ORS }
        END {
            if (index(document, "kind: " kind "\n") && index(document, "\n  name: ntfy\n")) {
                printf "%s", document
            }
        }
    ' "${manifest}"
}

extract_ntfy_container() {
    awk '
        function emit_container() {
            if (index(container, "\n        image: binwiederhier/ntfy:")) {
                printf "%s", container
                count++
            }
        }
        $0 == "      containers:" { in_containers = 1; next }
        in_containers && /^      - / {
            emit_container()
            container = $0 ORS
            next
        }
        in_containers { container = container $0 ORS }
        END {
            emit_container()
            exit count != 1
        }
    ' <<<"${deployment}"
}

kustomize build --enable-helm "${NTFY_COMPONENT}" >"${manifest}"

service="$(extract_resource Service)"
deployment="$(extract_resource Deployment)"

[[ -n "${service}" ]] || fail "rendered ntfy Service is missing"
[[ -n "${deployment}" ]] || fail "rendered ntfy Deployment is missing"
ntfy_container="$(extract_ntfy_container)" || fail "rendered ntfy container is missing or ambiguous"
[[ -n "${ntfy_container}" ]] || fail "rendered ntfy container is missing or ambiguous"

awk '
    $1 == "-" && $2 == "name:" && $3 == "NTFY_LISTEN_HTTP" { listener = 1; next }
    $1 == "-" && $2 == "name:" { listener = 0; next }
    listener && $1 == "value:" {
        value = $2
        gsub(/["\047]/, "", value)
        if (value == ":8080") {
            found = 1
        }
        listener = 0
    }
    END { exit !found }
' <<<"${ntfy_container}" || fail "rendered ntfy Deployment must set NTFY_LISTEN_HTTP to :8080"

awk '
    $0 == "  - name: http" { in_http_port = 1; next }
    in_http_port && /^  - / { in_http_port = 0 }
    in_http_port && $1 == "port:" && $2 == "80" { service_port = 1; next }
    in_http_port && $1 == "targetPort:" && $2 == "8080" { target_port = 1 }
    END { exit !(service_port && target_port) }
' <<<"${service}" || fail "rendered ntfy Service must expose port 80 and target port 8080"

awk '
    $0 == "        livenessProbe:" { probe = "liveness"; next }
    $0 == "        readinessProbe:" { probe = "readiness"; next }
    probe != "" && $0 == "          httpGet:" { http_get[probe] = 1; next }
    probe != "" && http_get[probe] && $0 == "            port: 8080" { port[probe] = 1 }
    END { exit !(http_get["liveness"] && port["liveness"] && http_get["readiness"] && port["readiness"]) }
' <<<"${ntfy_container}" || fail "rendered ntfy liveness and readiness HTTP probes must target port 8080"

printf 'PASS: rendered ntfy listener, Service, and probe ports are consistent\n'
