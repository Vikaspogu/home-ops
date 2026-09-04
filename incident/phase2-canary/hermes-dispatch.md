# Phase 2 Canary: Hermes Dispatch

**Incident key:** `phase2-canary/herms/dispatch`

## Summary
This canary enables `infra-dispatch` only for the `kubernetes-alert` webhook.

## Desired State
- Only the `kubernetes-alert` webhook receives `infra-dispatch` traffic.
- All other services remain unaffected.

## Pull Request Documentation
Any automatically generated pull requests triggered by this canary **must be reviewed** by humans before merging. These PRs introduce documentation or configuration changes but **do not modify the running cluster**. No runtime changes are requested; the PRs are review‑only artifacts.

## Review Process
1. Human reviewer checks the PR content for correctness.
2. Ensure no unintended cluster state changes are proposed.
3. Approve and merge manually if acceptable.

## Notes
- This PR is intentionally minimal and serves as a record of the desired state.
- Do not merge without explicit approval.