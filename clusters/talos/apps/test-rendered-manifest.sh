#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly APPS_COMPONENT="${ROOT_DIR}/clusters/talos/apps"
readonly manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

kustomize build --enable-helm "${APPS_COMPONENT}" >"${manifest}"

application_count="$(yq ea -r '[select(.kind == "Application")] | length' "${manifest}")"
[[ "${application_count}" -gt 0 ]] || fail "no Argo Applications rendered"

[[ "$(yq ea -r '[select(.kind == "Application" and .spec.syncPolicy.automated.allowEmpty == true)] | length' "${manifest}")" == "${application_count}" ]] ||
  fail "every Argo Application must allow an empty automated sync"
[[ "$(yq ea -r '[select(.kind == "Application" and .spec.syncPolicy.retry.limit != null)] | length' "${manifest}")" == "${application_count}" ]] ||
  fail "every Argo Application must configure sync retries"
[[ "$(yq ea -r '[select(.kind == "Application" and (.spec.syncPolicy.syncOptions | contains(["ApplyOutOfSyncOnly=true", "PrunePropagationPolicy=foreground", "PruneLast=true", "ServerSideApply=true", "FailOnSharedResource=true", "RespectIgnoreDifferences=true"])))] | length' "${manifest}")" == "${application_count}" ]] ||
  fail "every Argo Application must retain the default sync options"

for app in kubevirt-operator cdi-operator arc-controller arc-kubevirt-runner; do
  [[ "$(APP="${app}" yq ea -r '[select(.kind == "Application" and .metadata.name == env(APP) and .spec.syncPolicy.retry.limit == 5 and (.spec.syncPolicy.syncOptions | contains(["CreateNamespace=true"])))] | length' "${manifest}")" == "1" ]] ||
    fail "${app} must retain namespace creation and retry limit 5"
done

volsync_apps='[select(.kind == "Application") | select(.spec.source.plugin.env[]? | .name == "VOLSYNC_CAPACITY")]'
volsync_schedules='[select(.kind == "Application") | .spec.source.plugin.env[]? | select(.name == "VOLSYNC_SCHEDULE") | .value]'
volsync_storage_classes='[select(.kind == "Application") | .spec.source.plugin.env[]? | select(.name == "VOLSYNC_STORAGE_CLASS") | .value]'
volsync_count="$(yq ea -r "${volsync_apps} | length" "${manifest}")"
[[ "$(yq ea -r "${volsync_storage_classes} | map(select(. == \"ceph-block-volsync\")) | length" "${manifest}")" == "${volsync_count}" ]] ||
  fail "every VolSync application must use ceph-block-volsync"
[[ "$(yq ea -r "${volsync_schedules} | length" "${manifest}")" == "${volsync_count}" ]] ||
  fail "every VolSync application must declare an explicit schedule"
[[ "$(yq ea -r "${volsync_schedules} | unique | length" "${manifest}")" == "${volsync_count}" ]] ||
  fail "VolSync schedules must be unique to avoid synchronized mover jobs"

printf 'PASS: rendered Argo Applications include sync policy and staggered VolSync schedules\n'
