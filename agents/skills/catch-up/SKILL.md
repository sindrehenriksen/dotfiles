---
name: catch-up
description: 'The catch-up summary for a user returning to a long session after time away: what happened since their last message, what is needed of them (each ask with its reminder), what they already decided, calls made on their word, what is parked. USE FOR: "catch me up", "update on status", "what happened since my last message", "what do you need me for", "where are we", "remind me", "so I don''t have to scroll", the user returning after hours away. DO NOT USE FOR: the prompts that carry work across /compact (handoff), a final report at the end of a task, steering other sessions (central-session).'
allowed-tools: Read, Grep, Glob, Bash
---

# Catch up

The reader has been away for hours and has forgotten the detail. The summary lets them act without scrolling. It follows the global "Calibrating what surfaces": outcomes before mechanics, plain words before identifiers.

## Gather first, then write

Re-read state from primary sources, not from memory of the conversation: open PRs and their checks, tickets, `git status` and recent commits, background agents (running and finished), queued messages and anything that arrived while away. Never report a running agent's result as known. If something could not be checked, say so in the summary.

## Shape

One screen if possible. Tables only for enumerable facts (PR, state, what is next).

1. **Title**: one line saying where things stand.
2. **What happened since your last message**: what finished, what was cut off, what fell short of what was promised, each with its reason in one line. No apology padding.
3. **What I need you for**: numbered. This is what the reader came for, so keep section 2 short enough that both are on screen together. One action per item, with:
   - a one-or-two-line reminder of why, written for someone who forgot;
   - what happens if they do nothing;
   - the deadline, if any.
   Where an ask has a clear answer, give a recommendation, not an open question.
4. **Decisions you made, for reference**: settled; listed so they are not re-litigated.
5. **Calls I made on your word**: each with its reason, so the user can overrule.
6. **Parked, no action needed now**: one line each.

Drop any section that is empty. If nothing needs the user, say that first.

## Rules

- Items the user has answered, dropped or parked are not re-raised as asks; they appear only in the sections above.
- Say what is verified and what is not (read from the source now, versus reported by an agent, versus assumed).
- Describe things by what they do, not by their ids or names. An id appears only after the plain description, and only when the user needs it to find the thing. No internal jargon the user did not coin.
- End without a question unless something truly blocks, and then it is an ask in section 3.

## What not to do

Replies to earlier catch-ups were "what now?" and "remind me", so a line that needs that follow-up has failed.

- Terse fragments of jargon or shorthand labels (an item "(a2)", "the cutover") that the user must decode.
- Asking for something with no reminder of why or what is at stake.
- Narrating mechanics, cost or usage figures, or work that changes nothing the user decides.
- Re-listing what they already answered, or asking something a recommendation could settle.
- A wall of text: if it needs scrolling, cut the history, not the asks.
