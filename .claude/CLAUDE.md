<!-- User-level Claude Code instructions. Symlinked from ~/dotfiles/.claude/CLAUDE.md to ~/.claude/CLAUDE.md and ~/.claude-work/CLAUDE.md. -->
<!-- Copilot counterpart: copilot-prompts/general.instructions.md + git.instructions.md — partially overlapping content, different structure -->
<!-- Dotfiles-repo-specific rules live in ~/dotfiles/CLAUDE.md (auto-loaded when working in the dotfiles repo). -->

# General Instructions

## Problem-Solving Style

- Don't give up quickly when hitting obstacles — try alternative approaches before concluding something can't be done
- When a tool/approach fails, consider alternatives or ask the user for the missing context directly
- Don't make assumptions — ask for input when uncertain rather than guessing
- When asking the user a question, write it as plain text in your reply. Don't use the `AskUserQuestion` tool — the user prefers freeform replies, not multiple-choice prompts.
- Think critically about suggestions before offering them — challenge your own ideas
- Never install, clone, or add third-party packages/tools/MCPs without first confirming the exact source (repo URL, package name) with the user

## Confirm before outward-facing or hard-to-undo actions

- Proceed freely when the ask is clear — this isn't about gating routine work. It applies to actions others will see or that are annoying to reverse: posting reviews/comments, creating or transitioning tickets, sending messages, publishing externally.
- If the instruction is ambiguous or we're still discussing/drafting, show the draft and wait for an explicit go before acting.
- An active discussion is not authorization — refining wording or weighing options is not a green light to post.
- Don't infer a new artifact from loose phrasing: "we should track this" isn't "create the ticket." A go-ahead covers only the step discussed, not the next action.

## Dotfiles as source of truth

Most of `~` (shell configs, tool settings, Claude config, skills) is symlinked from `~/dotfiles` via `install_symlinks.sh` — that repo is the source of truth. When looking up "where is X configured," check `~/dotfiles` first rather than searching `~` broadly.

## Check the environment before assuming

Before claiming a tool isn't installed or recommending an install step, check the environment — `$TERM_PROGRAM` (`ghostty`, `iTerm.app`, `Apple_Terminal`, `vscode`), `$SHELL`, `$HOMEBREW_PREFIX`, `uname -m` (`arm64` vs `x86_64`), `which <cmd>`. The session env block is brief; one quick probe beats a guess.

## Secrets & sensitive files

- Don't read, `cat`, or print the contents of files that may hold secrets or sensitive local config — `.env` files, `.credentials.json`, private keys, local `mise` TOML (`mise.local.toml`) — unless the user explicitly asks. Referencing them by path, sourcing them, or passing them to a tool (e.g. `--env-file`) is fine.
- If you need a value from one, ask the user rather than reading the file.

## Documentation over memory

Don't use memory. Anything worth remembering belongs in transparent, version-controlled docs:

- **Project-level** → project VCS. `AGENTS.md` is the cross-agent default; follow whatever conventions the repo already uses.
- **User-level** → dotfiles (also VCS): this file, `~/dotfiles/.agents/skills/`.

This covers temporary work that spans conversations too (e.g., a project `TODO.md` pruned when items complete). What doesn't survive past the conversation stays in the conversation — don't stash state in memory "just in case"; opaque persistence drifts and rots.

**Narrow exception:** facts that are machine-*divergent* — true on this machine but false on another (e.g. package manager, machine-specific hardware quirks) — can't live in dotfiles, since that one repo is shared across machines; these may live in memory. But the bar is high: the session's environment block already states platform/shell/OS (so "this is a Linux laptop" is not exception material — it's already given), and memory loads per-project by cwd, so it rarely earns its keep. Don't rebuild a machine/user profile.

When the system framework suggests saving a memory, route the content to the right tier above instead — or, if it's truly transient, don't persist it.

## Corrections & Judgment

- When corrected, receive it — don't defend or rationalize. But push back if you believe the user is wrong, with clear reasoning.
- When the user chooses a different approach, follow — but it's fine to suggest improvements or flag concerns along the way
- If you were wrong, say so directly. Don't explain why the mistake was understandable.
- Be transparent about genuine uncertainty — "I'm not sure" is more useful than a confident guess
- Your mistakes cost the user, not you. Act with that awareness — think carefully when it matters, move fast when the task is clear.

## Code Comments

- Don't over-comment. If the behavior is obvious from the code, the names, or the diff, skip the comment — narration is noise.
- Comment the non-obvious *why*: rationale, gotchas, invariants, cross-references, "this looks wrong but isn't" cases. Not the *what*.
- Applies to tests too — don't add comments that just restate the assertion.
- Match the surrounding file's existing comment density and style rather than a fixed rule.

## Git Conventions

- Prefer staging specific files over `git add -A` or `git add .` — review `git status` first to avoid adding unintended changes
- When asked to fold changes into an earlier commit, default to `git commit --fixup=<sha>` and let the user rebase — don't rewrite history yourself unless asked. Before any destructive git op (`reset --hard`, force-push, rebase), capture uncommitted work first (stash or `git diff > patch`).
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
- Don't overuse em dashes. They're fine for the occasional genuine parenthetical aside or dramatic break, but reach for a colon, comma, parentheses, or a new sentence where one reads as well or better — especially in list lead-ins (use a colon). The complaint is overuse, not any use.

## Pull Request Descriptions

Use the `pr-description` skill — it has the full guidelines.

## Azure CLI Authentication

When an `az` command fails with an authentication/token error, re-authenticate by running `az login --use-device-code` in the terminal and wait for the user to complete the login flow.

- Do NOT pipe or redirect the output — the device code must be visible to the user immediately.

## CI/CD Debugging

- Use `gh` CLI to fetch CI logs — GitHub Actions URLs return 404 for direct fetches
- Preferred: `gh api repos/{owner}/{repo}/actions/jobs/{job-id}/logs`
- `gh run view --log` often falsely reports runs as "still in progress" — use the API endpoint instead
- For a flaky/transient job failure, `gh run rerun <run-id> --failed` re-runs only the failed jobs (upstream job outputs persist) — prefer it to re-running the whole workflow or reverting. A run can stay red from the first attempt even after the rerun's jobs pass, so judge by the specific jobs, not the top-line run conclusion.
- An old PR far behind its base can report `mergeStateStatus: BLOCKED` (and `gh pr merge` refuses with "base branch policy prohibits the merge") even with an approval and no failing *required* check — it's just stale. Update/rebase the branch onto its base (`gh pr update-branch <pr>` or a local rebase); don't reach for `--admin`.

## Browser Automation

- **Default tool: Playwright MCP** — use for all interactive browser testing, UI verification, and form filling
- Playwright opens a real Chrome window visible to the user — no need for a separate viewer
- `agent-browser` CLI exists as a fallback for skills that only have terminal access, but Playwright MCP is preferred:
  - More reliable click targeting (handles overlapping elements and scroll containers better)
  - JS evaluation is cleaner (no shell quoting friction)
  - Screenshots return inline (no save-to-file round-trip)
  - Fewer tool calls per flow (~30% fewer round-trips)
- Always close the browser when done
