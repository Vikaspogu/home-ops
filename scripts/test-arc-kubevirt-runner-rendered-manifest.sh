#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly TEMPLATE_COMPONENT="${ROOT_DIR}/components/actions-runner-templates/kubevirt-runner"
readonly RUNNER_COMPONENT="${ROOT_DIR}/components/actions-runners/kubevirt-runner"
readonly APPLICATIONS="${ROOT_DIR}/clusters/talos/apps/30-system.yaml"
readonly TEMPLATE_MANIFEST="$(mktemp)"
readonly RUNNER_MANIFEST="$(mktemp)"
trap 'rm -f -- "${TEMPLATE_MANIFEST}" "${RUNNER_MANIFEST}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

kustomize build "${TEMPLATE_COMPONENT}" >"${TEMPLATE_MANIFEST}"
kustomize build --enable-helm "${RUNNER_COMPONENT}" >"${RUNNER_MANIFEST}"

count() {
    yq ea -r "[select(.kind == \"$1\" and .metadata.name == \"$2\")] | length" "$3"
}

[[ "$(count Namespace actions-runner-templates "${TEMPLATE_MANIFEST}")" == "1" ]] || fail "runner template namespace is missing"
[[ "$(count DataVolume ubuntu-runner-base "${TEMPLATE_MANIFEST}")" == "1" ]] || fail "runner base DataVolume is missing"
[[ "$(yq ea -r 'select(.kind == "DataVolume" and .metadata.name == "ubuntu-runner-base") | .spec.storage.storageClassName' "${TEMPLATE_MANIFEST}")" == "ceph-block" ]] || fail "runner base must use ceph-block"
[[ "$(yq ea -r 'select(.kind == "DataVolume" and .metadata.name == "ubuntu-runner-base") | .spec.source.registry.url' "${TEMPLATE_MANIFEST}")" == "docker://quay.io/containerdisks/ubuntu@sha256:b6e57f3b59a34915587f6d8de671c4fe27397807789eeb96b972f3fa2f2107e1" ]] || fail "runner base image must be pinned"
[[ "$(count VirtualMachine ubuntu-runner "${TEMPLATE_MANIFEST}")" == "1" ]] || fail "runner VM template is missing"
[[ "$(yq ea -r 'select(.kind == "VirtualMachine" and .metadata.name == "ubuntu-runner") | .spec.runStrategy' "${TEMPLATE_MANIFEST}")" == "Manual" ]] || fail "runner VM template must remain manual"
[[ "$(yq ea -r 'select(.kind == "VirtualMachine" and .metadata.name == "ubuntu-runner") | .spec.dataVolumeTemplates[0].spec.source.pvc.name' "${TEMPLATE_MANIFEST}")" == "ubuntu-runner-base" ]] || fail "runner VM template must clone the base disk"
[[ "$(yq ea -r 'select(.kind == "VirtualMachine" and .metadata.name == "ubuntu-runner") | .spec.template.spec.volumes[] | select(.name == "cloudinitdisk") | .cloudInitNoCloud.userData' "${TEMPLATE_MANIFEST}" | grep -c 'actions-runner-linux-x64-2.336.0.tar.gz')" == "1" ]] || fail "runner bootstrap must pin the Actions runner release"
[[ "$(yq ea -r 'select(.kind == "VirtualMachine" and .metadata.name == "ubuntu-runner") | .spec.template.spec.volumes[] | select(.name == "cloudinitdisk") | .cloudInitNoCloud.userData' "${TEMPLATE_MANIFEST}" | grep -c 'sha256sum --check')" == "1" ]] || fail "runner bootstrap must verify the Actions runner release"
[[ "$(count Role kubevirt-actions-runner-template-reader "${TEMPLATE_MANIFEST}")" == "1" ]] || fail "runner template reader Role is missing"

[[ "$(count AutoscalingRunnerSet kubevirt "${RUNNER_MANIFEST}")" == "1" ]] || fail "ARC runner scale set is missing"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.minRunners' "${RUNNER_MANIFEST}")" == "0" ]] || fail "runner scale set must have minRunners zero"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.maxRunners' "${RUNNER_MANIFEST}")" == "1" ]] || fail "runner scale set must have maxRunners one"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.githubConfigUrl' "${RUNNER_MANIFEST}")" == "https://github.com/Vikaspogu/home-ops" ]] || fail "runner scale set must target home-ops"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.template.spec.serviceAccountName' "${RUNNER_MANIFEST}")" == "kubevirt-actions-runner" ]] || fail "runner scale set must use the dedicated ServiceAccount"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.template.spec.containers[] | select(.name == "runner") | .image' "${RUNNER_MANIFEST}")" == "docker.io/electrocucaracha/kubevirt-actions-runner@sha256:5c4ecf8e489afbe9a215c2ecaf0fb4342d47dac935b538b9952fceb735a596e1" ]] || fail "runner image must be pinned"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.template.spec.containers[] | select(.name == "runner") | .env[] | select(.name == "KUBEVIRT_VM_TEMPLATE_NAMESPACE") | .value' "${RUNNER_MANIFEST}")" == "actions-runner-templates" ]] || fail "runner must use the dedicated template namespace"

[[ "$(yq ea -r '.applications."arc-runner-template".annotations."argocd.argoproj.io/sync-wave"' "${APPLICATIONS}")" == "34" ]] || fail "runner template ArgoCD application must sync after ARC controller"
[[ "$(yq ea -r '.applications."arc-kubevirt-runner".annotations."argocd.argoproj.io/sync-wave"' "${APPLICATIONS}")" == "35" ]] || fail "runner scale-set ArgoCD application must sync after the template"

printf 'PASS: ARC KubeVirt runner template, scale set, and ArgoCD registration render correctly\n'
