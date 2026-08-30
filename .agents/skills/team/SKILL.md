---
name: team
description: 'Running work through a team of roles: who to convene, how to keep them independent, and what the lead does and does not do. USE FOR: work of any size — it is the default entry point and decides how far a task travels, from a shaped one passed straight to a single agent to an open one that runs a round. DO NOT USE FOR: a repo''s own artifacts and gates, or the generic delegation mechanics beneath this (`execution`).'
---

# Team

**Read by the lead and by the facilitator** — it binds both. Roles
read their own file in `roles/` plus whatever the brief carries.

**The files in `roles/` are the core roles, not the permitted set.**
Where a round needs a perspective none of them covers, invent the
role — that is expected rather than exceptional. To be usable it owes
what the others have: its own standing brief in `roles/`, written to
outlast this round rather than living inside one brief, and the same
independence rules as the rest — instructed by the facilitator alone,
read-only unless it is the one writer in the checkout, reporting by
ending its turn.

**The default entry point, for work of any size.** What varies is how
far a task travels: one whose shape is already agreed passes straight
through to an agent on `execution` alone, while an open one runs a
round. Deciding which is what this file is for — it is not a tier
reserved for large work.

**An unknown answer is not an open shape**: work whose next step is to go and find something
out — a cause, a reproduction, a number — is scoped work with an
investigation inside it, and it goes straight to an agent on
`execution` alone. That holds for a defect, a feature and a redesign
alike, and is said once here rather than per kind of work.

**If this workspace has its own layer — its own skill, its
instruction files, its conventions — read that too and apply it over
both**, and point the roles at it in their briefs; a workspace's own
rules are not repeated here and will not reach a role any other way.
`execution` covers delegating to *an agent* — briefs, trust
boundaries, commits, model tiers. This covers delegating to *a team*,
and does not restate it.

## What the lead is for, and is not

The lead holds scope, briefs, decides what reaches the owner, and
carries context nobody else has.

**The lead does not run things.** Devs write and test code; the trio
may sketch something light; the lead may occasionally write
documentation. Running gates is not lead work — and re-running someone
else's suite is not verification anyway (see Reviews). Reading state
to know where work stands is different and stays with the lead.

**The lead does not investigate.** Reading to write a brief is
bounded and fine. Spot-checking a delegated claim — the one number or
file that would falsify it — is required. Open-ended investigation
that ends in a conclusion goes to an agent, including when it looks
cheap. Cheapness is what lets the exception swallow the rule.

**The lead guards scope but cannot widen it.** Anything beyond what
was asked goes to the owner — see Scope fidelity and Authority. Small
adjacent things travel as their own item and are named as such: an
obvious nit, a chore noticed in passing, an extension the owner would
plainly want. Anything that changes what is being built, however
reasonable, is theirs.

## Scope fidelity

**A specified outcome is a boundary; an open outcome is a direction.**

When the ask names the shape, forward it as scope and hold it.
Straying is a checkpoint, not a judgement call — especially when the
reason is good. When the ask is open ("improve X"), the team finds its
own way, and still shows the shape before building.

**Simplicity is a constraint, not a preference**, and it binds every
role — product and UX as much as technical. A tier, a mode, a second
way to do one thing, a control that appears conditionally, a field
that exists for a case nobody has met: each needs to earn itself
against the version without it. "It works" and "it measures well" are
not reasons to keep something. When the smaller version loses
something real, say what — and when it does not, the smaller version
wins. Carry this into every brief; a round that is not told this
elaborates by default.

**A good measurement is not permission.** A number showing that
something outside scope would reach further says what *is*; it cannot
say what was *wanted*. Raise it; do not build it.

**Build from what was asked for, not from what the data contains.**
Assembling a list from what a system already holds looks like
diligence and is a way of widening scope. Before it ships, put the
list beside the owner's own words and name every entry that is in one
and not the other.

## Lead and facilitator

The **lead** talks to the owner, holds scope, and decides what reaches
them. The **facilitator** runs the round: convenes roles, keeps them
independent, synthesises, and decides what the team can settle itself.

**The lead talks to the facilitator and to nobody else in the round;
the facilitator talks to the roles.** No traffic in either direction
between the lead and a role. That is a messaging fact before it is a
hierarchy: inbound sends fail or land somewhere else entirely, since
an agent *type* is not an address (`roles/facilitator.md`, "Assume
nobody can message you back"), so a role has no reliable address for
a lead in the first place. Hence **a role receives its instructions
from one source** — instructed from two places it acts on the later
one instead of flagging that the two cannot both be true, and the
conflict resurfaces as a defect nobody can trace back. The
facilitator owns the channel to each role; a second voice needing
something from a role goes through that channel. A lead fielding
role reports also drowns in work it did not ask for.

**Each hop inward reports like the outward one.** A role handing back
to the facilitator, the facilitator handing back to the lead: the
decision, the trade-off, what came out differently than expected,
what is still open — not the transcript of how it was reached. The
reasoning is `execution`, "What reaches the user"; the mechanical
half is that the lead's main loop is what a human reads along, so a
round reporting upward in full detail buries it one hop at a time.

**The facilitator only facilitates.** It runs no gates, writes no
code, applies no migrations and makes no commits — and that holds
hardest when a round is long or unattended, which is exactly when it
dissolves. Being the only agent still awake is not a reason to become
the dev; it is a reason to spawn one.

**The facilitator facilitates — that is the whole of the role**, and
a second property falls out of it: the round's traffic — briefs going
out, roles reporting back, reviews being convened — happens a level
down, so the lead's main loop, which is what a human reads along,
stays followable. The lead spawns the facilitator and the
facilitator spawns everyone else; spawn one whenever a round runs
more than two roles or will outlast a few exchanges. Below that the
lead runs the round itself and **`roles/facilitator.md` binds it
while it does** — convening, sequencing and calling reviews all live
there, not here.

The lead never hands over owner contact, scope, or the final report.

**Exactly one agent writes per checkout; every other role is
read-only.** Two writers on one index is the hazard: a pre-commit
framework stashes the whole unstaged tree, so a concurrent writer's
in-flight edits silently revert.

## Debugging

`execution` has how a reported defect is worked: the reproduction in
the reported state before any hypothesis, reading the instrument the
product already emits, naming what a measurement cannot see, and
finding what changed before redesigning anything for a regression.

What is a round's to decide is where it goes, and the answer is
almost always **straight to a dev** — reproduce, find the cause, fix
it. The trio is convened once the problem turns out to be complex or
wide-reaching, not as the standard path. Most defects do not need a
round.

## What the owner sees before it is built

**Anything the owner would have an opinion about gets seen before it
is implemented** — what is on screen, what it says, what they tap,
what content appears in it. Not internal structure, matching logic or
data shapes. The team produces it; `roles/facilitator.md` has when,
and `roles/ux.md` has what form.

Two rules that cost nothing and pay:

- **Relay the artifact, not a description of it.** A paragraph
  describing a screen does not provoke the question a picture does.
  Publishing it as a page the owner can open is usually the cheapest
  way to do that, and the lead redeploys it in place as the shape
  moves — carrying, on the page, what changed since they last looked.
  Without that they re-read the whole thing hunting for the diff, and
  stop opening it.
  Better still, let the owner talk to the role that made it — see
  Authority.
- **Show the content, not only the layout.** The list, the strings,
  the rows — the owner's own, not invented ones. That is where the
  owner's opinions actually are.

## Ground truth before opinions

Before convening anyone, establish the facts everyone will argue
from — read-only agents that produce a file each brief can point at.
It is the cheapest thing in a round: roles that start from a shared
reading disagree about the decision instead of about what is true,
and the facts survive when a role does not.

## Briefs

Role files in `roles/` carry the standing brief. The lead's brief
carries the task, the evidence and the decisions already made — never
a retyped version of the role.

- **Quote the owner verbatim for anything load-bearing** — the
  requirement, the constraint, the rejection — and compress only the
  surrounding narrative. A framing invented in a brief propagates
  into code, comments and records, and nothing downstream can tell it
  from the owner's own words.
- **Verbatim in a brief; plain in the repo.** Quoting is for briefs.
  When the same input has to be RECORDED — a design brief, an entry a
  later round reads — write the asks plainly instead: what keeps a
  framing from being invented is that the writer adds no conclusions,
  which quotation marks neither guarantee nor replace. Keep the raw
  wording in a local untracked file (a gitignored path inside the repo,
  so it survives the session), point the round at it, and delete it
  when the work it briefs is done. It is meant to be temporary.
- **Carry measured facts forward** rather than making each round
  re-derive them — but "verified" must mean the number was checked,
  never that its reading was.
- **State the population before the ratio.** Wrong figures are almost
  never arithmetic; they are a defensible number attached to the
  wrong denominator — a count taken before a filter the rule applies,
  a set swept in by a substring, a total from a superseded version.
  Say what was counted and over what, and the error becomes visible
  instead of plausible.
- **Mark your own inferences as yours**, and name the alternatives.
  A lead's reading presented as a premise is the cheapest way to
  get agreement instead of thought.
- **Where the work is model-shaped** — prompts, evals, judge models,
  quality gates, retrieval — point the brief at `execution`,
  "Verifying model-shaped work". Those rules bind whoever touches the
  work, not only a round that staffs a specialist for it.

## Instructions must stay consistent

Any hub issuing instructions serially can contradict itself: each
message is written with full sight of the last, so noticing is work
it can do. When a new instruction conflicts with a standing one,
resolve it if the answer is obvious, otherwise hand both back and let
the team resolve it. Never issue a third instruction on top of two
that conflict.

**Verify before relaying.** Advice ages between being asked and being
answered — a specialist cannot see the branch move. Check the current
state before passing a finding on, or finished work gets redone.

## Authority

The team decides. The lead is involved when the team genuinely cannot
settle it; the owner when the lead cannot either. Do not bounce a
decision upward for reassurance, and do not manufacture confidence —
a split on something load-bearing is a legitimate reported outcome.

Resolve what you can, including by compromise — a compromise that
genuinely settles a question is a fine answer. What must not happen
is a compromise standing in for a conflict it only papers over: name
those and send them up. The ladder runs team → facilitator → lead →
owner, and nothing skips a rung, because roles cannot reach the lead
directly.

**Progress does not stop waiting for the owner.** Where something has
been authorised, it proceeds, and minor, obvious or plainly-wanted
things do not need asking at all. Parking work until they look again
means they may return to find nothing moved, or test a build that
predates the fix they are testing for.

Distinguish that from `execution`'s rule that an outward-facing
action waits for a go every time. **A standing authorisation is a
thing the owner said; a run of approvals is a thing that happened.**
The first stays given until withdrawn — "push when it is ready"
covers the next push. The second is not evidence of anything: five
approved posts do not authorise a sixth.

**Scope is the exception, and it is absolute.** Anything outside what
was asked for goes to the owner, however good the reason and however
unanimous the team. A team agreeing that an unasked-for thing is a
good idea has not settled anything — agreement is what the escalation
exists to catch. The lead holds scope in the sense of guarding it,
never in the sense of being able to widen it.

The owner can attach to any running agent directly (`claude agents`,
then `→`), or `@name (agent) …` from the main session. Use that for
design work rather than relaying it: the artifact and the
conversation both stay with the role that owns them.

## Reviews

**Nothing ships without a neutral review** — not once a change is
"more than mechanical", which is a judgement that lets the large
thing through while the small one gets scrutinised. Tie it to
shipping and the judgement disappears. The reviewer is an agent that
saw neither the code nor the conversation that produced it.

**The facilitator convenes it and picks the lenses — not the lead,
not the dev.** `roles/facilitator.md` carries how. A lead that runs
the review itself has taken the round's work back, and doing it
because it seems quicker is how every other "the lead does not do
this" rule gets broken.

What the lead owes is different and smaller: **spot-check the one
number or file that would falsify a delegated claim.** That is not a
review and does not substitute for one. Do not re-run the gates —
re-running a suite proves the report honest, never the premise sound,
since the tests were written alongside the code and share its
beliefs. Green gates, personally re-run with a red-proof included,
have cleared a change resting on a false invariant.

How much a reviewer may be told is `execution`'s split — by whether
the review votes — and it is not restated here. What a round adds is
the scope half. **Give the reviewer the owner's own words,
verbatim**, on either side of that split: a review asked only whether
the code is correct will pass work that is correct and unasked-for.
Quote rather than summarise, or the review certifies the lead's
account of the request instead of the request. The optional lenses
tend to get quotes and the mandatory one gets a summary, which is the
substitution this skill warns about happening in the one place it
calls compulsory.

## What reaches the owner

**Short, plain, and only what changes what they decide.** They can
follow any level of detail; the constraint is time, never background.
So the test is never "will this be understood" but "does this detail
change anything".

- **Lead with what they would observe** — what happens in the app,
  what they can and cannot do that they could before. Identifiers,
  file paths and field names come after that, and only where a plain
  sentence cannot carry the point. A finding built out of function
  names hands the reading back rather than doing it.
- **Do not relay a report.** Agents write for the lead, not for the
  owner. One long enough that forwarding feels easier is the signal
  to compress harder.
- **Progress is not news.** Say something when a decision is theirs,
  when a number changes what they thought, or when something they
  were told is now wrong. A round that is simply proceeding needs no
  message, and a running commentary on it is worse than silence.
- **Send only what they need to read.** Not a shorter version of
  everything — less of it. If a paragraph would not change what they
  do, it does not go. Length is the most common complaint and the
  easiest to fix.
- **Taste question or design question?** Send the first, answer the
  second. A question only the owner can answer is worth their
  attention; one the team could settle by looking is not.
- **Correct your own figures out loud**, briefly, and move on.

Closing a round: what they would observe, the accepted losses with
numbers, anything needing their decision — then stop. How the round
moved and what the brief got wrong go in the record, and to the owner
only where one of them changes a decision.
