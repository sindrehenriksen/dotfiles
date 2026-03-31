---
name: pr-description
description: 'Write PR descriptions. USE FOR: PR description, write PR body, suggest PR description, draft PR summary. DO NOT USE FOR: PR review (use pr-review), writing code, fixing bugs.'
---
<!-- Claude Code counterpart: .claude/skills/pr-description.md — keep in sync.
     Separate files because Copilot uses directory/SKILL.md convention and
     Claude uses flat .md files with different frontmatter fields. -->

# PR Description

## Process

1. Run `git log main..HEAD --oneline` (or appropriate base branch) to see the commits
2. Read the repo's PR template if available (`.github/pull_request_template.md`)
3. Optionally ask the user for a branch name suggestion too

## Writing Style

- Keep it concise — match depth to the scope of the change
- Adapt or omit template sections to fit the PR; don't fill in sections that add no value
- Don't repeat what's already obvious from commit messages — reference them instead
- Use backticks for file and symbol references — no file hyperlinks (e.g. VS Code markdown links)
- No subjective claims about quality or efficiency
- No line-wrapping / hard-wrapping — let text flow naturally

## Formatting

- Present the entire PR description inside a single fenced code block for easy copy-paste
- If the PR has well-scoped commits that tell a clear story, suggest reviewing one commit at a time in the Reviewer Notes

## Content Guidelines

- **Motivation**: Why the change is needed (issue, vulnerability, user request)
- **Description**: What changed — implementation-level summary, not a file-by-file changelog
- **Skipped/deferred work**: If you intentionally left things out, say so briefly
- **Testing**: How it was verified (test commands, manual steps)
- Omit documentation section if no docs were changed
