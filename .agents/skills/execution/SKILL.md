---
name: execution
description: 'How work gets executed: delegation as the default, briefing and verifying subagents, and the problem → design → plan → implement → verify phases. USE FOR: any task beyond a quick lookup — implementation, research, design, review, long living sessions. DO NOT USE FOR: repo-specific artifacts and gates (project skills and instruction files cover those).'
---

# Execution

How work runs: what gets delegated, how agents are briefed and checked, and the phases a piece of work moves through. **For open work — anything still needing a shape decided — the `team` skill runs on top of this and is the default; load this alone when the task is already planned and clearly shaped.** Generic mechanics only — it deliberately does not cover a repo's own artifacts, gates or commands, which live in its instruction files and project skills. **If this workspace has its own execution layer, read that too** and apply it on top of this. Written for an Opus 5-class main loop, so most of what follows is restraint, brief quality and trust boundaries — not encouragement to delegate or to self-check.

## Delegate by default

Two reasons, and the order matters. **Legibility first:** the main loop should carry decisions, results and whatever genuinely needs a human, not mechanics — delegate and the person reading along sees headlines and judgement calls instead of diffs and step-by-step detail. **Context economy second, and it is the lesser one:** reading is what spends main-loop context, so pushing it into agents lets a session run far longer before it must be compacted or restarted. A real gain, but a benefit on top, not the point. Investigation and implementation both belong in an agent; what comes back is conclusions, findings and open questions, while the detail behind them — files read, paths ruled out, the reasoning that got there — stays in the agent's thread.

- **Stay inline** for what is cheap to do and expensive to explain: single lookups and reads, one-line edits, and small changes whose correctness depends on context accumulated in this conversation. When the two pull apart, the precedence is: small AND context-dependent stays inline; anything else delegates, including a context-dependent change big enough to produce a diff worth reviewing (brief it with the context it needs).
- **Cap fan-out** to what you can meaningfully review — parallel agents you skim-approve are worse than fewer you actually check.
- **Prefer one agent doing several related things** to several doing one thing each. Every spawn costs a full brief in and a full report out; batching pays that once and lets the agent reuse what it has already loaded.
- **Sequential by default; parallel only when file-disjoint** (or isolated, e.g. separate worktrees), with explicit write territory per agent. Files are not the only shared resource: parallel lanes contend for the machine, and a wall-clock-sensitive gate is what notices — run those while the other lanes are idle, and suspect the machine before the code when a slow test fails alone. **File-disjoint is not sufficient in a shared working tree the moment anything commits.** A pre-commit framework stashes the *whole* unstaged tree — every other lane's in-flight edits with it — runs the hooks, and restores; interrupt that cycle and the other lane's files silently revert to HEAD mid-edit, which reads as the model undoing its own work rather than as a collision. One committer plus one concurrent writer is enough to trigger it, so serializing commits does not fix it. Either no lane commits until all are done, or give each lane its own worktree.
- **Never edit files in a checkout an agent is working in** — not even a doc it isn't touching. Its `git add` sweeps up whatever is dirty, so your write lands inside its commit under its message, and you find out from the log afterwards. Wait for it to finish, or edit somewhere else.
- **A fresh worktree has none of the repo's gitignored local config**, so it usually isn't runnable until that is set up — copy it across (without reading secrets) rather than reading absence as a defect. An agent that finds a file missing there has found what "untracked" means, not a deletion.
- Prefer continuing an existing agent over spawning fresh when its built-up context is the valuable part. Spawn fresh when inherited assumptions are the risk instead — critique, second opinions, anything where the first answer may have been wrong — and say so in the brief ("don't inherit my framing; concluding *keep it as it is* is legitimate"), or it will just agree with you. A *fork* is the sharpest case: it inherits the whole conversation, conclusions and blind spots together, so a fork asked to review reads as a second opinion while being the same one. Reserve forks for work that genuinely continues the thread and would lose something in a re-brief — it also keeps a long session from copying a large context N ways, which is what OOM-kills the process. Between phases the question is sharper than it looks: **a written artifact that a human has reviewed has already externalised the context worth keeping**, so hand it to a fresh agent — continuing mostly preserves the first one's investment in its own output, and a plan only its author can execute isn't a plan. Continue when no artifact and no gate sit between the two pieces of work, or when the exploration itself was the expensive part; continue too when a review finding sends the *same* artifact back for tightening, where re-briefing costs more than it buys.

## Phases

Four questions per unit of work: **problem → design (only when needed) → plan → implement → verify.**

- **Problem** is its own step, not a preamble to design. A request usually arrives as a proposed fix, and taking it at face value smuggles in the assumption that the problem is what it first looked like. State three things and check them with the user: the problem or opportunity in one sentence, what evidence says it is real, and what would be different once it is solved. If any of the three can't be answered, closing that gap is the first piece of work — not the build.
- **Design** answers the *next* question: given the problem, which of several shapes is right. Run it when the shape is genuinely open or the cost of getting it wrong is structural; skip it when the shape is settled. Its output is the decision and its reasoning, written down — not code.
- **Plan** agrees scope before code. Iteration-sized work gets a plan doc the user reviews; a small fix gets a sentence or two. This is where the user's input concentrates: constraints, priorities, taste.
- **Implement** runs autonomously through the agreed scope. Tests first (red) → minimal implementation (green) → refactor; gates green; checkboxes ticked when their tests pass — a checkbox records a fact, not an approval. Tests are specifications, not sacred: when one has wrong expectations, fix the test rather than bending production code around it. When a blocker forces a plan change, update the plan and keep going. Don't ask "continue?"; don't narrate progress. Interrupt only for a scope decision the plan doesn't answer, a destructive or outward-facing action, or a blocker unresolvable from the repo — everything else batches to the end.
- **Verify** re-runs the gates independently, closes with a review, and reports: outcome → evidence → deviations from the plan → batched questions.

**A phase boundary is not automatically a checkpoint.** Ask what the user's answer would actually change: when the next phase is theirs to steer — scope, priorities, taste — stop and show the artifact. When it isn't, carry through into the next phase and show them the result, because a gate that only ever gets approved is a delay charged to the person waiting. Say which boundaries you passed without stopping, so anything they would have commented on can still be picked up; going back a step when they do is cheap and is the process working, while making them press go five times is not.

**This is not a waterfall.** They are questions to keep answered, not stages to march through, and the arrow runs both ways: what is cheap to build informs which problem is worth solving at all; a design pass that measures its options regularly discovers the problem was not what was stated; implementation surfaces constraints that send you back to the design and sometimes to the problem; a review at any gate can reopen an earlier one. Moving backwards when evidence arrives is the process working — not a planning failure to apologise for.

Being allowed to go back is the easy half; **noticing that an assumption broke** is the hard half, because an unstated assumption cannot be contradicted — it just quietly makes everything downstream wrong. So when a step hands off, name in the plan doc or the brief what it is assuming that the next step could disprove. Then, when something small and odd turns up later, check it against that list before explaining it away.

**Four questions at every boundary**, asked out loud rather than left to be noticed — noticing is exactly what stops happening under momentum.

- **What would falsify this, and who would notice?** The assumption list above is the answer; an empty list is itself the finding.
- **Who hasn't been asked whose objection would change the answer?** Not everyone relevant — only the ones who could move the decision.
- **Is this the second or third fix at the same seam?** Make it a lookup rather than an intuition: `git log` the files being touched and read what the earlier fixes there were for. A second patch at one seam is a design (`~/.agents/principles.md`, "Ask what you are compensating for").
- **Has anyone actually used it?** Not "do the gates pass" — has a person or an agent operated the surface end to end. This is the one that never fires on its own.

## Measure it

- **Everything should be measurable**, through logging or metrics. Any mechanism that silently changes what happens — a guard, a cap, a retry, a drop path, a cache, a fallback — ships with the counter that makes it visible. Before merging, ask: if this misbehaved, what number would move, and is anyone emitting it? Full reasoning in `~/.agents/principles.md`, "Log for the debugging you will actually do".
- **Be evidence-driven from the start.** Collect metrics — logged or otherwise, quantitative or qualitative — *before* deciding, rather than reasoning from intuition and measuring afterwards to confirm what you already chose.

## Delegation prompts

Agents see nothing of the conversation. Every delegation prompt includes:

- The full agreed design and decisions already made — the agent must not re-derive or re-litigate them.
- Pointers to the repo's instruction files (`AGENTS.md`/`CLAUDE.md`) and applicable conventions (commits, style).
- What to run (tests, linters) and hard boundaries: the agent commits locally, while pushing, merging and anything else outward-facing stay the main loop's. The standing exception is an agent that has to push in order to deploy or test its change — common enough to grant deliberately rather than treat as a breach. Flag new dependencies in the report for sign-off rather than treating them as pre-approved.
- Environmental gotchas the last agent hit (a stale dev server on a port, a slow gate) — they travel between agents only via the brief.
- The report format, and keep it terse: files changed, decisions it made itself, test results, identifiers (SHAs, paths). Ask for a short factual report — default reports run long.
- **Whether the agent may sub-delegate, and where.** An agent handed a large scope will parallelise it, and by default it will do so inside the checkout you gave it — which is the collision above. Say explicitly: sub-delegate freely for read-only work, never for concurrent writes to one tree.
- **Ask what the brief got wrong.** Briefs carry errors — a stale path, a wrong name, an assumption that doesn't hold. Agents that say so plainly are far more useful than ones that quietly work around it, so make it a named line in the report format rather than hoping it surfaces.
- **Ask for evidence honesty explicitly** ("state plainly if the window gave you nothing"). It works.

## Trust boundaries

Verify *delegated* work before building on it: read the diff yourself, re-run the tests. Don't take the report's word for outcomes. When a result fails your gate, take that piece back inline rather than iterating blind through re-briefs — and treat an agent that repeatedly fails gates as a brief problem or an inline-work signal before it is a model problem.

A green test is not evidence that the test exercised anything. When an agent reports a suite passing, check that the assertion *could* have failed — one that mocks away the thing it names, or returns before reaching it, reports success while doing nothing. It's the failure mode delegation is most prone to, because the report is honest and the number is real.

**Independence of execution is not independence of assumption.** Re-running the gates yourself catches a dishonest report; it cannot catch a premise the code and its tests share, because they were written together and encode the same beliefs. A suite can be green, a red-proof can fail for the right reason, and the whole series can still rest on an invariant the rest of the system contradicts. What catches that is a reader who saw neither the code nor the conversation that produced it, reading the source against what the system actually does elsewhere — which is why the neutral review is not optional once a change is more than mechanical.

**A completion notification can arrive before the agent's last writes land.** Reading the working tree the moment it reports gets a state that is still moving — a file half-written, a temp probe not yet deleted, a change not yet committed. Reporting from that read means telling the user something already untrue, and editing on top of it races the agent in a checkout you were told not to touch. Confirm it has settled first: compare a cheap signal (`git status --porcelain`, a file's content) twice a short interval apart, and only then read or act.

An empty result is not evidence of absence either. A query against logs or telemetry returns nothing when the event never happened, but equally when it fell outside a silent retention window, or a filter was wrong, or the context pointed at the wrong account — none of which raise an error. Before concluding something never ran, establish that the query would have found it.

Verify cheaply, though. For a *claim* rather than a diff, spot-check the load-bearing number or the one file that would falsify it; re-deriving the agent's whole analysis in the main loop spends exactly the context the delegation was meant to save. But don't stack blanket "double-check everything" instructions on your own work — the model already self-verifies, and redundant instructions cause over-verification.

## Verifying model-shaped work

Whenever a model sits inside the product's contract — not the agent building it, the model the product itself calls — the usual gates under-report, in ways that repeat.

- **Live runs beat green suites.** Every prompt or protocol design that passed its unit suite still broke on first live contact in some new way (models mangling long ids, echoing short keys, ignoring language rules). Budget a live-run and eyeball gate into any iteration whose contract involves a model.
- **Verify the signal before gating on it.** Before making behavior depend on a model-produced score, check the live distribution and read the actual scored items — a textbook threshold failed the exact case that mattered until calibration moved it, and reading the items sharpened the prompt itself.
- **Verify against reality, not a proxy.** Measure the exact interaction reported; adjacent-path numbers went green twice while the reported drag stayed broken. Know what emulation can't show (touch feel, fixed-overlay geometry, engine-specific events, system fonts): assert against real obstructions and against the environment's own rendered ground truth — measure, then expect — never a fixed "fits at width X". Where only real hardware can decide, ship the hygiene fix, state the limit, and hand the check back.
- **The user's bug report IS the repro spec.** Turn it into a failing test before fixing (red-proof) and keep it as the regression guard. Fixes shipped without a red-proof recur.
- **E2E determinism is a contract:** three consecutive green runs before shipping suite changes; flakes get root-caused — they have repeatedly exposed real product races — never retried into silence. Root-causing includes ruling out load from a parallel lane, the one cause a retry does "fix" and therefore the one most often mistaken for flakiness. Specs change FORWARD, with the intended semantics itemized in the report.
- **Repeated patching at one seam is evidence about the design** — the trigger and its reasoning are in `~/.agents/principles.md`, "Ask what you are compensating for". Price the structural fix honestly, up to a larger redesign; a third patch stops being the default. Sharpest instance: a fix for a reported behavior failing on device twice — stop tuning, re-derive, and expect the win to be REMOVING the mechanism.

## What reaches the user

- **Never relay a subagent's report verbatim.** Give the conclusion, what it changes, and what needs their input. A report long enough that pasting it feels easier is the signal to summarise harder, not to forward.
- **Say what the user needs in order to decide or to know** — a correction to something you told them earlier, a finding that changes the plan, a choice that is genuinely theirs. Progress narration is none of those.
- **The same applies to anything an agent writes for a third party** — PR descriptions and comments, ticket bodies, chat drafts. An agent narrates the work it just did, so each one posts a progress log that was individually reasonable; several of them turn a PR into a changelog of the session, and the later ones contradict the earlier ones as the branch moves. Don't have agents post their own summaries; have them report to you, and own the end-state framing yourself. If you do delegate the writing, brief the end state rather than the story (the `pr-description` skill carries the writing rules for that surface).

## Commits across a long session

- **Tell agents to commit after each coherent step**, not at the end. Long runs get interrupted, and uncommitted work is lost work — say it in the brief, because saving it all for the end is the default. An agent that owns its checkout writes its own commits: it knows what it changed, which is what an honest commit message needs. Two writers sharing one index is the hazard, not delegated committing.
- **Commit only your own changes.** Stage explicit paths, and while agents are live run `git status` + `git diff --staged` before every commit; after any conflicted stash apply, `git reset` before adding anything. Shared files — lockfiles, generated artifacts, anything under evaluation — are the classic traps.
- **Commit freely while working, tidy before review.** The two only conflict if the tidying never happens: `git commit --fixup=<sha>` as you go, autosquash before the branch is reviewed, `--force-with-lease` to push the rewritten branch.
- **Keep the commits that earn a place in history** — one coherent change, reasoning in the body, the kind someone later runs `git log` to understand. A review finding fixed as its own commit usually qualifies; reviewers read the branch in that order. Fold the artefacts of how the work happened: a format-only commit a hook produced, a typo fix to its own predecessor, a comment corrected two commits later on the same branch. After folding, confirm it changed no content: `git rev-parse HEAD^{tree}` before and after should match.
- **Rewrite only unmerged branches you own.** Never anything already merged, never a branch someone else may have pulled, and `--force-with-lease` over `--force` so a concurrent push fails loudly instead of being clobbered.

## Reviews

Close each meaningful unit of work — an iteration, a phase, a coherent set of changes — with a review before calling it done; skip only trivial or mechanical changes. If the repo or session carries its own review guidance (skills, instruction files, plan-doc conventions), follow that first — what's below is the floor, not a replacement.

Never review work from the conversation that produced it — that context is biased toward approving its own build. Spawn a neutral agent whose entire input is the artifact reference (PR, diff, doc) plus the review instructions; no framing, focus hints, or expected verdict.

On a local working diff, before there is a PR, the `coderabbit` skill can run as an independent second pass beside the neutral agent — an extra reviewer, never a substitute for one.

The neutral agent judges the artifact; the conversation knows what it can't see — where the design felt fragile, which constraints were negotiated, what almost went wrong. Use that context for the complementary pass: decide what else to exercise (targeted tests, evals, checks), run it now, and promote what has lasting value into the suite or CI rather than leaving it one-off.

**What to run is a function of what the change touched**, and the same mapping picks the design lenses at the start — one rule at both ends, so nobody has to remember which review this deserves.

- Correctness is the floor and always runs.
- Untrusted input, authn/authz, secrets, a new boundary → a security pass.
- Deploy, CI, cost, data retention → an infra pass.
- A new seam, or a second implementation of a concept that already exists → an architecture pass.
- Anything a future reader has to navigate → conventions and repo ergonomics.
- A user-facing surface → **two** passes, and they are not the same thing. A **UX review** judges the shape by reasoning: hierarchy, affordance, flow, wording. A **product critic** operates the running thing and reports what actually happened. Only the second finds the clipped popover and the word that reads wrong.
- Prose gets its own pass, and it must be allowed to delete: does this read like a log of events, does something else already say it, can it be shorter.

**The outer loop.** Everything above attaches to a change, and some rot doesn't. Run a step-back pass that examines the product rather than the diff — UX, architecture, infra, CI, plans, docs — sized to whatever has moved since the last one. Drive it by trigger rather than calendar: before a large change, which is the cheapest moment to discover the shape is wrong and the one that never happens on its own; after one lands; and a floor of N iterations so it cannot drift indefinitely.

## Model and effort choice

- **Suggest escalation (or de-escalation) to the user when the session warrants it.** If the work turns out judgment-heavy or long-horizon — deep architectural planning, gnarly debugging, adversarial review, autonomous overnight runs — recommend raising effort above the default or moving the main loop to the frontier tier (currently Fable-class). Likewise suggest stepping down for routine sessions; don't just silently run at whatever the session started on.
- **Pick each subagent's model deliberately** — don't default-inherit the session model. Mechanical, well-specified work (scaffolds, fixtures, config, sweeps) → Haiku-class; standard implementation and research → Sonnet-class; algorithm-critical or judgment-heavy pieces that can't stay inline → Opus-class. **Never run subagents on the frontier tier (currently Fable-class)**: it costs and weighs on usage limits roughly double Opus-class, runs slower, and Opus-class matches or beats it on much of this work — if the frontier premium is worth paying anywhere, it's in the main loop. The independent verification above is what makes the smaller tiers safe.

## Improving the setup

- **Promote or it rots.** Plan docs and result notes are working artifacts for the run. Anything future-load-bearing — semantics, invariants, gotchas, "why not X" — gets promoted into a canonical home (instruction files, reference docs, decision records, code comments) as part of closing the work. Archives are narrative, not retrieval.
- **Fold friction into the setup, in the same run.** When a run hits friction — a git-flow accident, a model tier under-delivering, a test gap that let a regression through, an ambiguous instruction — fold the lesson into the relevant config, docs or instructions before the run ends. Don't accumulate process debt. The same goes for a small defect noticed in passing — a doc claim that is no longer true, a fixture that cannot exercise the thing it exists for, a command that silently does the wrong thing: FIX IT IN THE RUN rather than handing it back as a finding. The test is whether it is obvious and whether it needs a human decision, not whether it was in scope. List these changes at the end of an autonomous run; ask first only when genuinely unsure, sparingly, since docs-only changes are cheap to reverse.
- **Reconsider the autonomy when results keep getting rejected.** If work that ran unattended is work the user sends back at the end review, tighten toward step-wise check-ins for that kind of task rather than re-briefing harder.

## Living sessions

- Before an autonomous stretch: confirm scope and batch clarifying questions in ONE round. Then run; interrupt only for scope decisions, destructive or outward-facing actions, and blockers you can't resolve.
- Durable learnings go to versioned docs (instruction files, skills, tickets) as they happen — not chat history, which gets summarized away in long sessions.
- When a compaction or a fresh session is coming, the `handoff` skill covers the prompt pair that carries the work across — and what belongs on disk instead of in a prompt.
- Keep load-bearing state (task lists, decisions, open questions) in files the session can re-read, so the conversation surviving a compaction doesn't lose the plot. That is also what makes a run interruption-proof: an agent killed mid-run resumes from a short message stating the *disk* state — checkboxes, `git status`, which tests were red — with zero rework. Corollary for research agents: have them write the deliverable file incrementally, never only at the end.
