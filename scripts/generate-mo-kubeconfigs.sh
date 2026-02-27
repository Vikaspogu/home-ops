#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="${LOG_LEVEL:-info}"

# ── Cluster list ─────────────────────────────────────────────────
# Names used in alert titles / Mo's /etc/kube/<name>
CLUSTER_NAMES=("talos" "omv")

SA_NAME="mo-reader"
SECRET_NAME="mo-reader-token"
SA_NAMESPACE="kube-system"
OP_VAULT="kubernetes"
OUTPUT_DIR="${TMPDIR:-/tmp}/mo-kubeconfigs"

function usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Generate kubeconfig files from the mo-reader ServiceAccount on each cluster
and store them in 1Password.

Options:
  --dry-run       Generate kubeconfigs locally but skip 1Password upload
  --output-dir    Directory for generated files (default: \$TMPDIR/mo-kubeconfigs)
  -h, --help      Show this help message

Prerequisites:
  - Kubeconfig files at ~/.kube/configs/ (used via kubeswitch)
  - mo-reader ServiceAccount + token Secret deployed (via ArgoCD)
  - op CLI authenticated (for 1Password upload)

The script prompts you to switch kubectl context before each cluster.
EOF
    exit 0
}

# ── Parse args ───────────────────────────────────────────────────
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true; shift ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            log error "Unknown option: $1" ;;
    esac
done

function generate_kubeconfig() {
    local cluster_name="$1"
    local output_file="${OUTPUT_DIR}/${cluster_name}"

    log info "Generating kubeconfig" "cluster=${cluster_name}"

    # Prompt user to switch to the right context
    echo ""
    echo "  Switch kubectl to the '${cluster_name}' cluster, then press Enter."
    echo "  (e.g.: kubectx <context-name>)"
    read -r -p "  Ready? "

    # Verify we can reach the cluster
    if ! kubectl get secret "${SECRET_NAME}" -n "${SA_NAMESPACE}" &>/dev/null; then
        log warn "Secret not found — check context or ArgoCD sync" "secret=${SECRET_NAME}" "cluster=${cluster_name}"
        return 1
    fi

    # Extract token (base64-decoded)
    local token
    token=$(kubectl get secret "${SECRET_NAME}" \
        -n "${SA_NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d)

    # Extract CA cert (keep base64-encoded for kubeconfig)
    local ca
    ca=$(kubectl get secret "${SECRET_NAME}" \
        -n "${SA_NAMESPACE}" -o jsonpath='{.data.ca\.crt}')

    # Get API server URL from current context
    local server
    server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

    if [[ -z "${token}" || -z "${ca}" || -z "${server}" ]]; then
        log warn "Failed to extract credentials" "cluster=${cluster_name}"
        return 1
    fi

    # Write kubeconfig
    cat > "${output_file}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${cluster_name}
    cluster:
      server: ${server}
      certificate-authority-data: ${ca}
contexts:
  - name: mo-reader
    context:
      cluster: ${cluster_name}
      user: mo-reader
current-context: mo-reader
users:
  - name: mo-reader
    user:
      token: ${token}
EOF

    log info "Kubeconfig written" "file=${output_file}"

    # Verify the generated kubeconfig works
    if kubectl --kubeconfig "${output_file}" get namespaces &>/dev/null; then
        log info "Kubeconfig verified — read access works" "cluster=${cluster_name}"
    else
        log warn "Kubeconfig verification failed — check RBAC" "cluster=${cluster_name}"
    fi
}

function upload_to_1password() {
    local cluster_name="$1"
    local kubeconfig_file="${OUTPUT_DIR}/${cluster_name}"
    local op_item="${cluster_name}"
    local op_field="mo-kube-config"

    if [[ ! -f "${kubeconfig_file}" ]]; then
        log warn "Kubeconfig file not found, skipping upload" "file=${kubeconfig_file}"
        return 1
    fi

    local kubeconfig_content
    kubeconfig_content=$(cat "${kubeconfig_file}")

    # Add/update the mo-kube-config password field on the existing cluster item
    # Unset Connect env vars — op item edit requires desktop app auth
    log info "Updating 1Password item" "item=${op_item}" "field=${op_field}"
    env -u OP_CONNECT_HOST -u OP_CONNECT_TOKEN \
        op item edit "${op_item}" \
        --vault "${OP_VAULT}" \
        "${op_field}[password]=${kubeconfig_content}"

    log info "Stored in 1Password" "vault=${OP_VAULT}" "item=${op_item}" "field=${op_field}"
}

function cleanup() {
    if [[ -d "${OUTPUT_DIR}" ]]; then
        rm -rf "${OUTPUT_DIR}"
        log debug "Cleaned up temp files" "dir=${OUTPUT_DIR}"
    fi
}

function main() {
    check_cli kubectl
    if [[ "${DRY_RUN}" == "false" ]]; then
        check_cli op
    fi

    mkdir -p "${OUTPUT_DIR}"
    trap cleanup EXIT

    local failed=0

    for cluster_name in "${CLUSTER_NAMES[@]}"; do
        if ! generate_kubeconfig "${cluster_name}"; then
            ((failed++))
            continue
        fi

        if [[ "${DRY_RUN}" == "true" ]]; then
            log info "Dry run — skipping 1Password upload" "cluster=${cluster_name}"
            # Copy to current dir so user can inspect
            cp "${OUTPUT_DIR}/${cluster_name}" "./${cluster_name}.kubeconfig"
            log info "Kubeconfig saved locally" "file=./${cluster_name}.kubeconfig"
        else
            upload_to_1password "${cluster_name}"
        fi
    done

    if [[ ${failed} -gt 0 ]]; then
        log warn "Some clusters failed" "failed=${failed}/${#CLUSTER_NAMES[@]}"
    else
        log info "All kubeconfigs generated successfully" "clusters=${#CLUSTER_NAMES[@]}"
    fi

    if [[ "${DRY_RUN}" == "false" ]]; then
        echo ""
        log info "Next steps:"
        echo "  1. Create a K8s Secret in Mo's cluster from the 1Password documents"
        echo "  2. Mount it into Mo's pod at /etc/kube/ (read-only)"
        echo ""
        echo "  Example using External Secrets + 1Password:"
        echo "    op://kubernetes/talos/mo-kube-config → /etc/kube/talos"
        echo "    op://kubernetes/omv/mo-kube-config   → /etc/kube/omv"
    fi
}

main "$@"
