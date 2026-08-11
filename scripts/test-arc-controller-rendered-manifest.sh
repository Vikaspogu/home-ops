#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly COMPONENT="${ROOT_DIR}/components/actions-runner-system/arc-controller"
readonly APPLICATIONS="${ROOT_DIR}/clusters/talos/apps/30-system.yaml"
readonly MANIFEST="$(mktemp)"
trap 'rm -f -- "${MANIFEST}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[[ -d "${COMPONENT}" ]] || fail "ARC controller component is missing"
kustomize build --enable-helm "${COMPONENT}" >"${MANIFEST}"

count() {
    yq ea -r "[select(.kind == \"$1\" and .metadata.name == \"$2\")] | length" "${MANIFEST}"
}

[[ "$(count Deployment arc-controller-gha-rs-controller)" == "1" ]] || fail "ARC controller Deployment is missing"
[[ "$(count ExternalSecret github-arc)" == "1" ]] || fail "GitHub App ExternalSecret is missing"
[[ "$(yq ea -r 'select(.kind == "ExternalSecret" and .metadata.name == "github-arc") | .metadata.namespace' "${MANIFEST}")" == "actions-runners" ]] || fail "GitHub App ExternalSecret must be in actions-runners"
[[ "$(yq ea -r 'select(.kind == "ExternalSecret" and .metadata.name == "github-arc") | .spec.target.name' "${MANIFEST}")" == "github-arc-secret" ]] || fail "ARC ExternalSecret target must be github-arc-secret"
[[ "$(yq ea -r 'select(.kind == "ExternalSecret" and .metadata.name == "github-arc") | .spec.target.template.data | keys | join(",")' "${MANIFEST}")" == "github_token" ]] || fail "ARC ExternalSecret must render only github_token"
[[ "$(yq ea -r 'select(.kind == "ExternalSecret" and .metadata.name == "github-arc") | .spec.target.template.data.github_token' "${MANIFEST}")" == "{{ .GITHUB_ARC_TOKEN }}" ]] || fail "ARC ExternalSecret must map GITHUB_ARC_TOKEN"
[[ "$(yq ea -r 'select(.kind == "ExternalSecret" and .metadata.name == "github-arc") | .spec.dataFrom[0].extract.key' "${MANIFEST}")" == "Github" ]] || fail "ARC ExternalSecret must use the Github 1Password item"
[[ "$(count ServiceAccount kubevirt-actions-runner)" == "1" ]] || fail "runner ServiceAccount is missing"
[[ "$(count Role kubevirt-actions-runner)" == "1" ]] || fail "runner Role is missing"
[[ "$(count RoleBinding kubevirt-actions-runner)" == "1" ]] || fail "runner RoleBinding is missing"
[[ "$(yq ea -r 'select(.kind == "Role" and .metadata.name == "kubevirt-actions-runner") | .rules[] | select(.apiGroups[] == "kubevirt.io" and .resources[] == "virtualmachineinstances") | .verbs | sort | join(",")' "${MANIFEST}")" == "create,delete,get,list,watch" ]] || fail "runner Role must manage VMIs"
[[ "$(yq ea -r 'select(.kind == "Role" and .metadata.name == "kubevirt-actions-runner") | .rules[] | select(.apiGroups[] == "cdi.kubevirt.io" and .resources[] == "datavolumes") | .verbs | sort | join(",")' "${MANIFEST}")" == "create,delete,get,list,watch" ]] || fail "runner Role must manage DataVolumes"
[[ "$(yq ea -r 'select(.kind == "ClusterRole" and .metadata.name == "kubevirt-actions-runner-cdi-cloner") | .rules[] | select(.apiGroups[] == "cdi.kubevirt.io" and .resources[] == "datavolumes/source") | .verbs | join(",")' "${MANIFEST}")" == "create" ]] || fail "CDI clone-source permission is missing"
[[ "$(yq ea -r '.applications."arc-controller".source.path' "${APPLICATIONS}")" == "components/actions-runner-system/arc-controller" ]] || fail "ARC controller ArgoCD application is missing"
[[ "$(yq ea -r '.applications."arc-controller".destination.namespace' "${APPLICATIONS}")" == "actions-runner-system" ]] || fail "ARC controller must target actions-runner-system"
[[ "$(yq ea -r '.applications."arc-controller".annotations."argocd.argoproj.io/sync-wave"' "${APPLICATIONS}")" == "33" ]] || fail "ARC controller must sync after the KubeVirt canary"
[[ "$(yq ea -r '.applications."arc-controller".syncPolicy.syncOptions[]' "${APPLICATIONS}")" == "CreateNamespace=true" ]] || fail "ARC controller must create its namespace"

printf 'PASS: ARC controller, GitHub App secret projection, runner RBAC, and ArgoCD registration render correctly\n'
