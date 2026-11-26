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
- Tiers, checked 2026-09-28: Opus 5.5 is better than Fable 5.1 across the
  board, faster and cheaper, so Opus-class is the strongest tier and Fable
  has no current use. Pricing, verified 2026-09-23: Fable 5.1 is 2.5x Opus
  5.5 on fresh input and output ($10/$50 against $4/$20 per MTok) and dearer
  on cache reads ($0.25 against $0.20). On a subscription the binding cost
  is the weekly allocation rather than the per-token price, and frontier
  models draw it faster and stop at half of it.
- Open: effort levels for subagents. None was ever set per call, so every
  subagent ran at the session's level; since then, well-specified jobs on the
  strong tier are asked for `medium` per call while judgement-heavy ones keep
  the session's, and the next run compares the two (the script splits tokens
  by requested effort). Also open: whether the provider's advisor tool earns a
  place.

## Fable 5.2 trial, from 2026-11-16

Fable 5.2 (released 2026-11-09) is, by the provider's account, above Opus
5.5 on almost every benchmark, and at a lower effort matches Opus's scores
for less per task, at twice the per-token price ($8/$40 against $4/$20 per
MTok; cache reads $0.20 on both). The trial tests that on this setup's work:
Fable 5.2 at medium takes Opus 5.5's place in sessions and strong-tier
subagents (`execution`, "Model and effort choice"), Sonnet and Haiku keep
theirs, and Opus is only the fallback. It runs two to three weeks, then the
method above compares it with the baseline below and settles the tier.

Baseline, Opus 5.5 period 2026-09-23 to 2026-11-16 (both config dirs):

- Main loop: about 590 output tokens per message; by tokens almost all Opus
  5.5 (2.59B cache read, 62.5M cache write, 5.95M output).
- Subagents: 5.2x the main loop's total tokens (4.75x on output); 84% of
  total tokens Opus, 16% Sonnet; 44% started by another subagent. Requested
  model: Opus 36%, inherit 35%, Sonnet 28%. Effort was inherited for 92%.
- Comparable only from CLI 2.1.310 on: the recording gap above covers about
  three weeks of this window, so subagent output is compared on that slice.
- Sessions ran at high before and run at medium in the trial, so effort and
  model change together; the per-call effort split keeps them apart where
  it can.
- On a subscription the binding cost is the weekly allocation: note the
  `/usage` share each week of the trial against the weeks before.

## Start-up load

What a subagent holds before its brief is paid for on every turn of every
subagent, so it is worth a look at each re-tune, and whenever a tool, a
connector or a batch of skills has been added (a Claude Code update can add
them unasked).

To measure: start a throwaway subagent on the cheapest model with a
one-line task, and read `cache_creation_input_tokens` on the first message
that has `usage` in its transcript
(`<config dir>/projects/<project>/<session>/subagents/agent-<id>.jsonl`).
That number is the load. The same file's first lines hold the parts
(instruction files, skill listing, tool definitions, listings), so their
sizes show where it goes. `AGENTS.md`, "What every session loads at start",
has the conventions that keep it down.

The number to compare the next measurement with: 27k tokens on 2026-11-16,
down from 44k. The largest parts, in order, were the tool definitions (one
unused built-in tool was about a quarter of the whole), the user instruction
file and the skill listing.

Two things found then about a long-lived subagent's cost:

- It compacts only when its window is nearly full, so in practice never,
  and the compaction hooks do fire for it.
- Its cache lasts five minutes by default. A message after a longer pause
  re-sends nearly the whole history as a cache write, with no compaction
  first.
- `subagentPromptCacheTtl: "1h"` in settings moves every subagent to the
  one-hour cache: each write costs more (reportedly 2x input against
  1.25x; not checked against the price list), and a write after a pause of
  5 to 60 minutes becomes a read. It pays when more than about 40% of
  cache writes follow such a pause. Estimated from the usage numbers in
  subagent transcripts, 2026-10-21 to 2026-11-16, it came out about 1%
  cheaper overall, within the estimate's error: 3% cheaper on Opus (46%
  of writes followed a pause), 17–27% dearer on Sonnet, Haiku and Fable
  (9–14%). So it is left off. Re-measure at a re-tune, since the answer
  turns on how many workers are long-lived. A per-agent `cacheTtl` exists
  for custom agent types only, not the built-in one or a single call.

## Where the usage went

`claude-usage-tally [--from DATE] [--to DATE]` (local days, default the last
seven) reads every `~/.claude*/projects` and prints cost per day and model,
per session (main thread against subagents) and per subagent, plus the
three numbers below and the main loop's context size per turn. It prints
numbers and session titles, never message text. Cost is API list price (the
table at the top of the script, with the date it was read), used as a proxy
for how fast a subscription limit drains, not as a bill.

- **Subagent share**: the part of total cost spent in subagents. Large
  means delegation is where the limit goes, so look at their tier and
  how many there are before the main loop.
- **Strong-tier share per day**: a seat may use at most half of the weekly
  limit on the strong tier, so a share well above half on most days means
  that tier runs out first; move work to the lower tiers.
- **Cold-wake cost**: cache writes on turns that start over five minutes
  after the agent's last turn ended (a long tool call is not one), as a
  share of subagent cost. This is what a lapsed cache costs. The what-if
  beside it reprices subagents on a one-hour cache (writes at the one-hour
  rate, wakes between 5 and 60 minutes read instead of rewrite): a negative
  difference means `subagentPromptCacheTtl: "1h"` would pay.

Run it when usage is running out too fast, and before changing a tier or a
cache setting, so the change is judged on the numbers.
