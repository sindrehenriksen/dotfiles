---
name: handoff
description: 'Prompt pairs that carry work across a context boundary — one to pass with `/compact`, one to kick off after. USE FOR: "two prompts", handoff prompt, prompt to go with /compact, kick-off prompt, running out of context/tokens, splitting remaining work across conversations. DO NOT USE FOR: handing work to a human teammate, the summary the harness writes on its own.'
allowed-tools: Read, Grep, Glob, Bash
---

# Handoff

Carrying work across a context boundary. The deliverable is prompts the user pastes — text only, no tool calls beyond checking state. **If this workspace has its own handoff layer, read that too** and apply it on top of this. A session that follows tickets (it has had `[desk-follow]` updates) also carries what the `desk-follow` skill's "Before compacting" section lists.

**Two prompts for an in-place `/compact` is the default shape.** Anything the user says about the shape overrides it — how many conversations, what to keep or drop, what the next session should do first. Take that as given and don't re-ask; ask only when a detail would change the prompts and can't be inferred.

## Before writing either prompt

- **Make what's moving findable, rather than winding it down.** Unpushed commits, a dirty worktree, a deploy, a watcher, a running agent — these carry across the boundary or can be started again, so the keep-list names them instead: how to resume from disk (SHA, run id, which checkboxes are ticked, which tests were red), and for anything still running, what it is doing and what to do with its result when it lands — a live subagent, for instance, keeps working through the compaction and reports into the new context, which needs to know what to expect from it. After an in-place compaction the worktrees the session or its subagents acted in, their dirty files and unpushed commits, and the background agents still running are read back from disk (see the end of this skill), so the keep-list need not copy those; it still says what each is for and what to do with an agent's result. What a boundary does lose is whatever exists nowhere but the conversation — an unsent draft, a half-applied write with no record elsewhere — so finish that first.
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
- **Point at sources of truth instead of copying them** — "read the ticket in the tracker rather than relying on memory" survives; a paraphrase competes with the real thing and loses. Copy only what lives nowhere else: exact identifiers (SHAs, run ids, paths, symbol and constant names with their values) and numbers that were expensive to measure.
- **Decisions already settled, each with its reason, marked do-not-relitigate.** Highest-value block in the prompt: without the reason the next turn reopens them, and the default template's every-user-message habit actively feeds that.
- **Decisions still open, as a separate list, marked as needing the user.** An open decision that reads like a settled one gets invented.
- **Every instruction the user gave, with its scope**: what a go covered and what it did not, so a go for one step does not come back as a standing permission.
- **Gotchas that actually bit us** — environmental traps, a convention that was violated anyway. These travel only in briefs and prompts.
- Facts, not chronology. No "we discussed", no "then I". Quote the user verbatim only where their exact phrasing was load-bearing — a constraint or a rejection.

## Prompt 2 — the kick-off

Written as the user's next message, in their voice, not as a note to self.

- Open by naming the work and the one authoritative thing to read before acting.
- **Everything still open, not only what is next**: the remaining steps, parked threads, follow-ups promised to the user or to another session, a line each. What the kick-off leaves out is easily forgotten by the user and the session alike.
- **What is specific to this session**: its standing gos and their limits, the conventions it settled into, the other sessions it works alongside.
- **Point at the process skills and the phase or stage to enter**, rather than restating the process.
- **Block explicitly on what only the user can decide.** Anything an agent could invent a plausible number or scope for and shouldn't becomes "come back to me with a proposal before writing code". This is why the pair exists rather than one prompt.
- **Name how the change gets verified** when the effect is qualitative — otherwise verification silently becomes "tests pass".
- Say what to delegate and what stays in the main loop.
- Carry nothing Prompt 1 already preserves. Overlap means one of the two is wrong. Prompt 1 carries facts; Prompt 2 carries intent and the open items, a line each, with the detail left to Prompt 1.
- **It is the prompt the user reads.** Prompt 1 tends to get skimmed, so what the user would want to catch has to be visible here: what the next session may do without asking, and what it must bring back. That is intent, so it is no overlap.

## Delivering

- One fenced block per prompt, labelled and in paste order. Plain text inside the fence — no markdown emphasis, no links; it's going into a composer, not a document. Hard-wrap around 72 columns.
- No commentary inside a fence. Anything worth flagging goes after it, briefly.
- Offer to `pbcopy` the one they need first.
- Then stop. Starting new work after delivering a handoff defeats it.

## Offer it unprompted

At a natural boundary with the context budget getting tight — a phase change, a merged PR, a closed ticket — offer the handoff instead of waiting to be asked. Don't offer it mid-task; the pre-check above would fail anyway.

**A compaction nobody prompted** (an automatic or idle one, or a bare `/compact`) gets this skill's Prompt 1 and Prompt 2 sections through a `PreCompact` hook (`claude/hooks/compact-handoff.sh`), plus those of any workspace layer named in `COMPACT_HANDOFF_LAYERS`. The summary then carries a `## Waiting on you` section, since compaction clears the earlier conversation from the screen: what the user must do or decide (open decisions, pending gos, things to try or review), one line each. It ends with a suggested kick-off that does not restate those items. Both are shown to the user afterwards, but only the kick-off is for them to copy, edit and send. That is a fallback, written with no chance to check state first, so load-bearing state still belongs in a file the session re-reads (see `execution` → Living sessions). A handoff you had to hand-write for state that could have lived on disk is a signal to move it there.

**After any compaction**, a `SessionStart` hook for the `compact` source tells the restored session that it was just compacted, that its full transcript is the place to search for a specific the summary lacks, and that skill and file text come back as copies from when they were loaded, so it re-reads the relevant ones from disk before acting under them. It then adds a block of current state read from disk (`claude/hooks/compact-state.sh`): the worktrees the session or its subagents acted in (edited or wrote a file in, ran a Bash command in, or gave to `git -C` or `worktree add`, per their transcripts) with their branches, which are dirty and which hold commits not on their upstream, the background agents this session started that have not reported back, and the output of any workspace command named in `COMPACT_STATE_COMMANDS`. Where the block and the summary disagree, the block is current.
