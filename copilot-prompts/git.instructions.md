---
applyTo: '**'
---
# Git Conventions

## Commit Messages

Before committing:
- Never use `git add -A` or `git add .`
- Check `git status` first, only add relevant files
- Check `git diff` before writing the commit message. For large diffs, focus on relevant parts (e.g. `git diff -- <path>`). If changes are already staged, check `git diff --staged` as well.

When generating commit messages:
- Keep them brief and high-level (under 50 chars when possible)
- Focus on WHAT changed and WHY, not implementation details
- Never include counts like '3 files' or '5 tests'
- Never reference documentation (TODO.md, implementation plans, step numbers)
- Always be descriptive about the actual changes, not tracking artifacts
- Defer to any repo-specific commit conventions

## Pull Request Descriptions

Use the `pr-description` skill — it has the full guidelines.