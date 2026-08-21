#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly COMPONENT="${ROOT_DIR}/components/rook-ceph/rook-ceph-cluster"
readonly manifest="$(mktemp)"
trap 'rm -f -- "${manifest}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

kustomize build --enable-helm "${COMPONENT}" >"${manifest}"

cephcluster() {
  yq ea -r 'select(.kind == "CephCluster" and .metadata.name == "rook-ceph")' "${manifest}"
}

[[ "$(cephcluster | yq -r '.spec.security.cephx.daemon.keyRotationPolicy')" == "KeyGeneration" ]] \
  || fail "Ceph daemon key rotation must use KeyGeneration"
[[ "$(cephcluster | yq -r '.spec.security.cephx.daemon.keyGeneration')" == "2" ]] \
  || fail "Ceph daemon keys must rotate to generation 2"
[[ "$(cephcluster | yq -r '.spec.security.cephx.csi.keyType')" == "aes" ]] \
  || fail "CSI keys must remain AES while Talos nodes run kernel 6.18"
[[ "$(cephcluster | yq -r '.spec.security.cephx.csi.keyRotationPolicy // "Disabled"')" == "Disabled" ]] \
  || fail "this daemon-key remediation must not rotate CSI keys"
[[ "$(cephcluster | yq -r '.spec.mgr.modules[] | select(.name == "rook") | .enabled')" == "false" ]] \
  || fail "the unstable Rook mgr module must remain disabled on Ceph Tentacle"
[[ "$(cephcluster | yq -r '.spec.healthCheck.muteHealthWarning | length')" == "3" ]] \
  || fail "only the three expected legacy-client warnings may be muted"
[[ "$(cephcluster | yq -r '.spec.healthCheck.muteHealthWarning.AUTH_INSECURE_SERVICE_KEY_TYPE.policy // "unmute"')" == "unmute" ]] \
  || fail "the CVE-critical service-key warning must remain visible"

for warning in \
  AUTH_INSECURE_CLIENT_KEY_TYPE \
  AUTH_INSECURE_KEYS_ALLOWED \
  AUTH_INSECURE_KEYS_CREATABLE; do
  [[ "$(cephcluster | WARNING="${warning}" yq -r '.spec.healthCheck.muteHealthWarning[env(WARNING)].policy')" == "mute" ]] \
    || fail "${warning} must remain muted while legacy CSI keys are required"
done

printf 'PASS: rendered CephCluster rotates daemon keys and preserves kernel-compatible CSI settings\n'
