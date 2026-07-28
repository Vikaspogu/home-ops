#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(git rev-parse --show-toplevel)"
readonly HERMES_COMPONENT="${ROOT_DIR}/components/ai/hermes-agent"
# Derive the image from values.yaml — a hardcoded tag rots on every
# automatic image bump and the whole script silently stops guarding.
readonly HERMES_IMAGE="$(yq -r '.controllers.app.containers.app.image | .repository + ":" + .tag' "${HERMES_COMPONENT}/values.yaml")"
export HERMES_IMAGE
readonly NEMO_RELAY_PLUGINS_PATH="/opt/data/nemo-relay-plugins.toml"
export NEMO_RELAY_PLUGINS_PATH
readonly NEMO_RELAY_PLUGINS_TOML=$'version = 1\n\n[[components]]\nkind = "observability"\nenabled = true\n\n[components.config]\nversion = 1\n\n[components.config.openinference]\nenabled = true\ntransport = "http_binary"\nendpoint = "http://alloy.observability.svc.cluster.local:4318/v1/traces"\nservice_name = "hermes-agent"\nservice_namespace = "ai"\ninstrumentation_scope = "hermes-nemo-relay"\ntimeout_millis = 3000\n\n[components.config.openinference.resource_attributes]\n"deployment.environment" = "talos"'
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

hermes_app_container_count() {
  yq ea -r '

    [
      select(.kind == "Deployment" and .metadata.name == "hermes-agent")
      | .spec.template.spec.containers[]?
      | select(.image | test("^gitea\\.a113\\.casa/vpogu/agent-platform-hermes-agent:"))
    ] | length

  ' "${manifest}"
}

hermes_app_image_count() {
  yq ea -r '

    [
      select(.kind == "Deployment" and .metadata.name == "hermes-agent")
      | .spec.template.spec.containers[]?
      | select(.image == strenv(HERMES_IMAGE))
    ] | length

  ' "${manifest}"
}

hermes_init_container_count() {
  yq ea -r '

    [
      select(.kind == "Deployment" and .metadata.name == "hermes-agent")
      | .spec.template.spec.initContainers[]?
      | select(.image | test("^gitea\\.a113\\.casa/vpogu/agent-platform-hermes-agent:"))
    ] | length

  ' "${manifest}"
}

hermes_init_image_count() {
  yq ea -r '

    [
      select(.kind == "Deployment" and .metadata.name == "hermes-agent")
      | .spec.template.spec.initContainers[]?
      | select(.image == strenv(HERMES_IMAGE))
    ] | length

  ' "${manifest}"
}

hermes_restore_permissions_container_count() {
  yq ea -r '

[
  select(.kind == "Deployment" and .metadata.name == "hermes-agent")
  | .spec.template.spec.initContainers[]?
  | select(
      (.name == "00-restore-permissions")
      and (.image == strenv(HERMES_IMAGE))
      and (.command[0] == "python")
      and (.command[1] == "-c")
      and (.command[2] | contains("path = \"/opt/data/.config/gogcli\""))
      and (.command[2] | contains("os.chown(root, 10000, 10000, follow_symlinks=False)"))
      and (.securityContext.runAsUser == 0)
      and (.securityContext.runAsGroup == 0)
      and (.securityContext.allowPrivilegeEscalation == false)
      and (.securityContext.readOnlyRootFilesystem == true)
      and (.securityContext.capabilities.drop | contains(["ALL"]))
      and (.securityContext.capabilities.add | contains(["CHOWN"]))
      and ([.volumeMounts[]? | select(.name == "app-data" and .mountPath == "/opt/data")] | length == 1)
    )
] | length

' "${manifest}"
}

hermes_first_init_container_name() {
  yq ea -r '

select(.kind == "Deployment" and .metadata.name == "hermes-agent")
| .spec.template.spec.initContainers[0].name

' "${manifest}"
}

hermes_restore_permissions_script() {
  yq ea -r '

select(.kind == "Deployment" and .metadata.name == "hermes-agent")
| .spec.template.spec.initContainers[]?
| select(.name == "00-restore-permissions")
| .command[2]

' "${manifest}"
}

hermes_app_env_count() {
  yq ea -r '

    [
      select(.kind == "Deployment" and .metadata.name == "hermes-agent")
      | .spec.template.spec.containers[]?
      | select(.image | test("^gitea\\.a113\\.casa/vpogu/agent-platform-hermes-agent:"))
      | .env[]?
      | select(.name == "HERMES_NEMO_RELAY_PLUGINS_TOML" and .value == strenv(NEMO_RELAY_PLUGINS_PATH))
    ] | length

  ' "${manifest}"
}

hermes_nemo_relay_plugin_count() {
  yq ea -r '
    [
      select(.kind == "ConfigMap" and .metadata.name == "hermes-agent-config")
      | .data["config.yaml"]
      | from_yaml
      | .plugins.enabled[]?
      | select(. == "observability/nemo_relay")
    ] | length
  ' "${manifest}"
}

hermes_config_volume_count() {
  yq ea -r '
    [
      select(.kind == "Deployment" and .metadata.name == "hermes-agent")
      | .spec.template.spec.volumes[]?
      | select(.name == "config" and .configMap.name == "hermes-agent-config")
    ] | length
  ' "${manifest}"
}

hermes_plugin_mount_count() {
  yq ea -r '

    [
      select(.kind == "Deployment" and .metadata.name == "hermes-agent")
      | .spec.template.spec.containers[]?
      | select(.image | test("^gitea\\.a113\\.casa/vpogu/agent-platform-hermes-agent:"))
      | .volumeMounts[]?
      | select(
          .name == "config"
          and .mountPath == strenv(NEMO_RELAY_PLUGINS_PATH)
          and .subPath == "nemo-relay-plugins.toml"
          and .readOnly == true
        )
    ] | length

  ' "${manifest}"
}

kustomize build --enable-helm "${HERMES_COMPONENT}" >"${manifest}"

[[ "$(resource_count Deployment hermes-agent)" == "1" ]] || fail "rendered Hermes Deployment is missing or ambiguous"
[[ "$(resource_count ConfigMap hermes-agent-config)" == "1" ]] || fail "rendered Hermes ConfigMap is missing or ambiguous"
[[ "$(hermes_app_container_count)" == "1" ]] || fail "rendered Hermes application container is missing or ambiguous"

[[ "$(hermes_init_container_count)" == "4" ]] || fail "rendered Hermes init containers are missing or ambiguous"

[[ "$(hermes_app_image_count)" == "1" ]] || fail "rendered Hermes application image must use ${HERMES_IMAGE} exactly once"

[[ "$(hermes_init_image_count)" == "3" ]] || fail "rendered Hermes init containers must retain their configured image tags"
[[ "$(hermes_restore_permissions_container_count)" == "1" ]] || fail "rendered Hermes restore-permissions init container must repair restored GOG config ownership"
[[ "$(hermes_first_init_container_name)" == "00-restore-permissions" ]] || fail "rendered Hermes ownership repair must run before bootstrap"
hermes_restore_permissions_script | python3 -c 'import sys; compile(sys.stdin.read(), "restore-permissions", "exec")'
[[ "$(hermes_nemo_relay_plugin_count)" == "1" ]] || fail "rendered Hermes configuration must enable observability/nemo_relay"
[[ "$(
  yq ea -r '
    select(.kind == "ConfigMap" and .metadata.name == "hermes-agent-config")
    | .data["nemo-relay-plugins.toml"]
  ' "${manifest}"
)" == "${NEMO_RELAY_PLUGINS_TOML}" ]] || fail "NeMo Relay OpenInference ConfigMap entry missing or invalid"
[[ "$(hermes_app_env_count)" == "1" ]] || fail "rendered Hermes application container must set HERMES_NEMO_RELAY_PLUGINS_TOML"
[[ "$(hermes_config_volume_count)" == "1" ]] || fail "rendered Hermes ConfigMap volume is missing or ambiguous"
[[ "$(hermes_plugin_mount_count)" == "1" ]] || fail "rendered Hermes application container must mount the NeMo Relay ConfigMap key read-only"

printf 'PASS: rendered Hermes image, NeMo Relay OpenInference config, environment, and ConfigMap mount are consistent\n'
