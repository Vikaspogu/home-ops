#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="debug"
export ROOT_DIR="$(git rev-parse --show-toplevel)"
export CLUSTER_NAME="${1}"

# Validate that CLUSTER_NAME is provided
if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "ERROR: CLUSTER_NAME is required as the first argument"
    echo "Usage: $0 <cluster_name>"
    exit 1
fi

export CLUSTER_DOMAIN=$(op read "op://kubernetes/${CLUSTER_NAME}/add more/CLUSTER_DOMAIN")
export EXTERNAL_IP_ADDRESS=$(op read "op://kubernetes/${CLUSTER_NAME}/add more/EXTERNAL_IP_ADDRESS")
export INTERNAL_IP_ADDRESS=$(op read "op://kubernetes/${CLUSTER_NAME}/add more/INTERNAL_IP_ADDRESS")
export GATEWAY_NAME=$(op read "op://kubernetes/${CLUSTER_NAME}/add more/GATEWAY")
export GATEWAY_NAMESPACE=$(op read "op://kubernetes/${CLUSTER_NAME}/add more/GATEWAY_NAMESPACE")

# Talos requires the nodes to be 'Ready=False' before applying resources
function wait_for_nodes() {
    log debug "Waiting for nodes to be available"

    # Skip waiting if all nodes are 'Ready=True'
    if kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then
        log info "Nodes are available and ready, skipping wait for nodes"
        return
    fi

    # Wait for all nodes to be 'Ready=False'
    until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do
        log info "Nodes are not available, waiting for nodes to be available. Retrying in 10 seconds..."
        sleep 10
    done
}

# Namespaces to be applied before the SOPS secrets are installed
function apply_namespaces() {
    log debug "Applying namespaces"

    local -r apps_dir="${ROOT_DIR}/components"

    if [[ ! -d "${apps_dir}" ]]; then
        log error "Directory does not exist" "directory=${apps_dir}"
    fi

    for app in "${apps_dir}"/*/; do
        namespace=$(basename "${app}")

        # Check if the namespace resources are up-to-date
        if kubectl get namespace "${namespace}" &>/dev/null; then
            log info "Namespace resource is up-to-date" "resource=${namespace}"
            continue
        fi

        # Apply the namespace resources
        if kubectl create namespace "${namespace}" --dry-run=client --output=yaml \
            | kubectl apply --server-side --filename - &>/dev/null;
        then
            log info "Namespace resource applied" "resource=${namespace}"
        else
            log error "Failed to apply namespace resource" "resource=${namespace}"
        fi
    done
}

# SOPS secrets to be applied before the helmfile charts are installed
function apply_sops_secrets() {
    log debug "Applying secrets"

    local -r secrets=(
        "${ROOT_DIR}/components/common/helm-secrets-private-keys.sops.yaml"
    )

    for secret in "${secrets[@]}"; do
        if [ ! -f "${secret}" ]; then
            log warn "File does not exist" "file=${secret}"
            continue
        fi

        # Apply secret resources
        if sops -d "${secret}" | kubectl --namespace argo-system apply -f- ; then
            log info "Secret resource applied successfully" "resource=$(basename "${secret}" ".sops.yaml")"
        else
            log error "Failed to apply secret resource" "resource=$(basename "${secret}" ".sops.yaml")"
        fi
    done
}

# CRDs to be applied before the helmfile charts are installed
function apply_crds() {
    log debug "Applying CRDs"

    local -r crds=(
        # renovate: datasource=github-releases depName=kubernetes-sigs/external-dns
        https://raw.githubusercontent.com/kubernetes-sigs/external-dns/refs/tags/v0.19.0/config/crd/standard/dnsendpoints.externaldns.k8s.io.yaml
        # renovate: datasource=github-releases depName=kubernetes-sigs/gateway-api
        https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml
        # renovate: datasource=github-releases depName=prometheus-operator/prometheus-operator
        https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.85.0/stripped-down-crds.yaml
        # renovate: datasource=github-releases depName=external-secrets/external-secrets
        https://raw.githubusercontent.com/external-secrets/external-secrets/v0.20.1/deploy/crds/bundle.yaml
    )

    for crd in "${crds[@]}"; do
        if kubectl diff --filename "${crd}" &>/dev/null; then
            log info "CRDs are up-to-date" "crd=${crd}"
            continue
        fi
        if kubectl apply --server-side --filename "${crd}" &>/dev/null; then
            log info "CRDs applied" "crd=${crd}"
        else
            log info "Failed to apply CRDs" "crd=${crd}"
        fi
    done
}

# Sync Helm releases
function sync_helm_releases() {
    log debug "Syncing Helm releases"

    local -r helmfile_file="${ROOT_DIR}/clusters/${CLUSTER_NAME}/bootstrap/apps/helmfile.yaml"

    if [[ ! -f "${helmfile_file}" ]]; then
        log info "No need to apply helmfile - file does not exist" "file=${helmfile_file}"
        return
    fi

    if ! helmfile --file "${helmfile_file}" sync --hide-notes --kubeconfig "${KUBECONFIG}"; then
        log error "Failed to sync Helm releases"
    fi

    log info "Helm releases synced successfully"
}

function setup_argo_cd() {
    log debug "Setting up Argo CD"

    local -r argo_cd_dir="${ROOT_DIR}/components/argo-system/argo-cd"

    # Check if the Argo CD directory exists
    if [[ ! -d "${argo_cd_dir}" ]]; then
        log error "Directory does not exist" "directory=${argo_cd_dir}"
        return 1
    fi

    # Apply the environment-variables secret from YAML file
    local -r env_vars_file="${ROOT_DIR}/components/common/environment-variables.yaml"

    if [[ ! -f "${env_vars_file}" ]]; then
        log error "File does not exist" "file=${env_vars_file}"
        return 1
    fi

    if envsubst < "${env_vars_file}" | kubectl apply --namespace argo-system -f- &>/dev/null; then
        log info "Environment variables secret applied successfully" "secret=environment-variables"
    else
        log error "Failed to apply environment variables secret" "secret=environment-variables"
    fi

    if ! kustomize build "${argo_cd_dir}" --enable-alpha-plugins --load-restrictor LoadRestrictionsNone | envsubst | kubectl apply -f- &>/dev/null; then
        log error "Failed to apply Argo CD"
    fi

    # Wait for all pods to be 'Ready=True'
    until kubectl wait --for=condition=Ready pods -l "app.kubernetes.io/name=argocd-repo-server" -n argo-system --timeout=10s &>/dev/null; do
        log info "Pods are not available, waiting for pods to be available. Retrying in 10 seconds..."
        sleep 10
    done

    log info "Argo CD applied successfully"
}

# Sync Argo Applications
function sync_argo_apps() {
    log debug "Sync Argo Applications"

    local -r root_application_dir="${ROOT_DIR}/clusters/${CLUSTER_NAME}/apps/argo-system/root-application"

    # Check if the Argo CD directory exists
    if [[ ! -d "${root_application_dir}" ]]; then
        log error "Directory does not exist" "directory=${root_application_dir}"
        return 1
    fi

    if ! kustomize build "${root_application_dir}" --enable-alpha-plugins --load-restrictor LoadRestrictionsNone | kubectl apply -f- &>/dev/null; then
        log error "Failed to apply Root Application"
    fi

    log info "Root Application applied successfully"
}

function main() {
    check_env KUBECONFIG TALOSCONFIG
    check_cli helmfile kubectl kustomize sops talhelper yq

    # Apply resources and Helm releases
    wait_for_nodes
    apply_namespaces
    # apply_sops_secrets
    # apply_crds
    # sync_helm_releases
    # setup_argo_cd
    # sync_argo_apps

    log info "Congrats! The cluster is bootstrapped and Argo is syncing the Git repository"
}

main "$@"
