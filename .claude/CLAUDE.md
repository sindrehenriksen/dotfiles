<!-- User-level Claude Code instructions. Symlinked from ~/dotfiles/.claude/CLAUDE.md to ~/.claude/CLAUDE.md and ~/.claude-work/CLAUDE.md. -->
<!-- Copilot counterpart: copilot-prompts/general.instructions.md + git.instructions.md — partially overlapping content, different structure -->
<!-- Dotfiles-repo-specific rules live in ~/dotfiles/CLAUDE.md (auto-loaded when working in the dotfiles repo). -->

# General Instructions

## Problem-Solving Style

- Don't give up quickly when hitting obstacles — try alternative approaches before concluding something can't be done
- When a tool/approach fails, consider alternatives or ask the user for the missing context directly
- Don't make assumptions — ask for input when uncertain rather than guessing
- Think critically about suggestions before offering them — challenge your own ideas
- Never install, clone, or add third-party packages/tools/MCPs without first confirming the exact source (repo URL, package name) with the user

## Secrets & sensitive files

- Don't read, `cat`, or print the contents of files that may hold secrets or sensitive local config — `.env` files, `.credentials.json`, private keys, local `mise` TOML (`mise.local.toml`) — unless the user explicitly asks. Referencing them by path, sourcing them, or passing them to a tool (e.g. `--env-file`) is fine.
- If you need a value from one, ask the user rather than reading the file.

## Documentation over memory

Don't use memory. Anything worth remembering belongs in transparent, version-controlled docs:

- **Project-level** → project VCS. `AGENTS.md` is the cross-agent default; follow whatever conventions the repo already uses.
- **User-level** → dotfiles (also VCS): this file, `~/dotfiles/.claude/skills/`.

This covers temporary work that spans conversations too (e.g., a project `TODO.md` pruned when items complete). What doesn't survive past the conversation stays in the conversation — don't stash state in memory "just in case"; opaque persistence drifts and rots.

**Narrow exception:** stable, system-specific facts that would feel ceremonial to put in any doc (e.g., "this is a Linux laptop") can live in memory. Threshold: small, machine-bound, useful to recall but not worth a doc entry.

When the system framework suggests saving a memory, route the content to the right tier above instead — or, if it's truly transient, don't persist it.

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
- Skip the body for cosmetic/trivial changes. When a body is warranted, summarise shape and reason — don't duplicate identifiers, paths, or quotes already visible in the diff
- Don't include counts like "3 files" or "5 tests"
- Don't reference temporary artifacts (TODO.md, implementation plans, step numbers) in commit messages
- Always be descriptive about the actual changes, not tracking artifacts
- Defer to any repo-specific commit conventions
- Sign with `Co-Authored-By: Claude <model> <version>` (e.g. `Co-Authored-By: Claude Opus 4.6`). No email, no angle brackets.
- Never push to a remote unless explicitly asked. The user handles pushes themselves.

## Output Formatting

- Don't hard-wrap markdown destined for renderers that wrap natively (GitHub PRs / issues / comments, Slack, Jira, Confluence) — let the UI render at the reader's chosen width. Hard-wrap only for plain-text contexts like commit message bodies.

## Pull Request Descriptions

Use the `pr-description` skill — it has the full guidelines.

## Azure CLI Authentication

When an `az` command fails with an authentication/token error, re-authenticate by running `az login --use-device-code` in the terminal and wait for the user to complete the login flow.

- Do NOT pipe or redirect the output — the device code must be visible to the user immediately.

## CI/CD Debugging

- Use `gh` CLI to fetch CI logs — GitHub Actions URLs return 404 for direct fetches
- Preferred: `gh api repos/{owner}/{repo}/actions/jobs/{job-id}/logs`
- `gh run view --log` often falsely reports runs as "still in progress" — use the API endpoint instead

## Browser Automation

- **Default tool: Playwright MCP** — use for all interactive browser testing, UI verification, and form filling
- Playwright opens a real Chrome window visible to the user — no need for a separate viewer
- `agent-browser` CLI exists as a fallback for skills that only have terminal access, but Playwright MCP is preferred:
  - More reliable click targeting (handles overlapping elements and scroll containers better)
  - JS evaluation is cleaner (no shell quoting friction)
  - Screenshots return inline (no save-to-file round-trip)
  - Fewer tool calls per flow (~30% fewer round-trips)
- Always close the browser when done
