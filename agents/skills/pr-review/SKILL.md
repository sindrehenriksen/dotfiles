---
name: pr-review
description: 'Reviewing someone else''s pull request, in any repo: framing what it means, where a human review adds value over the automated layers, severity, tone, attribution, and drafting and posting the review on the user''s go. USE FOR: a shared PR link or number with "let''s review" / "take a look" / "what do you think", a requested-reviewer notification, an escalation routed to the user, writing or posting review comments. DO NOT USE FOR: reviewing your own work, before or after opening a PR (execution, "Reviews"), writing code, fixing bugs, PR descriptions (pr-description). A repo or workspace may layer its own review skill on top of this one: read both, and the repo''s wins on its own mechanics.'
allowed-tools: Read, Grep, Glob, Bash, Agent
---

# PR Review

"The author" is whoever opened the PR; "the user" is the person you are reviewing for, and the review posts under their account.

## Where the value is

Linters, scanners, CI, eval suites and AI reviewers already cover style, tactical bugs, known vulnerabilities and tested regressions. Spend the pass on what they cannot weigh: what changes for users and consumers, architectural direction, shifts in security posture, whether tests exercise the changed behaviour where correctness is hard to eyeball, whether the repo's instructions and docs stay true after the change (missing updates included), and whether the PR solves the problem its ticket describes.

## Read

- **The thread before the diff**: description, linked ticket, existing reviews and inline comments, the author's replies, commits pushed since.
- **Read the files, not only the diff**, in a separate worktree, never by switching branches in the user's checkout: `git fetch origin pull/<n>/head`, then `git worktree add --detach <path> FETCH_HEAD`. Remove the worktree when the user says the review conversation is done.
- **No neutral reviewer needed.** The clean-context rule guards work the session produced; on someone else's PR the context you carry is an asset. Where you delegate the reading (`execution`), brief that context in.
- **Frame first**: a few sentences on what the change means, not a restatement of the description, and whether it is purely technical or has implications. "Purely technical" claims no behaviour change, so verify it rather than assuming it: a version bump that flips a default hides here. A question about the PR ("anything I need to understand?") gets this framing and a question back, not a hunt for findings.
- **Verify what a decision turns on.** A cheap check (running the code, measuring, tracing a call) is what a human pass adds over another automated one.

## Judge

- **Filter against what the author already wrote.** Covered and you agree: drop it. Partly covered: acknowledge that part, then raise the rest. The test before raising anything: would this change what the author does?
- **Severity**: blocker (bugs, security, data loss, broken contracts), should-fix, nit, question. A follow-up is for work genuinely out of scope, not for anything minor: fixes are cheap, so default to this PR and leave the call to the author. Where tests are missing, say whether they belong in this PR or a named follow-up; an unqualified "later" becomes never.
- **Separate what the user must decide from what only needs posting.** In chat, put the few calls only the user can make first, and the inline candidates after, so the user does not re-filter one mixed list. Often there are no decisions at all.
- **On an escalation, answer the question it asks.** Land on a side, give the reasoning, propose the wording or code. "Good point, what do you think?" wastes the round trip.
- **Don't re-decide settled policy in a PR thread.** Cite the repo's recorded position; if the PR shows the position is wrong, that is a change to the record, not a review comment.

## Write

- **Tone**: assume the author is senior. Ask and suggest ("worth considering…", "should this…?"). Where a finding rests on something you could not see (a measurement, an agreement), ask whether it exists rather than asserting it doesn't. Don't explain concepts or repo process they already know. No @-mention: they are notified anyway.
- **Shape**: one short overall comment (the most important point first, a pointer to the inline ones, no recap) and each specific finding inline, one concern per comment, tagged with its severity. Where an automated reviewer already said it, "+1" and your reason.
- **Label who did what.** The user's voice, first person, but never a claim the user did not make. Say in one line which parts are the agent's work (tracing, measuring, searching) and which are the user's judgement, and tag inline findings the user has not vetted (`[agent pass]`), so the author can tell a decision from an unverified trace. End the overall comment with the attribution line the session gives for PR descriptions.
- **Event**: `APPROVE` to unblock; the points raised are the author's to land before merging, with no second round. Any blocker → `REQUEST_CHANGES`. `COMMENT` when it is neither, or the pass was partial.

## Post

Draft the whole review in chat and post only on the user's explicit go; "review and approve" given up front is that go, unless the pass finds a blocker or a call only the user can make; bring those back first. Then post it as one review:

- `gh pr review` cannot carry inline comments. Use `POST /repos/{owner}/{repo}/pulls/{n}/reviews` with `commit_id` (the head SHA), `event`, `body` and `comments[]` (`path`, `line`, `side: RIGHT`), sent with `gh api --input <file>` from a JSON file rather than shell-quoted.
- Every inline anchor must fall inside a diff hunk, or the whole call fails with a 422. For a concern on an unchanged line, anchor on the nearest changed one and name the real line.
- Return the posted review's link.
