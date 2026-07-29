---
name: orchestration
description: 'Run a long-lived main conversation that plans, delegates to subagents, and reviews their work. USE FOR: heavier multi-step or living sessions, delegating implementation/research/review to agents, keeping main-loop context lean. DO NOT USE FOR: quick one-off tasks done inline, repo-specific lifecycle steps (project skills cover those).'
---

# Orchestration

For heavier, long-running conversations where the main loop plans, delegates, and judges — and subagents do the bulk work. Written for an Opus 5-class main loop: it delegates readily and verifies its own work on its own, so the guidance below is mostly about restraint, prompt quality, and trust boundaries — not about encouraging delegation or self-checks.

## Main-loop role

Spend main-loop context on decisions: scoping, design, integration, judging results. Push bulk work — broad searches, large reads, sizable implementation — into subagents so their output doesn't flood the conversation that has to stay coherent for hours.

## When to delegate

- **Delegate**: sizable well-specified implementation; independent parallel workstreams; broad exploration/searches where only the conclusion matters.
- **Do directly**: single-file reads, small sequential edits, anything needing judgment that depends on the conversation's accumulated context.
- **Cap fan-out** to what you can meaningfully review — parallel agents you skim-approve are worse than fewer you actually check.
- Parallel subagents only when their work is file-disjoint (or isolated, e.g. separate worktrees).
- Prefer continuing an existing agent (follow-up message) over spawning fresh when its built-up context is the valuable part.

## Delegation prompts

Agents see nothing of the conversation. Every delegation prompt includes:

- The full agreed design and decisions already made — the agent must not re-derive or re-litigate them.
- Pointers to the repo's instruction files (`AGENTS.md`/`CLAUDE.md`) and applicable conventions (commits, style).
- What to run (tests, linters) and hard boundaries (e.g. commit locally only — no push, no PR, nothing outward-facing; flag new dependencies in the report for sign-off rather than treating them as pre-approved).
- The report format, and keep it terse: files changed, decisions it made itself, test results, identifiers (SHAs, paths). Ask for a short factual report — default reports run long.

## Trust boundaries

Verify *delegated* work before building on it: read the diff yourself, re-run the tests. Don't take the report's word for outcomes. When a result fails your gate, take that piece back inline rather than iterating blind through re-briefs. But don't stack blanket "double-check everything" instructions on your own work — the model already self-verifies, and redundant instructions cause over-verification.

## Reviews

Close each meaningful unit of work — an iteration, a phase, a coherent set of changes — with a review before calling it done; skip only trivial or mechanical changes. If the repo or session carries its own review guidance (skills, instruction files, plan-doc conventions), follow that first — what's below is the floor, not a replacement.

Never review work from the conversation that produced it — that context is biased toward approving its own build. Spawn a neutral agent whose entire input is the artifact reference (PR, diff, doc) plus the review instructions; no framing, focus hints, or expected verdict.

## Model and effort choice

- **Suggest escalation (or de-escalation) to the user when the session warrants it.** If the work turns out judgment-heavy or long-horizon — deep architectural planning, gnarly debugging, adversarial review, autonomous overnight runs — recommend raising effort above the default or moving the main loop to the frontier tier (currently Fable-class). Likewise suggest stepping down for routine sessions; don't just silently run at whatever the session started on.
- **Pick each subagent's model deliberately** — don't default-inherit the session model. Mechanical, well-specified work (scaffolds, fixtures, config, sweeps) → Haiku-class; standard implementation and research → Sonnet-class; algorithm-critical or judgment-heavy pieces that can't stay inline → Opus-class. **Never run subagents on the frontier tier (currently Fable-class)**: it costs and weighs on usage limits roughly double Opus-class, runs slower, and Opus-class matches or beats it on much of this work — if the frontier premium is worth paying anywhere, it's in the main loop. The orchestrator's independent verification is what makes the smaller tiers safe.

## Living sessions

- Before an autonomous stretch: confirm scope and batch clarifying questions in ONE round. Then run; interrupt only for scope decisions, destructive or outward-facing actions, and blockers you can't resolve.
- Durable learnings go to versioned docs (instruction files, skills, tickets) as they happen — not chat history, which gets summarized away in long sessions.
- Keep load-bearing state (task lists, decisions, open questions) in files the session can re-read, so the conversation surviving a compaction doesn't lose the plot.
