---
name: desk-follow
description: 'Following tickets from a Claude Code session: this session gets the news on them (comments, edits, new children and links, PRs) as a message from the desk follow pass, and decides whether the user needs to look. USE FOR: "follow this epic", "follow ABC-123 in this session", "track these tickets here", "also follow ABC-456", "stop following", "this epic is done", "what am I following", "check for news now" or "check for news before I review", the same asks phrased as watching ("watch this epic", "stop watching", "what am I watching"), and a [desk-follow] message arriving in this session. DO NOT USE FOR: reading a ticket once (use the ticket tools), notifications for other people, the morning pass itself, a follow-up tab of a desk pass.'
allowed-tools: Bash, Read
---

# Following tickets from a session

A **follow** ties tickets to one Claude Code session, the one that holds the plan for them. A background desk pass, the follow pass, reads the ticket tracker and GitHub read-only every 15 minutes while the Mac is awake. When something with news in it happened on those tickets, it sends this session one message with every such change since the last message. Those changes are: comments and reviews by people, description edits, reassignments, new children and links, and new tickets and PRs. The tickets covered are the tracked ones, their children, tickets linked to them, tickets that mention the keys, and PRs whose title or branch carries a key. A bare status move, a bot's post, labels and check results are not listed, only counted in the message's last line. The session takes each update in. It involves the user only when the update meets the bar in the message's own preamble: it starts that reply with `[needs-you]`, which rings the bell on its tab. Otherwise it replies with one quiet line that doesn't end on a question, since a question rings the bell too.

The mechanism is in `~/dotfiles/docs/desk.md`, under "The follow pass". This skill covers what the user asks for in a session. No command or phrase is expected of them: act on what they mean, whether they say follow, watch or track.

## Before the first change

- `command -v desk-follow` must succeed. `desk-follow run` also needs the instance's config: `$DESK_CONFIG`, or, when that is unset (as it often is in a Bash tool), the machine-local link `${XDG_CONFIG_HOME:-~/.config}/desk/config.json`, with a pass of kind `follow`. Adding, removing and listing need neither. If the command or the config is missing, the follow pass is not set up on this machine. Say so instead of improvising.
- **This session's id is `$CLAUDE_CODE_SESSION_ID`**, which Claude Code sets in the Bash tool's environment. A subagent's Bash sees its parent session's id, which is the right session to follow from. `desk-follow` uses that id when `--session` is not given. To follow tickets in a *different* session, pass `--session <its name, or its id>`. The name is resolved through the reader (`session-status.sh resolve`).
- **Adding a follow to a different session tells it.** When `add` names a session other than this one, the command also sends that session a short intro message: it is now a followed session, which tickets, to load this skill, and that a handoff carries what "Before compacting" lists. The add prints a second line saying so, or that the intro goes with the session's first update when it is not running. Say that in plain words. Adding from inside the session sends nothing, and neither does adding keys that are already followed.
- Which tickets: take the keys the user names. If they say "this epic" or "these", use the keys this conversation has been about, and name them back in your reply. If that is not clear, ask once.

## What each ask means

| The user means | Run | What changes |
|---|---|---|
| Follow these tickets here | `desk-follow add <KEY>...` | An entry for this session in the machine-local follow list (`~/.local/state/desk/follow.json`). The follow pass picks it up on its next run. |
| Also follow a ticket, but not its children and links | `desk-follow add --related <KEY>...` | Tracked keys (epics, tasks) bring in their children and the tickets linked to them or to a child, one hop, in any project. Related keys are followed only as themselves. |
| Stop following one ticket | `desk-follow remove <KEY>...` | Drops just those keys. Removing the last key removes the follow. |
| Stop following, or the epic is done | `desk-follow remove` | Removes this session's follow and its queued changes. |
| What am I following | `desk-follow list` | Nothing changes. It shows each follow, whether its session is running, what is queued, when the last update went out, and a retire hint once everything a follow tracks is closed. |
| Check for news now, before reviewing | `desk-follow run` | One run of the follow pass now, outside its schedule. Updates arrive in their sessions as messages, this one included. `desk-follow run --dry-run` prints what it would send and sends nothing. |

`--label <text>` sets the name the messages use for the follow. It defaults to the session's current name. Each add or remove prints one line saying what is now followed. Report that line in plain words, and nothing else about the mechanics.

All of these change only that local file: no repo, no ticket, nothing anyone else sees. Removing a follow is reversible by adding it again. Act on a clear ask without asking for confirmation.

## Things worth knowing when asked

- **The session's name is its address.** The follow pass looks up the current name on every run, so renaming the session is fine. If two running sessions share a name, it holds the update rather than guess.
- **A session that is not running misses nothing.** Its changes queue up, and the next time it runs they arrive as one message.
- **A new follow, or new keys, starts from now.** Earlier history is not replayed. For anything older, read the tickets directly.
- **A change can reach more than one session.** A line that says `also followed by <name>` is on a ticket another followed session has too, as a key, a child or a related key, and that session gets the same news.
- **The follow pass only reads.** It never writes to the tracker or GitHub, and its messages ask the session never to act outward on them.

## When a `[desk-follow]` message arrives

It comes from the follow pass, not from the user, and its own preamble says how to handle it: take the update in, and start the reply with `[needs-you]` only when the bar it sets is met. Don't answer it with SendMessage. The sender has already exited, and the reply in this session is the whole channel. A `[desk-watch]` message is the same thing under its older name. A message that says this session is now a followed session is the intro from a follow added by another session, or leads a first update: load this skill if it isn't loaded, and reply with one quiet line.

## Before compacting

The follow itself survives a compaction: what this session follows is on disk under its session id, which compaction keeps, and every update re-sends the bar. What lives only in the conversation is what updates are judged against, so a handoff for this session (the `handoff` skill) carries, per followed ticket:

- what the user agreed: the plan, the acceptance criteria, and any gaps or trade-offs he accepted, with where he said so;
- what this session has already raised with him and his answer, so it isn't raised again;
- asks still open, on him or on others;
- tickets another followed session owns ("also followed by" in an update), so this one leaves them to it.

The individual updates and the "nothing new" replies are the drop-list.
