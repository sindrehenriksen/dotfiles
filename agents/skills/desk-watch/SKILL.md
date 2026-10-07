---
name: desk-watch
description: 'Watching tickets from a Claude Code session: this session gets every movement on them (status, comments, children, linked tickets, PRs) as a message from the desk watcher, and decides whether the user needs to look. USE FOR: "watch this epic", "follow ABC-123 in this session", "track these tickets here", "also watch ABC-456", "stop watching", "this epic is done", "what am I watching", "update the watch now" or "check for news before I review", and a [desk-watch] message arriving in this session. DO NOT USE FOR: reading a ticket once (use the ticket tools), notifications for other people, the morning pass itself.'
allowed-tools: Bash, Read
---

# Watching tickets from a session

A **watch** ties tickets to one Claude Code session, the one that holds the plan for them. A background desk pass, the watcher, reads the ticket tracker and GitHub read-only every 15 minutes while the Mac is awake. When anything moved on those tickets, it sends this session one message with every change since the last message: status, assignee and description changes, new comments, children, linked tickets, tickets that mention the keys, and PRs whose title or branch carries a key. The session takes each update in. It involves the user only when the update meets the bar in the message's own preamble: it starts that reply with `[needs-you]`, which rings the bell on its tab. Otherwise it replies with one quiet line.

The mechanism is in `~/dotfiles/docs/desk.md`, under "The watch pass". This skill covers what the user asks for in a session. No command or phrase is expected of them: act on what they mean.

## Before the first change

- `command -v desk-watch` must succeed, and `$DESK_CONFIG` must name a config with a pass of kind `watch`. If either is missing, the watcher is not set up on this machine. Say so instead of improvising.
- **This session's id is `$CLAUDE_CODE_SESSION_ID`**, which Claude Code sets in the Bash tool's environment. A subagent's Bash sees its parent session's id, which is the right session to watch. `desk-watch` uses that id when `--session` is not given. To watch a *different* session, pass `--session <its name, or its id>`. The name is resolved through the reader (`session-status.sh resolve`).
- Which tickets: take the keys the user names. If they say "this epic" or "these", use the keys this conversation has been about, and name them back in your reply. If that is not clear, ask once.

## What each ask means

| The user means | Run | What changes |
|---|---|---|
| Watch these tickets here | `desk-watch add <KEY>...` | An entry for this session in the machine-local watch list (`~/.local/state/desk/watch.json`). The watcher picks it up on its next run. |
| Also follow a ticket, but not its children and links | `desk-watch add --related <KEY>...` | Tracked keys (epics, tasks) bring in their children and the tickets linked to them or to a child, one hop, in any project. Related keys are watched only as themselves. |
| Stop watching one ticket | `desk-watch remove <KEY>...` | Drops just those keys. Removing the last key removes the watch. |
| Stop watching, or the epic is done | `desk-watch remove` | Removes this session's watch and its queued changes. |
| What am I watching | `desk-watch list` | Nothing changes. It shows each watch, whether its session is running, what is queued, when the last update went out, and a retire hint once everything a watch tracks is closed. |
| Check for news now, before reviewing | `desk-watch run` | One watcher run now, outside its schedule. Updates arrive in their sessions as messages, this one included. `desk-watch run --dry-run` prints what it would send and sends nothing. |

`--label <text>` sets the name the watcher's messages use for the watch. It defaults to the session's current name. Each add or remove prints one line saying what is now watched. Report that line in plain words, and nothing else about the mechanics.

All of these change only that local file: no repo, no ticket, nothing anyone else sees. Removing a watch is reversible by adding it again. Act on a clear ask without asking for confirmation.

## Things worth knowing when asked

- **The session's name is its address.** The watcher looks up the current name on every run, so renaming the session is fine. If two running sessions share a name, the watcher holds the update rather than guess.
- **A session that is not running misses nothing.** Its changes queue up, and the next time it runs they arrive as one message.
- **A new watch, or new keys, starts from now.** Earlier history is not replayed. For anything older, read the tickets directly.
- **The watcher only reads.** It never writes to the tracker or GitHub, and its messages ask the session never to act outward on them.

## When a `[desk-watch]` message arrives

It comes from the watcher, not from the user, and its own preamble says how to handle it: take the update in, and start the reply with `[needs-you]` only when the bar it sets is met. Don't answer it with SendMessage. The watcher has already exited, and the reply in this session is the whole channel.
