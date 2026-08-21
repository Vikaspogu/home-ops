#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
tmpdir="$(mktemp -d)"
trap 'rm -rf -- "${tmpdir}"' EXIT

render() {
    kustomize build "$1" >"$2"
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

readonly operator_manifest="${tmpdir}/operator.yaml"
render "${ROOT_DIR}/components/kubevirt/operator" "${operator_manifest}"

[[ "$(yq ea -r 'select(.kind == "KubeVirt") | .spec.workloads.nodePlacement.nodeSelector."kubernetes.io/hostname"' "${operator_manifest}")" == "k8s-5-1u" ]] \
    || fail "KubeVirt workloads must be restricted to k8s-5-1u"
[[ "$(yq ea -r 'select(.kind == "KubeVirt") | .spec.infra.nodePlacement.nodeSelector."node-role.kubernetes.io/control-plane"' "${operator_manifest}")" == "" ]] \
    || fail "KubeVirt control plane must be restricted to control-plane nodes"

printf 'PASS: KubeVirt placement constraints render correctly\n'
