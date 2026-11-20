#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly COMPONENT_DIR="${ROOT_DIR}/components/ai/sre-agent"
umask 077
readonly manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

kustomize build --enable-helm "${COMPONENT_DIR}" >"${manifest}"

[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "sre-agent" and .metadata.namespace == "sre-agent" and .spec.template.spec.serviceAccountName == "watchtower-read")] | length' "${manifest}")" == "1" ]] \
  || fail "sre-agent Deployment must be in namespace sre-agent and use serviceAccountName watchtower-read"

[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "sre-agent") | .spec.template.spec.containers[] | select(.name == "app") | .volumeMounts[] | select(.name == "write-token" and .mountPath == "/run/watchtower-write" and .readOnly == true)] | length' "${manifest}")" == "1" ]] \
  || fail "sre-agent app container must mount write-token read-only at /run/watchtower-write"

[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "sre-agent") | .spec.template.spec.volumes[] | select(.name == "write-token" and .secret.secretName == "watchtower-act-token" and .secret.defaultMode == 256)] | length' "${manifest}")" == "1" ]] \
  || fail "sre-agent write-token volume must project Secret watchtower-act-token with mode 0400 (256)"

[[ "$(yq ea -r '[select(.kind == "ServiceAccount" and .metadata.name == "watchtower-act" and .metadata.namespace == "sre-agent")] | length' "${manifest}")" == "1" ]] \
  || fail "ServiceAccount watchtower-act must exist in namespace sre-agent"

[[ "$(yq ea -r '[select(.kind == "Secret" and .metadata.name == "watchtower-act-token" and .metadata.namespace == "sre-agent" and .type == "kubernetes.io/service-account-token" and .metadata.annotations."kubernetes.io/service-account.name" == "watchtower-act")] | length' "${manifest}")" == "1" ]] \
  || fail "Secret watchtower-act-token must be a service-account-token for watchtower-act in sre-agent"

[[ "$(yq ea -r '[select((.kind == "ClusterRole" and .metadata.name == "watchtower-act") or (.kind == "ClusterRoleBinding" and (.metadata.name == "watchtower-act" or (.subjects[]?.name == "watchtower-act"))))] | length' "${manifest}")" == "0" ]] \
  || fail "watchtower-act must not have any cluster-wide ClusterRole or ClusterRoleBinding"

[[ "$(yq ea -r '[select(.kind == "Role" and .metadata.name == "watchtower-act-ceph-exec" and .metadata.namespace == "rook-ceph" and (.rules | length) == 3)] | length' "${manifest}")" == "1" ]] \
  || fail "Role watchtower-act-ceph-exec must preserve namespace rook-ceph with 3 rules"

[[ "$(yq ea -r '[select(.kind == "Role" and .metadata.name == "watchtower-act-ceph-exec") | .rules[] | select((.resources | length) == 1 and .resources[0] == "deployments" and (.resourceNames | length) == 1 and .resourceNames[0] == "rook-ceph-tools" and (.verbs | length) == 1 and .verbs[0] == "get")] | length' "${manifest}")" == "1" ]] \
  || fail "Role watchtower-act-ceph-exec must pin deployment lookup to resourceNames [rook-ceph-tools]"

[[ "$(yq ea -r '[select(.kind == "Role" and .metadata.name == "watchtower-act-ceph-exec") | .rules[] | select((.resources | length) == 1 and .resources[0] == "pods/exec" and (.verbs | length) == 1 and .verbs[0] == "create")] | length' "${manifest}")" == "1" ]] \
  || fail "Role watchtower-act-ceph-exec must only grant create on pods/exec"

[[ "$(yq ea -r '[select(.kind == "RoleBinding" and .metadata.name == "watchtower-act-ceph-exec" and .metadata.namespace == "rook-ceph" and (.subjects | length) == 1 and .subjects[0].name == "watchtower-act" and .subjects[0].namespace == "sre-agent")] | length' "${manifest}")" == "1" ]] \
  || fail "RoleBinding watchtower-act-ceph-exec must bind only watchtower-act (sre-agent) in namespace rook-ceph"

[[ "$(yq ea -r '[select(.kind == "Role" and .metadata.name == "watchtower-act-workload" and .metadata.namespace == "observability" and (.rules | length) == 1 and (.rules[0].resources | length) == 1 and .rules[0].resources[0] == "pods" and (.rules[0].verbs | length) == 3 and ([.rules[0].verbs[] | select(. != "get" and . != "list" and . != "delete")] | length) == 0)] | length' "${manifest}")" == "1" ]] \
  || fail "Role watchtower-act-workload must preserve namespace observability and only grant get/list/delete on pods"

printf 'PASS: rendered sre-agent manifests preserve cross-namespace RBAC and read-only write-token Secret mount\n'
