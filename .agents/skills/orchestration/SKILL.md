---
name: orchestration
description: 'Run a long-lived main conversation that plans, delegates to subagents, and reviews their work. USE FOR: heavier multi-step or living sessions, delegating implementation/research/review to agents, keeping main-loop context lean. DO NOT USE FOR: quick one-off tasks done inline, repo-specific lifecycle steps (project skills cover those).'
---

# Orchestration

For heavier, long-running conversations where the main loop plans, delegates, and judges — and subagents do the bulk work. Written for an Opus 5-class main loop: it delegates readily and verifies its own work on its own, so the guidance below is mostly about restraint, prompt quality, and trust boundaries — not about encouraging delegation or self-checks.

## Main-loop role

Spend main-loop context on decisions: scoping, design, integration, judging results. Push bulk work — broad searches, large reads, sizable implementation — into subagents so their output doesn't flood the conversation that has to stay coherent for hours.

Main-loop context is the scarce resource, and it is spent reading, not deciding. Investigation and implementation both belong in an agent; what comes back into the main thread is decisions, findings and open questions. The detail behind them — files read, paths ruled out, the reasoning that got there — stays in the agent's thread.

## When to delegate

- **Delegate**: sizable well-specified implementation; independent parallel workstreams; broad exploration/searches where only the conclusion matters.
- **Do directly**: single-file reads, small sequential edits, anything needing judgment that depends on the conversation's accumulated context.
- **Cap fan-out** to what you can meaningfully review — parallel agents you skim-approve are worse than fewer you actually check.
- **Prefer one agent doing several related things** to several agents doing one thing each. Every spawn costs a full brief in and a full report out; batching related work pays that once and lets the agent reuse what it has already loaded.
- Parallel subagents only when their work is file-disjoint (or isolated, e.g. separate worktrees).
- Prefer continuing an existing agent (follow-up message) over spawning fresh when its built-up context is the valuable part.

## Delegation prompts

Agents see nothing of the conversation. Every delegation prompt includes:

- The full agreed design and decisions already made — the agent must not re-derive or re-litigate them.
- Pointers to the repo's instruction files (`AGENTS.md`/`CLAUDE.md`) and applicable conventions (commits, style).
- What to run (tests, linters) and hard boundaries (e.g. commit locally only — no push, no PR, nothing outward-facing; flag new dependencies in the report for sign-off rather than treating them as pre-approved).
- The report format, and keep it terse: files changed, decisions it made itself, test results, identifiers (SHAs, paths). Ask for a short factual report — default reports run long.
- **Ask what the brief got wrong.** Briefs carry errors — a stale path, a wrong name, an assumption that doesn't hold. Agents that say so plainly are far more useful than ones that quietly work around it, so make it a named line in the report format rather than hoping it surfaces.

## Trust boundaries

Verify *delegated* work before building on it: read the diff yourself, re-run the tests. Don't take the report's word for outcomes. When a result fails your gate, take that piece back inline rather than iterating blind through re-briefs.

Verify cheaply, though. For a *claim* rather than a diff, spot-check the load-bearing number or the one file that would falsify it; re-deriving the agent's whole analysis in the main loop spends exactly the context the delegation was meant to save. But don't stack blanket "double-check everything" instructions on your own work — the model already self-verifies, and redundant instructions cause over-verification.

## What reaches the user

- **Never relay a subagent's report verbatim.** Give the conclusion, what it changes, and what needs their input. A report long enough that pasting it feels easier is the signal to summarise harder, not to forward.
- **Say what the user needs in order to decide or to know** — a correction to something you told them earlier, a finding that changes the plan, a choice that is genuinely theirs. Progress narration is none of those. (Interrupt triggers for an autonomous stretch are under Living sessions.)

## Commits across a long session

- **Tell agents to commit after each coherent step**, not at the end. Long runs get interrupted, and uncommitted work is lost work — say it in the brief, because saving it all for the end is the default.
- **Commit freely while working, tidy before review.** The two only conflict if the tidying never happens: `git commit --fixup=<sha>` as you go, autosquash before the branch is reviewed, `--force-with-lease` to push the rewritten branch.
- **Keep the commits that earn a place in history** — one coherent change, reasoning in the body, the kind someone later runs `git log` to understand. A review finding fixed as its own commit usually qualifies; reviewers read the branch in that order. Fold the artefacts of how the work happened: a format-only commit a hook produced, a typo fix to its own predecessor, a comment corrected two commits later on the same branch.
- **Rewrite only unmerged branches you own.** Never anything already merged, never a branch someone else may have pulled, and `--force-with-lease` over `--force` so a concurrent push fails loudly instead of being clobbered.

## Reviews

Close each meaningful unit of work — an iteration, a phase, a coherent set of changes — with a review before calling it done; skip only trivial or mechanical changes. If the repo or session carries its own review guidance (skills, instruction files, plan-doc conventions), follow that first — what's below is the floor, not a replacement.

Never review work from the conversation that produced it — that context is biased toward approving its own build. Spawn a neutral agent whose entire input is the artifact reference (PR, diff, doc) plus the review instructions; no framing, focus hints, or expected verdict.

The neutral agent judges the artifact; the conversation knows what it can't see — where the design felt fragile, which constraints were negotiated, what almost went wrong. Use that context for the complementary pass: decide what else to exercise (targeted tests, evals, checks), run it now, and promote what has lasting value into the suite or CI rather than leaving it one-off.

## Model and effort choice

- **Suggest escalation (or de-escalation) to the user when the session warrants it.** If the work turns out judgment-heavy or long-horizon — deep architectural planning, gnarly debugging, adversarial review, autonomous overnight runs — recommend raising effort above the default or moving the main loop to the frontier tier (currently Fable-class). Likewise suggest stepping down for routine sessions; don't just silently run at whatever the session started on.
- **Pick each subagent's model deliberately** — don't default-inherit the session model. Mechanical, well-specified work (scaffolds, fixtures, config, sweeps) → Haiku-class; standard implementation and research → Sonnet-class; algorithm-critical or judgment-heavy pieces that can't stay inline → Opus-class. **Never run subagents on the frontier tier (currently Fable-class)**: it costs and weighs on usage limits roughly double Opus-class, runs slower, and Opus-class matches or beats it on much of this work — if the frontier premium is worth paying anywhere, it's in the main loop. The orchestrator's independent verification is what makes the smaller tiers safe.

## Living sessions

- Before an autonomous stretch: confirm scope and batch clarifying questions in ONE round. Then run; interrupt only for scope decisions, destructive or outward-facing actions, and blockers you can't resolve.
- Durable learnings go to versioned docs (instruction files, skills, tickets) as they happen — not chat history, which gets summarized away in long sessions.
- Keep load-bearing state (task lists, decisions, open questions) in files the session can re-read, so the conversation surviving a compaction doesn't lose the plot.
