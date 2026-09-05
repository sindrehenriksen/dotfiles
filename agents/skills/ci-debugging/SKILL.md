---
name: ci-debugging
description: 'Debug GitHub Actions failures and stuck PRs with the `gh` CLI. USE FOR: fetching CI or workflow logs, failed and flaky job reruns, a PR that reports BLOCKED or refuses to merge. DO NOT USE FOR: writing workflow files, PR descriptions (pr-description), code review.'
allowed-tools: Bash, Read, Grep
---

# CI/CD Debugging

- Use `gh` CLI to fetch CI logs — GitHub Actions URLs return 404 for direct fetches
- Preferred: `gh api repos/{owner}/{repo}/actions/jobs/{job-id}/logs`
- `gh run view --log` often falsely reports runs as "still in progress" — use the API endpoint instead
- For a flaky/transient job failure, `gh run rerun <run-id> --failed` re-runs only the failed jobs (upstream job outputs persist) — prefer it to re-running the whole workflow or reverting. A run can stay red from the first attempt even after the rerun's jobs pass, so judge by the specific jobs, not the top-line run conclusion.
- An old PR far behind its base can report `mergeStateStatus: BLOCKED` (and `gh pr merge` refuses with "base branch policy prohibits the merge") even with an approval and no failing *required* check — it's just stale. Update/rebase the branch onto its base (`gh pr update-branch <pr>` or a local rebase); don't reach for `--admin`.
