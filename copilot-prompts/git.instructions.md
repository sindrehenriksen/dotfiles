---
applyTo: '**'
---
<!-- Claude Code counterpart: .claude/CLAUDE.md (Git Conventions section) — partially overlapping content -->
# Git Conventions

## Commit Messages

Before committing:
- Prefer staging specific files over `git add -A` or `git add .` — review `git status` first to avoid adding unintended changes
- Check `git diff` before writing the commit message. For large diffs, focus on relevant parts (e.g. `git diff -- <path>`). If changes are already staged, check `git diff --staged` as well.

When generating commit messages:
- Commit message titles: concise, under 50 chars when possible. Body lines: wrap at 72 chars.
- Focus on WHAT changed and WHY, not implementation details
- Don't include counts like '3 files' or '5 tests'
- Don't reference temporary artifacts (TODO.md, implementation plans, step numbers) in commit messages
- Always be descriptive about the actual changes, not tracking artifacts
- Defer to any repo-specific commit conventions
- Sign with `Co-Authored-By: <agent> <model> <version>` (e.g. `Co-Authored-By: Copilot GPT-4o`). No email, no angle brackets.

## Pull Request Descriptions

Use the `pr-description` skill — it has the full guidelines.