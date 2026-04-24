---
applyTo: '**'
---
<!-- Claude Code counterpart: .claude/CLAUDE.md — partially overlapping content, different structure -->
# Dotfiles Repo

This repo manages shell configs, tool settings, and setup scripts. Key entry points:

- `setup.sh` / `setup-visma.sh` — general and Visma-specific setup (MCP servers, credentials, etc.)
- `install_symlinks.sh` — symlinks managed configs into place
- `~/.secrets.env` / `~/.secrets-visma.env` — untracked secrets (chmod 600, `export KEY=VALUE` format); sourced by shell configs and MCP servers via `--env-file`
- Skills live in `.agents/skills/` (single source), symlinked to both `~/.agents/skills/` and `~/.claude/skills/`

Don't search `~` broadly for settings — check this repo and the paths above.

## Auto-Approved Commands

VS Code `chat.tools.terminal.autoApprove` (in User settings) defines which terminal commands are auto-approved vs prompted. Only genuinely safe (read-only, test, build) commands belong in the allow list. If the user asks to add a command, verify it's safe before adding — discuss with the user if there's any risk of destructive side effects or system modification. Keep in sync with the Claude Code `~/.claude/settings.json` permissions list.

# General Instructions

## Problem-Solving Style

- Don't give up quickly when hitting obstacles — try a couple of alternative approaches before concluding something can't be done
- Don't make assumptions — ask for input when uncertain rather than guessing
- When a tool/approach fails, consider alternatives or ask the user for the missing context directly
- Think critically about suggestions before offering them — challenge your own ideas (e.g. "is this a good name?" or "should we fix the root cause instead?")
- Never install, clone, or add third-party packages/tools/MCPs without first confirming the exact source (repo URL, package name) with the user — guessing at sources is a security risk

## Corrections & Judgment

- When corrected, receive it — don't defend or rationalize. But do push back if you believe the user is wrong, with clear reasoning.
- If you were wrong, say so directly. Don't explain why the mistake was understandable.
- When the user chooses a different approach, follow — but it's fine to suggest improvements or flag concerns along the way
- Be transparent about genuine uncertainty — "I'm not sure" is more useful than a confident guess
- Your mistakes cost the user, not you. Act with that awareness — think carefully when it matters, move fast when the task is clear

## Sharing Content Outside VS Code

When producing content intended to be shared outside the editor (commit messages, PR descriptions, Slack messages, emails, etc.):

- Use backticks for file and symbol references — not VS Code markdown file links (`[file.ts](file.ts)`), which don't render outside the editor

## Copyable Content Blocks

When the user asks for output in a single copyable block (e.g. a summary, investigation report, or template):

- Use exactly one fenced code block wrapping the entire content
- Never nest fenced code blocks — use indentation (4 spaces) for embedded code/queries instead of triple-backtick fences

## Azure CLI Authentication

When an `az` command fails with an authentication/token error, re-authenticate by running `az login --use-device-code` in the terminal and wait for the user to complete the device code login flow before retrying the command.

- Do NOT pipe or redirect the output (no `| tail`, `| head`, `2>&1 |`, etc.) — the device code must be visible to the user immediately in the terminal so they can complete the login flow.

## Reviewing Pull Requests

Tips for fetching PR data:

- `github-pull-request_issue_fetch` returns the PR description and issue-level comments — not inline review comments or review summaries
- Review summaries (e.g. Copilot's overall review): `gh api repos/{owner}/{repo}/pulls/{number}/reviews`
- Inline review comments (e.g. code suggestions): `gh api repos/{owner}/{repo}/pulls/{number}/comments`

## Atlassian MCP

- The Atlassian MCP is configured for Jira only (Confluence tools are disabled — auth/VPN issues)
- For Confluence, use the curl-based confluence skill/agent instead
- Default issue type is **Task** (not Story) unless explicitly requested otherwise
- The MCP converts description input from markdown to Jira wiki markup before posting. This means `*text*` becomes italic (not bold). Use markdown-style `**text**` for bold headers when creating issues through the MCP.
- `jira_link_to_epic` returns success but does not actually update the epic link on this Jira instance. To move an issue to a different epic, use `jira_update_issue` with the Epic Link custom field directly: `{"customfield_13061": "VFAI-485"}`. Verify with a follow-up search on `"Epic Link" = <key>`.

## CI/CD Debugging

- Use `gh` CLI to fetch CI logs, not `fetch_webpage` (GitHub Actions URLs return 404 for API fetches)
- Preferred log-fetching: `gh api repos/{owner}/{repo}/actions/jobs/{job-id}/logs`
- `gh run view --log` often reports runs as "still in progress" even when complete — use the API endpoint instead

## Browser Automation

- **Default tool: Playwright MCP** — use for all interactive browser testing, UI verification, and form filling
- Playwright opens a real Chrome window visible to the user — no need for VS Code Simple Browser alongside it
- `agent-browser` CLI exists as a fallback for subagents/skills that only have terminal access, but Playwright MCP is preferred:
  - More reliable click targeting (handles overlapping elements and scroll containers better)
  - JS evaluation is cleaner (no shell quoting friction)
  - Screenshots return inline as images (no save-to-file + view_image round-trip)
  - Fewer tool calls per flow (~30% fewer round-trips)
- Always close the browser when done (`browser_close` / `agent-browser close`)
