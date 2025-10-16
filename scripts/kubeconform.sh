#!/usr/bin/env bash
set -o errexit
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export ROOT_DIR="$(git rev-parse --show-toplevel)"

# Set default environment variables for envsubst validation
# These are placeholder values used only for syntax validation
export CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-example.local}"
export EXTERNAL_IP_ADDRESS="${EXTERNAL_IP_ADDRESS:-192.168.1.100}"
export INTERNAL_IP_ADDRESS="${INTERNAL_IP_ADDRESS:-10.0.0.100}"
export GATEWAY_NAME="${GATEWAY_NAME:-gateway}"
export GATEWAY_EXTERNAL="${GATEWAY_EXTERNAL:-gateway-external}"
export GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-gateway-system}"
export ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-app}"
export ARGOCD_ENV_VOLSYNC_CAPACITY="${ARGOCD_ENV_VOLSYNC_CAPACITY:-4Gi}"
export ARGOCD_ENV_VOLUME_SNAPSHOT_CLASS="${ARGOCD_ENV_VOLUME_SNAPSHOT_CLASS:-longhorn-snapclass}"
export ARGOCD_ENV_STORAGE_CLASS="${ARGOCD_ENV_STORAGE_CLASS:-longhorn}"
export NAS_IP_ADDRESS="${NAS_IP_ADDRESS:-192.168.1.100}"

kustomize_args=("--load-restrictor=LoadRestrictionsNone" "--enable-alpha-plugins")
kustomize_config="kustomization.yaml"
kubeconform_args=(
    "-strict"
    "-ignore-missing-schemas"
    "-skip"
    "Secret,ExternalSecret,SecretStore,ClusterSecretStore,HelmChart,HelmChartConfig"
    "-schema-location"
    "default"
    "-schema-location"
    "https://kubernetes-schemas.pages.dev/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
    "-schema-location"
    "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
    "-verbose"
)

# Function to validate a kustomization directory
validate_kustomization() {
    local dir="$1"
    local relative_path="${dir#${ROOT_DIR}/}"

    echo "=== Validating kustomization in ${relative_path} ==="

    # Check if directory contains helmCharts (skip these as they need Helm to render)
    if grep -q "helmCharts:" "${dir}/kustomization.yaml" 2>/dev/null; then
        echo "Skipping ${relative_path} - contains helmCharts (requires Helm rendering)"
        return 0
    fi

    # Build and validate the kustomization (process env vars with envsubst)
    if ! kustomize build "${dir}" "${kustomize_args[@]}" | envsubst | kubeconform "${kubeconform_args[@]}"; then
        echo "❌ Validation failed for ${relative_path}"
        return 1
    fi

    echo "✅ Validation passed for ${relative_path}"
    return 0
}

# Function to check if a file is referenced in configMapGenerator
is_configmap_generator_file() {
    local file="$1"
    local dir="${file%/*}"
    local filename="${file##*/}"
    local kustomization_file="${dir}/kustomization.yaml"

    # Check if kustomization.yaml exists and contains configMapGenerator referencing this file
    if [[ -f "${kustomization_file}" ]]; then
        if grep -q "configMapGenerator:" "${kustomization_file}" && grep -A 20 "configMapGenerator:" "${kustomization_file}" | grep -q "files:" && grep -A 20 "configMapGenerator:" "${kustomization_file}" | grep -A 10 "files:" | grep -q "${filename}"; then
            return 0  # File is referenced in configMapGenerator
        fi
    fi
    return 1  # File is not referenced in configMapGenerator
}

# Function to validate standalone YAML files
validate_standalone_files() {
    local search_dir="$1"
    local relative_path="${search_dir#${ROOT_DIR}/}"

    echo "=== Validating standalone YAML files in ${relative_path} ==="

    # Find standalone YAML files (excluding non-manifest files)
    find "${search_dir}" -maxdepth 1 -type f -name '*.yaml' \
        ! -name 'kustomization.yaml' \
        ! -name 'values.yaml' \
        ! -name 'helmfile.yaml' \
        ! -name 'Chart.yaml' \
        ! -name '*.sops.yaml' \
        ! -name 'config.yaml' \
        ! -name 'configuration.*' \
        -print0 | while IFS= read -r -d $'\0' file; do

        local file_relative="${file#${ROOT_DIR}/}"

        # Skip files that are referenced in configMapGenerator
        if is_configmap_generator_file "${file}"; then
            echo "Skipping ${file_relative} - referenced in configMapGenerator"
            continue
        fi

        echo "Validating ${file_relative}"
        if ! envsubst < "${file}" | kubeconform "${kubeconform_args[@]}"; then
            echo "❌ Validation failed for ${file_relative}"
            exit 1
        fi
    done
}

echo "🚀 Starting Kubernetes manifest validation for home-ops repository"

# Validate components directory
if [[ -d "${ROOT_DIR}/components" ]]; then
    echo ""
    echo "📦 Validating components directory..."

    # First validate any standalone YAML files in components subdirectories
    find "${ROOT_DIR}/components" -type d -name "*" | while read -r dir; do
        if [[ "${dir}" == "${ROOT_DIR}/components" ]]; then
            continue  # Skip the root components directory
        fi

        # Skip charts directories (contain Helm charts, not raw manifests)
        if [[ "${dir}" == */charts || "${dir}" == */charts/* ]]; then
            echo "Skipping ${dir#${ROOT_DIR}/} - charts directory"
            continue
        fi

        # Check if directory has standalone YAML files
        if find "${dir}" -maxdepth 1 -name '*.yaml' ! -name 'kustomization.yaml' | grep -q .; then
            validate_standalone_files "${dir}" || exit 1
        fi
    done

    # Then validate kustomizations in components
    find "${ROOT_DIR}/components" -type f -name "${kustomize_config}" -print0 | while IFS= read -r -d $'\0' file; do
        dir="${file%/${kustomize_config}}"

        # Skip kustomizations in charts directories
        if [[ "${dir}" == */charts || "${dir}" == */charts/* ]]; then
            echo "Skipping ${dir#${ROOT_DIR}/} - charts directory"
            continue
        fi

        validate_kustomization "${dir}" || exit 1
    done
fi

# Validate clusters directory
if [[ -d "${ROOT_DIR}/clusters" ]]; then
    echo ""
    echo "🏗️ Validating clusters directory..."

    # Validate cluster-specific configurations
    find "${ROOT_DIR}/clusters" -type f -name "${kustomize_config}" -print0 | while IFS= read -r -d $'\0' file; do
        dir="${file%/${kustomize_config}}"

        # Skip bootstrap directories as they may contain helmfile configs
        if [[ "${dir}" == *"/bootstrap"* ]]; then
            echo "Skipping ${dir#${ROOT_DIR}/} - bootstrap directory"
            continue
        fi

        validate_kustomization "${dir}" || exit 1
    done
fi

echo ""
echo "🎉 All Kubernetes manifest validation completed successfully!"
