#!/usr/bin/env bash

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rendered_manifest=$(mktemp "${TMPDIR:-/tmp}/searxng-render.XXXXXX")
render_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/searxng-render-test.XXXXXX")
config_template_dir="$render_test_dir/config-template"
runtime_config_dir="$render_test_dir/runtime-config"
trap 'rm -f "$rendered_manifest"; rm -rf "$render_test_dir"' EXIT HUP INT TERM

if ! command -v kustomize >/dev/null 2>&1; then
  printf 'FAIL: kustomize is required to render SearXNG manifests.\n' >&2
  exit 1
fi

kustomize build --enable-helm "$repo_root/components/ai/searxng" >"$rendered_manifest"
render_command_failure=0
init_command=$(awk '
  function indentation(line) {
    match(line, /^[[:space:]]*/)
    return RLENGTH
  }

  /^---[[:space:]]*$/ {
    in_deployment = 0
    in_init_containers = 0
    next
  }

  /^kind:[[:space:]]*/ {
    in_deployment = ($0 ~ /^kind:[[:space:]]*Deployment[[:space:]]*$/)
    in_init_containers = 0
    next
  }

  in_deployment && /^[[:space:]]+initContainers:[[:space:]]*$/ {
    init_containers_indentation = indentation($0)
    in_init_containers = 1
    next
  }

  in_init_containers && $0 !~ /^[[:space:]]*$/ && indentation($0) <= init_containers_indentation && $0 !~ /^[[:space:]]*-[[:space:]]/ {
    in_init_containers = 0
  }

  in_command {
    if ($0 ~ /^[[:space:]]*$/) {
      next
    }

    if (indentation($0) > command_indentation && $0 !~ /^[[:space:]]*-[[:space:]]/) {
      continuation = $0
      sub(/^[[:space:]]*/, "", continuation)
      command = command " " continuation
      next
    }

    print command
    emitted_command = 1
    exit
  }

  in_init_containers && /^[[:space:]]*-[[:space:]]*-c[[:space:]]*$/ {
    shell_command_follows = 1
    next
  }

  in_init_containers && shell_command_follows && /^[[:space:]]*-[[:space:]]*/ {
    command = $0
    command_indentation = indentation(command)
    sub(/^[[:space:]]*-[[:space:]]*/, "", command)
    in_command = 1
    shell_command_follows = 0
  }

  END {
    if (in_command && !emitted_command) {
      print command
    }
  }
' "$rendered_manifest")

if [ -z "$init_command" ]; then
  printf 'FAIL: could not locate the rendered SearXNG init-container command.\n' >&2
  render_command_failure=1
else
  mkdir -p "$config_template_dir" "$runtime_config_dir"
  cp "$repo_root/components/ai/searxng/settings.yml" "$config_template_dir/settings.yml"
  synthetic_secret='render/secret&pipe|backslash\value'
  runtime_init_command=${init_command//\/config-template/$config_template_dir}
  runtime_init_command=${runtime_init_command//\/runtime-config/$runtime_config_dir}

  if ! SEARXNG_SECRET="$synthetic_secret" sh -c "$runtime_init_command" >"$render_test_dir/init-command.stdout" 2>"$render_test_dir/init-command.stderr"; then
    printf 'FAIL: rendered init-container command cannot render a secret containing sed-special characters.\n' >&2
    render_command_failure=1
  elif [ ! -r "$runtime_config_dir/settings.yml" ]; then
    printf 'FAIL: rendered init-container command did not write the settings file.\n' >&2
    render_command_failure=1
  else
    rendered_secret=$(awk '
      /^[[:space:]]*secret_key:[[:space:]]*/ {
        value = $0
        sub(/^[[:space:]]*secret_key:[[:space:]]*/, "", value)
        sub(/^"/, "", value)
        sub(/"$/, "", value)
        print value
        exit
      }
    ' "$runtime_config_dir/settings.yml")

    if [ "$rendered_secret" != "$synthetic_secret" ]; then
      printf 'FAIL: rendered init-container command changed a secret containing sed-special characters.\n' >&2
      render_command_failure=1
    fi
  fi
fi

configmap_names=$(awk '
  function save_document() {
    if (kind == "ConfigMap") {
      print name
    }
  }

  /^---[[:space:]]*$/ {
    save_document()
    kind = ""
    name = ""
    in_metadata = 0
    next
  }

  /^kind:[[:space:]]*/ {
    kind = $0
    sub(/^kind:[[:space:]]*/, "", kind)
    next
  }

  /^metadata:[[:space:]]*$/ {
    in_metadata = 1
    next
  }

  in_metadata && /^[^[:space:]]/ {
    in_metadata = 0
  }

  in_metadata && /^[[:space:]]+name:[[:space:]]*/ {
    name = $0
    sub(/^[[:space:]]+name:[[:space:]]*/, "", name)
    sub(/[[:space:]]+$/, "", name)
    in_metadata = 0
  }

  END {
    save_document()
  }
' "$rendered_manifest")

reloader_values=$(awk '
  function save_document() {
    if (kind == "Deployment" && reloader_value_found) {
      print reloader_value
    }
  }

  /^---[[:space:]]*$/ {
    save_document()
    kind = ""
    in_metadata = 0
    in_annotations = 0
    reloader_value_found = 0
    reloader_value = ""
    next
  }

  /^kind:[[:space:]]*/ {
    kind = $0
    sub(/^kind:[[:space:]]*/, "", kind)
    next
  }

  /^metadata:[[:space:]]*$/ {
    in_metadata = 1
    next
  }

  in_metadata && /^[^[:space:]]/ {
    in_metadata = 0
    in_annotations = 0
  }

  in_metadata && /^  annotations:[[:space:]]*$/ {
    in_annotations = 1
    next
  }

  in_annotations && /^  [^[:space:]]/ {
    in_annotations = 0
  }

  in_annotations && /^    configmap\.reloader\.stakater\.com\/reload:[[:space:]]*/ {
    reloader_value = $0
    sub(/^    configmap\.reloader\.stakater\.com\/reload:[[:space:]]*/, "", reloader_value)
    sub(/[[:space:]]+$/, "", reloader_value)
    reloader_value_found = 1
  }

  END {
    save_document()
  }
' "$rendered_manifest")

failures=$render_command_failure

if ! printf '%s\n' "$configmap_names" | grep -Fx 'searxng-settings' >/dev/null; then
  printf 'FAIL: expected ConfigMap metadata.name to be searxng-settings; rendered ConfigMap names:\n%s\n' "${configmap_names:-<none>}" >&2
  failures=1
fi

hashed_configmap_names=$(printf '%s\n' "$configmap_names" | grep -E '^searxng-settings-[[:alnum:]]+$' || true)
if [ -n "$hashed_configmap_names" ]; then
  printf 'FAIL: generated ConfigMap hash suffix is not allowed: %s\n' "$hashed_configmap_names" >&2
  failures=1
fi

if [ "$reloader_values" != 'searxng-settings' ]; then
  printf 'FAIL: expected Deployment configmap.reloader.stakater.com/reload to equal searxng-settings; rendered values:\n%s\n' "${reloader_values:-<none>}" >&2
  failures=1
fi

if [ "$failures" -ne 0 ]; then
  exit 1
fi
