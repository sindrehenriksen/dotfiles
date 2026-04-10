# Dotfiles Repo

<!-- Copilot counterpart: copilot-prompts/general.instructions.md + git.instructions.md — partially overlapping content, different structure -->

This repo manages shell configs, tool settings, and setup scripts. Key entry points:

- `setup.sh` / `setup-visma.sh` — general and Visma-specific setup (MCP servers, credentials, etc.)
- `install_symlinks.sh` — symlinks managed configs into place
- `~/.secrets.env` / `~/.secrets-visma.env` — untracked secrets (chmod 600, `export KEY=VALUE` format); sourced by shell configs and MCP servers via `--env-file`
- Skills live in `.agents/skills/` (single source), symlinked to both `~/.agents/skills/` and `~/.claude/skills/`

Don't search `~` broadly for settings — check this repo and the paths above.

## Auto-Approved Commands

`~/.claude/settings.json` (symlinked from this repo) defines which Bash commands are auto-approved vs prompted. Only genuinely safe (read-only, test, build) commands belong in the allow list. If the user asks to add a command, verify it's safe before adding — discuss with the user if there's any risk of destructive side effects or system modification. Keep in sync with the VS Code `chat.tools.terminal.autoApprove` list.

# General Instructions

## Problem-Solving Style

- Don't give up quickly when hitting obstacles — try alternative approaches before concluding something can't be done
- When a tool/approach fails, consider alternatives or ask the user for the missing context directly
- Don't make assumptions — ask for input when uncertain rather than guessing
- Think critically about suggestions before offering them — challenge your own ideas
- Never install, clone, or add third-party packages/tools/MCPs without first confirming the exact source (repo URL, package name) with the user

## Corrections & Judgment

- When corrected, receive it — don't defend or rationalize. But push back if you believe the user is wrong, with clear reasoning.
- When the user chooses a different approach, follow — but it's fine to suggest improvements or flag concerns along the way
- If you were wrong, say so directly. Don't explain why the mistake was understandable.
- Be transparent about genuine uncertainty — "I'm not sure" is more useful than a confident guess
- Your mistakes cost the user, not you. Act with that awareness — think carefully when it matters, move fast when the task is clear.

## Git Conventions

- Prefer staging specific files over `git add -A` or `git add .` — review `git status` first to avoid adding unintended changes
- Check `git diff` (and `git diff --staged` if applicable) before writing the commit message
- Commit message titles: concise, under 50 chars when possible. Body lines: wrap at 72 chars.
- Focus on WHAT changed and WHY, not implementation details
- Don't include counts like "3 files" or "5 tests"
- Don't reference temporary artifacts (TODO.md, implementation plans, step numbers) in commit messages
- Always be descriptive about the actual changes, not tracking artifacts
- Defer to any repo-specific commit conventions
- Sign with `Co-Authored-By: Claude <model> <version>` (e.g. `Co-Authored-By: Claude Opus 4.6`). No email, no angle brackets.

## Pull Request Descriptions

Use the `pr-description` skill — it has the full guidelines.

## Azure CLI Authentication

When an `az` command fails with an authentication/token error, re-authenticate by running `az login --use-device-code` in the terminal and wait for the user to complete the login flow.

- Do NOT pipe or redirect the output — the device code must be visible to the user immediately.

## Atlassian MCP

- The Atlassian MCP is configured for Jira only (Confluence tools are disabled — auth/VPN issues)
- For Confluence, use the curl-based confluence skill instead
- Default issue type is **Task** (not Story) unless explicitly requested otherwise
- The MCP converts description input from markdown to Jira wiki markup before posting. This means `*text*` becomes italic (not bold). Use markdown-style `**text**` for bold headers when creating issues through the MCP.

## CI/CD Debugging

- Use `gh` CLI to fetch CI logs — GitHub Actions URLs return 404 for direct fetches
- Preferred: `gh api repos/{owner}/{repo}/actions/jobs/{job-id}/logs`
- `gh run view --log` often falsely reports runs as "still in progress" — use the API endpoint instead
