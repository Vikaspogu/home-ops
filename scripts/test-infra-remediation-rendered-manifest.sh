#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly INFRA_COMPONENT="${ROOT_DIR}/components/ai/infra-remediation"
readonly HERMES_COMPONENT="${ROOT_DIR}/components/ai/hermes-agent"
readonly PROMETHEUS_COMPONENT="${ROOT_DIR}/components/observability/kube-prometheus-stack"
readonly APPS="${ROOT_DIR}/clusters/talos/apps/20-applications.yaml"
umask 077
readonly infra_manifest="$(mktemp)"
readonly hermes_manifest="$(mktemp)"
readonly prometheus_manifest="$(mktemp)"
trap 'rm -f -- "${infra_manifest}" "${hermes_manifest}" "${prometheus_manifest}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

export ARGOCD_APP_NAME=infra-remediation
export ARGOCD_ENV_STORAGE_CLASS=ceph-block
export ARGOCD_ENV_VOLUME_SNAPSHOT_CLASS=csi-ceph-blockpool
export ARGOCD_ENV_VOLSYNC_CAPACITY=1Gi
export ARGOCD_ENV_VOLSYNC_CACHE_CAPACITY=2Gi

kustomize build --enable-helm "${INFRA_COMPONENT}" |
  envsubst '${ARGOCD_APP_NAME} ${ARGOCD_ENV_STORAGE_CLASS} ${ARGOCD_ENV_VOLUME_SNAPSHOT_CLASS} ${ARGOCD_ENV_VOLSYNC_CAPACITY} ${ARGOCD_ENV_VOLSYNC_CACHE_CAPACITY}' \
    >"${infra_manifest}"
kustomize build --enable-helm "${HERMES_COMPONENT}" >"${hermes_manifest}"
kustomize build --enable-helm "${PROMETHEUS_COMPONENT}" >"${prometheus_manifest}"

[[ "$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "infra-remediation" and .spec.replicas == 1 and .spec.strategy.type == "Recreate" and .spec.template.spec.automountServiceAccountToken == false and .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true and ([.spec.template.spec.containers[0].envFrom[] | select(.secretRef.name == "infra-remediation-secret")] | length == 1) and ([.spec.template.spec.containers[0].volumeMounts[] | select(.name == "data" and .mountPath == "/var/lib/infra-remediation")] | length == 1) and ([.spec.template.spec.volumes[] | select(.name == "data" and .persistentVolumeClaim.claimName == "infra-remediation")] | length == 1))] | length' "${infra_manifest}")" == "1" ]] \
  || fail "controller Deployment contract missing or ambiguous"

[[ "$(yq ea -r '[select(.kind == "PersistentVolumeClaim" and .metadata.name == "infra-remediation" and .spec.storageClassName == "ceph-block" and .spec.resources.requests.storage == "1Gi")] | length' "${infra_manifest}")" == "1" ]] \
  || fail "controller PVC does not match its name, class, or capacity contract"

[[ "$(yq ea -r '[select(.kind == "ReplicationDestination" and .metadata.name == "infra-remediation-dst" and .spec.kopia.storageClassName == "ceph-block" and .spec.kopia.volumeSnapshotClassName == "csi-ceph-blockpool" and .spec.kopia.capacity == "1Gi" and .spec.kopia.cacheCapacity == "2Gi")] | length' "${infra_manifest}")" == "1" ]] \
  || fail "controller restore contract is invalid"

[[ "$(yq ea -r '[select(.kind == "NetworkPolicy" and .metadata.name == "infra-remediation" and (.spec.policyTypes | contains(["Ingress", "Egress"])))] | length' "${infra_manifest}")" == "1" ]] \
  || fail "controller NetworkPolicy contract missing or ambiguous"

[[ "$(yq ea -r '[select(.kind == "ExternalSecret" and .metadata.name == "infra-remediation-secret" and (.spec.target.template.data | has("INFRA_REMEDIATION_HERMES_CARD_UPDATE_SECRET")))] | length' "${infra_manifest}")" == "1" ]] \
  || fail "controller card-update secret projection is missing"

[[ "$(yq ea -r '[select(.kind == "ConfigMap" and .metadata.name == "hermes-agent-config") | .data["config.yaml"] | from_yaml | select((.plugins.enabled | contains(["infra-proposal"])) and .platforms.webhook.enabled == true and .platforms.webhook.extra.routes."infra-card".deliver_only == true and .platforms.webhook.extra.routes."infra-card-update".deliver_only == true and (.platforms.webhook.extra.routes."infra-alert".toolsets | contains(["mcp-coroot", "infra-proposal"])) and ([.platforms.webhook.extra.routes[] | select(has("secret") and .secret == null)] | length == 3) and ([.platforms.webhook.extra.routes[] | select(has("secret") and .secret != null)] | length == 0))] | length' "${hermes_manifest}")" == "1" ]] \
  || fail "Hermes remediation routes or plugin missing"

[[ "$(yq ea -r '[select(.kind == "ExternalSecret" and .metadata.name == "hermes-agent" and (.spec.target.template.data | has("WEBHOOK_SECRET")))] | length' "${hermes_manifest}")" == "1" ]] \
  || fail "Hermes global webhook secret projection is missing"

[[ "$(yq ea -r '[select(.kind == "AlertmanagerConfig" and .metadata.name == "alertmanager") | select(([.spec.route.routes[] | select(.receiver == "infra-remediation" and .continue == true)] | length) == 1 and ([.spec.route.routes[] | select(.receiver == "ntfy" and .matchers[0].value == "warning|critical" and .matchers[0].matchType == "=~")] | length) == 1 and ([.spec.receivers[] | select(.name == "infra-remediation" and .webhookConfigs[0].httpConfig.authorization.credentials.key == "REMEDIATION_ALERT_TOKEN")] | length) == 1)] | length' "${prometheus_manifest}")" == "1" ]] \
  || fail "Alertmanager remediation receiver missing or unauthenticated"

[[ "$(yq e -r '.applications."infra-remediation".destination.namespace == "ai" and .applications."infra-remediation".source.path == "components/ai/infra-remediation" and .applications."infra-remediation".annotations."argocd.argoproj.io/sync-wave" == "25"' "${APPS}")" == "true" ]] \
  || fail "infra-remediation ArgoCD registration is invalid"

printf 'PASS: infra-remediation rendered integration contract\n'
