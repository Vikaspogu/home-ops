#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly component="${1:?Usage: bash scripts/test-rollout-recovery.sh filebrowser|renovate|kubechecks}"
umask 077
readonly manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

case "${component}" in
  filebrowser)
    kustomize build --enable-helm "${ROOT_DIR}/components/default/filebrowser" >"${manifest}"
    [[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "filebrowser") | .spec.template.spec.containers[] | select(.name == "app") | .image' "${manifest}")" == "ghcr.io/gtsteffaniak/filebrowser:1.5.8-stable@sha256:68455d4953bad8e984e1bc5d112ed1e9c918a0a04f104c13c9ece50790308894" ]] || fail "Filebrowser must use the pre-v2 image"
    [[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "filebrowser") | .spec.template.spec.volumes[] | select(.name == "config") | .persistentVolumeClaim.claimName' "${manifest}")" == "filebrowser" ]] || fail "Filebrowser must retain its existing PVC"
    [[ "$(yq ea -r 'select(.kind == "ConfigMap" and .metadata.name == "filebrowser-configmap") | .data."config.yaml" | from_yaml | .server.database' "${manifest}")" == "/home/filebrowser/data/database.db" ]] || fail "Filebrowser must retain its legacy database path"
    ;;
  renovate)
    kustomize build --enable-helm "${ROOT_DIR}/components/default/renovate" >"${manifest}"
    [[ "$(yq ea -r 'select(.kind == "CronJob" and .metadata.name == "renovate") | .spec.jobTemplate.spec.template.spec.containers[] | select(.name == "app") | .env[] | select(.name == "NODE_OPTIONS") | .value' "${manifest}")" == "--max-old-space-size=1536" ]] || fail "Renovate must have an explicit 1536 MiB heap limit"
    [[ "$(yq ea -r 'select(.kind == "CronJob" and .metadata.name == "renovate") | .spec.jobTemplate.spec.template.spec.containers[] | select(.name == "app") | .resources.limits.memory' "${manifest}")" == "2Gi" ]] || fail "Renovate must retain its 2 GiB memory limit"
    ;;
  kubechecks)
    kustomize build --enable-helm "${ROOT_DIR}/clusters/talos/apps" >"${manifest}"
    [[ "$(yq ea -r 'select(.kind == "Application" and .metadata.name == "kubechecks") | .spec.source.plugin.name' "${manifest}")" == "setenv-cmp-plugin-v1.0" ]] || fail "Kubechecks must select the substitution plugin"
    kustomize build --enable-helm "${ROOT_DIR}/components/argo-system/kubechecks" | CLUSTER_DOMAIN=example.test envsubst '${CLUSTER_DOMAIN}' >"${manifest}"
    [[ "$(yq ea -r 'select(.kind == "ConfigMap" and .metadata.name == "kubechecks") | .data.KUBECHECKS_ARGOCD_API_SERVER_ADDR' "${manifest}")" == "argo.example.test:443" ]] || fail "Kubechecks Argo address must substitute the domain"
    [[ "$(yq ea -r 'select(.kind == "ConfigMap" and .metadata.name == "kubechecks") | .data.KUBECHECKS_WEBHOOK_URL_BASE' "${manifest}")" == "https://kubechecks.example.test" ]] || fail "Kubechecks webhook URL must substitute the domain"
    [[ "$(yq ea -r 'select(.kind == "HTTPRoute" and .metadata.name == "kubechecks") | .spec.hostnames[0]' "${manifest}")" == "kubechecks.example.test" ]] || fail "Kubechecks route must substitute the domain"
    [[ "$(yq ea -r 'select(.kind == "ExternalSecret" and .metadata.name == "kubechecks") | .spec.target.template.data.KUBECHECKS_VCS_TOKEN' "${manifest}")" == "{{ .K8S_TOKEN }}" ]] || fail "Kubechecks secret template must remain intact"
    ;;
  *) fail "unknown component: ${component}" ;;
esac

printf 'PASS: %s recovery manifest\n' "${component}"
