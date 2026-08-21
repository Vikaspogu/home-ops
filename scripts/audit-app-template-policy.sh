#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly report="$(mktemp)"
trap 'rm -f -- "${report}"' EXIT

while IFS= read -r -d '' values; do
  relative="${values#${ROOT_DIR}/}"

  for section in containers initContainers; do
    FILE="${relative}" SECTION="${section}" yq -r '
      (.controllers // {}) | to_entries[] |
      {"controller": .key, "containers": (.value[strenv(SECTION)] // {})} |
      [.controller, (.containers | to_entries[])] |
      select(.[1].value.image.repository != null) |
      select(.[1].value.image.tag == null or .[1].value.image.tag == "" or .[1].value.image.tag == "latest") |
      "image|" + strenv(FILE) + ":" + .[0] + "/" + .[1].key
    ' "${values}" >>"${report}"

    FILE="${relative}" SECTION="${section}" yq -r '
      (.controllers // {}) | to_entries[] |
      {"controller": .key, "containers": (.value[strenv(SECTION)] // {})} |
      [.controller, (.containers | to_entries[])] |
      select(.[1].value.image.repository != null) |
      select(.[1].value.resources.requests.cpu == null or
             .[1].value.resources.requests.memory == null or
             .[1].value.resources.limits.memory == null) |
      "resources|" + strenv(FILE) + ":" + .[0] + "/" + .[1].key
    ' "${values}" >>"${report}"

    FILE="${relative}" SECTION="${section}" yq -r '
      (.controllers // {}) | to_entries[] |
      {"controller": .key, "containers": (.value[strenv(SECTION)] // {})} |
      [.controller, (.containers | to_entries[])] |
      select(.[1].value.image.repository != null) |
      select(.[1].value.securityContext.allowPrivilegeEscalation != false or
             .[1].value.securityContext.readOnlyRootFilesystem != true or
             ((.[1].value.securityContext.capabilities.drop // []) | contains(["ALL"]) | not)) |
      "security|" + strenv(FILE) + ":" + .[0] + "/" + .[1].key
    ' "${values}" >>"${report}"
  done
done < <(find "${ROOT_DIR}/components" -type f -name values.yaml \
  ! -path '*/charts/*' ! -path '*/vendor/*' -print0)

sort -u "${report}" -o "${report}"
readonly image_count="$(grep -c '^image|' "${report}" || true)"
readonly resource_count="$(grep -c '^resources|' "${report}" || true)"
readonly security_count="$(grep -c '^security|' "${report}" || true)"

printf 'App-template policy audit (resources and security are report-only):\n'
if [[ -s "${report}" ]]; then
  cat "${report}"
fi
printf 'image=%s resources=%s security=%s\n' \
  "${image_count}" "${resource_count}" "${security_count}"

[[ "${image_count}" == "0" ]] || {
  printf 'FAIL: app-template images must use a versioned tag or digest\n' >&2
  exit 1
}
