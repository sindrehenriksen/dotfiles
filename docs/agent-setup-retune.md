# Re-tuning the agent setup for a new model

The delegation and model-tier rules in `agents/AGENTS.md` and the `execution`
and `team` skills were written against one model. When a new one arrives they
are hypotheses again. This is the method used the last time, so the next pass
starts from it rather than from scratch.

## Method

1. **Read the provider's guidance first**: the migration guide, the prompting
   guide, and any "when to use subagents" material. Treat it as hypotheses,
   not rules. It is written for a generic harness, and this setup differs on
   purpose: heavy briefs, keeping the owner's threads legible as the first
   reason to delegate, long-lived sessions, and review and team roles that
   mirror a human team.
2. **Measure from transcript metadata only**: model, token usage, CLI
   version, subagent count, type, requested model and effort, before against
   after the switch. No message text is read, so the numbers can be written
   down. [`claude/claude-usage-baseline`](../claude/claude-usage-baseline)
   does this: `--split` takes the switch date, `--root` each config dir's
   `projects/`, and `--json` keeps the full breakdown, which names local
   sessions and so stays out of any repo. Cache reads dominate total tokens,
   so output tokens are the better cost proxy once output is recorded; heed
   the script's warning about versions that did not record it. Transcripts
   are deleted after `cleanupPeriodDays` (120 in this repo's settings, shorter
   when unset), so a baseline expires: measure before the window you need
   ages out.
3. **Sample, extract, spot-check.** Take the heaviest sessions (the script
   lists them), about 20–40 subagents per session. Cheaper readers extract
   against a fixed rubric, and the main loop spot-checks their reports,
   because what to conclude is judgement. This step reads content, locally;
   only aggregate findings get recorded. The rubric:
   - the outcome per kind of delegation: used, fixed inline, sent back, redone;
   - each delegation against the provider's criteria (context bloat, parallel
     work, conflicting tools);
   - whether reviews changed the artifact;
   - which team roles changed the outcome;
   - how legible the owner's threads stayed;
   - the behaviours the provider's guide flags for the new model;
   - whether briefs carried the context needed, and whether they were bigger
     than their tasks;
   - where a lower-tier worker got stuck mid-task.
4. **Compare across the owner's own repos** in the same pass, since the
   instruction layers drift apart between re-tunes.
5. **Then edit.** The owner decides the rule changes; they go in as trimmed
   edits, followed by a neutral review.

**Why delegation stays the default.** The provider's
[when to fold subagents into your main agent loop](https://claude.com/resources/articles/building-agents-when-to-fold-subagents-into-your-main-agent-loop)
keeps a subagent only for context bloat, genuinely parallel work or
conflicting tools, and weighs cost and performance. This setup delegates by
default anyway, because legibility of the owner's threads comes first. It
meets the article by continuing long-lived workers by message rather than
spawning many fresh ones.

## Findings, October 2026

One sample, one owner, one switch. This time the readers judged rather than
extracted, and nobody spot-checked their reports, so these are leads for the
next pass, not settled facts.

- Long-lived workers continued by message kept the owner's threads cleanest.
- Fresh neutral reviews were the most consistently useful thing; most led to
  a real fix.
- Team-round roles usually changed the outcome.
- Lower-tier agents held up on well-specified work. The tier comparison is
  thin, because they were given different jobs.
- No path existed for a worker to ask a stronger model mid-task; one has been
  added.
- Briefs were often far bigger than their tasks, and brief errors came mostly
  from unverified facts copied forward from earlier reports.
- Waiting and polling leaked into user-facing threads.
- Self-forking agents raced each other.
- The numbers, all total tokens or counts, from `claude-usage-baseline --root
  ~/.claude/projects --root ~/.claude-work/projects --since 2026-09-01
  --until 2026-10-27 --split 2026-09-23`:
  - subagents used 1.8 times the main loop's total tokens before the switch,
    2.0 times after;
  - the lower tier's share of subagent total tokens rose from 13% to 34%;
  - 41–42% of subagents by count were started by other subagents, against
    33% over all retained history.
- Recording gap: subagent transcripts written by CLI versions 2.1.276 to
  2.1.306 (about 2026-09-18 to 2026-10-21) record about 10–113 output tokens
  per message, against about 370–2,140 for subagents outside that range and
  about 500–1,100 in main transcripts from the same versions (the script's
  `data_quality`). A one-off local check of content length confirmed the
  output went unrecorded rather than was produced less. Nothing recovers it,
  and the window straddles the switch, so subagent output is not compared
  across it here.
- Open: effort levels for subagents. None was ever set per call, so every
  subagent ran at the session's level; since then, well-specified jobs on the
  strong tier are asked for `medium` per call while judgement-heavy ones keep
  the session's, and the next run compares the two (the script splits tokens
  by requested effort). Also open: whether the provider's advisor tool earns a
  place.
