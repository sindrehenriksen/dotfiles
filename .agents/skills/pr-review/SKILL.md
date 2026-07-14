---
name: pr-review
description: 'Review pull requests. USE FOR: PR review, code review, review comments, pull request feedback, suggest PR comments. DO NOT USE FOR: writing code, fixing bugs, implementing features.'
allowed-tools: Read, Grep, Glob, Bash, Agent, WebFetch
---

# PR Review

## Tone & Audience

- Throughout this skill, "author" = the PR author. The user requesting the review is "the reviewer" / "the user". Don't conflate them in summaries or comments.
- **Posted comments are in the reviewer's voice.** Reviews post under the user's GitHub account, so write them in the user's first person — never refer to the user in the third person (not "Sindre and I went through this"; write "I went through this with Claude"). The agent is the third party in posted text, credited via the attribution line and `[agent pass]` tags. Same rule for where the discussion happened: it happened here, in the review session — don't attribute it to another channel ("recording our Slack discussion") that the author could go looking for.
- Never @-mention the PR author — they're notified of review comments automatically, and tagging them on their own PR reads oddly.
- Assume the PR author is senior unless told otherwise
- Suggest/ask rather than tell — "worth considering…", "should this…?", "have you thought about…?"
- When a finding rests on something you couldn't verify exists (a measurement, a comparison run, an agreement), ask whether it exists rather than asserting it doesn't — "has this been compared against X?", not "this is not measured". Your visibility is incomplete; the author may have done it without documenting it.
- Don't explain generic concepts they already know — point to the specific code/behavior that's the concern. Same for repo/process facts every contributor knows (the deploy chain, branch conventions): state the ask without re-explaining the machinery behind it.
- Be direct, not formal — skip preamble and filler

## Orientation

The human reviewer's job is **strategic judgment**. Automated layers — code reviewers (Copilot et al.), security scanners, eval suites, linters, CI — already cover style, tactical bugs, known vulnerabilities, and regressions caught by tests. Don't duplicate them. Spend attention on what only a human (or human+AI pair with full repo context) can weigh: product meaning, architectural direction, security *posture* (not tactical vulns), repo ergonomics for humans and agents, whether strategic test coverage exists where correctness is hard to eyeball.

When in doubt: *could a scanner, linter, or automated reviewer have caught this?* If yes, deprioritize it. If no, that's where your review is valuable.

**Conversation discipline — separate, don't merge.** Structure the user-facing summary into two distinct sections, never intermixed:

1. **Decisions for the user.** Strategic calls only the reviewer can make — the things they should actually spend thought on. Bar is *"does the user have a real decision that isn't already covered by (a) PR-author seniority, (b) existing repo safeguards (infra what-ifs, dev-first deploys, eval gates, AI reviewers, scanners), or (c) graceful failure modes?"* If no, it doesn't go here. A calibrated section (1) is often 0–2 items. A decision here resolves one of three ways: the user settles it in chat (it drops or becomes a settled point), the user owns it outside the review, or — the most common outcome — it goes on the PR as a neutral question to the author, leaving the call to them. Frame each decision so the ask-the-author path is ready to post.

2. **Inline-comment candidates.** Minor things worth nudging the PR author on but not worth the reviewer's strategic attention. Frame as "happy to comment on these inline too — but the focus is above." Items that typically belong here: predictable error-code or status-code mappings that fall out of the feature shape, infra changes covered by what-ifs and staged rollouts, edge-case data loss with graceful degradation (e.g. integrator just sees a missing field), mechanical consequences of an otherwise-correct implementation, small inconsistencies, "probably already aware but worth a double-check" nudges.

The failure mode this prevents: a single bucketed list ("here are the side effects") that puts strategic and minor items at the same visual weight, forcing the reviewer to re-filter. Keep the line between (1) and (2) clean — don't sprinkle minor items into (1) "for completeness." This applies to triage reads (*"looks good?"*, *"any side effects?"*) just as much as to formal Phase 2.

## Comment Structure

**Default structure: one overall summary comment + individual findings as inline comments on specific lines/files.** Specific findings always go inline — don't put detailed findings in the overall comment. Use this structure in both the discussion phase (Phase 2) and the drafting phase (Phase 3): present each finding anchored to a file and line, with severity, so the user can see what will become inline comments.

All comments should be in fenced code blocks for easy copy-paste.

### Source attribution

Always make the source of the review clear so the author can weigh findings by how vetted they are. Three categories of source:

- **User-raised** — concerns the user explicitly flagged before or during the review. Carry the user's full weight; lead with these in the overall comment.
- **Jointly discussed** — findings that surfaced in conversation and were refined together. Have both the user's and the agent's weight behind them.
- **Agent-driven** — findings the agent raised that the user only briefly reviewed (or didn't review). Don't carry the user's settled position; frame explicitly so the author knows.

How to surface attribution:

- **Agent-driven inline comments always carry the `[agent pass]` prefix** — in single-voice reviews too, not only multi-voice ones. A note in the overall comment ("this is a quick agent pass") does not cover the inline bodies; each inline finding the user didn't vet gets tagged individually so the author can weigh it on the spot.
- **Multi-voice review**: tag each finding to a category. Group findings by source in the overall comment (three short blocks) and prefix agent-driven inline bodies with `[agent pass]`.
- **Single-voice review** (purely user-driven or purely agent-driven): say so explicitly at the top of the overall comment — e.g. "this is a careful read by me" or "this is a quick agent pass — push back on anything that doesn't land". Don't omit attribution just because there's only one voice; the author still needs to know what level of vetting applies.

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

Reviews happen in a dedicated git worktree **per review** — **never check out branches in the user's active working dir** (it would disrupt in-progress work). Read-only inspection there (greps, `gh` API calls) is fine, and a small PR reviewable from `gh pr diff` plus targeted greps may not need a worktree at all.

**Naming convention — say what it reviews**, so anyone can tell at a glance what a worktree is for and whether it can be deleted: `<repo>-review-<id>` as a sibling of the active repo, where `<id>` is the ticket id if the branch carries one (e.g. `~/dev/myproject-review-PROJ-123`), else the PR number plus a short slug (`~/dev/myproject-review-pr42-auth-retry`). One worktree per review; concurrent reviews each get their own.

1. Create it detached at `origin/main` from the active repo, then check out the PR branch (strongly preferred — reading actual files beats diffs alone; skip only for trivial PRs where diff view is obviously sufficient):
   ```bash
   git -C <active-repo-path> fetch origin
   git -C <active-repo-path> worktree add --detach ../<repo>-review-<id> origin/main
   cd ../<repo>-review-<id> && gh pr checkout <number>
   ```
2. Copy `.env` from the active repo if the review needs it; install deps (`node_modules`, venv — gitignored, not shared across worktrees) only if you'll actually run code/tests.
3. For main-comparisons during review, use `origin/main` refs — **don't** check out local `main` in the worktree (git would lock it out of the active working dir; same branch can't be checked out in two worktrees).

The worktree lives until the user says the review conversation is done — keep it across re-review rounds; deletion is on the user's go (see Cleanup).

Each agent's trust model for paths outside the invocation cwd is independent. Worktree paths now vary per review, and Claude Code's `permissions.additionalDirectories` takes literal paths only (no globs) — so either trust the worktrees' **common parent directory** once (a trusted dir covers subdirectories created later, so future worktrees are included; e.g. the workspace dir in the repo's `.claude/settings.local.json`), or grant per session with `/add-dir ../<repo>-review-<id>` right after creating the worktree. No grant is needed when the session's cwd is already the worktrees' parent.

### Phase 0: Frame the change

Always run first. Shared picture of what the PR *means* before any findings.

**Pre-Phase-0 fetches.** `gh pr view` (PR metadata) is always required. Also pre-fetch the linked ticket if the PR body is thin, references the ticket for details, or ticket-vs-code alignment would meaningfully affect Phase 0 framing. Skip for clearly self-describing PRs (dep bumps, tooling, trivial chores); Phase 1 still handles those if we proceed deeper.

1. **Plain-language, outcome-focused summary.** 3–5 sentences — what changes for users / consumers / the system / the team. Skip implementation; don't restate the PR description.
2. **Classification** — *purely technical* (refactor, NFR, perf, tooling, pipeline hygiene, security hardening with no posture change) or *has implications* (flag which: product / UX, architectural, security posture, operational / alerting posture, repo ergonomics, stakeholder / contract, compliance, strategic test coverage).

   Classification is the review's load-bearing prediction, not a label — it forecasts whether the reviewer has real decisions to make and how much verification the change needs:
   - *Purely technical* is a **no-behavior-change claim, and must be earned by verifying it**, because silent behavior changes hide exactly here — a dependency-pin jump that flips a default, a docs-only path change that triggers a deploy. Verified clean, these PRs need no reviewer judgment; at most a process gate (e.g. "not yet run on dev"), which resolves as an ask to the author.
   - *Has implications* predicts a non-empty decisions section: each flagged dimension should name the question only the reviewer (or someone they'd consult) can settle — product direction, what wakes a human, what data may be logged, what a contract promises. If a dimension is flagged but no such question exists, the flag is probably wrong.
3. **Context only the human can supply** — where your judgment benefits from things the AI can't see (cross-team impact, external consumer assumptions, in-flight initiatives, product direction).

**Triage mode.** If the user asks a *question about* the PR — *"anything I need to understand?"*, *"is this purely technical?"* — stop after Phase 0, answer it, and ask how to proceed. Offer two paths: full review (Phases 1–3 with discussion), or post approval after a light pass (run Phases 1–3 independently, post anything worth posting inline, approve). Don't hunt for findings until asked. A **"quick review"** request is not triage: it's a full review — every phase, including the finding filter — with compact output. Don't stop after Phase 0 for it.

**Autonomous mode.** If the user says *"proceed to approve"*, *"go ahead and approve"*, *"review + approve"*, or similar — run Phases 1–3 independently and post without pausing for confirmation (i.e. skip Phase 3 step 3). Only come back to the user if a blocker surfaces, a REQUEST_CHANGES decision is in play, the "context only the human can supply" points from Phase 0 genuinely affect whether to approve, or something mechanical about posting is unclear. Otherwise post, report the review URL, and clean up.

### Phase 1: Gather context

1. Fetch PR metadata: `gh pr view <number> --json title,body,comments,reviews`
2. If the PR description (or branch name) references a ticket, fetch it for the original problem statement:
   - Jira (e.g. `PROJ-123`): use the Atlassian MCP `jira_get_issue`
   - GitHub issue (e.g. `#42` or `owner/repo#42`): `gh issue view <number>`
   - If no ticket is linked, skip — don't ask the user to find one

   **Treat ticket attachments and linked draft docs as context, not deliverables.** Helper scripts, scratch notes, working drafts attached to a ticket exist to help the author or future readers understand the work — they drift out of sync. Read for context; don't review them or anchor findings to them. The review target is the deliverable (PR, document under review), not the supporting material.
3. Fetch diffs: `gh pr diff <number>`
4. Fetch inline review comments: `gh api repos/{owner}/{repo}/pulls/{number}/comments`
5. Fetch review summaries: `gh api repos/{owner}/{repo}/pulls/{number}/reviews`
6. Read the actual changed files on the branch (checked out in Setup)
7. Check for existing review comments (Copilot, other reviewers) — reinforce good ones, skip resolved ones, don't duplicate

### Phase 2: Discussion round

1. **Filter candidates against the PR description and ticket** before presenting. Walk each draft finding against what the author already wrote. Three outcomes:
   - **Fully covered** and you agree with the reasoning → drop. Don't make the author repeat themselves.
   - **Partially covered** (author addressed the area but not your specific angle) → keep, but lead the comment by acknowledging what's covered before stating what's still open. Example: a duration-metric concern where the author explained one aspect (sub-minute clamping) but not your aspect (where the timer is captured).
   - **Not mentioned** → raise normally.

   Same rule for chat-section (1), chat-section (2), and inline-only items. Err on the side of dropping over re-raising — a thoughtfully-written description is a signal the author has thought about the area, and re-raising covered points erodes trust in the rest of the review.

   Make the filtering visible. Before step 2, output one line per draft finding: `<finding> → drop | partial | raise — "<quote from description>"` (or `not mentioned`). An invisible walk is too easy to skip under load; on-page verdicts aren't. Drops surface here only; partial/raise flow into step 2.
2. Present findings as a conversation — explain concerns, ask questions, flag tradeoffs. Use the two-section structure from Conversation discipline (decisions for the user, then inline-comment candidates). Severity below is an orthogonal axis.
3. Classify by severity but don't format as postable comments yet:
   - **Blockers**: bugs, security issues, data loss risks, broken contracts
   - **Should fix**: design issues, missing error handling, doc/code mismatches, missing strategic test coverage, missing repo-ergonomics updates that the change requires
   - **Nits**: style, naming, import ordering
   - **Follow-ups**: reserve for things that are genuinely out of scope (separate system, needs design discussion, depends on other work). Default is to suggest fixing now — with AI assistance most fixes are cheap, and deferring fragments the work. Don't reach for "follow-up" just because a finding is minor; nits and should-fixes can be handled in this PR. Ticket and PR scope aren't contracts either — if review surfaces related gaps beyond the stated scope, raise them and leave the in-PR-vs-follow-up call to the author, neutrally framed ("up to you"). Don't prescribe a follow-up just because something wasn't in the original description.

   *Severity ≠ chat placement.* "Nit" here is narrow (style/naming/imports). Chat section (2) is broader and may also include Should-fix-severity items that don't need reviewer judgment (e.g. a missing-test concern already covered by an existing eval gate, a predictable error-code mapping). Severity tells the PR author urgency once posted; chat-section split decides whether a finding reaches the reviewer's attention.
4. Incorporate the user's initial impressions if they shared any when requesting the review
5. Wait for user reaction — they may ask questions, add context, disagree, or confirm concerns. Iterate until alignment.

### Phase 3: Comment drafting

1. Only after discussion, draft postable comments (inline + overall) based on what survived the discussion. Apply source attribution (see Comment Structure → Source attribution) so user-raised, jointly discussed, and agent-driven findings are visibly distinct.
2. Suggest a review type alongside the drafted comments:
   - **APPROVE** — default. Use liberally. The goal is to unblock strategic judgment, not gatekeep correctness — AI reviewers handle correctness gatekeeping. If you have no strategic concern, approve, even if the PR has nits. Approving with should-fix comments is fine — trust the author to address them before merging. Call that expectation out in the overall comment (e.g. "approving — please take a look at the inline should-fixes before merging") so it's explicit rather than implied.
   - **REQUEST_CHANGES** — only for fundamental design issues or critical blockers (security, data loss, broken contracts). If unsure whether something rises to this level, ask.
   - **COMMENT** — when there's no clear approval or block (e.g. need more context, partially reviewed)
3. Present suggested comments + review type and ask user which to post (or whether to adjust)

### Cleanup

1. The worktree is deleted when the user says the review conversation is done — not automatically after posting. After posting the review, ask: "let me know when you're ready to delete the review worktree." On the user's go: `git -C <active-repo-path> worktree remove ../<repo>-review-<id>`, then delete the local PR branch (`git -C <active-repo-path> branch -D <pr-branch>`).
2. When touching a repo's worktrees, glance at `git worktree list` — any `-review-<id>` sibling whose PR is merged/closed is stale; remove it (checking `git status` for stray uncommitted notes first).

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
- **Always return the posted review's link**: `gh api repos/{owner}/{repo}/pulls/{number}/reviews --jq '.[-1].html_url'`

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
