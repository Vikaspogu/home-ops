#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly FORGE_COMPONENT="${ROOT_DIR}/components/ai/forge"
readonly manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

kustomize build --enable-helm "${FORGE_COMPONENT}" >"${manifest}"

[[ "$(yq ea -r '
  select(.kind == "Deployment" and .metadata.name == "forge-orchestrator")
  | .spec.template.spec.containers[]
  | select(.name == "app")
  | (.env[] | select(.name == "FORGE_HELM_REGISTRY_HOSTS") | .value | split(",")) as $helm_hosts
  | [(.env[] | select(.name == "FORGE_TOOL_ALLOWLIST") | .value | split(",") | contains(["helm"])),
     (.env[] | select(.name == "FORGE_TOOL_MIRROR_HOSTS") | .value | split(",") | contains(["get.helm.sh"])),
     ($helm_hosts | contains(["ghcr.io"])),
     ($helm_hosts | contains(["mirror.gcr.io"])),
     ($helm_hosts | contains(["quay.io"])),
     ($helm_hosts | contains(["registry.k8s.io"])),
     ($helm_hosts | contains(["us-east4-docker.pkg.dev"])),
     ((.env[] | select(.name == "FORGE_HELM_PATH") | .value) == "/opt/mise/installs/helm/4.2.4/linux-amd64/helm")]
  | join(",")
' "${manifest}")" == "true,true,true,true,true,true,true,true" ]] || fail "Forge must scope pinned Helm to declared read-only chart hosts"

printf 'PASS: Forge Helm access is constrained to declared read-only chart hosts\n'
