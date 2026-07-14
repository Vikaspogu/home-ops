#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly PROMETHEUS_COMPONENT="${ROOT_DIR}/components/observability/kube-prometheus-stack"
readonly COROOT_OPERATOR_COMPONENT="${ROOT_DIR}/components/observability/coroot-operator"
readonly COROOT_COMPONENT="${ROOT_DIR}/components/observability/coroot"
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

coroot_contract_count() {
  yq ea -r '
    [select(
      .apiVersion == "coroot.com/v1" and .kind == "Coroot" and .metadata.name == "coroot" and
      .spec.communityEdition.image.name == "ghcr.io/coroot/coroot:v1.23.3" and
      .spec.externalPrometheus.url == "http://prometheus-prometheus.observability.svc.cluster.local:9090" and
      .spec.externalPrometheus.remoteWriteURL == "http://prometheus-prometheus.observability.svc.cluster.local:9090/api/v1/write" and
      .spec.clickhouse.storage.className == "ceph-block" and .spec.clickhouse.storage.size == "100Gi" and
      .spec.clickhouse.keeper.storage.className == "ceph-block" and .spec.clickhouse.keeper.storage.size == "10Gi" and
      (.spec | has("externalClickhouse") | not) and (.spec.clickhouse | has("s3") | not) and
      .spec.cacheTTL == "30d" and .spec.tracesTTL == "7d" and .spec.logsTTL == "7d" and .spec.profilesTTL == "7d" and
      .spec.resources.requests.cpu == "100m" and .spec.resources.requests.memory == "512Mi" and .spec.resources.limits.memory == "1Gi" and
      .spec.clickhouse.resources.requests.cpu == "500m" and .spec.clickhouse.resources.requests.memory == "1Gi" and .spec.clickhouse.resources.limits.memory == "2Gi" and
      .spec.clickhouse.keeper.resources.requests.cpu == "100m" and .spec.clickhouse.keeper.resources.requests.memory == "256Mi" and .spec.clickhouse.keeper.resources.limits.memory == "512Mi" and
      .spec.clusterAgent.resources.requests.cpu == "50m" and .spec.clusterAgent.resources.requests.memory == "128Mi" and .spec.clusterAgent.resources.limits.memory == "256Mi" and
      .spec.nodeAgent.resources.requests.cpu == "50m" and .spec.nodeAgent.resources.requests.memory == "64Mi" and .spec.nodeAgent.resources.limits.memory == "256Mi"
    )] | length
  ' "${manifest}"
}

coroot_https_route_count() {
  yq ea -r '[select(.apiVersion == "gateway.networking.k8s.io/v1" and .kind == "HTTPRoute" and .metadata.name == "coroot" and ([.spec.parentRefs[] | select(.sectionName == "https")] | length == 1) and ([.spec.rules[]?.backendRefs[]?] | length == 1) and .spec.rules[0].backendRefs[0].name == "coroot-coroot" and .spec.rules[0].backendRefs[0].port == 8080)] | length' "${manifest}"
}

kustomize build --enable-helm "${PROMETHEUS_COMPONENT}" >"${manifest}"

[[ "$(remote_write_receiver_count)" == "1" ]] || fail "rendered Prometheus remote-write receiver missing or ambiguous"

kustomize build --enable-helm "${COROOT_OPERATOR_COMPONENT}" >"${manifest}"

[[ "$(coroot_crd_count)" == "1" ]] || fail "rendered Coroot CRD missing or ambiguous"
[[ "$(operator_deployment_count)" == "1" ]] || fail "rendered Coroot operator Deployment missing or ambiguous"
[[ "$(operator_hardened_container_count)" == "1" ]] || fail "rendered Coroot operator hardening missing or ambiguous"

kustomize build "${COROOT_COMPONENT}" >"${manifest}"

[[ "$(coroot_contract_count)" == "1" ]] || fail "rendered Coroot resource contract missing or ambiguous"
[[ "$(coroot_https_route_count)" == "1" ]] || fail "rendered Coroot HTTPS route missing or ambiguous"

printf 'Coroot rendered-manifest contract passed.\n'
