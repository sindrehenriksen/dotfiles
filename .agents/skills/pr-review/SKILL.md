---
name: pr-review
description: 'Review pull requests. USE FOR: PR review, code review, review comments, pull request feedback, suggest PR comments. DO NOT USE FOR: writing code, fixing bugs, implementing features.'
---
<!-- Claude Code counterpart: .claude/skills/pr-review.md — keep in sync.
     Separate files because Copilot uses directory/SKILL.md convention and
     Claude uses flat .md files with different frontmatter fields. -->

# PR Review

## Tone & Audience

- Assume the author is senior unless told otherwise
- Suggest/ask rather than tell — "worth considering…", "should this…?", "have you thought about…?"
- Don't explain generic concepts they already know — point to the specific code/behavior that's the concern
- Be direct, not formal — skip preamble and filler

## Comment Format

All comments should be in fenced code blocks for easy copy-paste.

### Inline comments

- Place on specific lines/files (GitHub review comments)
- State **where**: file path + line number + brief description of the code at that line
- Keep focused — one concern per comment
- Use backticks for symbol references — no file hyperlinks (e.g. VS Code markdown links)
- When reinforcing an automated reviewer's comment (e.g. Copilot), say "+1" and add your reasoning — don't repeat what it already said

### Overall PR comment

- Brief positive note if warranted (one line, not gushing)
- Lead with the most important design-level question or concern
- Reference inline comments ("a few things inline") rather than duplicating them
- Keep it short — 3-6 sentences typical

## Process

### Phase 1: Gather context

1. Fetch PR metadata (description, comments, review comments, diffs)
2. If the PR branch isn't checked out locally, check it out — or ask the user to do so if there are uncommitted changes. Reading actual files is much better than reviewing from diffs alone.
3. Read the actual changed files on the branch
4. Check for existing review comments (Copilot, other reviewers) — reinforce good ones, skip resolved ones, don't duplicate

### Phase 2: Discussion round

4. Present findings as a conversation — explain concerns, ask questions, flag tradeoffs
5. Classify by severity but don't format as postable comments yet:
   - **Blockers**: bugs, security issues, data loss risks, broken contracts
   - **Should fix**: design issues, missing error handling, doc/code mismatches
   - **Nits**: style, naming, import ordering
   - **Follow-ups**: things worth doing but not blocking this PR
6. Incorporate the user's initial impressions if they shared any when requesting the review
7. Wait for user reaction — they may ask questions, add context, disagree, or confirm concerns. Iterate until alignment.

### Phase 3: Comment drafting

8. Only after discussion, draft postable comments (inline + overall) based on what survived the discussion
9. Present suggested comments and ask user which to post (or whether to adjust)

## What to Look For

- Does the code match what the PR description claims?
- Are there code paths that contradict documentation?
- Are there concurrency, caching, or state-sharing issues?
- Is error handling appropriate at system boundaries?
- Do tests cover the new behavior (not just the happy path)?
- Are there unnecessary dual code paths or dead code?
- Infra changes: parameterization, secrets handling, consistency with existing modules
- Frontend: contract changes visible to external consumers
