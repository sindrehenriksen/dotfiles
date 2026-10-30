# Desk

Desk is a notes file you edit by hand, with suggestions for it staged beside it and reviewed in nvim, taken or declined one at a time. Around that sit scheduled passes that commit the notes and hand a morning brief to your central Claude Code session, a follow pass that forwards ticket news to the sessions working on those tickets, and a recorder and reader for Claude Code sessions, so the notes can name a session and a hotkey can jump to it.

This repo holds the mechanism only. Everything that makes it someone's (the prompts, the sources, the tools, the ticket keys, the schedule) is an **instance**, kept in a private repo and pointed at by `$DESK_CONFIG`. Nothing about an instance belongs here.

It runs on macOS (Ghostty tabs through Hammerspoon, passes from launchd) and Linux (a Ghostty window per tab, passes from systemd user timers).

## Day to day

- **Passes run on their own.** The morning pass commits your notes, checks the status of the tickets they name, lists idle sessions and sends your central session a brief, which does the reading and judging and brings you what matters. The weekly pass briefs it on Wednesdays.
- **Review suggestions** in your notes: `␣gR` draws them over the notes. `n`/`N` move between them, `dp` takes the ones on the cursor line, `␣gA`/`␣gD` take or decline one, `u` undoes. `␣go` lists them all. `Q` ends the review, recording its takes and declines and saving your notes. `␣gc` commits. Leaving one alone means "not now": it comes back with the next pass.
- **Sessions** suggest notes changes the same way, with `desk-propose`; they edit your notes directly only when you ask for that edit.
- **Follow tickets** by saying "follow this epic" in the session that works on it. The follow pass sends that session the news, and the session rings the bell only when you're needed.
- **Ending a session:** Ctrl+C twice or `/exit` marks it done; closing its tab leaves it open, to be reopened after a restart ("reopen my sessions"). The brief offers the sessions idle for days, and on your yes the central session ends them and stages a note on where each stood. `gx` on a session name jumps to it.
- **When something looks off:** the bar above your notes shows each pass's last result; the logs are in `~/.local/state/desk/logs/`. A pass runs once a day whatever comes of it; `desk-run <pass> --rerun` runs it again, brief and all.

## What keeps it safe

These hold whatever else changes, and are why the pieces look the way they do.

- **Nothing reaches your notes but your own edits and your takes.** A suggestion lives only in the proposal commit (`refs/desk/proposal`); the review draws it, and only a take puts it in your buffer, as an ordinary edit `u` undoes. Placement never moves or rewrites text you wrote: an item whose anchor is only in your uncommitted text waits for the commit, and one whose lines are gone is settled rather than put back.
- **Your decisions are recorded once and kept.** Takes and declines go to the ledger (`refs/desk/ledger`, append-only, written by compare-and-swap) as the review ends, and a declined suggestion is never proposed again, by id, by source URL or by content. The commit step pushes the ledger wrapped in a commit, to `refs/desk/ledger-log`, since git updates a remote ref holding a bare blob only by force.
- **Your notes are never written over a change on disk.** Auto-save, the commit key and the review's ends save only when the file on disk is what the buffer last read or wrote; otherwise the disk merge opens and nothing is saved, committed or recorded until it is done.
- **The commit step only commits**: the configured files as they are on disk, only on `main` with no rebase or merge in progress, then a pinned push. It never pulls, merges, rebases or force-pushes.
- **A headless call cannot act outward.** Every model call is `claude -p --restricted --permission-mode dontAsk` with an exact `--allowedTools` and `--tools`, `--strict-mcp-config` over an explicit MCP config and no session persistence, from a scratch directory outside any repo, under a timeout and a spend ceiling (20 minutes and $25, failsafes well above normal use). A call that sends has SendMessage as its only tool, its recipient and text pinned.
- **The deny hook is the second layer.** `claude/desk-lib/deny-unlisted-tool.sh` refuses any tool not on the call's list, admits a `Bash(…)` pattern only for a command that fits it with no shell operator or substitution, and with `--pinned` refuses any arguments but the pinned ones. It fails closed: every way out but the one allow exits 2. Each pass runs its own copy, so a pull mid-pass cannot change it under a call.
- **Ending a session from outside is deliberate.** `close-session.sh` refuses anything but a full id of a live session one process holds, not in `keep_open` and not itself, records the close, and closes the tab only when it is sure which one.
- **This repo never names an instance.** The denylist check refuses a push carrying an instance's names.

## How it works

**The notes repo.** A private git repo holding `notes.md` and `reading.md` at its root, on branch `main`, with an empty `.desk-notes` marker file. The marker, not a path, tells nvim a buffer is a desk notes file. nvim attaches to the config's `files`.

**Passes.** `desk-run <pass>` runs one pass's steps under one lock shared by every pass but the follow pass, then writes `~/.local/state/desk/status.json`, which the status line reads, and with a `brief` hands its run to the central session.

**The proposal.** A staging writes one commit to `refs/desk/proposal`: its parent your `HEAD` then, its tree the configured files with every open suggestion applied, plus `proposal.json` listing the items. Each staging rebuilds it from your newest `HEAD` with the earlier items you neither took nor declined. A new item replaces an open one it names in `supersedes`, that shares its URL, or that is the same kind of change to the same line; insertions never replace each other by place. Items are placed against the committed text: an insertion whose anchor has gone lands where that line stood, or on top when that can't be told; one whose lines are gone from your notes is settled, a removal as taken and the rest as declined, blocking only that item; one that cannot act now is deferred and counted on the status line. `nvim/lua/desk/apply.lua` and `proposal.lua` have the rules.

**Edits from sessions.** A session changes a notes file directly only when the user asks for that edit; a change that is its own idea it stages with `desk-propose <items.json>`, never by writing it in. `desk-propose --help` is the contract: an item that does not fit the shape fails the whole call, and text is cleaned of control characters, modelines and agent marks. `--list` prints what still waits, and `--withdraw <id>...` takes a staged suggestion back, recording it declined. The item shape:

| Field | Meaning |
|---|---|
| `id` | unique within the call; staged as `<pass>-<date>-<n>-<id>` |
| `file` | one of `files` |
| `kind` | `new`, `add`, `link` (insert); `edit`, `remove` (in place); `move`, `merge` (remove in one place, insert in another) |
| `target` | `"top"`, `{"under": line}` or `{"after": line}` (the end of the block that line heads or is in), or `{"at": line}`, the first line of `before`, for `edit` and `remove`; `move` and `merge` take `[{"at": …}, <landing anchor>]`. A quoted line is a whole line of at least three characters, matched apart from trailing whitespace and the agent mark. |
| `before` | the exact existing lines for in-place and moving kinds, else `""` |
| `after` | the new text, `""` for `remove` |
| `source`, `headline` | a URL or a tag such as `notes` or `ticket:ABC-1`; a few words for the overview. In the text a long link is `[short label](url)`, which nvim shows as its label, and a session is named exactly as it is. |
| `tier`, `also_sources`, `supersedes` | optional: `act`, `worth_knowing` or `wildcard`; other URLs for the same story; the id of one open item this replaces |

**Sessions.** `claude/hooks/session-recorder.sh` (hooks in `claude/settings.json`) records each session's start and end, and `claude/session-status.sh` (the reader) joins those with Claude Code's pid files and transcripts into one JSON line per session, documented in its header; `resolve <token>` finds one by name, id or id prefix, reporting several rather than ranking them. While two processes hold a session, `duplicate_pids` is true and nothing acts on it. `left_open` is a session whose latest run stopped without a deliberate end: the one to reopen after a restart.

**Marks and the hotkey.** Tokens the config's `tokens` table classifies get virtual text: a session its state, a ticket key its status from the ticket cache. `gx` follows a link under the cursor (`nvim/lua/mdlink.lua`; a bare word never goes to the system opener), else acts on the token: a ticket opens its URL, a session heading a section in the buffer jumps there, a live session's tab is focused by tty, and one not live is resumed in a new tab in its recorded cwd. An ambiguous name or a failed focus is reported, never guessed past, since a second process on a live transcript is worse than no tab.

**Tabs.** `hammerspoon/desk-open-tab.sh`, `desk-focus-tab.sh` and `desk-close-tab.sh` call into `hammerspoon/init.lua` over `hs -c`, each call limited to `DESK_HS_TIMEOUT_SECS`. A new tab goes into the Ghostty window in the ultrawide's `upper_C` slot, or `lower_C` when that is the window being typed in, else a new window clear of the focused one; an open never moves or resizes a window, hands focus back after a background open, and opens nothing with the screen locked. Commands run through `/bin/zsh -lic`, for your login `PATH` and `CLAUDE_CONFIG_DIR`. On Linux the helpers in `linux/desk/` open a new window each time, and cannot focus or close one. `claude/reopen-sessions.sh` (the `reopen-sessions` skill) resumes the `left_open` sessions after a restart, and `claude/close-session.sh <id>` ends a live session from outside, recording the close, checking the process is gone and closing its tab; their headers have the flags and refusals.

## The review

A review covers one of the config's `files`, drawn over that file's own window: a suggestion's new lines as tinted virtual lines with its headline, the lines it would remove or replace as your real lines tinted red, the words an edit changes marked more strongly. What you type is in your notes, and every change works the drawing out again. A hidden buffer holds the merged text the overview and the counts read.

| Key | Action |
|---|---|
| `<leader>gR` | Open the review, or go to the one open; with nothing here but some in the other file, open there. |
| `<leader>gc` | Save the notes buffers and commit every file with changes in one commit, recording what is now in `HEAD` as taken. A suggestion waiting on a line you had not committed becomes reviewable then. With a change on disk not yet merged it saves, commits and records nothing, saying why. |
| `<leader>go` | The overview: a quickfix list across the top, one headline per open suggestion, the other file's prefixed with its name. Moving in it shows each suggestion; `<CR>` jumps to it (or moves the review to the other file); `t`/`dp` take and `x`/`gD` decline without leaving it; `q`/`Q` end the review. On macOS this nvim's Ghostty window goes full height while it is open, and back after (`hammerspoon/desk-window.sh`). |
| `<leader>gd` | Declined in the last 14 days (also `:DeskDeclined`); `r` restores one. |
| `dp`, `do` | Take every suggestion on the cursor line, as one change `u` takes back; with a count, that many places down. |
| `<leader>gA`, `<leader>gD` | Take, or decline, just the suggestion on the cursor line. A decline is recorded as the review ends; `u` brings it back until you change your notes. |
| `u` | Undo the latest decline, else your notes' own undo, which takes a take back. |
| `n`/`N`, `]c`/`[c` | Next or previous suggestion, wrapping; `n`/`N` are the search's own while one is highlighted. |
| `Q`, `<leader>gq`, `:q` | End the review: declines and takes recorded, the notes saved (`:q` leaves the takes for the next save), never over a change on disk, and one line saying what it recorded. Quitting nvim records them too. |

The review also ends on its own once nothing is left open in the file. A take is recorded by id, so it stays taken whatever you do to the text after; deleting an edit's red lines by hand declines it, typing into them leaves it to the next staging. When the proposal changes under an open review, the next look or key works the drawing out over the new one, keeping the declines; a key that noticed does nothing that once.

The bar above the notes has the keys on the left and the status line on the right: each pass's last result, the untaken suggestions (while a review is open, its live and recorded counts, as in `30 left (34 saved)`) and the deferred ones.

<a id="auto-save"></a>**Auto-save.** A notes file with unsaved edits is written on leaving insert mode, its buffer or window, and when nvim loses focus, each time only after `checktime` and only when the file on disk is still what the buffer last read or wrote; otherwise the disk merge (`nvim/lua/diskmerge.lua`) takes over, after any open review ends.

## Config reference

`$DESK_CONFIG` is one JSON file, read fresh on every run; unset, the commands use `${XDG_CONFIG_HOME:-~/.config}/desk/config.json`. Paths in it are relative to its directory.

| Key | Default | Meaning |
|---|---|---|
| `notes_repo`, `files` | required | The notes repo's toplevel (absolute, `~` expanded) and its notes files. |
| `passes` | required | Pass name → pass, below. |
| `ticket_status_step_id`, `ticket_search_tool` | none | The fetch step that checks ticket status, and the tool whose results become the ticket cache. |
| `push_enabled` | `false` | Push after committing. |
| `central_session` | none | The central session's id, where briefs go. |
| `close_after_working_days`, `keep_open`, `away_days` | `3`, `[]`, `5` | Offer sessions idle that many Mon–Fri days, never those named, and none on the first pass after that many days away. |
| `calls_root` | the state directory | Where `runs/` and the calls' `scratch/` go. |
| `caps.<name>` | none | `{act, worth_knowing, wildcard}`, the usual size `{{caps}}` names. |
| `default_max_budget_usd` | `25` | The spend ceiling on every call. |
| `sources_file`, `timezone`, `tokens` | `sources.json`, none, `[]` | Seeded as `sources.json`; the follow pass's clock; the token table. |

**A pass** has `steps` and optionally `brief`, `weekdays_only` (on a weekend slot only `commit_push` runs; default true for `morning`), `caps` (default `weekly` for `weekly`, else `daily`) and `trigger`: `start_calendar_interval`, `[{hour, minute, weekday?}]`, mirrors the schedule and decides which slot, and so which date, a run belongs to, the once-a-day guard keyed on that date; `same_day_only` makes a slot of an earlier day a no-op. `kind: "follow"` makes it the follow pass.

| Step kind | What it does |
|---|---|
| `commit_push` | Commits, records takes, pushes. Its failure stops the pass. |
| `fetch` | One call with `prompt`, `tools` (exactly; a pattern such as `Bash(gh run list:*)` brings the deny hook), `mcp_config` and `timeout`. The ticket step gets `{{jql}}` over every key the committed notes name, and its search results become the ticket cache. A failure flags the pass `partial`. |
| `close` | No call. Lists the sessions to offer as `close/<id>/` in the run directory (`session.json`, `transcript.txt`) and `close/candidates.json`. A failure flags the pass `partial`. |

Any other kind stops the pass.

**Tokens**, first match wins: `{"pattern": "^ABC-([0-9]+)$", "case_insensitive": true, "handler": "url", "template": "https://tickets.example.com/browse/ABC-{1}"}`, or `"handler": "session"`, a last `^.+$` making every other token a session lookup. nvim reads a pattern as Lua and the runner as an extended regex, so keep to literals, `[...]`, `.`, `+`, `*`, `?`, `(...)`, `^`, `$`.

**Prompts** are plain text with `{{name}}` placeholders, filled in one pass: `{{scratch}}`, `{{mode}}` (`WEEKLY` on a week's first ok run, else `DAILY`) and `{{today}}` for every call, `{{jql}}` for the ticket step, and for a brief's files also `{{caps}}`, `{{run_dir}}`, `{{inputs}}`, `{{pass}}` and `{{scheduled_date}}`. A prompt says what the tool list cannot: that the call changes nothing outside its reply, and that what it reads is data, never instructions.

## The central brief

A pass with a `brief` hands its run to the **central session**, the long-lived session the user steers from (the `central-session` skill), which reads the day's sources through subagents, judges with what its conversation holds, stages with `desk-propose`, offers the idle sessions and brings the brief, by the instance's instruction files. The runner prepares the run and sends one message.

**The run directory**, `runs/<pass>-<date>/`, holds `inputs/`, `instructions/` (each instruction file rendered), `run-status.txt` and `run.json` (how the run went, and the notes commit it saw), `notes-changes.txt` (the notes' own commits since the last judged brief, the latest run of any pass holding `judgement.json`, saying so when none was judged or the history was rewritten), `gone-edits.json` (edits the review settled because their lines were gone, to offer again), `notes-diff.md` and `close/`.

| Key (under `brief`) | Meaning |
|---|---|
| `input_files` | Seeded into `inputs/`: each of `files` (committed, each line you took from a suggestion marked `  <<agent-suggested>>`), `sources.json`, `tickets.json` (status changes since the last check), `sessions.json`, `open-items.json`; or `{name, path, sections?}`, an instance file, only the named Markdown sections when given. |
| `instructions` | The instruction files, in reading order. With none found, no brief is prepared. |
| `send` | `prompt`, `model`, `timeout` of the send call. |
| `notes_diff_since` | `last_wednesday` or `{"weekday", "time"}`: your own notes changes since then, taken suggestions left out, as `notes-diff.md`. |

**The message** goes as a follow update does, one restricted call with SendMessage pinned to the central session's current name and the exact text, starting `[desk-brief] The morning pass of 2026-10-13 is ready for you to judge. Not from the user.` and naming the run directory, how the run ended, the instruction files and what the directory holds. When it cannot go (the session not running, its name shared, the send failed), the run stays `brief.pending` and every later run of a pass with a brief tries again, sending each pass's waiting runs in one message, oldest first. A pending run is never swept; others go after seven days.

## The follow pass

A pass of kind `follow` forwards ticket news to the session working on those tickets, or on a whole GitHub repo, a **follow session**, as cross-session messages; only that session's reply decides whether to involve the user. The follow list is machine-local (`$DESK_FOLLOW_FILE`), edited only by `desk-follow`:

```sh
desk-follow add [--session <id|name>] [--label <text>] [--related <KEY>...] [--repo <owner/name>]... [<KEY>...]
desk-follow remove [--session <id|name>] [--repo <owner/name>]... [<KEY>...]   # none: the whole follow
desk-follow list [--json]
desk-follow run [--dry-run] [--lookback-minutes N]    # one run now
```

`--session` defaults to `$CLAUDE_CODE_SESSION_ID`; the `desk-follow` skill says what each ask means. A follow added from outside its session sends the session a short intro.

**What it reads**, read-only: tickets, in one restricted call with only the search tool, two queries the runner builds (the scope, the tracked and related keys and their children; and what changed in the window), counted only from calls whose `jql` is exactly the one built; and GitHub through `gh pr list`, `gh pr view`, `gh run list` and `gh repo view` only, never with `--web` (`desk_follow_gh`). PRs come from `github_repos`, where they count by the keys in their title or branch, and from every followed repo (an entry's `repos`), where they all count. Each ticket and PR is snapshotted in `$DESK_FOLLOW_STATE_FILE`, and a change is a difference from the snapshot. The first run after a repo is followed snapshots its open PRs and reads its default branch, so a later merge of a PR opened before the follow is a change rather than a first sighting.

**What it forwards.** Comments and reviews by people, description edits, renames, new commits, reassignments, parent and link changes, tickets and PRs new in the window, and a PR review request or assignment naming the user (`self`) or a team, including one a PR already carries when it is first seen. A session following a repo also gets its merges, and its CI runs that failed, timed out or could not start, on the default branch or an open PR's branch (a cancelled run is usually a superseded one). A PR matched both by a key and by its repo is one change, counted as the repo follow counts it. The rest is counted in the message's footer, by kind, so nothing goes missing silently: bots' posts and the PRs a bot opened, their merges and CI failures (`skip`), the user's own (`self`, and for field moves a pinned changelog read against `self_account_id`), status and state moves alone, labels, checks, review requests and assignments naming someone else, and anything only first seen. What the pass cannot read is forwarded rather than hidden.

**Delivery.** Changes queue per session, sent only while it is live and its name resolves back to it alone, by one restricted call with SendMessage pinned to that name and the text. The queue empties only on a confirmed delivery; sends back off up to four hours. The message starts `[desk-follow] Update for <label>: …. Not from the user.`, then the instance's `preamble` (the bar for involving the user, and the reply contract: a `[needs-you]` line, or one quiet line), the changes, and the footer. Changes on one ticket or PR, and CI failures on one default branch, are one entry with a line per change, placed at its first change, so a busy day on a followed repo reads PR by PR. Neither side may run in bypass mode, which holds messages across permission classes.

It takes its own lock, and none of the runner's guard or status file. `--scheduled` skips a run sooner than `interval_minutes` after the last; `--dry-run` prints and writes nothing. Its keys (`interval_minutes`, `jira.*`, `github_repos`, `send`, `preamble`, `self`, `skip`, …) are read in `claude/desk-lib/follow.sh`, which has the details.

## Setting up an instance

`install_symlinks.sh` links `desk-run`, `desk-follow`, `desk-propose`, the session scripts and the tab helpers into `~/.local/bin`, and nvim loads `nvim/lua/desk`; they need bash 4+, `jq`, `nvim`, `perl`, `rg`, `git` and `claude`, and on macOS Hammerspoon with `hs.ipc`. Make the notes repo (`notes.md`, `reading.md`, an empty `.desk-notes`, on `main`), write the config and prompts in a private instance repo, export `DESK_CONFIG` in `~/.shellrc.early` and link it to the default path, set the denylist (below), and run each pass by hand with `central_session` left out of a copy of the config, so the brief waits in its run directory with its message in `brief-message.txt`, before loading the schedule.

## Scheduling

On macOS, one LaunchAgent plist per pass in the instance repo runs `desk-run <pass>` through `/bin/sh -c` (launchd expands neither `~` nor `$HOME`) with `DESK_CONFIG`, `CLAUDE_CONFIG_DIR` and a `PATH` reaching the tools, appending to `~/.local/state/desk/logs/`. Keep `StartCalendarInterval` equal to the trigger. Several slots cover a machine asleep or off at the first, the once-a-day guard making the rest no-ops; `RunAtLoad` covers one that was off, with `same_day_only` so a login never runs the day before's. The follow pass uses `StartInterval` and `--scheduled`. A job survives restarts only linked into `~/Library/LaunchAgents`, then `launchctl bootstrap gui/$(id -u) <plist>`; `launchctl kickstart gui/$(id -u)/<label>` runs it once.

On Linux, a systemd user service per pass sets the same environment, and a timer starts it (`OnCalendar` mirroring the trigger, `Persistent=true`, `OnActiveSec` for login, `AccuracySec=1s`). While a pass works the runner holds a `systemd-inhibit` sleep lock, so a machine woken for a slot with its lid shut finishes the pass (`claude/desk-lib/sleep-inhibit.sh`).

## The denylist

The dotfiles clone refuses to push until `desk.denylist` is set in it, once, locally: `git -C ~/dotfiles config desk.denylist /path/to/instance/denylist.txt` (add more with `--add`; `none` opts out). The list holds one Perl regex per line (`#` comments), matched case-insensitively unless a line starts with `(?-i)`, against every commit message and diff being pushed. It keeps an instance's names out of this public repo, so it lives in the instance repo and never here. A missing or empty list refuses too. `git-hooks/pre-push` runs the check only when the repo being pushed is this one; by hand, `git-hooks/desk-denylist-check.sh <repo> <range> <list-file>`.

## Tests

**This is personal tooling, so the testing bar is a plain one.** A test guards a regression that would actually bother the user: their edits undone, a suggestion lost or wrongly counted, a pass acting where it shouldn't. Formatting, wording and exact output are not worth one. Fewer, plainer tests are the norm: a fix gets one regression test that fails without it, in the existing style, and no test frameworks or generators.

**Change desk code in a worktree, never in the main checkout.** The scheduled passes run their code straight from the clone at `~/dotfiles`, so a half-made edit there is live at the next slot: make desk changes in a `git worktree` of this repo and bring them into the main checkout only as finished, tested commits.

```sh
DESK_GUARD_REPOS="$HOME/dotfiles" bash tests/run-all.sh
```

`tests/run-all.sh` runs every suite it names (a new file runs only once listed there) with safe defaults exported first: state under a temp directory, refusing stubs for `claude`, the tab helpers, the URL opener and the sleep inhibitor, and an empty reader, so a test that forgets an override fails instead of acting. It fails if the local git config of any repo in `$DESK_GUARD_REPOS` (default this repo's main checkout) or the content of `~/.local/state/claude` and `~/.local/state/desk` changed during the run; the scheduled follow pass writing its state meanwhile trips that too, so rerun before suspecting a test. Tests that create repos use `tests/lib/git-safety.sh`, which refuses a root outside a temp directory and isolates git from the real global config.

The live checks are never in `run-all.sh`: `nvim/tests/desk-run-canary-restricted.sh` makes one real call to prove an unlisted tool is refused (`DESK_CANARY_LIVE=1`), and `hammerspoon/tests/tabs-live-check.sh` opens one real background tab and checks nothing moved (`DESK_TABS_LIVE=1`). The Linux helpers are tested against a stub `ghostty` only.

## State and overrides

The runner writes under `~/.local/state/desk` (`$DESK_STATE_DIR`): `status.json`, `ticket-status.json`, `lock/`, `scratch/`, `runs/` and `logs/`. Each path, the timing knobs and the helpers nvim and the runner call (`$DESK_OPEN_TAB_BIN`, `$DESK_FOCUS_TAB_BIN`, `$DESK_CLOSE_TAB_BIN`, `$DESK_READER`, `$DESK_OPEN_URL`, `$DESK_WINDOW_BIN`, `$DESK_GHOSTTY_BIN`, `$DESK_INHIBIT_BIN`) have an override read at the top of `claude/desk-lib/common.sh` or the file that uses them.
