#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly PROMETHEUS_COMPONENT="${ROOT_DIR}/components/observability/kube-prometheus-stack"
readonly COROOT_OPERATOR_COMPONENT="${ROOT_DIR}/components/observability/coroot-operator"
umask 077
readonly manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

remote_write_receiver_count() {
  yq ea -r '[select(.kind == "Prometheus" and .spec.enableRemoteWriteReceiver == true)] | length' "${manifest}"
}

coroot_crd_count() {
  yq ea -r '[select(.kind == "CustomResourceDefinition" and .metadata.name == "coroots.coroot.com")] | length' "${manifest}"
}

operator_deployment_count() {
  yq ea -r '[select(.kind == "Deployment" and .metadata.name == "coroot-operator")] | length' "${manifest}"
}

operator_hardened_container_count() {
  yq ea -r '[select(.kind == "Deployment" and .metadata.name == "coroot-operator") | .spec.template.spec.containers[] | select(.securityContext.allowPrivilegeEscalation == false and .securityContext.readOnlyRootFilesystem == true and .securityContext.runAsNonRoot == true and (.securityContext.capabilities.drop | contains(["ALL"])))] | length' "${manifest}"
}

kustomize build --enable-helm "${PROMETHEUS_COMPONENT}" >"${manifest}"

[[ "$(remote_write_receiver_count)" == "1" ]] || fail "rendered Prometheus remote-write receiver missing or ambiguous"

kustomize build --enable-helm "${COROOT_OPERATOR_COMPONENT}" >"${manifest}"

[[ "$(coroot_crd_count)" == "1" ]] || fail "rendered Coroot CRD missing or ambiguous"
[[ "$(operator_deployment_count)" == "1" ]] || fail "rendered Coroot operator Deployment missing or ambiguous"
[[ "$(operator_hardened_container_count)" == "1" ]] || fail "rendered Coroot operator hardening missing or ambiguous"

printf 'Coroot rendered-manifest contract passed.\n'
