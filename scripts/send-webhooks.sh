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
    PR_TITLE                  PR title
    PR_HTML_URL               PR URL
    PR_STATE                  PR state
    PR_HEAD_REF               PR head reference
    PR_HEAD_SHA               PR head SHA
    PR_BASE_REF               PR base reference
    PR_BASE_SHA               PR base SHA
    SENDER_LOGIN              PR sender login
    SENDER_HTML_URL           PR sender URL
    REPO_HTML_URL             Repository HTML URL

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

    # Use GitHub's standard webhook format
    cat << EOF
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
  "pull_request": {
    "url": "https://api.github.com/repos/${GITHUB_REPOSITORY:-unknown}/pulls/${GITHUB_EVENT_NUMBER:-0}",
    "id": ${PR_ID:-0},
    "node_id": "${PR_NODE_ID:-}",
    "html_url": "${PR_HTML_URL:-}",
    "diff_url": "${PR_HTML_URL:-}.diff",
    "patch_url": "${PR_HTML_URL:-}.patch",
    "issue_url": "https://api.github.com/repos/${GITHUB_REPOSITORY:-unknown}/issues/${GITHUB_EVENT_NUMBER:-0}",
    "number": ${GITHUB_EVENT_NUMBER:-0},
    "state": "${PR_STATE:-open}",
    "locked": ${PR_LOCKED:-false},
    "title": "${PR_TITLE:-}",
    "user": {
      "login": "${SENDER_LOGIN:-}",
      "id": ${SENDER_ID:-0},
      "node_id": "${SENDER_NODE_ID:-}",
      "avatar_url": "${SENDER_AVATAR_URL:-}",
      "gravatar_id": "${SENDER_GRAVATAR_ID:-}",
      "url": "https://api.github.com/users/${SENDER_LOGIN:-unknown}",
      "html_url": "${SENDER_HTML_URL:-}",
      "followers_url": "https://api.github.com/users/${SENDER_LOGIN:-unknown}/followers",
      "following_url": "https://api.github.com/users/${SENDER_LOGIN:-unknown}/following{/other_user}",
      "gists_url": "https://api.github.com/users/${SENDER_LOGIN:-unknown}/gists{/gist_id}",
      "starred_url": "https://api.github.com/users/${SENDER_LOGIN:-unknown}/starred{/owner}{/repo}",
      "subscriptions_url": "https://api.github.com/users/${SENDER_LOGIN:-unknown}/subscriptions",
      "organizations_url": "https://api.github.com/users/${SENDER_LOGIN:-unknown}/orgs",
      "repos_url": "https://api.github.com/users/${SENDER_LOGIN:-unknown}/repos",
      "events_url": "https://api.github.com/users/${SENDER_LOGIN:-unknown}/events{/privacy}",
      "received_events_url": "https://api.github.com/users/${SENDER_LOGIN:-unknown}/received_events",
      "type": "${SENDER_TYPE:-User}",
      "user_view_type": "public",
      "site_admin": ${SENDER_SITE_ADMIN:-false}
    },
    "body": "${PR_BODY:-}",
    "created_at": "${PR_CREATED_AT:-}",
    "updated_at": "${PR_UPDATED_AT:-}",
    "closed_at": ${PR_CLOSED_AT:-null},
    "merged_at": ${PR_MERGED_AT:-null},
    "merge_commit_sha": "${PR_MERGE_COMMIT_SHA:-null}",
    "assignee": ${PR_ASSIGNEE:-null},
    "assignees": [],
    "requested_reviewers": [],
    "requested_teams": [],
    "labels": [],
    "milestone": ${PR_MILESTONE:-null},
    "draft": ${PR_DRAFT:-false},
    "commits_url": "https://api.github.com/repos/${GITHUB_REPOSITORY:-unknown}/pulls/${GITHUB_EVENT_NUMBER:-0}/commits",
    "review_comments_url": "https://api.github.com/repos/${GITHUB_REPOSITORY:-unknown}/pulls/${GITHUB_EVENT_NUMBER:-0}/comments",
    "review_comment_url": "https://api.github.com/repos/${GITHUB_REPOSITORY:-unknown}/pulls/comments{/number}",
    "comments_url": "https://api.github.com/repos/${GITHUB_REPOSITORY:-unknown}/issues/${GITHUB_EVENT_NUMBER:-0}/comments",
    "statuses_url": "https://api.github.com/repos/${GITHUB_REPOSITORY:-unknown}/statuses/${PR_HEAD_SHA:-}",
    "head": {
      "label": "${PR_HEAD_LABEL:-}",
      "ref": "${PR_HEAD_REF:-}",
      "sha": "${PR_HEAD_SHA:-}",
      "user": {
        "login": "${SENDER_LOGIN:-}",
        "id": ${SENDER_ID:-0},
        "node_id": "${SENDER_NODE_ID:-}",
        "avatar_url": "${SENDER_AVATAR_URL:-}",
        "gravatar_id": "${SENDER_GRAVATAR_ID:-}",
        "url": "https://api.github.com/users/${SENDER_LOGIN:-unknown}",
        "html_url": "${SENDER_HTML_URL:-}",
        "type": "${SENDER_TYPE:-User}",
        "user_view_type": "public",
        "site_admin": ${SENDER_SITE_ADMIN:-false}
      },
      "repo": {
        "id": ${REPO_ID:-0},
        "node_id": "${REPO_NODE_ID:-}",
        "name": "${REPO_NAME:-}",
        "full_name": "${GITHUB_REPOSITORY:-unknown}",
        "private": ${REPO_PRIVATE:-false},
        "owner": {
          "login": "${REPO_OWNER_LOGIN:-}",
          "id": ${REPO_OWNER_ID:-0},
          "node_id": "${REPO_OWNER_NODE_ID:-}",
          "avatar_url": "${REPO_OWNER_AVATAR_URL:-}",
          "gravatar_id": "${REPO_OWNER_GRAVATAR_ID:-}",
          "url": "https://api.github.com/users/${REPO_OWNER_LOGIN:-unknown}",
          "html_url": "${REPO_OWNER_HTML_URL:-}",
          "type": "${REPO_OWNER_TYPE:-User}",
          "user_view_type": "public",
          "site_admin": ${REPO_OWNER_SITE_ADMIN:-false}
        },
        "html_url": "${REPO_HTML_URL:-}",
        "description": "${REPO_DESCRIPTION:-}",
        "fork": ${REPO_FORK:-false},
        "url": "https://api.github.com/repos/${GITHUB_REPOSITORY:-unknown}",
        "created_at": "${REPO_CREATED_AT:-}",
        "updated_at": "${REPO_UPDATED_AT:-}",
        "pushed_at": "${REPO_PUSHED_AT:-}",
        "git_url": "git://github.com/${GITHUB_REPOSITORY:-unknown}.git",
        "ssh_url": "git@github.com:${GITHUB_REPOSITORY:-unknown}.git",
        "clone_url": "https://github.com/${GITHUB_REPOSITORY:-unknown}.git",
        "svn_url": "https://github.com/${GITHUB_REPOSITORY:-unknown}",
        "homepage": "${REPO_HOMEPAGE:-}",
        "size": ${REPO_SIZE:-0},
        "stargazers_count": ${REPO_STARGAZERS_COUNT:-0},
        "watchers_count": ${REPO_WATCHERS_COUNT:-0},
        "language": "${REPO_LANGUAGE:-}",
        "has_issues": ${REPO_HAS_ISSUES:-true},
        "has_projects": ${REPO_HAS_PROJECTS:-true},
        "has_wiki": ${REPO_HAS_WIKI:-true},
        "has_pages": ${REPO_HAS_PAGES:-false},
        "has_downloads": ${REPO_HAS_DOWNLOADS:-true},
        "archived": ${REPO_ARCHIVED:-false},
        "disabled": ${REPO_DISABLED:-false},
        "open_issues_count": ${REPO_OPEN_ISSUES_COUNT:-0},
        "license": ${REPO_LICENSE:-null},
        "allow_forking": ${REPO_ALLOW_FORKING:-true},
        "is_template": ${REPO_IS_TEMPLATE:-false},
        "web_commit_signoff_required": ${REPO_WEB_COMMIT_SIGNOFF_REQUIRED:-false},
        "topics": [],
        "visibility": "${REPO_VISIBILITY:-public}",
        "forks": ${REPO_FORKS:-0},
        "open_issues": ${REPO_OPEN_ISSUES:-0},
        "watchers": ${REPO_WATCHERS:-0},
        "default_branch": "${REPO_DEFAULT_BRANCH:-main}"
      }
    },
  "repository": {
    "id": ${REPO_ID:-0},
    "node_id": "${REPO_NODE_ID:-}",
    "name": "${REPO_NAME:-}",
    "full_name": "${GITHUB_REPOSITORY:-unknown}",
    "private": ${REPO_PRIVATE:-false},
    "owner": {
      "login": "${REPO_OWNER_LOGIN:-}",
      "id": ${REPO_OWNER_ID:-0},
      "node_id": "${REPO_OWNER_NODE_ID:-}",
      "avatar_url": "${REPO_OWNER_AVATAR_URL:-}",
      "gravatar_id": "${REPO_OWNER_GRAVATAR_ID:-}",
      "url": "https://api.github.com/users/${REPO_OWNER_LOGIN:-unknown}",
      "html_url": "${REPO_OWNER_HTML_URL:-}",
      "type": "${REPO_OWNER_TYPE:-User}",
      "user_view_type": "public",
      "site_admin": ${REPO_OWNER_SITE_ADMIN:-false}
    }
  },
  "sender": {
    "login": "${SENDER_LOGIN:-}",
    "id": ${SENDER_ID:-0},
    "node_id": "${SENDER_NODE_ID:-}",
    "avatar_url": "${SENDER_AVATAR_URL:-}",
    "gravatar_id": "${SENDER_GRAVATAR_ID:-}",
    "url": "https://api.github.com/users/${SENDER_LOGIN:-unknown}",
  },
  "changed_files": {
    "$cluster": "$changed_files"
  }
}
EOF
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
    check_cli curl

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
