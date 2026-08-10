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
readonly cdi_manifest="${tmpdir}/cdi.yaml"
readonly canary_manifest="${tmpdir}/canary.yaml"
render "${ROOT_DIR}/components/kubevirt/operator" "${operator_manifest}"
render "${ROOT_DIR}/components/kubevirt/cdi-operator" "${cdi_manifest}"
render "${ROOT_DIR}/components/kubevirt/canary" "${canary_manifest}"

[[ "$(yq ea -r 'select(.kind == "KubeVirt") | .spec.workloads.nodePlacement.nodeSelector."kubernetes.io/hostname"' "${operator_manifest}")" == "k8s-5-1u" ]] \
    || fail "KubeVirt workloads must be restricted to k8s-5-1u"
[[ "$(yq ea -r 'select(.kind == "KubeVirt") | .spec.infra.nodePlacement.nodeSelector."node-role.kubernetes.io/control-plane"' "${operator_manifest}")" == "" ]] \
    || fail "KubeVirt control plane must be restricted to control-plane nodes"
[[ "$(yq ea -r 'select(.kind == "VirtualMachine") | .spec.runStrategy' "${canary_manifest}")" == "Manual" ]] \
    || fail "canary VM must be manually started"
[[ "$(yq ea -r 'select(.kind == "VirtualMachine") | .spec.template.spec.domain.devices.interfaces[0].macAddress' "${canary_manifest}")" == "02:00:00:00:05:01" ]] \
    || fail "canary VM MAC address changed"
[[ "$(yq ea -r '[select(.kind == "VirtualMachine") | .spec.template.spec.volumes[]? | select(has("persistentVolumeClaim") or has("dataVolume"))] | length' "${canary_manifest}")" == "0" ]] \
    || fail "canary VM must not use persistent storage"

printf 'PASS: KubeVirt and CDI render, and the VM canary is constrained and ephemeral\n'
