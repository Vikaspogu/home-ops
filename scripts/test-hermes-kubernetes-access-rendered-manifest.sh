#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly HERMES_COMPONENT="${ROOT_DIR}/components/ai/hermes-agent"
umask 077
readonly manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

resource_count() {
  local kind="$1"
  local name="$2"
  yq ea -r "[select(.kind == \"${kind}\" and .metadata.name == \"${name}\")] | length" "${manifest}"
}

kustomize build --enable-helm "${HERMES_COMPONENT}" >"${manifest}"

for kind in ServiceAccount ClusterRole ClusterRoleBinding; do
  [[ "$(resource_count "${kind}" hermes-cluster-reader)" == "1" ]] || fail "missing ${kind}/hermes-cluster-reader"
done

[[ "$(yq ea -r '
  select(.kind == "ServiceAccount" and .metadata.name == "hermes-cluster-reader")
  | .automountServiceAccountToken == false
' "${manifest}")" == "true" ]] || fail "ServiceAccount token automount must be disabled"

[[ "$(yq ea -r 'select(.kind == "ClusterRole" and .metadata.name == "hermes-cluster-reader") | [.rules[].verbs[]] | unique | sort | join(",")' "${manifest}")" == "get,list" ]] || fail "ClusterRole verbs must be get and list only"
[[ "$(yq ea -r 'select(.kind == "ClusterRole" and .metadata.name == "hermes-cluster-reader") | [.rules[].apiGroups[]] | unique | sort | join(",")' "${manifest}")" == ",apps,argoproj.io,batch,events.k8s.io,policy" ]] || fail "ClusterRole API groups must remain explicit"
[[ "$(yq ea -r 'select(.kind == "ClusterRole" and .metadata.name == "hermes-cluster-reader") | [.rules[].resources[]] | unique | sort | join(",")' "${manifest}")" == "applications,cronjobs,daemonsets,deployments,events,jobs,namespaces,nodes,persistentvolumeclaims,poddisruptionbudgets,pods,replicasets,services,statefulsets" ]] || fail "ClusterRole resources must remain explicit and non-sensitive"

[[ "$(yq ea -r '
  select(.kind == "ClusterRoleBinding" and .metadata.name == "hermes-cluster-reader")
  | [.roleRef.kind, .roleRef.name, .subjects[0].kind, .subjects[0].name, .subjects[0].namespace, (.subjects | length)]
  | join(",")
' "${manifest}")" == "ClusterRole,hermes-cluster-reader,ServiceAccount,hermes-cluster-reader,ai,1" ]] || fail "ClusterRoleBinding must target only the Hermes reader"

[[ "$(yq ea -r '
  select(.kind == "Deployment" and .metadata.name == "hermes-agent")
  | [.spec.template.spec.serviceAccountName, .spec.template.spec.automountServiceAccountToken]
  | join(",")
' "${manifest}")" == "hermes-cluster-reader,false" ]] || fail "Hermes Pod must use only the non-automounted reader identity"

[[ "$(yq ea -r '
  select(.kind == "Deployment" and .metadata.name == "hermes-agent")
  | .spec.template.spec.volumes[]?
  | select(.name == "kubernetes-api")
  | [.projected.sources[0].serviceAccountToken.path,
     .projected.sources[0].serviceAccountToken.expirationSeconds,
     (.projected.sources[0].serviceAccountToken.audience // ""),
     .projected.sources[1].configMap.name,
     .projected.sources[1].configMap.items[0].path,
     .projected.sources[2].downwardAPI.items[0].fieldRef.fieldPath]
  | join(",")
' "${manifest}")" == "token,3600,,kube-root-ca.crt,ca.crt,metadata.namespace" ]] || fail "projected API credential must use the default audience and one-hour lifetime"

[[ "$(yq ea -r '
  [select(.kind == "Deployment" and .metadata.name == "hermes-agent")
   | .spec.template.spec.containers[]?
   | select(.name == "app")
   | .volumeMounts[]?
   | select(.name == "kubernetes-api" and .mountPath == "/var/run/secrets/kubernetes.io/serviceaccount" and .readOnly == true)]
  | length
' "${manifest}")" == "1" ]] || fail "projected API credential must mount in the Hermes app container"

[[ "$(yq ea -r '
  [select(.kind == "Deployment" and .metadata.name == "hermes-agent")
   | .spec.template.spec.initContainers[]?
   | .volumeMounts[]?
   | select(.name == "kubernetes-api")]
  | length
' "${manifest}")" == "0" ]] || fail "projected API credential must not mount in init containers or sidecars"

printf 'PASS: Hermes Kubernetes identity, RBAC, and projected credential are least privilege\n'
