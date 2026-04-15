---
name: pr-review
description: 'Review pull requests. USE FOR: PR review, code review, review comments, pull request feedback, suggest PR comments. DO NOT USE FOR: writing code, fixing bugs, implementing features.'
allowed-tools: Read, Grep, Glob, Bash, Agent, WebFetch
---

# PR Review

## Tone & Audience

- Assume the author is senior unless told otherwise
- Suggest/ask rather than tell — "worth considering…", "should this…?", "have you thought about…?"
- Don't explain generic concepts they already know — point to the specific code/behavior that's the concern
- Be direct, not formal — skip preamble and filler

## Comment Structure

**Default structure: one overall summary comment + individual findings as inline comments on specific lines/files.** Specific findings always go inline — don't put detailed findings in the overall comment. Use this structure in both the discussion phase (Phase 2) and the drafting phase (Phase 3): present each finding anchored to a file and line, with severity, so the user can see what will become inline comments.

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
- Don't duplicate or summarize inline findings — the overall comment is a wrapper, not a recap
- Keep it short — 3-6 sentences typical
- End with an attribution line: `_Review co-authored with <agent> <model> <version>._` (e.g. `_Review co-authored with Claude Code Opus 4.6._`)

## Process

### Setup: review worktree

Reviews happen in a dedicated git worktree per repo — **never in the user's active working dir** (branch-switching would disrupt in-progress work). Convention: `<repo>-review` as a sibling of the active repo (e.g. `~/dev/flyt/flytai-api-review` for `~/dev/flyt/flytai-api`).

1. `cd` into `<repo>-review`. If it doesn't exist, create it from the active repo:
   ```bash
   git -C <active-repo-path> worktree add ../<repo>-review origin/main
   ```
   One-time on first use: copy `.env` from the sibling and install deps (`node_modules`, venv, etc. are gitignored and not shared across worktrees).
2. Always start with up-to-date main: `git fetch origin && git switch main && git pull --ff-only`.
3. Check out the PR branch (strongly preferred — reading actual files beats diffs alone): `gh pr checkout <number>`. Skip only for trivial PRs where diff view is obviously sufficient.

Each agent's trust model for paths outside the invocation cwd is independent — configure per-agent to avoid mid-session approval prompts on file ops in the review worktree. For Claude Code: `permissions.additionalDirectories` in `~/.claude/settings.local.json` (see `.claude/CLAUDE.md`).

### Phase 1: Gather context

1. Fetch PR metadata: `gh pr view <number> --json title,body,comments,reviews`
2. If the PR description (or branch name) references a ticket, fetch it for the original problem statement:
   - Jira (e.g. `PROJ-123`): use the Atlassian MCP `jira_get_issue`
   - GitHub issue (e.g. `#42` or `owner/repo#42`): `gh issue view <number>`
   - If no ticket is linked, skip — don't ask the user to find one
3. Fetch diffs: `gh pr diff <number>`
4. Fetch inline review comments: `gh api repos/{owner}/{repo}/pulls/{number}/comments`
5. Fetch review summaries: `gh api repos/{owner}/{repo}/pulls/{number}/reviews`
6. Read the actual changed files on the branch (checked out in Setup)
7. Check for existing review comments (Copilot, other reviewers) — reinforce good ones, skip resolved ones, don't duplicate

### Phase 2: Discussion round

1. Present findings as a conversation — explain concerns, ask questions, flag tradeoffs
2. Classify by severity but don't format as postable comments yet:
   - **Blockers**: bugs, security issues, data loss risks, broken contracts
   - **Should fix**: design issues, missing error handling, doc/code mismatches
   - **Nits**: style, naming, import ordering
   - **Follow-ups**: reserve for things that are genuinely out of scope (separate system, needs design discussion, depends on other work). Default is to suggest fixing now — with AI assistance most fixes are cheap, and deferring fragments the work. Don't reach for "follow-up" just because a finding is minor; nits and should-fixes can be handled in this PR.
3. Incorporate the user's initial impressions if they shared any when requesting the review
4. Wait for user reaction — they may ask questions, add context, disagree, or confirm concerns. Iterate until alignment.

### Phase 3: Comment drafting

1. Only after discussion, draft postable comments (inline + overall) based on what survived the discussion
2. Suggest a review type alongside the drafted comments:
   - **APPROVE** — default. Use liberally so the author can merge when ready. Approving with should-fix comments is fine — trust the author to address them before merging. Call that expectation out in the overall comment (e.g. "approving — please take a look at the inline should-fixes before merging") so it's explicit rather than implied.
   - **REQUEST_CHANGES** — only for fundamental design issues or critical blockers (security, data loss, broken contracts). If unsure whether something rises to this level, ask.
   - **COMMENT** — when there's no clear approval or block (e.g. need more context, partially reviewed)
3. Present suggested comments + review type and ask user which to post (or whether to adjust)

### Cleanup

1. After the review is complete (comments posted or user is done), switch back to main and delete any local branches that were checked out for the review.

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
- If a ticket is linked (Jira, GitHub issue, etc.), does the change actually address the problem described there — not just the narrower interpretation in the PR description? Flag scope mismatches.
- Are there code paths that contradict documentation?
- Are there concurrency, caching, or state-sharing issues?
- Is error handling appropriate at system boundaries?
- Do tests cover the new behavior (not just the happy path)?
- Are there unnecessary dual code paths or dead code?
- Infra changes: parameterization, secrets handling, consistency with existing modules
- Frontend: contract changes visible to external consumers
