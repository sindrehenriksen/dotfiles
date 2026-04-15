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

## Orientation

The human reviewer's job is **strategic judgment**. Automated layers — code reviewers (Copilot et al.), security scanners, eval suites, linters, CI — already cover style, tactical bugs, known vulnerabilities, and regressions caught by tests. Don't duplicate them. Spend attention on what only a human (or human+AI pair with full repo context) can weigh: product meaning, architectural direction, security *posture* (not tactical vulns), repo ergonomics for humans and agents, whether strategic test coverage exists where correctness is hard to eyeball.

When in doubt: *could a scanner, linter, or automated reviewer have caught this?* If yes, deprioritize it. If no, that's where your review is valuable.

**Conversation discipline.** Keep discussion with the user on top-tier findings. Nits and any other tactical concerns that slipped through: compress to a one-line count ("3 nits inline"), don't walk through each. Post them inline if useful to the author — just don't burn the conversation on them.

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

### Phase 0: Frame the change

Always run first. Shared picture of what the PR *means* before any findings.

**Pre-Phase-0 fetches.** `gh pr view` (PR metadata) is always required. Also pre-fetch the linked ticket if the PR body is thin, references the ticket for details, or ticket-vs-code alignment would meaningfully affect Phase 0 framing. Skip for clearly self-describing PRs (dep bumps, tooling, trivial chores); Phase 1 still handles those if we proceed deeper.

1. **Plain-language, outcome-focused summary.** 3–5 sentences — what changes for users / consumers / the system / the team. Skip implementation; don't restate the PR description.
2. **Classification** — *purely technical* (refactor, NFR, perf, tooling, security hardening with no posture change) or *has implications* (flag which: product / UX, architectural, security posture, repo ergonomics, stakeholder / contract, compliance, strategic test coverage).
3. **Context only the human can supply** — where your judgment benefits from things the AI can't see (cross-team impact, external consumer assumptions, in-flight initiatives, product direction).

**Triage mode.** If the user's ask signals they just want a quick read — *"anything I need to understand"*, *"is this purely technical"*, *"just a quick look"* — stop after Phase 0 and ask how to proceed. Offer two paths: full review (Phases 1–3 with discussion), or post approval after a light pass (run Phases 1–3 independently, post anything worth posting inline, approve). Don't hunt for findings until asked.

**Autonomous mode.** If the user says *"proceed to approve"*, *"go ahead and approve"*, *"review + approve"*, or similar — run Phases 1–3 independently and post without pausing for confirmation (i.e. skip Phase 3 step 3). Only come back to the user if a blocker surfaces, a REQUEST_CHANGES decision is in play, the "context only the human can supply" points from Phase 0 genuinely affect whether to approve, or something mechanical about posting is unclear. Otherwise post, report the review URL, and clean up.

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

1. Present findings as a conversation — explain concerns, ask questions, flag tradeoffs. Lead with top-tier (strategic) findings; compress bottom-tier (nits/style) into a one-line count.
2. Classify by severity but don't format as postable comments yet:
   - **Blockers**: bugs, security issues, data loss risks, broken contracts
   - **Should fix**: design issues, missing error handling, doc/code mismatches, missing strategic test coverage, missing repo-ergonomics updates that the change requires
   - **Nits**: style, naming, import ordering
   - **Follow-ups**: reserve for things that are genuinely out of scope (separate system, needs design discussion, depends on other work). Default is to suggest fixing now — with AI assistance most fixes are cheap, and deferring fragments the work. Don't reach for "follow-up" just because a finding is minor; nits and should-fixes can be handled in this PR.
3. Incorporate the user's initial impressions if they shared any when requesting the review
4. Wait for user reaction — they may ask questions, add context, disagree, or confirm concerns. Iterate until alignment.

### Phase 3: Comment drafting

1. Only after discussion, draft postable comments (inline + overall) based on what survived the discussion
2. Suggest a review type alongside the drafted comments:
   - **APPROVE** — default. Use liberally. The goal is to unblock strategic judgment, not gatekeep correctness — AI reviewers handle correctness gatekeeping. If you have no strategic concern, approve, even if the PR has nits. Approving with should-fix comments is fine — trust the author to address them before merging. Call that expectation out in the overall comment (e.g. "approving — please take a look at the inline should-fixes before merging") so it's explicit rather than implied.
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

Grouped by impact tier. Spend reviewing effort proportional to tier — top tier is where human judgment adds value that automated reviewers can't.

### Top tier — human-reviewer-only judgment

- **Product / consumer impact.** What changes for the people or systems using this? Does the observable contract change (API shapes, UI flows, CLI behavior, agent responses, AI outputs)? Breaking vs additive?
- **Architectural direction.** Does this shift how the system is structured, who owns what, or which patterns will scale? Would repeating this approach in five future PRs be good or bad?
- **Security posture** (not tactical vulnerabilities — AI security reviews and scanners cover those). Strategic shifts: new attack surface, changed trust model, compliance implications, secrets / identity boundary shifts, cases where static scanning would classify the code differently than the runtime behaves.
- **Repo ergonomics — including *missing* changes.** Strategic question: does this leave the repo harder or easier to work in — for humans *and* AI agents? Whether instructions, conventions, and guardrails (e.g. `CLAUDE.md`, `AGENTS.md`, rule files, skills, import-linter contracts, pre-commit hooks) stay coherent with the code after this PR. Call out *omissions* as much as additions — a renamed concept whose old name lingers in instructions, a new module without doc/rule updates, or a silently removed guardrail all compound over time. Don't chase every minor inconsistency; flag things that will materially slow future work.
- **Strategic test coverage.** For changes where correctness is hard to eyeball — AI pipelines (evals, deepeval-style regression suites, prompt / model changes), public API contracts (E2E tests), UI flows (integration tests), infra (smoke tests against real resources) — is coverage present and meaningful? Missing or weakened coverage here is a top-tier concern, not a nit: fast-paced iteration on models, prompts, contracts, or shared components *requires* suites that prove improvements don't hide regressions. Also flag the inverse: tests that look thorough but don't actually exercise the changed behavior.
- **Stakeholder / scope.** Does the PR cross team boundaries, touch shared infra, or change contracts with external consumers in ways that need alignment outside this review?
- **Ticket ↔ PR alignment.** If a ticket is linked, does the change address the actual problem described there — or just the narrower interpretation in the PR description? Flag scope mismatches in either direction (PR does less than the ticket asks; PR does more and quietly expands scope).

### Middle tier — worth a quick pass, often already handled

- Does the code match what the PR description claims?
- Contradictions between code and existing documentation.
- Error handling at system boundaries (external APIs, user input, untrusted data).
- Concurrency, caching, or state-sharing issues.
- Unnecessary dual code paths, dead code, incomplete refactors.

### Bottom tier — AI reviewers cover this; minimize effort

- Style, naming, import ordering, docstring nits, micro-optimizations.
- Policy: **+1 automated reviewer findings when right** (add brief reasoning so the note isn't just noise). Don't independently hunt for this tier. If you happen to notice something, post it inline; don't lead discussion with it.
