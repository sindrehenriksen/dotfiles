---
name: desk-follow
description: 'Following tickets from a Claude Code session: this session gets the news on them (comments, edits, new children and links, PRs) as a message from the desk follow pass, and decides whether the user needs to look. USE FOR: "follow this epic", "follow ABC-123 in this session", "track these tickets here", "also follow ABC-456", "stop following", "this epic is done", "what am I following", "check for news now" or "check for news before I review", the same asks phrased as watching ("watch this epic", "stop watching", "what am I watching"), and a [desk-follow] message arriving in this session. DO NOT USE FOR: reading a ticket once (use the ticket tools), notifications for other people, the morning pass itself, a follow-up tab of a desk pass.'
allowed-tools: Bash, Read
---

# Following tickets from a session

A **follow** ties tickets to the Claude Code session that holds the plan for them. The desk follow pass reads the ticket tracker and GitHub, read-only, every 15 minutes while the machine is awake, and sends this session one message with every change that has news in it since the last message: comments and reviews by people, description edits, reassignments, new children and links, new tickets and PRs. It covers the tracked tickets, their children, tickets linked to them or mentioning their keys, and PRs whose title or branch carries a key. Bare status moves, bot posts, labels and check results are only counted, in the message's last line. The session involves the user only when an update meets the bar in the message's own preamble, by starting its reply with `[needs-you]`, which rings the bell on its tab; otherwise it replies with one quiet line that doesn't end on a question, since a question rings the bell too.

The mechanism is in `~/dotfiles/docs/desk.md`, under "The follow pass". This skill covers what the user asks for in a session. No command or phrase is expected of them: act on what they mean, whether they say follow, watch or track.

## Before the first change

- `command -v desk-follow` must succeed. `desk-follow run` also needs the instance's config, with a pass of kind `follow`: `$DESK_CONFIG`, which the shell sets to this session's account's instance, or, when that is unset, `${XDG_CONFIG_HOME:-~/.config}/desk/config.json`. The follow list is per instance too, in its state directory (`$DESK_STATE_DIR`). Adding, removing and listing need neither. If the command or the config is missing, the follow pass is not set up on this machine: say so instead of improvising.
- **This session's id is `$CLAUDE_CODE_SESSION_ID`**, set in the Bash tool's environment; a subagent's Bash sees its parent's, which is the right session to follow from. `desk-follow` uses it when `--session` is not given. To follow tickets in a *different* session, pass `--session <its name, or its id>`.
- **Adding a follow to a different session tells it**, with a short intro message (see "When a `[desk-follow]` message arrives"). The add prints a second line saying the intro went, or that it goes with the session's first update when the session is not running: pass that on in plain words. Adding from inside the session, or adding keys already followed, sends nothing.
- Which tickets: take the keys the user names. For "this epic" or "these", use the keys this conversation has been about and name them back in your reply. If that is not clear, ask once.

## What each ask means

| The user means | Run | What changes |
|---|---|---|
| Follow these tickets here | `desk-follow add <KEY>...` | An entry for this session in the machine-local follow list (`follow.json` in the state directory, `~/.local/state/desk` by default). The follow pass picks it up on its next run. |
| Also follow a ticket, but not its children and links | `desk-follow add --related <KEY>...` | Tracked keys (epics, tasks) bring in their children and the tickets linked to them or to a child, one hop, in any project. Related keys are followed only as themselves. |
| Stop following one ticket | `desk-follow remove <KEY>...` | Drops just those keys. Removing the last key removes the follow. |
| Stop following, or the epic is done | `desk-follow remove` | Removes this session's follow and its queued changes. |
| What am I following | `desk-follow list` | Nothing changes. It shows each follow, whether its session is running, what is queued, when the last update went out, and a retire hint once everything a follow tracks is closed. |
| Check for news now, before reviewing | `desk-follow run` | One run of the follow pass now, outside its schedule. Updates arrive in their sessions as messages, this one included. `desk-follow run --dry-run` prints what it would send and sends nothing. |

`--label <text>` sets the name the messages use for the follow; it defaults to the session's current name. Each add or remove prints one line saying what is now followed: report that line in plain words, and nothing else about the mechanics.

All of these change only that local file, nothing anyone else sees, and a removal is undone by adding again. Act on a clear ask without asking for confirmation.

## Things worth knowing when asked

- **The session's name is its address.** The follow pass looks up the current name on every run, so renaming the session is fine. If two running sessions share a name, it holds the update rather than guess.
- **A session that is not running misses nothing.** Its changes queue up, and the next time it runs they arrive as one message.
- **A new follow, or new keys, starts from now.** Earlier history is not replayed. For anything older, read the tickets directly.
- **A change can reach more than one session.** A line that says `also followed by <name>` is on a ticket another followed session also has, and that session gets the same news.
- **The follow pass only reads.** It never writes to the tracker or GitHub, and its messages ask the session never to act outward on them.

## When a `[desk-follow]` message arrives

It comes from the follow pass, not from the user, and its own preamble says how to handle it: take the update in, and start the reply with `[needs-you]` only when the bar it sets is met. Don't answer it with SendMessage: the sender has already exited, and the reply in this session is the whole channel.

A message saying this session is now followed is the intro from a follow another session added (it names the tickets and points here), or leads a first update: load this skill if it isn't loaded, and reply with one quiet line.

## Before compacting

The follow survives a compaction: it is on disk under the session id, which compaction keeps, and every update re-sends the bar. What updates are judged against lives only in the conversation, so a handoff for this session (the `handoff` skill) carries, per followed ticket:

- what the user agreed: the plan, the acceptance criteria, and any gaps or trade-offs accepted, with where the user said so;
- what this session has already raised with the user and the answer, so it isn't raised again;
- asks still open, on the user or on others;
- tickets another followed session owns ("also followed by" in an update), so this one leaves them to it.

The individual updates and the "nothing new" replies are the drop-list.
