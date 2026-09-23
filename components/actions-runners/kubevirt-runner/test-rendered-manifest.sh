#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly COMPONENT="${ROOT_DIR}/components/actions-runners/kubevirt-runner"
readonly APPLICATIONS="${ROOT_DIR}/clusters/talos/apps/30-system.yaml"
readonly WORKFLOW="${ROOT_DIR}/.github/workflows/kubeconform.yml"
readonly MANIFEST="$(mktemp)"
trap 'rm -f -- "${MANIFEST}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

kustomize build --enable-helm "${COMPONENT}" >"${MANIFEST}"

count() {
    yq ea -r "[select(.kind == \"$1\" and .metadata.name == \"$2\")] | length" "${MANIFEST}"
}

[[ "$(count DataVolume ubuntu-runner-base)" == "1" ]] || fail "runner base DataVolume is missing"
[[ "$(yq ea -r 'select(.kind == "DataVolume" and .metadata.name == "ubuntu-runner-base") | .metadata.namespace' "${MANIFEST}")" == "actions-runners" ]] || fail "runner base must share the runner namespace"
[[ "$(yq ea -r 'select(.kind == "DataVolume" and .metadata.name == "ubuntu-runner-base") | .spec.storage.storageClassName' "${MANIFEST}")" == "ceph-block" ]] || fail "runner base must use ceph-block"
[[ "$(yq ea -r 'select(.kind == "DataVolume" and .metadata.name == "ubuntu-runner-base") | .spec.source.registry.url' "${MANIFEST}")" == "docker://quay.io/containerdisks/ubuntu@sha256:b6e57f3b59a34915587f6d8de671c4fe27397807789eeb96b972f3fa2f2107e1" ]] || fail "runner base image must be pinned"
[[ "$(count VirtualMachine ubuntu-runner)" == "1" ]] || fail "runner VM template is missing"
[[ "$(yq ea -r 'select(.kind == "VirtualMachine" and .metadata.name == "ubuntu-runner") | .metadata.annotations."argocd.argoproj.io/ignore-healthcheck"' "${MANIFEST}")" == "true" ]] || fail "stopped runner template must not suspend ArgoCD application health"
[[ "$(yq ea -r 'select(.kind == "VirtualMachine" and .metadata.name == "ubuntu-runner") | .spec.runStrategy' "${MANIFEST}")" == "Manual" ]] || fail "runner VM template must remain manual"
[[ "$(yq ea -r 'select(.kind == "VirtualMachine" and .metadata.name == "ubuntu-runner") | .spec.dataVolumeTemplates[0].spec.source.pvc.name' "${MANIFEST}")" == "ubuntu-runner-base" ]] || fail "runner VM template must clone the base disk"
[[ "$(yq ea -r 'select(.kind == "VirtualMachine" and .metadata.name == "ubuntu-runner") | .spec.template.spec.volumes[] | select(.name == "cloudinitdisk") | .cloudInitNoCloud.userData' "${MANIFEST}" | grep -c 'actions-runner-linux-x64-2.336.0.tar.gz')" == "1" ]] || fail "runner bootstrap must pin the Actions runner release"
[[ "$(yq ea -r 'select(.kind == "VirtualMachine" and .metadata.name == "ubuntu-runner") | .spec.template.spec.volumes[] | select(.name == "cloudinitdisk") | .cloudInitNoCloud.userData' "${MANIFEST}" | grep -c 'sha256sum --check')" == "1" ]] || fail "runner bootstrap must verify the Actions runner release"
[[ "$(yq ea -r 'select(.kind == "VirtualMachine" and .metadata.name == "ubuntu-runner") | .spec.template.spec.volumes[] | select(.name == "cloudinitdisk") | .cloudInitNoCloud.userData' "${MANIFEST}" | grep -c 'sudo: ALL=(ALL) NOPASSWD:ALL')" == "1" ]] || fail "runner user must support non-interactive workflow setup"
grep -qF "runs-on: \${{ github.event_name == 'workflow_dispatch' && 'kubevirt' || 'ubuntu-24.04' }}" "${WORKFLOW}" || fail "manual validation must use KubeVirt without moving untrusted PR jobs in-cluster"

[[ "$(count AutoscalingRunnerSet kubevirt)" == "1" ]] || fail "ARC runner scale set is missing"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.minRunners' "${MANIFEST}")" == "0" ]] || fail "runner scale set must have minRunners zero"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.maxRunners' "${MANIFEST}")" == "1" ]] || fail "runner scale set must have maxRunners one"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.githubConfigUrl' "${MANIFEST}")" == "https://github.com/Vikaspogu/home-ops" ]] || fail "runner scale set must target home-ops"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.template.spec.serviceAccountName' "${MANIFEST}")" == "kubevirt-actions-runner" ]] || fail "runner scale set must use the dedicated ServiceAccount"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.template.spec.containers[] | select(.name == "runner") | .image' "${MANIFEST}")" == "docker.io/electrocucaracha/kubevirt-actions-runner@sha256:5c4ecf8e489afbe9a215c2ecaf0fb4342d47dac935b538b9952fceb735a596e1" ]] || fail "runner image must be pinned"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.template.spec.containers[] | select(.name == "runner") | .env[] | select(.name == "KUBEVIRT_VM_TEMPLATE_NAMESPACE") | .value' "${MANIFEST}")" == "actions-runners" ]] || fail "runner must use its own namespace for the VM template"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.template.spec.containers[] | select(.name == "runner") | .env[] | select(.name == "KAR_TELEMETRY_ENABLED") | .value' "${MANIFEST}")" == "true" ]] || fail "runner telemetry must be enabled"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.template.spec.containers[] | select(.name == "runner") | .env[] | select(.name == "KAR_TELEMETRY_EXPORT_TYPE") | .value' "${MANIFEST}")" == "otlp" ]] || fail "runner telemetry must use OTLP"
[[ "$(yq ea -r 'select(.kind == "AutoscalingRunnerSet" and .metadata.name == "kubevirt") | .spec.template.spec.containers[] | select(.name == "runner") | .env[] | select(.name == "KAR_TELEMETRY_OTLP_ENDPOINT") | .value' "${MANIFEST}")" == "http://alloy.observability.svc.cluster.local:4318" ]] || fail "runner telemetry must use the Alloy OTLP endpoint"

[[ "$(yq ea -r '.applications."arc-kubevirt-runner".annotations."argocd.argoproj.io/sync-wave"' "${APPLICATIONS}")" == "34" ]] || fail "runner scale-set ArgoCD application must sync after the controller"
[[ "$(yq ea -r '.applications | has("arc-runner-template")' "${APPLICATIONS}")" == "false" ]] || fail "runner template must not be a separate ArgoCD application"

printf 'PASS: ARC KubeVirt runner template, scale set, and ArgoCD registration render correctly\n'
