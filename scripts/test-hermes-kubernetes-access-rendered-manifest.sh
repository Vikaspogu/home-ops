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

[[ "$(yq ea -r '
  select(.kind == "ConfigMap" and .metadata.name == "hermes-agent-config")
  | .data["config.yaml"]
  | from_yaml
  | [
      ([.plugins.enabled[] | select(. == "kube-read")] | length),
      ([.platform_toolsets.cli[] | select(. == "kube-read")] | length),
      ([.platform_toolsets.telegram[] | select(. == "kube-read")] | length),
      ([.known_plugin_toolsets.cli[] | select(. == "kube-read")] | length),
      ([.known_plugin_toolsets.telegram[] | select(. == "kube-read")] | length)
    ]
  | join(",")
' "${manifest}")" == "1,1,1,1,1" ]] || fail "kube-read plugin and toolset must be enabled exactly once"

[[ "$(yq ea -r '
  select(.kind == "ConfigMap" and .metadata.name == "hermes-agent-config")
  | .data["config.yaml"]
  | from_yaml
  | [.platforms.webhook.enabled,
     .platforms.webhook.extra.host,
     .platforms.webhook.extra.routes."kubernetes-alert".deliver,
     (.platforms.webhook.extra.routes."kubernetes-alert".events | join(",")),
     (.platforms.webhook.extra.routes."kubernetes-alert".toolsets | join(",")),
     (.platform_toolsets.webhook | join(",")),
     (.known_plugin_toolsets.webhook | join(","))]
  | join(",")
' "${manifest}")" == "true,127.0.0.1,telegram,ntfy_alert,kube-read,kube-read,kube-read" ]] || fail "ntfy webhook route must be loopback-only and restricted to kube-read"

[[ "$(yq ea -r '
  select(.kind == "ConfigMap" and .metadata.name == "hermes-agent-config")
  | .data["config.yaml"]
  | from_yaml
  | .platforms.webhook.extra.routes."kubernetes-alert".prompt as $prompt
  | [($prompt | contains("Untrusted content boundary")),
     ($prompt | contains("notification is resolved")),
     ($prompt | contains("malformed")),
     ($prompt | contains("API is unavailable")),
     ($prompt | contains("Never mutate the cluster")),
     ($prompt | contains("Return exactly this compact plain-text format")),
     ($prompt | contains("Evidence: <at most three short facts"))]
  | join(",")
' "${manifest}")" == "true,true,true,true,true,true,true" ]] || fail "autonomous alert prompt is missing a required failure, injection, or format boundary"

[[ "$(yq ea -r '
  select(.kind == "Deployment" and .metadata.name == "hermes-agent")
  | [.spec.template.spec.initContainers[]?
     | select(.name == "ntfy-alert-bridge")
     | (.command | join(" "))]
  | join(",")
' "${manifest}")" == "python /usr/local/bin/hermes-ntfy-alert-bridge" ]] || fail "restricted ntfy alert bridge sidecar is missing"

[[ "$(yq ea -r '
  select(.kind == "Deployment" and .metadata.name == "hermes-agent")
  | [.spec.template.spec.initContainers[0].name,
     (.spec.template.spec.initContainers[0].command | join(" ") | contains("os.makedirs(alert_state"))]
  | join(",")
' "${manifest}")" == "00-restore-permissions,true" ]] || fail "alert cursor subpath must be created before native sidecars start"

[[ "$(yq ea -r '
  select(.kind == "Deployment" and .metadata.name == "hermes-agent")
  | [.spec.template.spec.initContainers[]?
     | select(.name == "ntfy-alert-bridge")
     | .volumeMounts[]?
     | select(.name == "app-data")
     | [.mountPath, .subPath]
     | join(",")]
  | join(",")
' "${manifest}")" == "/var/lib/hermes-alert-intake,alert-intake" ]] || fail "ntfy bridge cursor must persist in its isolated PVC subpath"

[[ "$(yq ea -r '
  select(.kind == "Deployment" and .metadata.name == "hermes-agent")
  | [.spec.template.spec.containers[]
     | select(.name == "app")
     | .env[]
     | select(.name == "WEBHOOK_ENABLED")
     | .value]
  | join(",")
' "${manifest}")" == "true" ]] || fail "Hermes webhook environment enablement is missing"

[[ "$(yq ea -r '
  select(.kind == "Deployment" and .metadata.name == "hermes-agent")
  | [.spec.template.spec.initContainers[]?
     | select(.name == "ntfy-alert-bridge")
     | .env[]
     | select(has("valueFrom"))
     | [.name, .valueFrom.secretKeyRef.name, .valueFrom.secretKeyRef.key]
     | join("/")]
  | sort
  | join(",")
' "${manifest}")" == "NTFY_TOKEN/hermes-alert-intake-secret/NTFY_TOKEN,WEBHOOK_SECRET/hermes-alert-intake-secret/WEBHOOK_SECRET" ]] || fail "ntfy bridge must receive only its two dedicated secrets"

[[ "$(yq ea -r '
  select(.kind == "ExternalSecret" and .metadata.name == "hermes-alert-intake")
  | [.spec.data[]
     | [.secretKey, .remoteRef.key, .remoteRef.property]
     | join("/")]
  | sort
  | join(",")
' "${manifest}")" == "NTFY_TOKEN/ntfy/HERMES_READ_TOKEN,WEBHOOK_SECRET/ntfy/HERMES_ALERT_WEBHOOK_SECRET" ]] || fail "alert intake secrets must be explicit and isolated"

[[ "$(yq ea -r '
  select(.kind == "Deployment" and .metadata.name == "hermes-agent")
  | [.spec.template.spec.containers[]
     | select(.name == "app")
     | .env[]
     | select(.name == "WEBHOOK_SECRET")
     | [.valueFrom.secretKeyRef.name, .valueFrom.secretKeyRef.key]
     | join("/")]
  | join(",")
' "${manifest}")" == "hermes-alert-intake-secret/WEBHOOK_SECRET" ]] || fail "only the Hermes app may verify the isolated alert webhook secret"

[[ "$(yq ea -r '
  select(.kind == "Service" and .metadata.name == "hermes-agent")
  | [.spec.ports[]?.port | select(. == 8644)]
  | length
' "${manifest}")" == "0" ]] || fail "loopback webhook must not be exposed by the Service"

printf 'PASS: Hermes Kubernetes identity, RBAC, projected credential, and autonomous kube-read routes are least privilege\n'
