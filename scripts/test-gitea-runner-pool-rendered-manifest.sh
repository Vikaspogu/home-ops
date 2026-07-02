#!/usr/bin/env bash
set -Eeuo pipefail

# Contract test for the staged Gitea runner pool: a baseline runner
# (capacity 2) plus a burst runner (capacity 1) that shares no persistent
# state with the baseline. Both components are rendered as ArgoCD would render
# them — `kustomize build --enable-helm` piped through `envsubst` restricted to
# an explicit allowlist of the seven plugin variables ArgoCD injects — so the
# assertions run against the real rendered Helm output, not the source YAML.
# The rendered manifests (which contain ExternalSecret definitions) are never
# printed; assertions inspect resource names, counts, and scalar fields only.

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly BASELINE_COMPONENT="${ROOT_DIR}/components/default/gitea-runner"
readonly BURST_COMPONENT="${ROOT_DIR}/components/default/gitea-runner-burst"
readonly APPLICATIONS="${ROOT_DIR}/clusters/talos/apps/20-applications.yaml"

readonly BASELINE_APP="gitea-runner"
readonly BURST_APP="gitea-runner-burst"

umask 077
readonly baseline_manifest="$(mktemp)"
readonly burst_manifest="$(mktemp)"
trap 'rm -f -- "${baseline_manifest}" "${burst_manifest}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# Render a component the way ArgoCD does: kustomize build --enable-helm, then
# envsubst with the plugin environment. VOLSYNC_SCHEDULE is quoted because it
# contains spaces and glob characters.
render() {
    local component="$1" app_name="$2" out="$3"

    [[ -d "${component}" ]] || fail "component directory is missing: ${component}"

    # Restrict envsubst to exactly the seven plugin variables ArgoCD injects, so
    # any other `$word` inside rendered manifests (shell snippets, Go templates)
    # is left untouched. The schedule value carries spaces/glob chars; it is
    # exported, never word-split into the allowlist.
    local -r allowlist='${ARGOCD_APP_NAME} ${ARGOCD_ENV_STORAGE_CLASS} ${ARGOCD_ENV_VOLUME_SNAPSHOT_CLASS} ${ARGOCD_ENV_VOLSYNC_CAPACITY} ${ARGOCD_ENV_VOLSYNC_CACHE_CAPACITY} ${ARGOCD_ENV_VOLSYNC_SCHEDULE} ${CLUSTER_DOMAIN}'

    ARGOCD_APP_NAME="${app_name}" \
    ARGOCD_ENV_STORAGE_CLASS="ceph-block" \
    ARGOCD_ENV_VOLUME_SNAPSHOT_CLASS="csi-ceph-blockpool" \
    ARGOCD_ENV_VOLSYNC_CAPACITY="2Gi" \
    ARGOCD_ENV_VOLSYNC_CACHE_CAPACITY="8Gi" \
    ARGOCD_ENV_VOLSYNC_SCHEDULE="40 */6 * * *" \
    CLUSTER_DOMAIN="example.local" \
        bash -c '
            set -Eeuo pipefail
            kustomize build --enable-helm "$1" | envsubst "$2"
        ' _ "${component}" "${allowlist}" >"${out}" \
        || fail "kustomize/envsubst render failed for ${app_name} (${component})"
}

deployment_replicas() {
    local manifest="$1" name="$2"

    yq ea -r "[select(.kind == \"Deployment\" and .metadata.name == \"${name}\") | .spec.replicas] | .[0] // \"none\"" "${manifest}"
}

# runner.capacity from the embedded act_runner config.yaml inside a rendered
# ConfigMap. This is the number of concurrent jobs a single runner process
# accepts — the pool's real capacity knob, independent of Deployment replicas.
runner_capacity() {
    local manifest="$1" name="$2"

    yq ea -r "[select(.kind == \"ConfigMap\" and .metadata.name == \"${name}\") | .data[\"config.yaml\"] | from_yaml | .runner.capacity] | .[0] // \"none\"" "${manifest}"
}

resource_count() {
    local manifest="$1" kind="$2" name="$3"

    yq ea -r "[select(.kind == \"${kind}\" and .metadata.name == \"${name}\")] | length" "${manifest}"
}

# Sorted persistent claims mounted by a Deployment's pod template. Sorting lets
# the caller assert an exact claim set without exposing rendered manifests.
deployment_claims() {
    local manifest="$1" name="$2"

    yq ea -r "[select(.kind == \"Deployment\" and .metadata.name == \"${name}\") | .spec.template.spec.volumes[]? | select(.persistentVolumeClaim) | .persistentVolumeClaim.claimName] | sort | .[]" "${manifest}"
}

# Sorted ConfigMaps mounted through a Deployment's pod volumes.
deployment_config_maps() {
    local manifest="$1" name="$2"

    yq ea -r "[select(.kind == \"Deployment\" and .metadata.name == \"${name}\") | .spec.template.spec.volumes[]? | select(.configMap) | .configMap.name] | sort | .[]" "${manifest}"
}

# Secret names referenced by the named runner container's envFrom entries.
# Only names are returned; secret values are never inspected or printed.
runner_envfrom_secrets() {
    local manifest="$1" deployment="$2" container="$3"

    yq ea -r "[select(.kind == \"Deployment\" and .metadata.name == \"${deployment}\") | .spec.template.spec.containers[]? | select(.name == \"${container}\") | .envFrom[]? | select(.secretRef) | .secretRef.name] | sort | .[]" "${manifest}"
}

external_secret_target() {
    local manifest="$1" name="$2"

    yq ea -r "[select(.kind == \"ExternalSecret\" and .metadata.name == \"${name}\") | .spec.target.name] | .[0] // \"none\"" "${manifest}"
}

app_field() {
    local expr="$1"

    yq ea -r "select(.applications) | .applications.\"${BURST_APP}\" | ${expr}" "${APPLICATIONS}"
}

plugin_env_value() {
    local var="$1"

    app_field ".source.plugin.env[]? | select(.name == \"${var}\") | .value"
}

render "${BASELINE_COMPONENT}" "${BASELINE_APP}" "${baseline_manifest}"

# --- Burst component exists and renders -------------------------------------
# Checked first: until the burst component is authored this is the contract's
# primary gap, and it should be the failure the test reports.
[[ -d "${BURST_COMPONENT}" ]] \
    || fail "burst component is missing: expected ${BURST_COMPONENT}"

render "${BURST_COMPONENT}" "${BURST_APP}" "${burst_manifest}"

# --- Baseline capacity ------------------------------------------------------
# Capacity is act_runner's runner.capacity (concurrent jobs per runner), read
# from the rendered ConfigMap. Each pool runs a single pod, so both Deployments
# keep spec.replicas == 1; scaling concurrency is done via runner.capacity.
[[ "$(resource_count "${baseline_manifest}" Deployment "${BASELINE_APP}")" == "1" ]] \
    || fail "rendered baseline Deployment ${BASELINE_APP} is missing or ambiguous"
[[ "$(resource_count "${baseline_manifest}" ConfigMap "${BASELINE_APP}-config")" == "1" ]] \
    || fail "rendered baseline ConfigMap ${BASELINE_APP}-config is missing or ambiguous"
[[ "$(runner_capacity "${baseline_manifest}" "${BASELINE_APP}-config")" == "2" ]] \
    || fail "rendered baseline ConfigMap ${BASELINE_APP}-config runner.capacity must be 2"
[[ "$(deployment_replicas "${baseline_manifest}" "${BASELINE_APP}")" == "1" ]] \
    || fail "rendered baseline ${BASELINE_APP} Deployment must run a single pod (spec.replicas == 1)"

# --- Burst capacity ---------------------------------------------------------
[[ "$(resource_count "${burst_manifest}" ConfigMap "${BURST_APP}-config")" == "1" ]] \
    || fail "rendered burst ConfigMap ${BURST_APP}-config is missing or ambiguous"
[[ "$(runner_capacity "${burst_manifest}" "${BURST_APP}-config")" == "1" ]] \
    || fail "rendered burst ConfigMap ${BURST_APP}-config runner.capacity must be 1"
[[ "$(deployment_replicas "${burst_manifest}" "${BURST_APP}")" == "1" ]] \
    || fail "rendered burst ${BURST_APP} Deployment must run a single pod (spec.replicas == 1)"

# --- Burst resources and wiring ---------------------------------------------
[[ "$(resource_count "${burst_manifest}" Deployment "${BURST_APP}")" == "1" ]] \
    || fail "rendered burst Deployment ${BURST_APP} is missing or ambiguous"
[[ "$(resource_count "${burst_manifest}" PersistentVolumeClaim "${BURST_APP}")" == "1" ]] \
    || fail "rendered burst data PVC ${BURST_APP} is missing or ambiguous"
[[ "$(resource_count "${burst_manifest}" PersistentVolumeClaim "${BURST_APP}-docker")" == "1" ]] \
    || fail "rendered burst docker PVC ${BURST_APP}-docker is missing or ambiguous"
[[ "$(resource_count "${burst_manifest}" ExternalSecret "${BURST_APP}")" == "1" ]] \
    || fail "rendered burst ExternalSecret ${BURST_APP} is missing or ambiguous"
[[ "$(external_secret_target "${burst_manifest}" "${BURST_APP}")" == "${BURST_APP}-secret" ]] \
    || fail "rendered burst ExternalSecret ${BURST_APP} must target ${BURST_APP}-secret"

# The complete persistent-claim set must be its two dedicated claims: this
# rejects missing, baseline, or any unexpected shared claim.
burst_claims="$(deployment_claims "${burst_manifest}" "${BURST_APP}")"
[[ "${burst_claims}" == "${BURST_APP}"$'\n'"${BURST_APP}-docker" ]] \
    || fail "burst ${BURST_APP} Deployment must mount exactly ${BURST_APP} and ${BURST_APP}-docker"
[[ "$(deployment_config_maps "${burst_manifest}" "${BURST_APP}")" == "${BURST_APP}-config" ]] \
    || fail "burst ${BURST_APP} Deployment must mount exactly ConfigMap ${BURST_APP}-config"
[[ "$(runner_envfrom_secrets "${burst_manifest}" "${BURST_APP}" runner)" == "${BURST_APP}-secret" ]] \
    || fail "burst ${BURST_APP} runner container envFrom must reference exactly ${BURST_APP}-secret"

# --- ArgoCD registration ----------------------------------------------------
[[ "$(app_field 'has("source")')" == "true" ]] \
    || fail "ArgoCD application ${BURST_APP} is not registered in ${APPLICATIONS}"
[[ "$(app_field '.source.path')" == "components/default/${BURST_APP}" ]] \
    || fail "ArgoCD ${BURST_APP} source.path must be components/default/${BURST_APP}"
[[ "$(app_field '.destination.namespace')" == "default" ]] \
    || fail "ArgoCD ${BURST_APP} destination.namespace must be default"
[[ "$(app_field '.annotations."argocd.argoproj.io/sync-wave"')" == "20" ]] \
    || fail "ArgoCD ${BURST_APP} sync-wave must be 20"

[[ "$(plugin_env_value STORAGE_CLASS)" == "ceph-block" ]] \
    || fail "ArgoCD ${BURST_APP} plugin STORAGE_CLASS must be ceph-block"
[[ "$(plugin_env_value VOLUME_SNAPSHOT_CLASS)" == "csi-ceph-blockpool" ]] \
    || fail "ArgoCD ${BURST_APP} plugin VOLUME_SNAPSHOT_CLASS must be csi-ceph-blockpool"
[[ "$(plugin_env_value VOLSYNC_CAPACITY)" == "2Gi" ]] \
    || fail "ArgoCD ${BURST_APP} plugin VOLSYNC_CAPACITY must be 2Gi"
[[ "$(plugin_env_value VOLSYNC_CACHE_CAPACITY)" == "8Gi" ]] \
    || fail "ArgoCD ${BURST_APP} plugin VOLSYNC_CACHE_CAPACITY must be 8Gi"
[[ "$(plugin_env_value VOLSYNC_SCHEDULE)" == "40 */6 * * *" ]] \
    || fail "ArgoCD ${BURST_APP} plugin VOLSYNC_SCHEDULE must be '40 */6 * * *'"

printf 'PASS: gitea runner pool baseline capacity, burst capacity, burst workload wiring, and ArgoCD burst registration are consistent\n'
