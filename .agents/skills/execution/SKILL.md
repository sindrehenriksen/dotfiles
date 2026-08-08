---
name: execution
description: 'How work gets executed: delegation as the default, briefing and verifying subagents, and the problem → design → plan → implement → verify phases. USE FOR: any task beyond a quick lookup — implementation, research, design, review, long living sessions. DO NOT USE FOR: repo-specific artifacts and gates (project skills and instruction files cover those).'
---

# Execution

How work runs: what gets delegated, how agents are briefed and checked, and the phases a piece of work moves through. Generic mechanics only — it deliberately does not cover a repo's own artifacts, gates or commands, which live in its instruction files and project skills. **If this workspace has its own execution layer, read that too** and apply it on top of this. Written for an Opus 5-class main loop, so most of what follows is restraint, brief quality and trust boundaries — not encouragement to delegate or to self-check.

## Delegate by default

Two reasons, and the order matters. **Legibility first:** the main loop should carry decisions, results and whatever genuinely needs a human, not mechanics — delegate and the person reading along sees headlines and judgement calls instead of diffs and step-by-step detail. **Context economy second, and it is the lesser one:** reading is what spends main-loop context, so pushing it into agents lets a session run far longer before it must be compacted or restarted. A real gain, but a benefit on top, not the point. Investigation and implementation both belong in an agent; what comes back is conclusions, findings and open questions, while the detail behind them — files read, paths ruled out, the reasoning that got there — stays in the agent's thread.

- **Stay inline** for what is cheap to do and expensive to explain: single lookups and reads, one-line edits, and small changes whose correctness depends on context accumulated in this conversation. When the two pull apart, the precedence is: small AND context-dependent stays inline; anything else delegates, including a context-dependent change big enough to produce a diff worth reviewing (brief it with the context it needs).
- **Cap fan-out** to what you can meaningfully review — parallel agents you skim-approve are worse than fewer you actually check.
- **Prefer one agent doing several related things** to several doing one thing each. Every spawn costs a full brief in and a full report out; batching pays that once and lets the agent reuse what it has already loaded.
- **Sequential by default; parallel only when file-disjoint** (or isolated, e.g. separate worktrees), with explicit write territory per agent. Files are not the only shared resource: parallel lanes contend for the machine, and a wall-clock-sensitive gate is what notices — run those while the other lanes are idle, and suspect the machine before the code when a slow test fails alone.
- **Never edit files in a checkout an agent is working in** — not even a doc it isn't touching. Its `git add` sweeps up whatever is dirty, so your write lands inside its commit under its message, and you find out from the log afterwards. Wait for it to finish, or edit somewhere else.
- Prefer continuing an existing agent over spawning fresh when its built-up context is the valuable part. Spawn fresh when inherited assumptions are the risk instead — critique, second opinions, anything where the first answer may have been wrong — and say so in the brief ("don't inherit my framing; concluding *keep it as it is* is legitimate"), or it will just agree with you.

## Phases

Four questions per unit of work: **problem → design (only when needed) → plan → implement → verify.**

- **Problem** is its own step, not a preamble to design. A request usually arrives as a proposed fix, and taking it at face value smuggles in the assumption that the problem is what it first looked like. State three things and check them with the user: the problem or opportunity in one sentence, what evidence says it is real, and what would be different once it is solved. If any of the three can't be answered, closing that gap is the first piece of work — not the build.
- **Design** answers the *next* question: given the problem, which of several shapes is right. Run it when the shape is genuinely open or the cost of getting it wrong is structural; skip it when the shape is settled. Its output is the decision and its reasoning, written down — not code.
- **Plan** agrees scope before code. Iteration-sized work gets a plan doc the user reviews; a small fix gets a sentence or two. This is where the user's input concentrates: constraints, priorities, taste.
- **Implement** runs autonomously through the agreed scope. Tests first (red) → minimal implementation (green) → refactor; gates green; checkboxes ticked when their tests pass — a checkbox records a fact, not an approval. Tests are specifications, not sacred: when one has wrong expectations, fix the test rather than bending production code around it. When a blocker forces a plan change, update the plan and keep going. Don't ask "continue?"; don't narrate progress. Interrupt only for a scope decision the plan doesn't answer, a destructive or outward-facing action, or a blocker unresolvable from the repo — everything else batches to the end.
- **Verify** re-runs the gates independently, closes with a review, and reports: outcome → evidence → deviations from the plan → batched questions.

**This is not a waterfall.** They are questions to keep answered, not stages to march through, and the arrow runs both ways: what is cheap to build informs which problem is worth solving at all; a design pass that measures its options regularly discovers the problem was not what was stated; implementation surfaces constraints that send you back to the design and sometimes to the problem; a review at any gate can reopen an earlier one. Moving backwards when evidence arrives is the process working — not a planning failure to apologise for.

Being allowed to go back is the easy half; **noticing that an assumption broke** is the hard half, because an unstated assumption cannot be contradicted — it just quietly makes everything downstream wrong. So when a step hands off, name in the plan doc or the brief what it is assuming that the next step could disprove. Then, when something small and odd turns up later, check it against that list before explaining it away.

## Measure it

- **Everything should be measurable**, through logging or metrics. Any mechanism that silently changes what happens — a guard, a cap, a retry, a drop path, a cache, a fallback — ships with the counter that makes it visible. Before merging, ask: if this misbehaved, what number would move, and is anyone emitting it?
- **Be evidence-driven from the start.** Collect metrics — logged or otherwise, quantitative or qualitative — *before* deciding, rather than reasoning from intuition and measuring afterwards to confirm what you already chose.

## Delegation prompts

Agents see nothing of the conversation. Every delegation prompt includes:

- The full agreed design and decisions already made — the agent must not re-derive or re-litigate them.
- Pointers to the repo's instruction files (`AGENTS.md`/`CLAUDE.md`) and applicable conventions (commits, style).
- What to run (tests, linters) and hard boundaries: the agent commits locally, while pushing, merging and anything else outward-facing stay the main loop's. The standing exception is an agent that has to push in order to deploy or test its change — common enough to grant deliberately rather than treat as a breach. Flag new dependencies in the report for sign-off rather than treating them as pre-approved.
- Environmental gotchas the last agent hit (a stale dev server on a port, a slow gate) — they travel between agents only via the brief.
- The report format, and keep it terse: files changed, decisions it made itself, test results, identifiers (SHAs, paths). Ask for a short factual report — default reports run long.
- **Ask what the brief got wrong.** Briefs carry errors — a stale path, a wrong name, an assumption that doesn't hold. Agents that say so plainly are far more useful than ones that quietly work around it, so make it a named line in the report format rather than hoping it surfaces.
- **Ask for evidence honesty explicitly** ("state plainly if the window gave you nothing"). It works.

## Trust boundaries

Verify *delegated* work before building on it: read the diff yourself, re-run the tests. Don't take the report's word for outcomes. When a result fails your gate, take that piece back inline rather than iterating blind through re-briefs — and treat an agent that repeatedly fails gates as a brief problem or an inline-work signal before it is a model problem.

A green test is not evidence that the test exercised anything. When an agent reports a suite passing, check that the assertion *could* have failed — one that mocks away the thing it names, or returns before reaching it, reports success while doing nothing. It's the failure mode delegation is most prone to, because the report is honest and the number is real.

Verify cheaply, though. For a *claim* rather than a diff, spot-check the load-bearing number or the one file that would falsify it; re-deriving the agent's whole analysis in the main loop spends exactly the context the delegation was meant to save. But don't stack blanket "double-check everything" instructions on your own work — the model already self-verifies, and redundant instructions cause over-verification.

## What reaches the user

- **Never relay a subagent's report verbatim.** Give the conclusion, what it changes, and what needs their input. A report long enough that pasting it feels easier is the signal to summarise harder, not to forward.
- **Say what the user needs in order to decide or to know** — a correction to something you told them earlier, a finding that changes the plan, a choice that is genuinely theirs. Progress narration is none of those.

## Commits across a long session

- **Tell agents to commit after each coherent step**, not at the end. Long runs get interrupted, and uncommitted work is lost work — say it in the brief, because saving it all for the end is the default.
- **Commit only your own changes.** Stage explicit paths, and while agents are live run `git status` + `git diff --staged` before every commit; after any conflicted stash apply, `git reset` before adding anything. Shared files — lockfiles, generated artifacts, anything under evaluation — are the classic traps.
- **Commit freely while working, tidy before review.** The two only conflict if the tidying never happens: `git commit --fixup=<sha>` as you go, autosquash before the branch is reviewed, `--force-with-lease` to push the rewritten branch.
- **Keep the commits that earn a place in history** — one coherent change, reasoning in the body, the kind someone later runs `git log` to understand. A review finding fixed as its own commit usually qualifies; reviewers read the branch in that order. Fold the artefacts of how the work happened: a format-only commit a hook produced, a typo fix to its own predecessor, a comment corrected two commits later on the same branch.
- **Rewrite only unmerged branches you own.** Never anything already merged, never a branch someone else may have pulled, and `--force-with-lease` over `--force` so a concurrent push fails loudly instead of being clobbered.

## Reviews

Close each meaningful unit of work — an iteration, a phase, a coherent set of changes — with a review before calling it done; skip only trivial or mechanical changes. If the repo or session carries its own review guidance (skills, instruction files, plan-doc conventions), follow that first — what's below is the floor, not a replacement.

Never review work from the conversation that produced it — that context is biased toward approving its own build. Spawn a neutral agent whose entire input is the artifact reference (PR, diff, doc) plus the review instructions; no framing, focus hints, or expected verdict.

On a code diff, the `coderabbit` skill can run as an independent second pass beside the neutral agent — an extra reviewer, never a substitute for one.

The neutral agent judges the artifact; the conversation knows what it can't see — where the design felt fragile, which constraints were negotiated, what almost went wrong. Use that context for the complementary pass: decide what else to exercise (targeted tests, evals, checks), run it now, and promote what has lasting value into the suite or CI rather than leaving it one-off.

## Model and effort choice

- **Suggest escalation (or de-escalation) to the user when the session warrants it.** If the work turns out judgment-heavy or long-horizon — deep architectural planning, gnarly debugging, adversarial review, autonomous overnight runs — recommend raising effort above the default or moving the main loop to the frontier tier (currently Fable-class). Likewise suggest stepping down for routine sessions; don't just silently run at whatever the session started on.
- **Pick each subagent's model deliberately** — don't default-inherit the session model. Mechanical, well-specified work (scaffolds, fixtures, config, sweeps) → Haiku-class; standard implementation and research → Sonnet-class; algorithm-critical or judgment-heavy pieces that can't stay inline → Opus-class. **Never run subagents on the frontier tier (currently Fable-class)**: it costs and weighs on usage limits roughly double Opus-class, runs slower, and Opus-class matches or beats it on much of this work — if the frontier premium is worth paying anywhere, it's in the main loop. The independent verification above is what makes the smaller tiers safe.

## Living sessions

- Before an autonomous stretch: confirm scope and batch clarifying questions in ONE round. Then run; interrupt only for scope decisions, destructive or outward-facing actions, and blockers you can't resolve.
- Durable learnings go to versioned docs (instruction files, skills, tickets) as they happen — not chat history, which gets summarized away in long sessions.
- Keep load-bearing state (task lists, decisions, open questions) in files the session can re-read, so the conversation surviving a compaction doesn't lose the plot. That is also what makes a run interruption-proof: an agent killed mid-run resumes from a short message stating the *disk* state — checkboxes, `git status`, which tests were red — with zero rework. Corollary for research agents: have them write the deliverable file incrementally, never only at the end.
