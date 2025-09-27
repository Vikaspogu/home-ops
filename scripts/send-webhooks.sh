#!/usr/bin/env bash

# GitHub PR Webhook Sender
# This script sends webhook notifications to different URLs based on cluster changes

set -Eeuo pipefail

# Get the directory of this script and source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Script version
readonly VERSION="1.0.0"

# Default values
declare -A CHANGED_FILES=()
declare -A CLUSTER_CHANGED=()
RESULTS_FILE=""
DRY_RUN=false
GENERATE_SUMMARY=false
SUMMARY_FILE=""

# Usage function
usage() {
    cat <<EOF
GitHub PR Webhook Sender v${VERSION}

Sends webhook payloads to cluster-specific URLs when changes are detected.

USAGE:
    $(basename "$0") [OPTIONS]

OPTIONS:
    -h, --help              Show this help message
    -d, --dry-run          Simulate webhook sending without actual HTTP calls
    -r, --results-file     File to write results to (default: stdout)
    -s, --summary          Generate GitHub Actions step summary
    --summary-file         File to write GitHub Actions summary to (default: $GITHUB_STEP_SUMMARY)
    -v, --verbose          Enable debug logging

ENVIRONMENT VARIABLES:
    WEBHOOK_URL               Webhook URL to send notifications to
    WEBHOOK_SECRET           Secret token for webhook authentication (optional)
    OMV_CHANGED_FILES         Space-separated list of changed files for omv
    OMV_ANY_CHANGED          'true' if omv has changes

    # GitHub Action Environment Variables (automatically available)
    GITHUB_EVENT_ACTION       GitHub event action (opened, synchronize, etc.)
    GITHUB_REPOSITORY         Repository name
    GITHUB_EVENT_NUMBER       PR number
    PR                        Pull request
    REPO                      Repository
    SENDER                    Sender

    # GitHub Webhook Headers
    X_GITHUB_EVENT            Event type (push, pull_request, etc.)
    X_GITHUB_DELIVERY         Unique delivery ID
    X_HUB_SIGNATURE_256       HMAC signature for verification
    X_GITHUB_HOOK_ID          Hook ID
    X_GITHUB_HOOK_INSTALLATION_TARGET_ID    Hook installation target ID
    X_GITHUB_HOOK_INSTALLATION_TARGET_TYPE  Hook installation target type

EXAMPLES:
    # Send webhooks for detected changes
    $(basename "$0")

    # Dry run to test configuration
    $(basename "$0") --dry-run

    # Generate GitHub Actions summary
    $(basename "$0") --summary

    # Enable debug logging
    LOG_LEVEL=debug $(basename "$0") --verbose

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -d|--dry-run)
                DRY_RUN=true
                log info "Dry run mode enabled"
                shift
                ;;
            -r|--results-file)
                RESULTS_FILE="$2"
                log info "Results will be written to: $RESULTS_FILE"
                shift 2
                ;;
            -s|--summary)
                GENERATE_SUMMARY=true
                SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/tmp/github-step-summary.md}"
                log info "Summary generation enabled, output: $SUMMARY_FILE"
                shift
                ;;
            --summary-file)
                GENERATE_SUMMARY=true
                SUMMARY_FILE="$2"
                log info "Summary will be written to: $SUMMARY_FILE"
                shift 2
                ;;
            -v|--verbose)
                export LOG_LEVEL=debug
                log debug "Debug logging enabled"
                shift
                ;;
            *)
                log error "Unknown option: $1" "use --help for usage"
                ;;
        esac
    done
}

# Load configuration from environment
load_config() {
    log info "Loading configuration from environment"

    # Load changed files
    CHANGED_FILES[omv]="${OMV_CHANGED_FILES:-}"

    # Load change indicators
    CLUSTER_CHANGED[omv]="${OMV_ANY_CHANGED:-false}"

    log debug "Configuration loaded" \
        "webhook_url=${WEBHOOK_URL:0:30}..." \
        "webhook_secret_set=$([[ -n "${WEBHOOK_SECRET:-}" ]] && echo "true" || echo "false")" \
        "omv_changed=${CLUSTER_CHANGED[omv]}"
}

# Create webhook payload for a cluster
create_payload() {
    local cluster="$1"
    local changed_files="$2"

    # Create base payload structure
    local base_payload
    base_payload=$(cat << EOF
{
  "cluster": "${cluster}",
  "action": "${GITHUB_EVENT_ACTION:-opened}",
  "number": ${GITHUB_EVENT_NUMBER:-0},
  "github_webhook_headers": {
    "x_github_event": "${X_GITHUB_EVENT:-}",
    "x_github_delivery": "${X_GITHUB_DELIVERY:-}",
    "x_hub_signature_256": "${X_HUB_SIGNATURE_256:-}",
    "x_github_hook_id": "${X_GITHUB_HOOK_ID:-}",
    "x_github_hook_installation_target_id": "${X_GITHUB_HOOK_INSTALLATION_TARGET_ID:-}",
    "x_github_hook_installation_target_type": "${X_GITHUB_HOOK_INSTALLATION_TARGET_TYPE:-}"
  },
  "changed_files": {
    "${cluster}": "${changed_files}"
  }
}
EOF
)

    # Use jq to merge GitHub objects if available, otherwise create fallback
    if command -v jq >/dev/null 2>&1; then
        # Parse and merge the GitHub objects
        echo "$base_payload" | jq \
            --argjson pr "${PR:-null}" \
            --argjson repo "${REPO:-null}" \
            --argjson sender "${SENDER:-null}" \
            '. + {
                "pull_request": $pr,
                "repository": $repo,
                "sender": $sender
            }'
    else
        # Fallback without jq - create minimal structure
        echo "$base_payload" | sed 's/}$/,
  "pull_request": null,
  "repository": null,
  "sender": null
}/'
    fi
}


# Send webhook to a cluster
send_webhook() {
    local cluster="$1"
    local webhook_url="$2"
    local changed_files="$3"

    if [[ -z "$webhook_url" ]]; then
        log warn "No webhook URL configured for $cluster, skipping" "cluster=$cluster"
        return 2  # Skip status
    fi

    log info "Sending webhook for $cluster cluster" "cluster=$cluster" "files_count=$(echo "$changed_files" | wc -w)"

    local payload
    payload=$(create_payload "$cluster" "$changed_files")

    if [[ "$DRY_RUN" == "true" ]]; then
        log info "DRY RUN: Would send webhook" "cluster=$cluster" "url=${webhook_url:0:30}..."
        log debug "Payload preview" "payload=${payload:0:200}..."
        return 0
    fi

    # Send the webhook
    local http_status
    local curl_headers=(
        -H "Content-Type: application/json"
        -H "User-Agent: GitHub-Actions-Webhook/v${VERSION}"
    )

    # Add webhook secret header if provided
    if [[ -n "${WEBHOOK_SECRET:-}" ]]; then
        curl_headers+=(-H "X-Webhook-Secret: $WEBHOOK_SECRET")
        log debug "Adding webhook secret header" "cluster=$cluster"
    fi

    http_status=$(curl -X POST \
        "${curl_headers[@]}" \
        -d "$payload" \
        "$webhook_url" \
        --silent \
        --show-error \
        --write-out "%{http_code}" \
        --output /dev/null)

    if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        log info "Successfully sent webhook" "cluster=$cluster" "status=$http_status"
        return 0  # Success
    else
        log warn "Webhook failed" "cluster=$cluster" "status=$http_status"
        return 1  # Failed
    fi
}

# Generate GitHub Actions step summary
generate_summary() {
    local results_string="$1"

    if [[ "$GENERATE_SUMMARY" != "true" ]]; then
        log debug "Summary generation not enabled, skipping"
        return 0
    fi

    log info "Generating GitHub Actions step summary" "file=$SUMMARY_FILE"

    # Parse results into an array
    local -A results=()
    for result in $results_string; do
        local cluster=$(echo "$result" | cut -d':' -f1)
        local status=$(echo "$result" | cut -d':' -f2)
        results["$cluster"]="$status"
    done

    # Create summary file
    {
        echo "## Webhook Summary"
        echo ""

        # Process each cluster
        for cluster in omv; do
            local status="${results[$cluster]:-unknown}"
            local changed_env_var="${cluster^^}_ANY_CHANGED"
            local files_env_var="${cluster^^}_CHANGED_FILES"
            local changed="${!changed_env_var:-false}"
            local changed_files="${!files_env_var:-}"

            case $status in
                "success")
                    echo "✅ **$cluster**: Webhook sent successfully"
                    if [[ "$changed" == "true" ]]; then
                        echo "  - Changed files: $changed_files"
                    fi
                    ;;
                "failed")
                    echo "❌ **$cluster**: Webhook failed to send"
                    if [[ "$changed" == "true" ]]; then
                        echo "  - Changed files: $changed_files"
                    fi
                    ;;
                "skipped")
                    echo "⏭️ **$cluster**: No changes detected, webhook skipped"
                    ;;
                *)
                    echo "❓ **$cluster**: Unknown status ($status)"
                    ;;
            esac
            echo ""
        done

        # Add file change overview
        echo "### Changed Files Overview"
        echo ""

        # Show omv files if changed
        if [[ "${OMV_ANY_CHANGED:-false}" == "true" ]]; then
            echo "**omv affected files:**"
            echo '```'
            echo "${OMV_CHANGED_FILES:-}" | tr ' ' '\n'
            echo '```'
        fi

    } > "$SUMMARY_FILE"

    log info "GitHub Actions summary generated" "file=$SUMMARY_FILE"
}

# Process webhooks for all clusters
process_webhooks() {
    local results=()
    local overall_exit_code=0

    log info "Processing webhooks for all clusters"

    for cluster in omv; do
        local changed="${CLUSTER_CHANGED[$cluster]}"
        local changed_files="${CHANGED_FILES[$cluster]}"

        if [[ "$changed" == "true" ]]; then
            log info "Changes detected for $cluster" "cluster=$cluster" "files=$changed_files"

            local status
            if send_webhook "$cluster" "${WEBHOOK_URL}" "$changed_files"; then
                results+=("$cluster:success")
                log info "✅ Webhook sent successfully" "cluster=$cluster"
            elif [[ $? -eq 2 ]]; then
                results+=("$cluster:skipped")
                log info "⏭️ Webhook skipped" "cluster=$cluster"
            else
                results+=("$cluster:failed")
                log warn "❌ Webhook failed" "cluster=$cluster"
                overall_exit_code=1
            fi
        else
            log info "No changes detected, skipping webhook" "cluster=$cluster"
            results+=("$cluster:skipped")
        fi
    done

    # Output results
    local result_string="${results[*]}"
    if [[ -n "$RESULTS_FILE" ]]; then
        echo "webhook_results=$result_string" > "$RESULTS_FILE"
        log info "Results written to file" "file=$RESULTS_FILE"
    else
        echo "webhook_results=$result_string"
    fi

    # Generate summary if requested
    generate_summary "$result_string"

    log info "Webhook processing completed" "results=$result_string"
    return $overall_exit_code
}

# Main function
main() {
    log info "Starting GitHub PR Webhook Sender" "version=$VERSION"

    # Check required dependencies
    check_cli curl jq

    # Parse arguments
    parse_args "$@"

    # Load configuration
    load_config

    # Process webhooks
    if process_webhooks; then
        log info "All webhooks processed successfully"
        exit 0
    else
        log warn "Some webhooks failed to send"
        exit 1
    fi
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
