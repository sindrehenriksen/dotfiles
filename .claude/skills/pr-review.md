---
name: pr-review
description: "Review pull requests. USE FOR: PR review, code review, review comments, pull request feedback, suggest PR comments. DO NOT USE FOR: writing code, fixing bugs, implementing features."
allowed-tools: Read, Grep, Glob, Bash, Agent, WebFetch
---
<!-- Copilot counterpart: .agents/skills/pr-review/SKILL.md — keep in sync.
     Separate files because Copilot uses directory/SKILL.md convention and
     Claude uses flat .md files with different frontmatter fields. -->

# PR Review

## Tone & Audience

- Assume the author is senior unless told otherwise
- Suggest/ask rather than tell — "worth considering…", "should this…?", "have you thought about…?"
- Don't explain generic concepts — point to the specific code/behavior that's the concern
- Be direct, not formal — skip preamble and filler

## Comment Format

All comments should be in fenced code blocks for easy copy-paste.

### Inline comments

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

1. Fetch PR metadata: `gh pr view <number> --json title,body,comments,reviews`
2. Fetch diffs: `gh pr diff <number>`
3. Fetch inline review comments: `gh api repos/{owner}/{repo}/pulls/{number}/comments`
4. Fetch review summaries: `gh api repos/{owner}/{repo}/pulls/{number}/reviews`
5. If the PR branch isn't checked out locally, check it out — or ask the user if there are uncommitted changes. Reading actual files is much better than reviewing from diffs alone.
6. Read the actual changed files on the branch
7. Check for existing review comments — reinforce good ones, skip resolved ones, don't duplicate

### Phase 2: Discussion round

8. Present findings as a conversation — explain concerns, ask questions, flag tradeoffs
9. Classify by severity but don't format as postable comments yet:
   - **Blockers**: bugs, security issues, data loss risks, broken contracts
   - **Should fix**: design issues, missing error handling, doc/code mismatches
   - **Nits**: style, naming, import ordering
   - **Follow-ups**: things worth doing but not blocking this PR
10. Incorporate the user's initial impressions if they shared any
11. Wait for user reaction — iterate until alignment

### Phase 3: Comment drafting

12. Only after discussion, draft postable comments (inline + overall) based on what survived the discussion
13. Present suggested comments and ask user which to post (or whether to adjust)

## Posting Reviews via GitHub API

`gh pr review` only supports `--body` (overall comment) with `--approve`/`--request-changes`/`--comment`. It **cannot** post inline comments. To post an approval (or request-changes) with inline comments, use the REST API directly:

```bash
gh api repos/{owner}/{repo}/pulls/{number}/reviews \
  --method POST --input - <<'JSON'
{
  "commit_id": "<head SHA>",
  "event": "APPROVE",
  "body": "Overall comment here",
  "comments": [
    {
      "path": "src/foo.py",
      "line": 42,
      "side": "RIGHT",
      "body": "Inline comment here"
    }
  ]
}
JSON
```

Key gotchas:
- **Get the head SHA first**: `gh api repos/{owner}/{repo}/pulls/{number} --jq '.head.sha'`
- **Use `--input` with raw JSON**, not `--field` — the `--field` flag can't encode the `comments` array correctly
- **Inline comments can only target lines present in the diff**. If the concern is on an unchanged line, attach the comment to the nearest changed line and reference the actual line number in the body
- **`event`** is one of: `APPROVE`, `REQUEST_CHANGES`, `COMMENT`

## What to Look For

- Does the code match what the PR description claims?
- Are there code paths that contradict documentation?
- Are there concurrency, caching, or state-sharing issues?
- Is error handling appropriate at system boundaries?
- Do tests cover the new behavior (not just the happy path)?
- Are there unnecessary dual code paths or dead code?
- Infra changes: parameterization, secrets handling, consistency with existing modules
- Frontend: contract changes visible to external consumers
