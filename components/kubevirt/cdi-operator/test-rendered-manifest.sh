#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly COMPONENT="${ROOT_DIR}/components/kubevirt/cdi-operator"
readonly manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

kustomize build "${COMPONENT}" >"${manifest}"

[[ "$(yq ea -r '[select(.kind == "CustomResourceDefinition" and .metadata.name == "cdis.cdi.kubevirt.io") | .spec.versions[]] | length' "${manifest}")" == "1" ]] \
  || fail "CDI CRD must render only the operator-managed v1beta1 version"
[[ "$(yq ea -r 'select(.kind == "CustomResourceDefinition" and .metadata.name == "cdis.cdi.kubevirt.io") | .spec.versions[0] | [.name, .served, .storage] | join(",")' "${manifest}")" == "v1beta1,true,true" ]] \
  || fail "CDI CRD v1beta1 must remain served and stored"

printf 'PASS: rendered CDI CRD matches the operator-managed version set\n'
