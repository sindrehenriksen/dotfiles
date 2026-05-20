---
name: coderabbit
description: 'Run CodeRabbit CLI for AI code review of local changes. USE ONLY when the user explicitly mentions "coderabbit", "cr review", or "run coderabbit". DO NOT USE FOR: generic PR review or code review (use pr-review instead), reviews of GitHub PRs unless coderabbit is explicitly mentioned.'
allowed-tools: Bash, Read
---

# CodeRabbit CLI

Thin wrapper around the CodeRabbit CLI (`cr`). Free tier with daily rate limits — one-time signup at https://app.coderabbit.ai.

## Bootstrap

If `cr` is missing from PATH, tell the user once and stop:

```
brew install coderabbit
cr auth login
```

Don't run the installer or auth flow yourself — `cr auth login` opens a browser and must be driven interactively by the user.

## Default invocation

Run from inside the git repo. The command is bare `cr` (no `review` subcommand). The typical case is **branch's own commits vs the merge-base against the latest `origin/<base>`** — that base is independent of any local commits the user may have on their local `<base>` (e.g. unpushed chore commits).

Use `--base-commit <SHA>` with the resolved merge-base, not `--base <branch>`:

```
git fetch origin <base>
MB=$(git merge-base HEAD origin/<base>)
cr --prompt-only --type committed --base-commit "$MB"
```

- `--type committed` — only commits on this branch, excluding uncommitted/staged. CLI default is `all`; not what's usually wanted.
- `--base-commit` pins to a specific SHA → unambiguous, sidesteps stale-local-`main` and unclear `--base origin/<base>` semantics.
- `--prompt-only` — minimal agent-oriented output, preferred when you'll be summarizing. Use `--plain` only if the user wants raw CodeRabbit output (non-interactive, human-formatted).
- Base branch defaults to the repo default. Resolve it via `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'` (fallback: `main`).

If unsure about other flags, check `cr --help` once at the start of a session.

## Scope variants

| User intent | `--type` |
|---|---|
| Committed branch changes only (default for this skill) | `committed` |
| Uncommitted only | `uncommitted` |
| Everything (CLI default) | `all` |

## Workflow

1. Verify `cr` is installed; if not, surface the bootstrap message and stop.
2. Resolve `<base>` (default `main` or repo default) unless the user named one.
3. `git fetch origin <base>` so `origin/<base>` is current.
4. Check rebase staleness: compare `git merge-base HEAD origin/<base>` with `git rev-parse origin/<base>`. If they differ, **stop and ask** before running cr — e.g. *"branch is N commits behind `origin/<base>` (`git rev-list --count HEAD..origin/<base>`). Rebase first, or run review against the current merge-base anyway?"* Wait for the user's answer; don't run cr until they choose.
5. Compute `MB=$(git merge-base HEAD origin/<base>)`.
6. Run `cr --prompt-only --type committed --base-commit "$MB"` (swap `--type` if the user asked for a different scope). Reviews typically take 30–90s; let it run.
4. Summarize the findings concisely:
   - Group by severity, then by file
   - Skip nits the user has clearly already addressed in recent commits
   - Don't restate what the diff already shows — call out the concern
   - Quote `file:line` so the user can jump to each finding
5. If the user asked to fix things, propose edits next. Otherwise stop at the summary.

## Don't

- Don't invoke this skill unless the user explicitly named coderabbit / cr.
- Don't blend with the `pr-review` skill — they answer different questions. If the user wants a strategic human-style review on top, they'll ask separately.
- Don't post findings to GitHub. This is local-first by design.
- Don't retry on rate-limit failures — surface the message and let the user decide.
