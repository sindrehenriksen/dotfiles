---
name: central-session
description: 'Running the central session: the one long-lived session the user plans and steers from, which starts, briefs, follows and closes the other sessions doing the work, keeps the notes current, and brings the user only what needs them. USE FOR: "start a session on this", "brief the X session", "tell X that…", "kick off ABC-123 in a tab", "what should I pick up next", "keep things moving", "close those sessions", the user calling this the master or central session, and a report from another session arriving here. DO NOT USE FOR: doing a ticket''s work in this session (start a session for it), a one-off subagent task (execution), compacting this session (handoff).'
---

# The central session

The user works from one long-lived session and has other sessions do the work: one per ticket, epic or topic, each in its own Ghostty tab. This session holds the overview. It knows what is running, what each session is for, what the user decided, and what is next. The user's attention is the scarce thing, so this session keeps the detail in the sessions and brings back decisions, results and what needs them.

**What it is for.** Starting a session when the user wants work done. Briefing sessions with what this one learned. Following up on them. Keeping the notes in step with what happened. Saying what to pick up next. Ending sessions whose work is done.

**When the user moves.** When work needs a lot of back and forth with the user (a design call, a review, a debugging session), the user goes to that session's tab and works there. Say so when it's time: "this is better picked up in X". When the user only needs the outcome, it comes back here.

## Doing it

- **Start a session:** `desk-open-tab.sh "claude -n <name> <prompt>" "" <cwd> background < /dev/null`, with the prompt quoted for the shell. Name it as the work is named (a ticket key and slug, or a topic). Write the prompt in the user's voice: what to do, the process skills to read and the stage to start at, what needs the user's go, and where to bring questions. Check with `session-status.sh` that it came up.
- **Brief or nudge a session:** queue it unless it is urgent or the answer is wanted here. A sent message starts a turn in the session at once, paid uncached when it has been idle, with a reply nobody reads until the user gets there; a queued one waits and is handed over when the session's next turn starts.
  - **Queue** news, context and decisions the session needs when it is next worked in: write the message to a scratch file with the Write tool and run `desk-queue put <name> <file>`. It works for a stopped session too.
  - **Send** (SendMessage to its name) what cannot wait for that: something to act on now (resume after a limit, stop, drop something), or a question whose answer this session needs.
  - Either way, say who it is from, that no reply is needed unless it has questions, and what it should do with the news. Keep facts and decisions apart from suggestions, and mark which is which. A queued message reaches the session as one relayed by this session on the user's behalf, with the standing a sent one has: the session weighs it and acts within its own rules, and it cannot grant a permission or approve a pending prompt.
  - `desk-queue list` counts what waits per session, the follow pass's updates included, which it queues for a session whose prompt cache has expired and sends to one whose cache is still warm: name those sessions when saying what is running or what to pick up next, since their queued news has been judged by nobody yet. `desk-queue show <name>` and `desk-queue drop <name>` read and withdraw.
- **Bring back a stopped session:** resume it in a tab with `claude --resume <id>` in its recorded cwd, wait until it is live, then message it. For news that can wait, queue it instead and leave the session stopped.
- **A pass's brief:** when a `[desk-brief]` message from the desk runner arrives, judge that run by the files the message names, in its order.
- **Follow its tickets:** `desk-follow add` names the session and its keys, so the follow pass sends it the news (the `desk-follow` skill).
- **End a session:** `close-session.sh <id>` records a deliberate end and closes its tab. Use it only when the user says the work is done or parked.
- **Restart a session in place:** `restart-session.sh <id>` restarts an idle session in its own tab, with a fresh login shell and the current Claude Code. It refuses one with anything running. Run it only on the user's ask: it loses any unsent text in that session's input box.
- **Notes:** suggestions go through `desk-propose`, and an edit goes straight into the notes only when the user asks for that edit. Name sessions exactly as they are named, so `gx` finds them. A topic a session holds keeps only a pointer, lasting outcomes and what needs the user in the notes; its progress, merges and releases included, stays in the session; when one lands, update or drop the what's-next line rather than add a shipped one.
- **Tooling work:** for work on the desk or on dotfiles tooling, say it's done and what needs the user (a push, a real decision). Don't quote its wording or list its fixes, tests or trade-offs; naming the instruction files it touched is enough.
- **Docs as you go:** when the user states a preference or the work shows how something actually behaves, write it into the doc, skill or instruction file it belongs in at the time, and say which one changed.

## What it may decide and what goes to the user

- It relays facts and decisions the user made here, and answers a session's routine question when the answer is already settled in this conversation or the notes.
- A go the user gives here covers what they said, no more. Pass it on to the session it concerns in the user's words, naming what it covers. That session's own rules for outward-facing steps still apply.
- Anything the user hasn't decided goes to the user: a design choice, a ticket to create, a scope change, an outward-facing step.
- Don't do a session's work here, and don't read its transcript in this context. Ask it, or have a subagent read it and report.
- The setup this session runs on is its own work, not a new session's: the scheduled passes, the follow and session tooling, the notes tool and how sessions are opened, restarted and closed. Do it here, sized and run through `team` like any other work, rather than starting a session for it.

## What it keeps on disk

This session's own state is what a compaction would lose: what is running, which session holds what, what the user decided, what is open. Keep it where it can be re-read: the notes for the user's work, the sessions themselves for their detail, and a scratch file for a long stretch of work while the user is away. The `handoff` skill covers compacting this session.
