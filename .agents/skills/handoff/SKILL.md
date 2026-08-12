---
name: handoff
description: 'Prompt pairs that carry work across a context boundary — one to pass with `/compact`, one to kick off after. USE FOR: "two prompts", handoff prompt, prompt to go with /compact, kick-off prompt, running out of context/tokens, splitting remaining work across conversations. DO NOT USE FOR: handing work to a human teammate (share-findings), the summary the harness writes on its own.'
allowed-tools: Read, Grep, Glob, Bash
---

# Handoff

Carrying work across a context boundary. The deliverable is prompts the user pastes — text only, no tool calls beyond checking state. **If this workspace has its own handoff layer, read that too** and apply it on top of this.

**Two prompts for an in-place `/compact` is the default shape.** Anything the user says about the shape overrides it — how many conversations, what to keep or drop, what the next session should do first. Take that as given and don't re-ask; ask only when a detail would change the prompts and can't be inferred.

## Before writing either prompt

- **Confirm nothing is in flight.** Unpushed commits, a running deploy or watcher, live subagents, a dirty worktree, a drafted message not yet sent. A handoff across an unfinished action loses it. Either finish it, or name it in the keep-list as in-flight state *with how to resume from disk* — SHA, run id, which checkboxes are ticked, which tests were red.
- **Put durable content where it belongs first.** Anything that outlives this handoff — analysis, decisions, scope — goes into the ticket, plan doc or instruction file *now*, so the prompt can say "read it" instead of carrying a copy that will rot. The prompt is only for what has no other home.
- If either check turns something up, say so and deal with it before producing prompts.

## Which boundary

- **In-place `/compact`**: the session continues. Two prompts — a keep-list for the compactor, then a kick-off.
- **Fresh session**: there is no compactor to instruct, so one self-contained prompt only. It must name the repo and cwd and pull its own context from disk, the tracker or the PR.
- **Fan-out across conversations**: one keep-list for the surviving session plus one self-contained prompt per new one. Split on context dependence — work carrying accumulated design context stays where that context is, self-contained items move out. State the split and the reasoning; it's a judgement the user may want to overrule.

## Prompt 1 — what goes with `/compact`

Instructions **to the compactor**, not a summary of the session. It replaces a fixed default template whose weakest points are that it preserves every user message at equal weight and describes current work as narrative — so counteract those two specifically.

- **Detail gradient, thin to thick**: the whole arc in a line or two → recent changes → in-flight and open work → what's next. Most of the words belong to the last two.
- **An explicit drop-list**, and it's the part that gets skipped. Name the narratives that dominate the transcript but are finished: concluded investigations, support correspondence, message drafts, deploy tracking, designs that were superseded.
- **Point at sources of truth instead of copying them** — "read VFAI-887 on Cloud rather than relying on memory" survives; a paraphrase competes with the real thing and loses. Copy only what lives nowhere else: exact identifiers (SHAs, run ids, paths, symbol and constant names with their values) and numbers that were expensive to measure.
- **Decisions already settled, each with its reason, marked do-not-relitigate.** Highest-value block in the prompt: without the reason the next turn reopens them, and the default template's every-user-message habit actively feeds that.
- **Decisions still open, as a separate list, marked as needing the user.** An open decision that reads like a settled one gets invented.
- **Gotchas that actually bit us** — environmental traps, a convention that was violated anyway. These travel only in briefs and prompts.
- Facts, not chronology. No "we discussed", no "then I". Quote the user verbatim only where their exact phrasing was load-bearing — a constraint or a rejection.

## Prompt 2 — the kick-off

Written as the user's next message, in their voice, not as a note to self.

- Open by naming the work and the one authoritative thing to read before acting.
- **Point at the process skills and the phase or stage to enter**, rather than restating the process.
- **Block explicitly on what only the user can decide.** Anything an agent could invent a plausible number or scope for and shouldn't becomes "come back to me with a proposal before writing code". This is why the pair exists rather than one prompt.
- **Name how the change gets verified** when the effect is qualitative — otherwise verification silently becomes "tests pass".
- Say what to delegate and what stays in the main loop.
- Carry nothing Prompt 1 already preserves. Overlap means one of the two is wrong. Prompt 1 carries facts; Prompt 2 carries intent, and stays short.

## Delivering

- One fenced block per prompt, labelled and in paste order. Plain text inside the fence — no markdown emphasis, no links; it's going into a composer, not a document. Hard-wrap around 72 columns.
- No commentary inside a fence. Anything worth flagging goes after it, briefly.
- Offer to `pbcopy` the one they need first.
- Then stop. Starting new work after delivering a handoff defeats it.

## Offer it unprompted

At a natural boundary with the context budget getting tight — a phase change, a merged PR, a closed ticket — offer the handoff instead of waiting to be asked. Don't offer it mid-task; the pre-check above would fail anyway.

**Auto-compaction gets no prompt at all.** Standing keep-rules can't be written in the moment, so load-bearing state belongs in a file the session re-reads (see `execution` → Living sessions). A handoff you had to hand-write for state that could have lived on disk is a signal to move it there.
