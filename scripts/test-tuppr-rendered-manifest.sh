#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly NAMESPACE_COMPONENT="${ROOT_DIR}/components/system-upgrade/namespace"
readonly TUPPR_COMPONENT="${ROOT_DIR}/components/system-upgrade/tuppr"
readonly UPGRADE_COMPONENT="${ROOT_DIR}/components/system-upgrade/talos-upgrade"
readonly APPLICATIONS_FILE="${ROOT_DIR}/clusters/talos/apps/30-system.yaml"
readonly manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

kustomize build "${NAMESPACE_COMPONENT}" >"${manifest}"
[[ "$(yq ea -r '[select(.kind == "Namespace" and .metadata.name == "system-upgrade")] | length' "${manifest}")" == "1" ]] || fail "system-upgrade Namespace missing or ambiguous"

kustomize build --enable-helm "${TUPPR_COMPONENT}" >"${manifest}"
[[ "$(yq ea -r '[select(.kind == "CustomResourceDefinition" and .metadata.name == "talosupgrades.tuppr.home-operations.com")] | length' "${manifest}")" == "1" ]] || fail "TalosUpgrade CRD missing or ambiguous"
[[ "$(yq ea -r '[select(.apiVersion == "talos.dev/v1alpha1" and .kind == "ServiceAccount" and .metadata.name == "tuppr-talosconfig")] | length' "${manifest}")" == "1" ]] || fail "Tuppr Talos ServiceAccount missing or ambiguous"
[[ "$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "tuppr") | .spec.template.spec.volumes[]?.secret.secretName | select(. == "tuppr-talosconfig")' "${manifest}")" == "tuppr-talosconfig" ]] || fail "Tuppr must mount its generated talosconfig"

kustomize build "${UPGRADE_COMPONENT}" >"${manifest}"
[[ "$(yq ea -r 'select(.kind == "TalosUpgrade" and .metadata.name == "cluster") | .metadata.annotations."tuppr.home-operations.com/suspend"' "${manifest}")" == "true" ]] || fail "TalosUpgrade must remain suspended"
[[ "$(yq ea -r 'select(.kind == "TalosUpgrade" and .metadata.name == "cluster") | .spec.parallelism' "${manifest}")" == "1" ]] || fail "TalosUpgrade must be sequential"
[[ "$(yq ea -r 'select(.kind == "TalosUpgrade" and .metadata.name == "cluster") | .spec.maintenance.windows[0] | [.start, .duration, .timezone] | join(",")' "${manifest}")" == "0 2 * * 0,4h,UTC" ]] || fail "TalosUpgrade maintenance window must be Sunday 02:00-06:00 UTC"
[[ "$(yq ea -r 'select(.kind == "TalosUpgrade" and .metadata.name == "cluster") | .spec.talos.version' "${manifest}")" == "v1.13.4" ]] || fail "TalosUpgrade version must match talenv"

[[ "$(yq -r '.applications."system-upgrade".annotations."argocd.argoproj.io/sync-wave"' "${APPLICATIONS_FILE}")" == "30" ]] || fail "system-upgrade must sync at wave 30"
[[ "$(yq -r '.applications.tuppr.annotations."argocd.argoproj.io/sync-wave"' "${APPLICATIONS_FILE}")" == "35" ]] || fail "Tuppr must sync at wave 35"
[[ "$(yq -r '.applications."talos-upgrade".annotations."argocd.argoproj.io/sync-wave"' "${APPLICATIONS_FILE}")" == "40" ]] || fail "TalosUpgrade must sync at wave 40"

printf 'PASS: Tuppr namespace, credential, and suspended upgrade policy are rendered\n'
