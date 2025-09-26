# GitHub Actions Workflows

## PR Webhook Notifications (`pr-webhook.yaml`)

This workflow sends webhook payloads to different URLs based on which cluster is affected by changes in a pull request.

### Features

- **Triggers**: Runs on PR open and pushes to PRs (`pull_request` events: `opened`, `synchronize`)
- **Smart Detection**: Analyzes changed files to determine which clusters are affected
- **Conditional Webhooks**: Sends webhooks only to affected clusters
- **Rich Payload**: Includes full GitHub event data plus cluster-specific information

### Cluster Detection

The workflow detects changes to:

- **cluster01**: Changes in `clusters/cluster01/**` or `components/**`
- **omv**: Changes in `clusters/omv/**` or `components/**`

> Note: Changes to `components/**` affect both clusters since these are shared components.

### Setup

1. **Configure Repository Secrets**: Add the following secrets in your GitHub repository settings:
   - `CLUSTER01_WEBHOOK_URL`: The webhook URL for cluster01 notifications
   - `OMV_WEBHOOK_URL`: The webhook URL for omv cluster notifications

2. **Webhook Payload Structure**: Each webhook receives a JSON payload containing:

   ```json
   {
     "cluster": "cluster01|omv",
     "event_type": "opened|synchronize",
     "github_event": { ... }, // Full GitHub event payload
     "repository": { ... },
     "pull_request": { ... },
     "sender": { ... },
     "changed_files": {
       "cluster_name": "space-separated list of changed files"
     }
   }
   ```

### Security

- Webhook URLs are stored as encrypted GitHub repository secrets
- The workflow includes error handling and won't expose sensitive information
- Each webhook includes a `User-Agent: GitHub-Actions-Webhook` header

### Monitoring

The workflow provides a comprehensive summary in the GitHub Actions interface showing:

- Which clusters were affected
- Whether webhooks were sent successfully, failed, or skipped
- List of changed files per cluster with detailed file listing
- Real-time logging during webhook execution with emojis for easy status identification

### Workflow Structure

The workflow uses a **dedicated shell script** (`scripts/send-webhooks.sh`) for webhook processing that:
- **Modular Design**: Separates webhook logic from workflow configuration
- **Reusable Function**: Can be used independently or from other contexts
- **Comprehensive Logging**: Uses structured logging with visual indicators (✅ success, ❌ failed, ⏭️ skipped)
- **Error Handling**: Proper exit codes and error reporting
- **Testing Support**: Includes dry-run mode for testing without sending actual webhooks

### Script Features

The `send-webhooks.sh` script provides:
- **Help Documentation**: Built-in help with `--help` flag
- **Dry Run Mode**: Test configuration with `--dry-run`
- **Verbose Logging**: Debug output with `--verbose` or `LOG_LEVEL=debug`
- **Flexible Output**: Results to file or stdout
- **Environment Validation**: Checks required dependencies and configuration

### Testing the Script

You can test the webhook script independently:

```bash
# View help and usage
./scripts/send-webhooks.sh --help

# Test with dry run (no actual webhooks sent)
CLUSTER01_WEBHOOK_URL="https://your-webhook-url" \
CLUSTER01_ANY_CHANGED="true" \
CLUSTER01_CHANGED_FILES="test.yaml" \
./scripts/send-webhooks.sh --dry-run --verbose

# Test with actual environment from GitHub Actions
# (set all required environment variables)
./scripts/send-webhooks.sh
```

### Customization

To modify which files trigger webhooks for each cluster, edit the `files_yaml` section in the `Get changed files` step of the workflow.

### Script Location

The webhook logic is now contained in `scripts/send-webhooks.sh`, making it:
- **Maintainable**: Easy to update webhook logic without touching workflow YAML
- **Testable**: Can be run locally with mock data
- **Reusable**: Can be called from other scripts or contexts
- **Debuggable**: Provides detailed logging and error information
