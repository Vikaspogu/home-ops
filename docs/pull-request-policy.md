# Pull Request Policy

This repository follows a policy that all generated pull requests require human review and explicit merge. No cluster runtime changes are automatically applied.

## Key Points

- **Human Review Required**: Every pull request that is auto-generated must be reviewed by a human before merging.
- **No Automatic Runtime Changes**: Merging a pull request does not automatically trigger any deployment or cluster state change. The change remains purely in version control until manually applied.
- **Manual Approval**: Approval must be given by an authorized team member who confirms that the PR does not introduce unintended changes.
- **Applicability**: This policy applies to all PRs related to the Hermes dispatch canary incident and any future generated PRs.

For more information on the automation process, see the documentation in `docs/incidents/phase2-canary.md`.