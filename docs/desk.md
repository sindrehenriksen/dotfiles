# Desk

Desk is a notes file you edit by hand, plus scheduled passes that read it alongside whatever sources an instance configures and *propose* changes to it. A proposal never touches the file: it waits as a commit beside it, and you review it as a diff in nvim, taking or declining one suggestion at a time. Around that sit a recorder and reader for Claude Code sessions, so the notes can name a session and a pass can capture or close one, and a hotkey that acts on whatever token is under the cursor.

This repo holds the mechanism only. Everything that makes it someone's (which sources, which tools, which ticket keys, the prompts, the schedule) is an **instance**, kept in a private repo and pointed at by `$DESK_CONFIG`. Nothing about an instance belongs here; `claude/desk-example/` is a complete, work-free instance to start from, and `nvim/tests/desk-example-instance-test.sh` keeps it runnable.

macOS only: tabs open in Ghostty through Hammerspoon, and passes run from launchd. There is no Linux counterpart.

## Day to day

- **Passes run on their own.** A scheduled pass reads its sources and leaves suggestions for your notes; its follow-up tab opens in the background (no focus taken) on a plain summary of what it proposed, what it left out, and what it needs from you. Reply there.
- **Review suggestions** in your notes: `␣gR` opens them above your notes. `n`/`N` (or `]c`/`[c`) move between them, `dp` takes one into your notes, `␣gA`/`␣gD` take or decline the one under the cursor, `u` undoes. `␣go` lists them all (`t` take, `x` decline, `q` close the list, `Q` end the review). `␣gc` commits. Leaving one alone means "not now": it comes back next time.
- **Sessions** suggest notes changes the same way, with `desk-propose`; they edit your notes directly only when you ask for that edit.
- **Follow tickets** by saying "follow this epic" in the session that works on it. The follow pass then sends that session the news, and the session rings the bell (🔔 in its tab title) only when you're needed.
- **Ending a session:** Ctrl+C twice or `/exit` marks it done. Closing its tab leaves it open, so it is reopened after a restart (ask for "reopen my sessions"). `␣gx` on a session name in your notes jumps to its tab or resumes it.
- **When something looks off:** the bar above your notes shows each pass's last result; the logs are in `~/.local/state/desk/logs/`.

Everything below is reference: how it works, and every setting.

## How it works

**The notes repo.** A private git repo holding `notes.md` and `reading.md` at its root, on branch `main`, with an empty `.desk-notes` marker file. The marker, not a path, is what tells nvim a buffer is a desk notes file, so this repo never names where the notes live. nvim attaches to the config's `files` (default those two names), and session captures land in `captures_file` (default the first entry of `files`).

**Passes.** `desk-run <pass>` runs one pass from the config: an ordered list of steps, each of one kind (below). Every model call is a headless `claude -p` with an exact tool allowlist, from a scratch directory outside any repo, under a timeout and a spend cap. A pass ends by writing `~/.local/state/desk/status.json`, which the status line reads. One lock is shared by every pass, since they all write the same repo and status file; a run that cannot get it waits up to 30 minutes, then gives up and says so in status.

**The proposal.** A pass that suggests anything writes one commit to `refs/desk/proposal` in the notes repo: its parent is your `HEAD` at pass time, its tree is the configured files with every suggestion applied, plus `proposal.json` listing the items. The next pass rebuilds it from your newest `HEAD`, plus the previous items you neither took nor declined, plus its own new ones. Leaving a suggestion alone therefore means "not now". A pass's own items sit above those carried from earlier passes, and among themselves keep the order of the steps that staged them, so the order of `steps` decides what reads first; that is also the order in which items landing at the same spot go in. What you decided lives on `refs/desk/ledger`: declines (by item id, by source URL, and by content — file, kind, target and normalised before/after — so a declined link or a regenerated copy is never proposed again) and takes (so a taken suggestion's text is recognised as agent-written later, even after you edit or move it).

**The review.** In a notes buffer, `<leader>gR` merges your current buffer with the proposal and opens the result in a split above your notes, both windows in diff mode, with the cursor in the split: the proposal is where you work, and your notes below it show the result. While the review is open both windows read like a git diff, in colours taken from the colourscheme: green is what a take brings in, red what it takes out, stronger on the changed words, and the filler rows opposite a missing line are grey. Both windows soft-wrap long lines, bullets wrapping under their own text, and your notes window gets its own wrap settings back when the review ends. Taking is an ordinary diff take; declining makes the suggestion equal your text; nothing is recorded until you save the review split. The keys are in [Review keys](#review-keys).

**Edits from sessions.** The notes are also edited from Claude Code sessions, as work goes. A session changes a notes file directly only when the user asks for that edit in the conversation. A change that is the session's own idea it stages as a suggestion for review with `desk-propose` (below), never by writing it in or by offering in chat to apply it; asking in chat is for a question the session can't settle, not a substitute for the suggestion. Agent text in the notes writes a long link as `[short label](url)` (next paragraph) and a session name exactly as the session is named, so marks and the hotkey find it. The notes repo's own instructions file (`AGENTS.md`, with a `CLAUDE.md` link for Claude Code), which every session working in it reads, is where an instance says this, along with what the user's own markup means, and that the working files may hold unreviewed suggestions while the reviewed text is `HEAD`'s. A session stages suggestions with `desk-propose [--pass <name>] [--date <YYYY-MM-DD>] [--dry-run] <items.json>` (`claude/desk-propose`): the items are in the reply's item shape ([The prompt contract](#the-prompt-contract)), the notes repo and files come from the config, and the proposal is rebuilt the way a pass rebuilds it, carrying what still waits, dropping what was declined or is already in the notes, and replacing an open item named in `supersedes`. Ids become `<pass>-<date>-<n>-<id>` (`session` and today by default). A session's items set `source` to `session:<its session id>`, as the close and retention steps do, so a suggestion can be traced back to the session that holds its detail, and each item gets its own headline, since the overview lists headlines rather than lines. An `edit` of a stale line is preferred over an `add` beneath it. `desk-propose --help` prints this contract's short form. An item that does not fit the shape fails the whole call and is named, so nothing half-lands. Text is cleaned as a pass's is, but its URLs are kept: a session shows the user its items before staging them, which is what the runner's URL check stands in for on calls nobody watches.

**Links.** Agent text writes a link as `[short label](url)`, so a long Slack or mail URL does not swamp the line: in a notes buffer nvim conceals it (`conceallevel=2`, with markdown tree-sitter highlighting started for the buffer, since the legacy syntax file leaves link URLs visible), showing the label and revealing the URL on the cursor line. The runner's URL check treats a labelled link as one unit: kept whole when its URL is an allowed source, reduced to `label [url removed]` when not.

**Sessions.** `claude/hooks/session-recorder.sh` appends a start and an end event per Claude Code session to `~/.local/state/claude/session-events/<session id>.jsonl` (a start from a hook also records its process's pid and terminal), wired from `claude/settings.json` as the `SessionStart` and `SessionEnd` hooks. `claude/session-status.sh` (the reader) joins those events with Claude Code's own pid files and transcripts under `$CLAUDE_CONFIG_DIR` into one JSON line per session: name, liveness, cwd, tty, last human message and more, documented in its header. `session-status.sh resolve <token>` finds one session by the name you gave it, or by its session id or a unique prefix of 8 or more characters (what an unnamed capture is labelled with); several matches are reported, never ranked by id. Sessions the runner starts are recorded with source `desk-run`, so a capture never mistakes one for one of yours. A tab it opens for you to work in is the exception: an `open_tab` step's session and a follow-up tab's status session start as yours (source `startup`), and a follow-up tab that resumes a pass's call records your resume as its latest start, so a restart reopens each of them like any session you left open. A capture still skips a follow-up tab's session, by its `desk-` name and its cwd under `runs/`. A `restricted` `open_tab` loads no hooks, so it records nothing at all.

**One session, two processes.** A session can be open in two Claude Code processes at once, when it is resumed in a second window while the first still runs. Start and end events fired from a hook therefore carry the pid of the process that fired them, and the reader matches each end to its own process's start: a session is `ended` only once none of its processes is live. A start fired inside a process that already runs the session (after a compaction) replaces that process's run, and an end never lands on a run some process left open earlier (a crash, a shutdown, a start that recorded no pid), so the first end of the latest run is the one that counts: a `close` written just before the process is signalled stays the session's end when the process's own `SessionEnd` follows. While two are live, both of their pid files name the session and `duplicate_pids` is true, so the hotkey and the close step refuse to act on it. When a process starts on a session another live process already holds, the recorder's `SessionStart` hook returns a `systemMessage`, so Claude Code shows a warning naming the other process's tty and pid; the hook never blocks the start.

**How a session ended.** For an ended session the reader reports `end_deliberate`: true when you ended it, false when something else ended the process. Claude Code's `SessionEnd` reason is what tells the two apart. Every way of leaving at the prompt (Ctrl+C twice, Ctrl+D, `/exit`) reports `prompt_input_exit`; `/clear`, `/resume` and `/logout` report `clear`, `resume` and `logout`; the close step's own close, and `close-session.sh`'s, records `closed-by-pass`. Those are deliberate. Closing the tab, quitting Ghostty, a restart or shutdown (which quits Ghostty or sends SIGTERM) and Claude Code's own error exits all report `other`, and SIGKILL records no end at all; any reason not in the deliberate list counts as not deliberate. `left_open` builds on it: a session with a start event, not live and not started by a scheduled call, whose latest run stopped without a deliberate end. That is the session to reopen after a restart. A tab closed on purpose reads exactly like a shutdown, so it counts as left open; Ctrl+C twice or `/exit` marks a session done.

**Marks and the hotkey.** Each token in a notes buffer that the config's `tokens` table classifies gets virtual text: a session name shows that session's state from the reader, a ticket-like token shows its status from the ticket cache a pass writes. `<leader>gx` acts on the token under the cursor, in your notes and in the review split alike, read without the markdown emphasis around it or a trailing colon, so `**name:**` and `__name__` are the session `name` (and a line written that way heads its section): a URL token opens its templated URL, unless the template gave a bare word with neither a scheme nor a dot, which it reports as not a link or session rather than handing to the system opener; a session token that heads a section elsewhere in the buffer jumps there; otherwise the session is resolved through the reader and, if live, its Ghostty tab is focused by tty, or, if not, resumed with `claude --resume <id>` in a new tab in its recorded cwd. An ambiguous name, or a failed focus, is reported rather than guessed past: a second process on a live transcript is worse than no tab. A token that is neither, on a markdown link, follows the link the way `gx` does in any markdown buffer (`nvim/lua/mdlink.lua`, not desk's own): `#anchor` jumps to the heading with that GitHub slug, a relative path opens the file at its anchor, a URL opens in the browser, and a bare word is never handed to the system opener.

**Tabs.** `hammerspoon/desk-open-tab.sh` and `desk-focus-tab.sh` call `DeskOpenTab` and `DeskFocusTab` in `hammerspoon/init.lua` over `hs -c`. A new tab opens in the Ghostty window whose centre sits in the ultrawide's `upper_C` slot (upper half of the middle column, picker key `c`). A background open never goes into the window being typed in, so when that is `upper_C` it uses the `lower_C` window instead. With no window to use, a new window opens. No existing window's frame is ever set. With no ultrawide screen at all, the frontmost window stands in for `upper_C` if it is Ghostty's. Every tab command runs through `/bin/zsh -lic`, so it gets your login shell's `PATH` and `CLAUDE_CONFIG_DIR`.

The scheduled passes open their tabs in the background (`desk-open-tab.sh … background`); the notes hotkey (`<leader>gx` on a session name in the notes) opens that session's tab in the foreground and focuses it. A tab must never move a window on screen, and Ghostty would: it saves the frame of the window it last focused, moved or resized (its `NSWindowLastPosition` preference) and moves every window it shows to that position, a new tab included, and a tab has already joined its window when it is shown, so the window goes with it. So before adding a tab, `DeskOpenTab` reads that saved position and adds the tab only when it is the target window's own frame. When it isn't, the open first makes the target Ghostty's focused window with Ghostty's own `activate window`, which saves the target's frame, and checks the save landed. If it never does, the open opens a new window instead. Ghostty's scripting has no way to add a tab without selecting it and activating the app, so for four seconds after a background open, `DeskOpenTab` watches for focus landing on what the open created and hands it back each time, which Ghostty may need more than once: to a Ghostty window through `activate window`, by the id of Ghostty's key window read before the open, and to another app's through Hammerspoon. It waits to see the new tab focused before handing back from a target it focused itself, since handing back earlier would make the user's window the saved position again before Ghostty shows the tab. Focus the user moves elsewhere is left alone, and each step is logged to the Hammerspoon console. In the moment between, a keystroke can still land in the new tab. Ghostty's own window ids are unrelated to Hammerspoon's, so the target is matched to Ghostty's by title and front-to-back order; when the match is not certain, a new window opens. Ghostty shows a new window at that same saved position, right over the window being worked in, so a background open moves it clear: to the first slot of the ultrawide that is not over the focused window and holds no other window (the outer columns first, then the middle, then other screens), else the first not over the focused window. It does so only for a window it knows for certain it created (Ghostty counts exactly one more window, and exactly one Hammerspoon id is new while every earlier one remains, since a window's id changes with its selected tab), and in the same step that hands focus back, just before: the new frame becomes Ghostty's saved position, and handing focus back to a Ghostty window saves that window's frame again, so a tab opened there next cannot drag it. The fourth argument also takes `close` (as in `background,close`): the tab then closes when its command exits, by handing the command to the new shell as its initial input, since Ghostty keeps any surface it was given a `command` for open after it exits. Without it the tab stays, so a finished session can still be read. With the screen locked Hammerspoon sees none of Ghostty's windows, so nothing opens and the helper exits 1, leaving the tab to a later retry slot. The helper's exit status is `DeskOpenTab`'s own result. Both helpers give `hs` an empty stdin, since `hs` reads a piped one as more commands and waits for it to close, and a hard limit of `DESK_HS_TIMEOUT_SECS` (default 6): a call that has not returned by then is killed and fails with exit 124. The notes hotkey's calls carry their own limit as well, so a stuck helper is reported rather than left running.

**Reopening after a restart.** `claude/reopen-sessions.sh` resumes the sessions that were open when the machine last went down, each with `claude --resume <id>` in its recorded cwd in a background tab. It is written to be run by an agent on request, through the `reopen-sessions` skill: `--dry-run` lists without opening, `--json` gives one object instead of lines, and the exit code says whether anything failed. A session counts when its latest run is in the previous boot or this one and the reader reports it `left_open` (see "How a session ended" above); every start event records its boot, and a process cannot outlive its boot, so a session orphaned weeks ago is only counted as an old orphan unless `--all-boots` asks for it. To end a session so it is not reopened, use Ctrl+C twice, `/exit` or `close-session.sh` (below); closing the tab doesn't count. Active ones are opened and idle ones listed with their last-message date, by the close step's own measure (`close_after_working_days`, 3 without a config). Each open refuses a non-UUID id, re-checks liveness first, and calls `desk-open-tab.sh … background` with stdin from `/dev/null` under a hard timeout, since `hs` reads a piped stdin as more commands. Its header documents the output format and overrides.

**Closing a session and its tab.** `claude/close-session.sh <session id>` ends a live session on purpose from outside it, for an agent or a hand in another session: it records the close (`closed-by-pass`, so the session is not reopened), sends its process `SIGTERM`, re-checks that it is gone (a survivor is recorded as a failed close, as the close step records one, and its tab is left alone), and then closes the Ghostty tab it ran in. It refuses an id that is not a full UUID, a session that is not live, one two processes hold, one named in the config's `keep_open`, and the session running the command. The tab is identified before the signal, while the process still holds its terminal: the one Ghostty terminal on the session's tty whose foreground process is the session's pid, on the tty the session's latest start recorded when it recorded one (`hammerspoon/desk-close-tab.sh find`, `DeskTabTerminal` in `init.lua`). After the process exits only that terminal's Ghostty id is used, which unlike a tty is never handed to another, and its tab closes only when it holds no other terminal (`desk-close-tab.sh close`, `DeskCloseTerminalTab`). Closing moves no window, and for a moment afterwards focus the close moved onto Ghostty is handed back, as a background open hands it back. Anything short of certain leaves the tab open and the output line says why. Its header documents the output and overrides.

## What an instance provides

| Piece | Where it lives | Notes |
|---|---|---|
| Config file | the private instance repo; `$DESK_CONFIG` points at it | [Config reference](#config-reference) |
| Prompts | beside the config, paths relative to its directory | [The prompt contract](#the-prompt-contract) |
| Sources file | beside the config (`sources_file`) | free-form JSON, handed to prompts verbatim |
| Notes repo | anywhere, named by `notes_repo` | `notes.md`, `reading.md`, `.desk-notes`, branch `main` |
| LaunchAgent plists | the instance repo | [Scheduling](#scheduling) |
| Denylist | the instance repo, untracked here | [The denylist](#the-denylist) |

## Setting up an instance

1. **Install the pieces.** `install_symlinks.sh` links `desk-run`, `desk-follow`, `desk-propose`, `session-status.sh`, `reopen-sessions.sh`, `close-session.sh`, `desk-open-tab.sh`, `desk-focus-tab.sh` and `desk-close-tab.sh` into `~/.local/bin`, and nvim loads `nvim/lua/desk` from `nvim/init.lua`. The scripts need bash 4 or later (Homebrew's; macOS's `/bin/bash` is 3.2), `jq`, `nvim`, `perl`, `rg`, `git` and `claude` on `PATH`, and Hammerspoon with `hs.ipc` loaded (as `hammerspoon/init.lua` does) for `hs -c`.
2. **Make the notes repo.** `git init`, add `notes.md`, `reading.md` and an empty `.desk-notes`, commit on `main`. A remote is optional; with `push_enabled` on, the commit step pushes `main` and `refs/desk/ledger` to `origin` (`$DESK_NOTES_REMOTE`) over SSH in batch mode. The proposal ref stays local.
3. **Copy the example.** Copy `claude/desk-example/` into the private instance repo, then replace its sources, prompts, tokens and schedule. Set `notes_repo`.
4. **Export `DESK_CONFIG`** in the shell, e.g. from `~/.shellrc.early`. The runner gets it from the plist, but nvim reads the token table from it too, so without it marks and the hotkey have nothing to classify against. Also link the config to `${XDG_CONFIG_HOME:-~/.config}/desk/config.json`, the machine-local default: with `DESK_CONFIG` unset, `desk-run` and `desk-follow` use that path if it exists. That covers a shell started before the export, and an agent's Bash tool. The instance's installer makes the link; this repo never names the instance's path. (`DESK_CONFIG_DEFAULT` overrides the default path, which is how the test suite keeps a real instance out of reach.)
5. **Check the recorder hooks.** `claude/settings.json` already wires them, as `$HOME/dotfiles/claude/hooks/session-recorder.sh`; they only need the clone at `~/dotfiles`. Sessions started before the hooks existed have no start event and are never captured or closed.
6. **Set the denylist** in the dotfiles clone (below), before the next push from it.
7. **Dry-run each pass by hand** (below), then load the plists.

## A second instance on one machine

Instances coexist by sharing nothing mutable: each one has its own `DESK_CONFIG`, its own `DESK_STATE_DIR` (so its own status file, lock, guard, runs and caches) with `DESK_STATUS_FILE` (and `DESK_TICKET_CACHE`) exported to the nvim that reviews it, since the status line and marks read those, not the runner's state directory, its own notes repo, and its own plists (different labels, each exporting those variables). What they do share is the machine's Claude Code sessions: the recorder and reader are global, so every instance's capture and close steps see all sessions, including ones the other instance's notes name. Give them disjoint `keep_open` lists and expect a session to be captured or closed by whichever instance's pass gets to it first. The reader's default cache is per config directory, so two accounts never overwrite each other's.

Once the recorder hooks are live, any headless `claude -p` session started outside desk (a script, a CI-style helper) records a start event with no deliberate end, and may therefore show up as a `dropped` capture. Desk's own calls are tagged and excluded; others are not.

## Config reference

`$DESK_CONFIG` is one JSON file. `desk-run` reads it fresh on every run; nvim reads `tokens` from it when a notes buffer opens.

### Top level

| Key | Default | Meaning |
|---|---|---|
| `notes_repo` | required | Absolute path (a leading `~` is expanded) that is a repo's own toplevel. Anything else refuses the pass. |
| `files` | required | The files a pass commits and suggests into, e.g. `["notes.md", "reading.md"]`. nvim attaches to these names (default `notes.md`, `reading.md` when no config is readable). A judge's `input_files` may name any of them, and each is seeded as its committed copy. |
| `captures_file` | first entry of `files` | Where session captures go. Also the file a close call is seeded with. |
| `timezone` | required | IANA zone name; `{{window_start}}`/`{{window_end}}` render in it. |
| `ticket_search_tool` | required | Tool name whose results build the ticket cache. |
| `mail_search_tool` | required | Tool name whose digest search the write step pins thread ids from. |
| `ticket_status_step_id` | required | Id of the fetch step that checks ticket status. |
| `mail_fetch_step_id` | required | Id of the fetch step that searches mail; its reply becomes `f-private.json` (besides the generic `<id>.json` below). |
| `passes` | required | Pass name → pass object. |
| `push_enabled` | `false` | Push the notes repo after committing. Off: status reads `push: disabled`. |
| `dry_run` | `true` | The write step logs the ids it would act on and makes no call. |
| `log_only` | `true` | The close step queues its closure notes and never signals a session. |
| `close_after_working_days` | `3` | Idle threshold for closing, in Mon–Fri days since your last message in that session. |
| `keep_open` | `[]` | Session names never closed. |
| `max_closes` | `3` | Real closes per pass. |
| `away_days` | `5` | A pass more than this many days after the pass's last ok run closes nothing. |
| `follow_up_summary_prompt` | `claude/desk-lib/follow-up-summary.md` | The prompt for a follow-up tab's plain-language turn (`follow_up_step`), relative to the config's directory. |
| `follow_up_status_prompt` | `claude/desk-lib/follow-up-status.md` | The first turn of the status session a follow-up tab opens when there is no session to resume. |
| `retention_warn_days` | `14` | How many days before Claude Code deletes a transcript the `retention` step warns about it. |
| `caps.<name>` | none | `{act, worth_knowing, wildcard}`: how many tiered items a judge may keep. Which entry a pass uses is its `caps` key; absent, `weekly` for a pass named `weekly` and `daily` for every other. |
| `default_max_budget_usd` | `$DESK_DEFAULT_MAX_BUDGET_USD`, `2` | Spend cap for a model call whose step has no `max_budget_usd`. |
| `tokens` | `[]` | The token table, below. |
| `sources_file` | `sources.json` | Relative to the config's directory. Substituted whole into `{{sources}}` and copied to the judge as `sources.json`. |
| `digest_gmail_label` | `Digest` | The label as the Gmail search tool accepts it in `label:`: its label ID, not its display name (the tool's own description: "accepts label IDs, not display names"; get the ID from the connector's `list_labels`). Put that ID here; the default `Digest` only works if that is literally the ID. |
| `gmail_window_lookback_secs` | `172800` | Fetch window on a pass's first run; afterwards the window starts where the last fully successful fetch ended. |
| `slack_workspace_url` | none | When set, a channel/ts pair found in raw tool results also allows its rebuilt permalink as a source. |

The five required tool and step-id fields have no defaults on purpose: this repo cannot ship an instance's tool names. An instance without mail or tickets still sets them, to ids no step uses, as the example does.

### Passes

| Key | Meaning |
|---|---|
| `steps` | Ordered list of step objects. A step that fails (other than a fetch) stops the pass. |
| `trigger.start_calendar_interval` | `[{hour, minute, weekday?}]`, `weekday` 1 = Monday … 7 = Sunday. The runner never reads a plist, so this mirrors the plist's schedule and decides which slot a run belongs to: the once-a-day guard is keyed on that slot's date, so an evening slot that only fires at next morning's wake still counts as yesterday's, and a later slot for a date that already finished ok is a no-op. Without it, the run's own date is used. |
| `trigger.same_day_only` | Boolean, default `false`. `true`: a run whose slot falls on an earlier day than the run itself is a no-op, so a login or a wake only ever catches up today's slot. With `RunAtLoad`, that keeps a weekly pass to the day it missed (a Thursday login after a missed Wednesday does nothing), and a login before a daily pass's first slot waits for that slot instead of running the previous day's. A daily pass loses nothing by it when its fetch window starts at the last successful fetch, as it does by default. |
| `weekdays_only` | Boolean. `true`: when the slot's scheduled date (not the day the runner happens to start) is a Saturday or Sunday, every step but `commit_push` is skipped (notes are still committed, with no model calls). Absent: `true` for a pass named `morning`, `false` for any other name. |
| `caps` | Name of the top-level `caps` entry this pass's judge uses. Absent: `weekly` for a pass named `weekly`, else `daily`. |
| `kind` | `"follow"` makes the pass the follow pass, which takes none of the keys here: its own are in [The follow pass](#the-follow-pass). Absent for every other pass. |
| `follow_up_step` | A step id. After the pass, whatever its result, the most recent `visible` call of that step (found by the session id the runner generated for it, never by display name) opens in a background tab with `claude --resume` (a session already live is left in its tab, never focused). That is one tab per scheduled date: a retry slot the same date, and calls of other visible steps, open none, and a weekend slot of a `weekdays_only` pass opens none at all. Before it opens, that session is resumed headless once more, under the same id, with no tools, no MCP servers and `--restricted`, for one turn written to the user in plain language: what the pass proposed and why, each item related to their notes, and any questions. The conversation then ends on that rather than on the step's JSON reply. The turn is told how the run went (which steps it has, any failed sources, where it stopped), so a quiet run says in a line that nothing needs the user and what was checked, and a partial or failed one says what failed and what still ran. When that call fails or replies in JSON again, the tab still opens, on the step's own reply, and the log says so: the conversation is still there to follow up in, where a tab held back would be lost. A live session gets no such turn. When no call of the step ran (a failure before it) or its session cannot be found, the tab opens a fresh interactive `claude` instead, named `desk-<pass>-<date>-status`, whose first turn reports the run from the same status. Whichever it is, the tab is an interactive Claude Code session, never a plain command. |

The pass names `morning` and `weekly` only supply the defaults of `weekdays_only` and `caps` above; nothing else about a pass depends on its name.

### Steps

Every step has `id` and `kind`. Model steps (`fetch`, `judge`, `write`, `close`, `retention`) also take:

| Key | Default | Meaning |
|---|---|---|
| `prompt` | none | Prompt file, relative to the config's directory. |
| `tools` | `[]` | The exact tool list. Passed as `--allowedTools`, and for a connector call also as `--tools` and to the deny hook. |
| `connector` | `false` | `true` loads your user settings so claude.ai connectors are available; a PreToolUse hook (`claude/desk-lib/deny-unlisted-tool.sh`) then refuses every tool not in `tools`, whatever your own allow rules say. `false` runs `--restricted` with `--strict-mcp-config`. |
| `mcp_config` | empty | Non-connector calls only: an MCP config file (relative to the config's directory) for tools that need a server. |
| `timeout` | `300` | Seconds; the call's whole process group is killed after it. |
| `max_budget_usd` | `default_max_budget_usd`, then `$DESK_DEFAULT_MAX_BUDGET_USD`, then `2` | Passed as `--max-budget-usd`. |
| `visible` | `false` | Persist the session under the name `desk-<pass>-<date>-<id>`, with its cwd kept under `~/.local/state/desk/runs/` for seven days, so it can be resumed. |

A judge, close or retention step whose `tools` include `Read` gets it narrowed to its own scratch directory, by the allowlist and again by the deny hook.

| Kind | What it does | Kind-specific keys |
|---|---|---|
| `commit_push` | Commits the configured files exactly as they are on disk, only when `HEAD` is `main` with no rebase or merge in progress; records suggestions now in `HEAD` as taken; pushes if `push_enabled`. Never pulls, merges, rebases or force-pushes. | none |
| `fetch` | One model call. A failure flags the pass `partial` instead of stopping it; a later slot the same scheduled date reruns only the fetches that failed, reusing the ones that succeeded. If its id is `ticket_status_step_id`, it gets `{{jql}}` and its `ticket_search_tool` results become the ticket cache. | none |
| `judge` | Seeds its input files, makes one call, validates the reply, caps tiered items and builds the proposal. A reply that is not the items shape fails the pass. | `input_files` (default: all eight names listed below) |
| `write` | A pinned single-tool write, currently built around one case: removing a label (`pinned_label`) from mail threads. It removes the label from exactly the threads the `mail_fetch_step_id` step's digest search returned. The deny hook refuses any call whose arguments are not one of those pinned `{threadId, labelIds}` pairs, and the runner fails the pass if the ids acted on differ from the pinned set. Refuses outright if that fetch failed or its search query was not exactly `{{digest_query}}`. | `pinned_label` (default `UNREAD`); `tools`: exactly one |
| `capture` | No model call. Adds a line on top of the captures file (`captures_file`) for each recorded session that is live (`running`) or left open, its last run stopped without a deliberate end (`dropped`, the reader's `left_open`; see "How a session ended" under [How it works](#how-it-works)), once per session and kind. A session you named that is already mentioned in your notes is skipped; an unnamed one is labelled `<auto title> · <first 8 chars of its id>`. | none |
| `close` | For each live session idle at least `close_after_working_days` and not in `keep_open`: one call over the end of its transcript, whose closure note goes into the proposal; then, unless `log_only` or past `max_closes`, a fresh re-check that it is still live and idle, and `SIGTERM`. A survivor is recorded as a failed close and not retried. | `cap`: transcript lines (default `200`) |
| `retention` | Warns before Claude Code deletes a transcript the notes still need. Selects every session the committed notes name (by its user-set name, or its id or an 8+ character prefix of it), that is not live, not a `desk-run` session and not ended as done (the reader's `end_deliberate`, other than a close by a pass, which leaves the work unfinished), whose transcript under `$CLAUDE_CONFIG_DIR/projects` is due for deletion within `retention_warn_days`. Per session, soonest first, one call over the end of its transcript (the same call `close` makes) whose item moves the session's entry to the top of the notes, or adds its name there, with a few bullets on where it stood and the deletion date. Items carry tier `act` and are capped under the pass's `caps` entry before any call is made; overflow goes to the brief. A warning already proposed, taken or declined for the same session and deletion date is not repeated. Nothing resumes, closes or writes to a session: a write would move the transcript's mtime and reset its clock, and that is the user's call. [Retention](#retention) has the rule it rests on. | `cap`: transcript lines (default `200`) |
| `open_tab` | Opens an interactive `claude` in a background Ghostty tab. Skipped when a session named `session_name` (placeholders filled) is already live. | below |

`open_tab` keys: `cwd` and `prompt_text` (both required; `~` expands in `cwd`, and `cwd_outside` is still read as its older name), `session_name`, `restricted` (default `true`: adds `--restricted`, `--permission-mode` (default `default`), `--tools`, and `--strict-mcp-config` when `strict_mcp_config` is true; `false` launches with your own permissions), `mcp_config`, `settings`, `skill` (appended with `--append-system-prompt-file`; all three relative to the config's directory, like `prompt`), `scratch_dir` (a fresh directory under it holds the step's files; the cwd stays `cwd`), and `notes_diff_file` with `notes_diff_since` (writes into that directory your own additions and removals since then, excluding text you took from suggestions). In `session_name` and `prompt_text`, `{{date}}` is the pass's scheduled date (`YYYY-MM-DD`), so a weekly session gets a name of its own each week and the live check asks about this week's; in `prompt_text`, `{{notes_diff}}` is the notes diff's absolute path. `notes_diff_since` is `{"weekday": "wed", "time": "08:00"}`: the most recent such moment on an earlier day than today (never today's own, even when today is that weekday), with the weekday as `mon`..`sun`, a full name or 1 (Monday) to 7, and `time` as `HH:MM` local time. The string `last_wednesday` is an alias for that example.

### Tokens

An ordered list; the first entry whose pattern matches the whole token wins.

```json
{ "pattern": "^ABC-([0-9]+)$", "case_insensitive": true, "handler": "url", "template": "https://tickets.example.com/browse/ABC-{1}" }
```

- `handler`: `url` opens `template` with `{1}`, `{2}`, … replaced by the pattern's captures, and marks the token with its ticket status; `session` resolves the token (or its first capture) as a session name. A last entry of `^.+$` with `session` makes every other token a session lookup.
- `pattern` is read by two engines: nvim reads it as a Lua pattern in which a bare `-` is literal, and the runner reads `url` patterns as an extended regex (anchors dropped, word boundaries added) to find ticket keys in the notes for the ticket check. Keep `url` patterns to what both read the same way: literals, `[...]` classes, `.`, `+`, `*`, `?`, `(...)`, `^`, `$`. Not `%d` (Lua only), and not `\d`, `{n}` or `|` (regex only).

## The prompt contract

A prompt is plain text with `{{name}}` placeholders, filled in one pass; a placeholder the runner does not know stays as written, which the example-instance test treats as an error. Bulk input never goes through placeholders: it arrives as files in the call's cwd, which is `{{scratch}}`.

| Placeholder | Filled for | Value |
|---|---|---|
| `scratch` | every model call | the call's cwd, where its input files are |
| `mode` | fetch, judge, write | `WEEKLY` when the pass's last ok run was in an earlier ISO week (or never), else `DAILY` |
| `today` | every model call | `YYYY-MM-DD` |
| `window_start`, `window_end` | fetch, judge, write | the fetch window, ISO 8601 in `timezone` |
| `slack_oldest`, `slack_latest` | fetch, judge, write | the same window, epoch seconds |
| `digest_query`, `inbox_query` | fetch, judge, write | `label:"<digest_gmail_label>" after:<epoch> before:<epoch>`, and the same for `in:inbox` |
| `sources` | fetch, judge, write | the whole sources file |
| `jql` | the `ticket_status_step_id` fetch | `key in (...)` over every ticket key the notes mention |
| `caps` | judge | e.g. `ACT ≤3, worth knowing ≤3, wildcard ≤1` |
| `thread_ids` | write | the pinned ids, one per line |
| `session_name`, `session_id` | close, retention | the session being closed or warned about |
| `pass`, `run_status` | the follow-up summary and status | the pass's name, and a paragraph on how its run went: its steps, and whether all ran, which sources failed, or where it stopped |
| `items`, `item_count`, `open_note` | the follow-up summary and status | the pass's own staged items as a JSON array (`file`, `kind`, `headline`, `tier`, `source`, `before`, `after`), how many, and a line about older items still waiting, or empty |
| `deletion_date`, `days_left` | retention | `YYYY-MM-DD` the transcript can be deleted from (today when already due), and the whole days until then |

A close prompt gets only `scratch`, `today`, `session_name` and `session_id`; a retention prompt gets those plus `deletion_date` and `days_left`; a follow-up summary or status prompt gets `pass`, `today`, `run_status`, `items`, `item_count` and `open_note`. The summary runs as a turn of the session it summarises, so it has that conversation and no input files; the status prompt is the first turn of an interactive session, with the user's own permissions, like the follow-up tab itself.

**Fetch steps.** What counts is the raw tool results, never the reply's prose: every URL that appears verbatim in any fetch step's tool *results* is what a judge may cite, and a URL that only appears in a call's arguments (the address passed to WebFetch) does not count unless a result repeats it. Any fetch step's reply becomes `<its id, lowercased>.json` (id `F-web` gives `f-web.json`), and the `mail_fetch_step_id` step's also becomes `f-private.json`, each only if it is valid JSON; a judge reads them by listing those names in `input_files`. The ticket step must call `ticket_search_tool` with `{{jql}}`; its results are read in either Jira search shape, `{"issues": [...]}` or `{"issues": {"nodes": [...]}}`, and its reply is ignored. The mail step must search with `{{digest_query}}` exactly, and the write step reads `threads[].id` from that result.

**Judge input files**, chosen by `input_files`:

| File | Contents |
|---|---|
| each name in `files` (`notes.md`, `reading.md`) | the committed file, with each line you took from a suggestion suffixed `  <<agent-suggested>>` |
| `sources.json` | the sources file |
| `f-private.json`, `<id>.json` (e.g. `f-web.json`) | those fetch replies, `{}` when absent or invalid (`f-` names) |
| `tickets.json` | `[{key, summary, status, previous_status}]` for tickets whose status changed since the last check |
| `sessions.json` | `[{name, status}]` from the reader |
| `open-items.json` | suggestions still waiting on you, in the item shape below, with their runner-assigned ids |
| `declined.json` | the 50 suggestions you most recently declined, same shape; a declined suggestion is also blocked by content (file, kind, target, normalised before/after), so a regenerated copy under a new id is dropped even without a URL source |

A close or retention call's cwd holds `session.json` (its reader entry), `transcript-tail.jsonl` and the captures file (`notes.md` by default).

**The reply** of a judge, close or retention call is its final message: one JSON object `{"items": [...]}` (a bare array is accepted too), nothing else.

| Field | Meaning |
|---|---|
| `id` | unique within the reply; the runner rewrites it to `<pass>-<scheduled date>-<n>-<id>` |
| `file` | one of `files` |
| `kind` | `new`, `add`, `link` (insert); `edit`, `remove` (in place); `move`, `merge` (remove in one place, insert in another) |
| `target` | `"top"`, `{"under": line}` (end of the block that line heads), `{"after": line}` (end of the block containing it), or `{"at": line}`, the first line of `before`, for `edit` and `remove`; `move` and `merge` take `[{"at": …}, <landing anchor>]`. A quoted line is a whole line, matched exactly, at least three characters. |
| `before` | the exact existing lines for in-place and moving kinds, else `""` |
| `after` | the new text, `""` for `remove` |
| `source` | a URL from the fetch results, or a non-URL tag such as `notes` or `ticket:ABC-1` |
| `headline` | a few words for the overview |
| `tier` | optional: `act`, `worth_knowing` or `wildcard`; only tiered items are capped |
| `also_sources` | optional: other URLs for the same story |
| `supersedes` | optional: the id of an open item this replaces |

An anchor whose quoted line has gone lands the item on top; an `edit` or `remove` whose `before` no longer sits at its anchor is deferred and retried next pass. Every item is placed against the committed text, never against what another item made of it: an `edit`, `remove`, `move` or `merge` takes away only its own `before` lines, so whatever lands beside them stays, and an edit's new text sits below anything inserted at the same spot. Two items that take away the same line cannot both apply; the one listed first does, and the other is deferred. Blank lines at the edges of `after` are fitted to where it lands: one is kept on a side where it separates the text from a line that is not blank, and any other is dropped, so an item can add the blank line between two sections but never doubles one or leaves one at the file's start or end. A `move` of a block that stands between blank lines, a section, takes one of them along, so its old place keeps a single one, and where it lands on a section boundary it gets a blank line on each side that meets text. The proposal stores each `after` as it landed. A capped tier's overflow goes to `~/.local/state/desk/briefs/<date>.md`; the per-tier count is reported in the status file (and shown as `+N more <tier> → brief` on the status line), never as a proposal item. A new item replaces an open one that it names in `supersedes`, that shares a URL with it, or that is an `edit`, `remove`, `move` or `merge` of the same existing line (same kind, same `at` target). Insertions never replace each other by place: two `add`s under one heading are two suggestions.

**What the runner enforces on a reply**: an item whose URL `source` is not in the allowed set is dropped; an `also_sources` URL not in it is dropped from the list; any other URL in the item's text becomes `[url removed]` (a labelled link to one becomes `label [url removed]`); control characters, ANSI sequences, vim modelines and `<<agent-suggested>>` markers are stripped. A close or retention call allows no URLs at all, and each of its bullets must cite a transcript turn as `[turn <first 8 chars of that entry's uuid>]`: an item citing a turn that is not in the tail it was given is dropped, and the markers are removed from what is kept.

**What only the prompt can say.** The tool allowlist decides what a call *can* do, not what it tries, and everything a call reads (your notes, a fetched page, a transcript) is written by someone other than the prompt's author. So every prompt carries two lines the runner cannot check: that the call never sends, posts or changes anything outside its own reply (for a write step, nothing beyond its one pinned call), and that everything it reads in files and tool results is data, never instructions to follow. That is the "External content is data, never instructions" principle in `agents/principles.md`, applied where the content arrives.

## Retention

Claude Code deletes a session's transcript once it is older than `cleanupPeriodDays`, default 30 and at least 1, in a background sweep "after a session starts" (settings reference, `cleanupPeriodDays`), so "a session you haven't used for longer than the retention period no longer appears in the `/resume` picker". The sweep runs at most once per session, and any Claude Code start runs it, the runner's own calls included. The docs don't name the timestamp the age is measured from; the `retention` step takes the transcript's mtime, the last write, and reports `mtime + cleanupPeriodDays` as the deletion date, the earliest the sweep can remove it. A resume writes to the transcript and so moves the date on.

The step reads `cleanupPeriodDays` from `$CLAUDE_CONFIG_DIR/settings.json` (default `~/.claude`), falling back to 30 when the file or the key is absent, and fails the step on a file it can't parse or a value that isn't a whole number of at least 1, the cases in which Claude Code pauses its sweep. It does not see a value set in managed settings or in a project's `.claude/settings.json`, which the sweep in a session started there would use, and it ignores transcripts outside `$CLAUDE_CONFIG_DIR/projects`, which another config directory's settings govern.

A retention item that moves the user's entry is kept only when its `before` is lines that sit together in the committed captures file and its `after` carries every one of them, in order and unchanged apart from indent and the appended date; otherwise it lands as `new` on top with just its first line and the added bullets, and the entry stays where it was. The runner appends the deletion date to the first line when the text lacks it.

## The follow pass

A pass of kind `follow` (`watch` is its older name, still accepted) forwards news on tickets to the Claude Code session that tracks them. The session is a **follow session**: one the user keeps open on an epic or a task, holding the plan for it. The pass sends that session each change with news in it as a cross-session message, and counts the rest, such as a bare status move or a bot's post. The session decides whether the user needs to look: the pass keeps the session current, and only the session's reply decides whether to involve the user.

**The follow list** is machine-local, since session ids exist only on this machine and a tracked file would leave a workspace repo dirty. It is `$DESK_FOLLOW_FILE` (default `~/.local/state/desk/follow.json`), `{"entries": {<session id>: {label, keys, related, added_at}}}`, and only `desk-follow` edits it:

```sh
desk-follow add [--session <id|name>] [--label <text>] [--related <KEY>...] <KEY>...
desk-follow remove [--session <id|name>] [<KEY>...]   # no keys: the whole follow
desk-follow list [--json]
desk-follow run [--dry-run] [--lookback-minutes N]    # one run now
```

`--session` defaults to `$CLAUDE_CODE_SESSION_ID`, which Claude Code sets in its Bash tool, so a session can register itself. The `desk-follow` skill (`agents/skills/desk-follow/`) tells a session what each ask means. A list or state file still at the older default paths (`watch.json`, `watch-state.json`) moves to the new one the first time either is looked for, and the older overrides `$DESK_WATCH_FILE` and `$DESK_WATCH_STATE_FILE` still apply. `list --json` is the seam for a later pass: each entry's liveness, queue, last send, and `all_closed_since` once every tracked and related ticket's status is in the done category.

**Telling a session it is followed.** A follow added from outside its session (`--session` names another session than `$CLAUDE_CODE_SESSION_ID`), or one whose keys change, also sends that session one short intro: it is now a followed session, which tickets, to load the `desk-follow` skill, and that a handoff carries what the skill's "Before compacting" lists. It goes through `desk_follow_send`, the same restricted, pinned send the pass uses, so it needs the pass's config and a live session whose name addresses it alone. Run inside the target session itself, `add` sends nothing, since the skill is loaded there. When the session is not running, or the send fails outright, the intro waits as `intro_due_at` on the entry and leads the session's first update instead, once (`intro_done` in the state file records it). A send that ran but was not confirmed is not queued, since it may have landed. Adding the same keys again, and removing, send nothing.

**What a run reads**, read-only:

- **Tickets**, in one restricted model call whose only tool is the configured search tool, running two queries the runner builds. The scope query, every `scope_refresh_minutes` or when the keys change, fetches the tracked keys, the related keys, and the children of the tracked keys. A session's scope is then those, plus every ticket linked to a tracked key or to a child (one hop, any project), except a ticket another followed session owns: one of its tracked keys or their children. That ticket's news goes only to the session that owns it, whether it would have reached another through a link or by mentioning one of its keys, so two sessions on neighbouring work don't hear about each other's tickets. A ticket two sessions both track goes to both, and so does one a session lists among its related keys. The changes query fetches every ticket in a scope, every child, and every ticket whose text mentions a tracked or related key, updated within the window. Results count only from calls whose `jql` is exactly the one the runner built.
- **Pull requests**, through `gh pr list` and `gh pr view` only (any other `gh` subcommand is refused), in each of `github_repos`, updated within the window, whose title or branch carries a key in some session's scope. Comments and reviews are fetched only for a PR that moved since its snapshot.

**What counts as a change.** Each ticket and PR is snapshotted in `$DESK_FOLLOW_STATE_FILE` (default `~/.local/state/desk/follow-state.json`), so a change is a difference from the snapshot. For a ticket that is status, summary, assignee, resolution, parent, labels, links, a description edit, and new or edited comments. For a PR it is state, draft, review decision, title, new commits, labels, a description edit, a change in the failing checks or a check run finishing, and new comments and reviews. The window runs from the last fetch of that source that came back, with five minutes of overlap; comment and review ids keep the overlap from repeating anything. A source's first run records snapshots and sends nothing. A failed fetch keeps that source's window where it was.

**What is forwarded, and what is only counted.** A follow session gets the changes with news in them. The rest is counted in the message's footer, by kind, so nothing goes missing silently. The split is deterministic, decided by the runner rather than a model, because every rule below is a property of the data:

| Forwarded | Counted, not listed |
|---|---|
| New or edited comments, reviews and PR comments by people | Comments and reviews by bots (`bot comments`, `bot reviews`) |
| A description edit, a rename or retitle, new commits on a PR | A status or resolution move with nothing else on that ticket (`status moves`); a PR merging, closing, going draft or ready, or changing review decision (`PR state changes`) |
| A reassignment, a move to another parent, a link added or removed | Labels (`label changes`), and check results (`check results`) |
| A ticket created in the window, a new child under a tracked key, a PR opened in the window | A ticket or PR only seen for the first time, with no snapshot to compare (`first-seen tickets`, `first-seen PRs`). This covers a ticket that merely mentions a key, and every ticket in a `--lookback-minutes` run. Its comments in the window are still forwarded. |

A ticket's field changes travel together: when any of them is forwarded, the line carries all of them, the status move included. A post is a bot's when its author matches one of the pass's `skip.bot_authors`, or when its body opens with one of `skip.bot_signatures`, which catches a bot posting through a person's account. A person quoting bot output further down a comment is still a person. Both lists are regexes in the instance's config, since which accounts are bots is the instance's knowledge. A run that has only counted changes sends nothing. Its counts carry over into the footer of the next message that goes out, and reset once that message is confirmed.

**Delivery.** Changes queue per session. For each session with a non-empty queue, the reader resolves the session id to its current name, since the name is the address and the user renames sessions. The message is sent only when the session is live and resolving that name gives back the same id. A session that isn't running, or one whose name another live session shares, keeps its queue, and gets everything in one message the next time it is reachable. The send is one restricted model call whose only tool is SendMessage. The deny hook pins its `to` and `message` to exactly the resolved name and the runner-built text (`--pinned` with `--ignore-keys`, for the transcript-only `summary` and the preview fields Claude Code adds to a SendMessage call's input: `content`, `type`, `recipient_kind`; the `recipient` it adds must equal `to`), so it can reach no other peer. The queue empties, and the session's last-sent time moves, when that exact call ran and its result reports a delivery: SendMessage answers a peer send with `{"success": true, "message": "“<first line>” → <name> (…)", "msg_id": …}`, and it confirms when it names the recipient and reports no outcome such as refused, held or dropped after it. The words in brackets are boilerplate naming what *may* still happen, and the quoted preview is the pass's own text, so neither is read as an outcome. A hold the receiver applies later is reported only as a delivery notice, which never reaches a headless sender: that is what the permission-class rule below prevents. A call that never ran, or a result of `success: false` (an unreachable name, a refusal), sent nothing: the queue stays, and the next scheduled try waits, doubling from `interval_minutes` up to four hours (a manual run always tries). A call that ran but whose result does not confirm may have delivered anyway, so a queue gets two such sends; after the second its changes count as sent, `last_sent` records `confirmed: false`, and the log says so, rather than the same message going out every run. Each outcome logs the tool's result.

**The message** starts with `[desk-follow] Update for <label>: …. Not from the user.`, the marker a hook can tell a follow turn by. Next comes the instance's standing preamble (`preamble`), so a session handles the message correctly even after compaction. Then the forwarded changes since the last send, oldest first, one line each: time, ticket or PR, title, how it relates to the session's keys, and what moved. When another followed session also has that ticket (as a key, a child of one, or a related key; for a PR, any of its keys), the line says so with that session's current name, `(also followed by <name>)`, so the session knows it is not alone with it. Past `message_max_chars`, later lines are named by ticket only. The last line is the footer: `Skipped since the last update, not listed: 4 status moves, 9 bot comments.`, or `nothing`. The preamble is where the instance states the bar for involving the user, and the reply contract: a reply that starts with `[needs-you]` and says in plain language what needs the user, or one quiet line otherwise. `claude/hooks/input-bell.sh` rings on an idle turn whose reply starts with `[needs-you]` or ends on a direct question, so a quiet reply must do neither.

**Permission class.** Every call runs with `--permission-mode dontAsk`, which Claude Code counts with the prompting modes (default, auto, acceptEdits). A sender and receiver in different classes (bypass against prompting) have their messages held for the receiver's approval, then dropped after five minutes. So the follow pass must never run in bypass mode, and a follow session must not run in bypass mode either.

**Its own path.** `desk-run <pass>` hands a follow pass to `claude/desk-lib/follow.sh` before anything else: no once-a-day guard, no shared runner lock (it takes its own, `follow`, and waits at most a minute for another follow run), no notes repo, no status file. `--scheduled` (what the plist passes) skips a run that comes less than `interval_minutes` after the last one. A manual run always runs. `--dry-run` fetches as usual, prints each message it would send, and sends nothing and writes no state. `--lookback-minutes N` sets the window to the last N minutes for that run and doesn't move the stored windows; with `--dry-run`, that previews real traffic on a machine with no state yet.

| Key (under the pass) | Default | Meaning |
|---|---|---|
| `kind` | required | `"follow"` (or `"watch"`) |
| `interval_minutes` | `15` | The schedule's spacing. Values under 15 are clamped to 15, with a log line. Keep the plist's `StartInterval` at this many seconds. |
| `scope_refresh_minutes` | `60` | How often the scope query reruns. |
| `jira.tool`, `jira.prompt` | required | The search tool and the prompt that runs the two queries. The prompt gets `{{scope_jql}}` and `{{changes_jql}}` (each `none` when it doesn't run), `{{scope_fields}}`, `{{changes_fields}}` and `{{today}}`. |
| `jira.mcp_config`, `jira.model`, `jira.timeout`, `jira.max_budget_usd` | none, the account's default, `300`, `1` | As for a step. |
| `jira.max_output_tokens` | `2000` | Passed as `MAX_MCP_OUTPUT_TOKENS`. A search result past it is saved to a file instead of reaching the model, and the runner reads that file (`desk_call_model --spill-dir`). So the tickets' text stays out of the model's context, which is cheaper and gives that text nothing to steer. The cost is pagination: the call can't see a next-page token in a saved result, so a query whose last page says more follow counts as failed. Keep each query under the 100 results one page holds. |
| `github_repos` | `[]` | `owner/name` repos whose PRs are matched. |
| `send.prompt` | required to send | Gets `{{to}}` and `{{message}}`. It must tell the call to send exactly that, once. |
| `send.model`, `send.timeout`, `send.max_budget_usd` | the account's default, `180`, `1` | |
| `preamble` | `prompts/follow-preamble.md` | The standing preamble, relative to the config's directory. |
| `message_max_chars` | `8000` | The send call copies the message into its tool call, and the deny hook refuses any copy that is not exact, so a shorter message is likelier to go through first time. |
| `queue_max` | `200` | Per session; older changes past it are counted, not kept. |
| `skip.bot_authors` | `[]` | Regexes, case-insensitive, for the author names of automated accounts: a GitHub login, or a Jira display name. |
| `skip.bot_signatures` | `[]` | Regexes for the opening of a post a bot makes through a person's account, matched against the raw body after leading whitespace. |

## Review keys

In a notes buffer:

| Key | Action |
|---|---|
| `<leader>gR` | Open the review split above your notes and focus it, or focus the one already open. Reopening over a split with unsaved declines asks to save, discard or cancel. With nothing to review in this file but some in the other, the review opens on the other file instead, in the same window. |
| `<leader>gc` | Save the open buffers of the notes files (the config's `files`), commit each one that has changes in one commit, and record suggestions now in `HEAD` as taken. The message says what changed, as in `Take 6 suggestions, edit 3 sections`, with a body listing the taken suggestions' headlines and the sections your own edits touched, one line each and prefixed with its file when the commit has more than one, cut at 72 columns with `…` rather than wrapped. A section is headed by the nearest column-0 line at or above a changed line that is not a `- ` bullet, or is one with indented lines under it, as a session's name heads its notes; a column-0 bullet with nothing under it belongs to the heading above it, and a heading you reworded is one section, by its new name. Lines a taken suggestion brought in or took out are not your edits; a take you reworded counts as both. |
| `<leader>go` | Overview: a quickfix list across the top of the screen with one headline per remaining diff hunk, a suggestion in the other file prefixed with its name. As the cursor moves in the list, the review split shows the entry's suggestion, cursor on it, while you stay in the list. `<CR>` jumps to it in the review split, where `dp` takes it, or in your notes window when no review is open; on an entry in the other file it instead moves the review to that file and previews the entry there, leaving you in the list to keep going down it; `Ctrl-O` after the jump goes back to where the split's cursor was before the list moved it. Without leaving the list, `t` or `dp` takes the entry's suggestion and `x` or `gD` declines it, as `<leader>gA` and `<leader>gD` do in the split: recorded on the split's save, undone with `u` there. `t`/`dp` and `x`/`gD` on an entry in the other file need its review open first, which `<CR>` does by moving the review there. `q` closes the list and `Q` ends the whole review, list and split, as `<leader>gq` does. The list's title names these keys. A list left open while the review reopens over a new proposal, or moves to the other file and back, follows the review that is open. As in the review's windows, the list's keys are in a bar above it, its status line below is just its name and position, and its highlighted entry is the one under the cursor. A key that can't act on an entry says why in one line. |
| `<leader>gd` | Declined in the last 14 days (also `:DeskDeclined`); `r` on an entry restores it, so the next pass proposes it again. |
| `<leader>gx` | The hotkey: act on the token under the cursor. The review split has it too. |

In the review split:

| Key | Action |
|---|---|
| `n`/`N` | Next or previous suggestion, wrapping from the last to the first and back with a message saying so. While a search is highlighted they are the search's own; `:noh` gives them back. `]c`/`[c` do the same at any time. |
| `dp` | Take the diff hunk under the cursor into your notes buffer: every adjacent suggestion in it, as `do` from the notes window does. For a suggestion that only removes lines, the cursor goes on the line just above or just below its grey filler; `]c` lands below. |
| `<leader>gA` | Take just the suggestion under the cursor into your notes buffer. |
| `<leader>gD` | Decline the suggestion under the cursor. |
| `u` | Undo the latest take or decline made here or from the overview. A take is undone in your notes buffer, unless you have edited your notes since, when it says so and leaves them alone; anything else is plain undo. |
| `<leader>go` | The overview. |
| `<leader>gc` | Save the split's declines, then commit your notes as `<leader>gc` in them does. The review stays open. |
| `<leader>gR` | Once this file has no suggestion left, move the review to the other file, in the same two windows, asking first about unsaved declines; with some left it says how many. The bar shows what waits there, as in `reading.md: 2 more ␣gR`. When another nvim has the other file open (its swap file is there), it says so in one line, with that nvim's pid, and the review stays as it was. |
| `zo`/`zc`, `zR`/`zM` | Open or close the fold of unchanged lines under the cursor; open or close them all. |
| `:w` | The commit point: records as declined every suggestion whose lines are gone from both the split and your notes, restores any declined this session whose lines are back, and records pending takes. |
| `<leader>gq` | End the review, from either window: unsaved declines ask to save, discard or cancel, and you are left in your notes. The overview goes with it. Only the notes window's bar names it; the split's is full. |
| `:q`, `:wq` | `:q` from either window ends the review and leaves you in your notes; `:wq` in the review split also saves declines. Quitting the split without saving records nothing; quitting your notes window over unsaved declines asks to save, discard or cancel, and cancelling puts your notes back below the split. A review that moved to the other file ends in the file it started from, as you left it. |

In your notes window while a review is open, keys that go when it ends. The suggestions' own lines are grey filler on this side, so a key here acts on the hunk the cursor is in: the one over the cursor line, else the filler just above it, else just below.

| Key | Action |
|---|---|
| `n`/`N`, `]c`/`[c` | As in the review split, wrapping around. |
| `do` | Take the diff hunk: every adjacent suggestion in it. |
| `<leader>gA` | Take just one suggestion of the hunk, the topmost; pressed again it takes the next. |
| `<leader>gD` | Decline one suggestion of the hunk, the topmost, which goes from the split; pressed again it declines the next. Recorded on the split's save, as a decline there is. |
| `u` | Undo the latest `<leader>gA` or `<leader>gD` made here while nothing has changed since, else plain undo, which is how a `do` take is undone. |
| `<leader>gq` | End the review, as in the review split. |

Not taking something is either a decline, from either window, or leaving it alone: an untaken suggestion comes back with the next pass.

A `move` or `merge` shows as two hunks, its removal at the old place and its landing at the new one, and is only ever taken or declined whole. `dp`, `do`, `<leader>gA` and the overview's take on either hunk take both places, and say so in one line, as in `took the whole move: removed here, added under Section C`; the decline keys decline both. One already taken in one place, by hand or by an older take, gets the other place on its next take, and declining it removes just its landing, leaving your notes as they are.

A take is remembered when you make it and recorded on the next save of either buffer, so a suggestion you edit right after taking stays taken. The notes window's winbar shows the status line: each pass's last result, untaken suggestions, closes and lockouts. While a review is open its count is that review's own, live first and recorded after, as in `30 left (34 saved)`: the first is the suggestions in this file neither taken nor declined, counting unsaved takes and declines as done, so it moves as you work; the second is what the ledger and `HEAD` say, which moves on a save or a commit. With no review open it is the recorded count over both files, `proposal pending (34 untaken)`. Every bar puts its keys on the left and its count or status line on the right, so the two windows read the same way: with no review open, the keys you are likeliest to forget, `<leader>gR`, `<leader>gx`, `<leader>go` and `<leader>gc`; in the review split, its keys in one line, `zo`/`zc` for folds, `<leader>gc` and `C-n` for the window below, then what waits in the other file and the same count; in the notes window, its own keys, `<leader>gc`, `<leader>gq` and `C-t` for the window above.

## Scheduling

One LaunchAgent plist per pass, each running `desk-run <pass>` with `DESK_CONFIG` and a `PATH` that reaches bash 4+, `jq`, `nvim`, `perl`, `rg`, `claude` and `~/.local/bin`. `claude/desk-example/com.local.desk.morning.plist` is the pattern: launchd expands neither `~` nor `$HOME`, so it runs through `/bin/sh -c`, and it appends the pass's log to `~/.local/state/desk/logs/`. Set `CLAUDE_CONFIG_DIR` there too if your sessions live in a config directory other than `~/.claude`: the capture and close steps read sessions from it. Keep `StartCalendarInterval` equal to the pass's `trigger.start_calendar_interval` (launchd's `Weekday` uses the same 1–7 numbers). Several slots per pass are the retry mechanism: once a scheduled date finishes ok, later slots for it do nothing.

**Missed slots.** launchd runs a `StartCalendarInterval` slot missed while the Mac slept once it wakes (several missed ones coalesce into one run), but not one missed while it was off: after a restart or shutdown the job waits for its next slot. `RunAtLoad`, as in the example plist, closes that gap: the job also runs whenever launchd loads it, which is at every login, and the once-a-day guard makes the day's later slots no-ops. A login before the day's first slot belongs to the previous day's last slot (`trigger.start_calendar_interval` above), so it runs only if that day never finished, and then the first slot runs the day's own pass too; `trigger.same_day_only` makes that login a no-op instead. A weekly pass with `RunAtLoad` needs `same_day_only`, or the first login of any day after a missed slot runs it. `RunAtLoad` fires at `launchctl bootstrap` too, so enabling such a job runs its pass straight away.

A follow pass's plist uses `StartInterval` (seconds, `interval_minutes` × 60) instead of `StartCalendarInterval`, and runs `desk-run <pass> --scheduled`. launchd doesn't run a missed interval while the Mac sleeps; the first one after wake covers the whole gap, since the window runs from the last fetch that came back.

**Loading.** A job loaded with `launchctl bootstrap` stays loaded until a `bootout` or the next logout; at login, launchd loads only what is in `~/Library/LaunchAgents`. So a job that should survive restarts is linked there from the instance repo, and enabled by bootstrapping the link:

```sh
ln -s /path/to/instance/com.local.desk.morning.plist ~/Library/LaunchAgents/ \
  && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.desk.morning.plist
launchctl kickstart gui/$(id -u)/com.local.desk.morning    # run once now
launchctl bootout gui/$(id -u)/com.local.desk.morning \
  && rm ~/Library/LaunchAgents/com.local.desk.morning.plist
```

Link a job only once its instance runs cleanly by hand: from then on it runs on its own at every login. Until then, `bootstrap` straight from the instance path tries it for one login session, and one `bootout` undoes it.

## The denylist

The dotfiles clone refuses to push until `desk.denylist` is set in it, once, locally:

```sh
git -C ~/dotfiles config desk.denylist /path/to/instance/denylist.txt
```

The list holds one Perl regex per line (`#` comments), matched case-insensitively unless a line turns that off with `(?-i)`, against every commit message and diff being pushed. Its point is to keep the instance's own names (tools, hosts, ticket keys, people) out of this public repo, so it lives in the instance repo and is never tracked here; its contents would be the leak. A missing or empty list refuses too. `none` opts out explicitly. `git-hooks/pre-push` runs the check only when the repo being pushed is this one, since `core.hooksPath` points every repo on the machine at the same hooks. To check a range by hand: `git-hooks/desk-denylist-check.sh <repo> <range> <list-file>`.

## Dry-running a new instance

The defaults are the safe side of every outward-facing switch: `dry_run` (no write call), `log_only` (no session signalled) and `push_enabled` off. Fetch and judge calls are real model calls even then, `follow_up_step` makes one more for its summary turn, and it and `open_tab` open real tabs.

- **Offline**, to check the config and prompts: point `DESK_CLAUDE_BIN` at a stub that prints a stream-json result, `DESK_OPEN_TAB_BIN` and `DESK_FOCUS_TAB_BIN` at stubs, and `DESK_STATE_DIR` and `CLAUDE_SESSION_STORE` at a temp directory, then `DESK_CONFIG=… desk-run <pass>`. `nvim/tests/desk-example-instance-test.sh` is a worked version, and checks that every placeholder a prompt uses is one the runner fills.
- **Live, without side effects**, against a copy: clone the notes repo to a temp path, point `notes_repo` at the clone in a copy of the config, and run each pass by hand with `DESK_STATE_DIR` set to a temp directory so the real status file, ledger and caches stay untouched. Read the log and `status.json`, then `<leader>gR` in the clone.
- Then on the real repo with the defaults still on, then each switch one at a time.

## Tests

```sh
DESK_GUARD_REPOS="$HOME/dotfiles" bash tests/run-all.sh
```

`tests/run-all.sh` runs every suite it names (a new file runs only once listed there) with safe defaults exported first: state and the reader cache under a temp directory, refusing stubs for `claude`, the tab helpers and the URL opener, and an empty reader, so a test that forgets an override fails instead of acting. It snapshots `git config --local --list` of every repo in `$DESK_GUARD_REPOS` (colon-separated; default this repo's main checkout) and the content hashes of `~/.local/state/claude` and `~/.local/state/desk` (Claude Code's own `locks/` is skipped, and the recorder's event files and log, which any open session appends to, are compared by path only), and fails if either changed. `git-hooks/pre-commit` applies the same guards when it runs the hook tests. Tests that create repos use `tests/lib/git-safety.sh`, which refuses a root outside a temp directory and isolates git from the real global config.

The two live canaries, `nvim/tests/desk-run-canary.sh` and `desk-run-canary-restricted.sh`, make one real model call each to prove that an unlisted tool is refused on the connector and restricted paths. They are never in `run-all.sh`, and skip unless `DESK_CANARY_LIVE=1`. Likewise `hammerspoon/tests/tabs-live-check.sh` opens one real background tab that closes itself, and checks that focus is unchanged, that no visible window anywhere moved or resized, that a new window it needed is not over the focused one, that Ghostty's saved position is the focused window's again, and that the tab is gone by the end. It skips unless `DESK_TABS_LIVE=1`; `tabs-live-check-selftest.sh` checks its own parsing and exit codes offline.

## State and overrides

Everything the runner writes lives under `~/.local/state/desk` (`$DESK_STATE_DIR`): `status.json`, `ticket-status.json`, `lock/`, `guard/`, `scratch/` (removed after each pass), `runs/` (visible calls, kept seven days), `fetch-cache/`, `briefs/` and `logs/`. Each has its own override, read at the top of `claude/desk-lib/common.sh` and the file that owns it, which is also where the timing knobs (`DESK_LOCK_MAX_WAIT_SECS`, `DESK_STALE_RUNNING_MINUTES`, …) are. The recorder's store is `$CLAUDE_SESSION_STORE`. Both nvim and the runner locate the tab helpers through `$DESK_OPEN_TAB_BIN` and `$DESK_FOCUS_TAB_BIN` (`close-session.sh` its own through `$DESK_CLOSE_TAB_BIN`) (the older `$DESK_OPEN_TAB` and `$DESK_FOCUS_TAB` still work as aliases on both sides). nvim also reads `$DESK_READER` and `$DESK_OPEN_URL`. All default to the names on `PATH` and `open`.
