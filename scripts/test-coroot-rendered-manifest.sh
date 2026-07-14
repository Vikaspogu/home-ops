#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly PROMETHEUS_COMPONENT="${ROOT_DIR}/components/observability/kube-prometheus-stack"
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

kustomize build --enable-helm "${PROMETHEUS_COMPONENT}" >"${manifest}"

[[ "$(remote_write_receiver_count)" == "1" ]] || fail "rendered Prometheus remote-write receiver missing or ambiguous"

printf 'Coroot rendered-manifest contract passed.\n'
