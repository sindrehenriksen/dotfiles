---
name: reopen-sessions
description: 'Reopen the Claude Code sessions that were open before a restart, each resumed in a background Ghostty tab, with `reopen-sessions.sh`. USE FOR: "reopen my sessions", "what was open before the restart", "bring my tabs back", restoring sessions after a reboot, a crash or quitting the terminal, opening chosen idle sessions from that list. DO NOT USE FOR: resuming one named session the user is already pointing at (just `claude --resume <id>`), listing every session ever (`session-status.sh`), closing sessions.'
allowed-tools: Bash, Read
---

# Reopen sessions

`reopen-sessions.sh` (on `PATH` via `install_symlinks.sh`; the source is `~/dotfiles/claude/reopen-sessions.sh`, macOS only) finds the sessions that were still open when the machine last went down, or that stopped since without the user ending them, and resumes the active ones in background tabs. Its header documents the rules; what follows is how to run it for the user.

## Steps

1. **Always run `reopen-sessions.sh --dry-run` first.** It opens nothing and writes nothing.
2. **Show the user the list**, grouped: what would be reopened, what is already running, what is idle (with each one's last-message date), and any failures with their reason. Use names, not ids, with the date in plain words ("last message Friday"); keep ids for the follow-up command.
3. **Then act on what they asked.**
   - Asked to reopen: run `reopen-sessions.sh` straight after showing the list, without asking again, unless the dry run holds a surprise worth a word first: more than a handful to open, or failures.
   - Asked only what was open: stop after the list.
   - To open chosen idle ones too: `reopen-sessions.sh --session <id>` (repeatable; a full id or an 8+ character prefix). That opens them even though idle.
4. **Report the real run's outcome** the same way, from its output, not from the dry run.

## Reading the output

One tab-separated line per session, then a summary line:

```
<status>  <id>  <last message YYYY-MM-DD HH:MM>  <idle working days>  <name>  <cwd>  <detail>
summary   dry_run=… opened=… would_open=… running=… idle=… failed=… older_orphans=… ended_deliberately=… idle_after_working_days=N(source) went_down_after=… booted=…
```

`--json` gives the same as `{summary, sessions: [...]}`; prefer it when you need to pick fields out.

| status | means |
|---|---|
| `would-open` | dry run: this one would be resumed |
| `opened` | resumed in a background tab; `confirmed_live` (JSON) or the detail says whether it has come up yet |
| `running` | was open at the shutdown and is already live again; left alone |
| `idle` | its last human message is at least the threshold in working days old; listed, not opened |
| `failed` | not opened; the detail says why (a malformed id, a missing cwd or transcript, a timeout, a locked screen, the tab helper declining) |

Whether a session was left open is the session reader's call (`left_open` in `session-status.sh`); the detail only says which kind it was: "no end recorded", or "ended without the user". `ended_deliberately` counts the sessions the user ended themselves, which are never reopened, not even with `--session`.

Exit codes: `0` nothing failed (including nothing to do), `1` at least one session failed, `2` usage error, `3` the store or reader could not be read, so there is no list at all. On `3`, say so rather than reporting "nothing was open".

## Things to know

- To end a session so it isn't reopened next time, tell the user: Ctrl+C twice or `/exit`. Closing the tab doesn't count; it reads the same as a shutdown.
- A locked screen makes every open fail with that reason; ask the user to unlock and run the command again.
- `older_orphans` counts sessions left open by an earlier boot (weeks-old crashes). They are not listed; `--all-boots` lists them if the user asks.
- The idle threshold is the desk config's `close_after_working_days` when `DESK_CONFIG` is set, otherwise 3; `--idle-days N` overrides it for one run.
- Never call the tab helper (`desk-open-tab.sh`) yourself to "finish the job": the command is what refuses empty ids, re-checks that a session is not already live, and keeps each open from hanging.
- A `failed` with a timeout may still have opened its tab late. Run `--dry-run` again before retrying; a session that came up shows as `running`.
- A session whose transcript belongs to another Claude config directory fails with that reason; it can be reopened by running the command with that `CLAUDE_CONFIG_DIR`.
