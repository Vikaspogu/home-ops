#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly BACKUP_COMPONENT="${ROOT_DIR}/components/default/synology-photos-backup"
readonly manifest="$(mktemp)"
readonly exclude="--exclude '**/@eaDir/**'"
trap 'rm -f -- "${manifest}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

kustomize build "${BACKUP_COMPONENT}" >"${manifest}"

command="$(yq ea -r '
  select(.kind == "CronJob" and .metadata.name == "synology-backup")
  | .spec.jobTemplate.spec.template.spec.containers[]
  | select(.name == "rclone")
  | .command[2]
' "${manifest}")"

remaining="${command}"
count=0
while [[ "${remaining}" == *"${exclude}"* ]]; do
  remaining="${remaining#*"${exclude}"}"
  ((count += 1))
done

[[ "${count}" == "2" ]] || fail "rendered backup job must exclude @eaDir from both rclone sync commands"
printf 'PASS: rendered backup job excludes unreadable Synology index directories from both syncs\n'
