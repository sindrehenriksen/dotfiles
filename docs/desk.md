# Desk

Desk is a notes file you edit by hand, plus scheduled passes that read it alongside whatever sources an instance configures and *propose* changes to it. A proposal never touches the file: it waits as a commit beside it, and you review it as a diff in nvim, taking or declining one suggestion at a time. Around that sit a recorder and reader for Claude Code sessions, so the notes can name a session and a pass can capture or close one, and a hotkey that acts on whatever token is under the cursor.

This repo holds the mechanism only. Everything that makes it someone's (which sources, which tools, which ticket keys, the prompts, the schedule) is an **instance**, kept in a private repo and pointed at by `$DESK_CONFIG`. Nothing about an instance belongs here; `claude/desk-example/` is a complete, work-free instance to start from, and `nvim/tests/desk-example-instance-test.sh` keeps it runnable.

macOS only: tabs open in Ghostty through Hammerspoon, and passes run from launchd. There is no Linux counterpart.

## How it works

**The notes repo.** A private git repo holding `notes.md` and `reading.md` at its root, on branch `main`, with an empty `.desk-notes` marker file. The marker, not a path, is what tells nvim a buffer is a desk notes file, so this repo never names where the notes live. nvim attaches to the config's `files` (default those two names), and session captures land in `captures_file` (default the first entry of `files`).

**Passes.** `desk-run <pass>` runs one pass from the config: an ordered list of steps, each of one kind (below). Every model call is a headless `claude -p` with an exact tool allowlist, from a scratch directory outside any repo, under a timeout and a spend cap. A pass ends by writing `~/.local/state/desk/status.json`, which the status line reads. One lock is shared by every pass, since they all write the same repo and status file; a run that cannot get it waits up to 30 minutes, then gives up and says so in status.

**The proposal.** A pass that suggests anything writes one commit to `refs/desk/proposal` in the notes repo: its parent is your `HEAD` at pass time, its tree is the configured files with every suggestion applied, plus `proposal.json` listing the items. The next pass rebuilds it from your newest `HEAD`, plus the previous items you neither took nor declined, plus its own new ones. Leaving a suggestion alone therefore means "not now". On top, items whose id starts with `morning-` (the morning pass's) sort above every other pass's, whichever pass ran last; within a pass they keep the pass's order. What you decided lives on `refs/desk/ledger`: declines (by item id, by source URL, and by content — file, kind, target and normalised before/after — so a declined link or a regenerated copy is never proposed again) and takes (so a taken suggestion's text is recognised as agent-written later, even after you edit or moves it).

**The review.** In a notes buffer, `<leader>gR` merges your current buffer with the proposal and opens the result in a stacked split, both windows in diff mode. Taking is an ordinary diff take; declining makes the suggestion equal your text; nothing is recorded until you save the review split. The keys are in [Review keys](#review-keys).

**Sessions.** `claude/hooks/session-recorder.sh` appends a start and an end event per Claude Code session to `~/.local/state/claude/session-events/<session id>.jsonl`, wired from `claude/settings.json` as the `SessionStart` and `SessionEnd` hooks. `claude/session-status.sh` (the reader) joins those events with Claude Code's own pid files and transcripts under `$CLAUDE_CONFIG_DIR` into one JSON line per session: name, liveness, cwd, tty, last human message and more, documented in its header. `session-status.sh resolve <token>` finds one session by the name you gave it, or by its session id or a unique prefix of 8 or more characters (what an unnamed capture is labelled with); several matches are reported, never ranked by id. Sessions the runner starts are recorded with source `desk-run`, so a capture never mistakes one for one of yours.

**One session, two processes.** A session can be open in two Claude Code processes at once, when it is resumed in a second window while the first still runs. Start and end events fired from a hook therefore carry the pid of the process that fired them, and the reader matches each end to its own process's start: a session is `ended` only once none of its processes is live. While two are live, both of their pid files name the session and `duplicate_pids` is true, so the hotkey and the close step refuse to act on it. When a process starts on a session another live process already holds, the recorder's `SessionStart` hook returns a `systemMessage`, so Claude Code shows a warning naming the other process's tty and pid; the hook never blocks the start.

**Marks and the hotkey.** Each token in a notes buffer that the config's `tokens` table classifies gets virtual text: a session name shows that session's state from the reader, a ticket-like token shows its status from the ticket cache a pass writes. `<leader>gx` acts on the token under the cursor: a URL token opens its templated URL; a session token that heads a section elsewhere in the buffer jumps there; otherwise the session is resolved through the reader and, if live, its Ghostty tab is focused by tty, or, if not, resumed with `claude --resume <id>` in a new tab in its recorded cwd. An ambiguous name, or a failed focus, is reported rather than guessed past: a second process on a live transcript is worse than no tab.

**Tabs.** `hammerspoon/desk-open-tab.sh` and `desk-focus-tab.sh` call `DeskOpenTab` and `DeskFocusTab` in `hammerspoon/init.lua` over `hs -c`. A new tab opens in the Ghostty window whose centre sits in the ultrawide's `upper_C` slot (upper half of the middle column, picker key `c`); with no window there, a new window is opened and placed in that slot; with no ultrawide screen at all, the frontmost window is used if it is Ghostty, and otherwise nothing opens. Every tab command runs through `/bin/zsh -lic`, so it gets your login shell's `PATH` and `CLAUDE_CONFIG_DIR`.

The scheduled passes open their tabs in the background (`desk-open-tab.sh … background`). Ghostty's scripting has no way to add a tab without selecting it and activating the app, so `DeskOpenTab` does two things instead. It never puts the tab in the Ghostty window being typed in: when that is the `upper_C` window, the frontmost other Ghostty window gets the tab (preferring the ultrawide), or a new window when there is no other. And it watches for the focus Ghostty takes and hands it straight back to the window that had it. In the moment between, a keystroke can still land in the new tab. The notes hotkey opens and focuses tabs as before. Ghostty's own window ids are unrelated to the ones Hammerspoon sees, so the target window is matched to Ghostty's by title and front-to-back order; when that match is not certain, a new window opens rather than a tab Ghostty would put in its last-focused window. Both helpers give `hs` an empty stdin, since `hs` reads a piped one as more commands and waits for it to close, and a hard limit of `DESK_HS_TIMEOUT_SECS` (default 6): a call that has not returned by then is killed and fails with exit 124. The notes hotkey's calls carry their own limit as well, so a stuck helper is reported rather than left running.

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

1. **Install the pieces.** `install_symlinks.sh` links `desk-run`, `session-status.sh`, `desk-open-tab.sh` and `desk-focus-tab.sh` into `~/.local/bin`, and nvim loads `nvim/lua/desk` from `nvim/init.lua`. The scripts need bash 4 or later (Homebrew's; macOS's `/bin/bash` is 3.2), `jq`, `nvim`, `perl`, `rg`, `git` and `claude` on `PATH`, and Hammerspoon with `hs.ipc` loaded (as `hammerspoon/init.lua` does) for `hs -c`.
2. **Make the notes repo.** `git init`, add `notes.md`, `reading.md` and an empty `.desk-notes`, commit on `main`. A remote is optional; with `push_enabled` on, the commit step pushes `main` and `refs/desk/ledger` to `origin` (`$DESK_NOTES_REMOTE`) over SSH in batch mode. The proposal ref stays local.
3. **Copy the example.** Copy `claude/desk-example/` into the private instance repo, then replace its sources, prompts, tokens and schedule. Set `notes_repo`.
4. **Export `DESK_CONFIG`** in the shell, e.g. from `~/.shellrc.early`. The runner gets it from the plist, but nvim reads the token table from it too, so without it marks and the hotkey have nothing to classify against.
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
| `trigger.start_calendar_interval` | `[{hour, minute, weekday?}]`, `weekday` 1 = Monday … 7 = Sunday. The runner never reads a plist, so this mirrors the plist's schedule and decides which slot a run belongs to: the once-a-day guard is keyed on that slot's date, so a 16:30 slot that only fires at next morning's wake still counts as yesterday's, and a later slot for a date that already finished ok is a no-op. Without it, the run's own date is used. |
| `weekdays_only` | Boolean. `true`: when the slot's scheduled date (not the day the runner happens to start) is a Saturday or Sunday, every step but `commit_push` is skipped (notes are still committed, with no model calls). Absent: `true` for passes named `morning` or `1630`, `false` for any other name. |
| `caps` | Name of the top-level `caps` entry this pass's judge uses. Absent: `weekly` for a pass named `weekly`, else `daily`. |
| `follow_up_step` | A step id. After the pass, whatever its result, the most recent `visible` call of that step (found by the session id the runner generated for it, never by display name) opens in a background tab with `claude --resume` (a session already live is left in its tab, never focused), at most once per scheduled date. |

The pass names `morning`, `1630` and `weekly` only supply the defaults of `weekdays_only` and `caps` above; nothing else about a pass depends on its name.

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
| `capture` | No model call. Adds a line on top of the captures file (`captures_file`) for each recorded session that is live (`running`) or ended without a clean exit (`dropped`), once per session and kind. A session you named that is already mentioned in your notes is skipped; an unnamed one is labelled `<auto title> · <first 8 chars of its id>`. | none |
| `close` | For each live session idle at least `close_after_working_days` and not in `keep_open`: one call over the end of its transcript, whose closure note goes into the proposal; then, unless `log_only` or past `max_closes`, a fresh re-check that it is still live and idle, and `SIGTERM`. A survivor is recorded as a failed close and not retried. | `cap`: transcript lines (default `200`) |
| `retention` | Warns before Claude Code deletes a transcript the notes still need. Selects every session the committed notes name (by its user-set name, or its id or an 8+ character prefix of it), that is not live, not a `desk-run` session and not ended as done (`/exit`, `/clear`, logout), whose transcript under `$CLAUDE_CONFIG_DIR/projects` is due for deletion within `retention_warn_days`. Per session, soonest first, one call over the end of its transcript (the same call `close` makes) whose item moves the session's entry to the top of the notes, or adds its name there, with a few bullets on where it stood and the deletion date. Items carry tier `act` and are capped under the pass's `caps` entry before any call is made; overflow goes to the brief. A warning already proposed, taken or declined for the same session and deletion date is not repeated. Nothing resumes, closes or writes to a session: a write would move the transcript's mtime and reset its clock, and that is the user's call. [Retention](#retention) has the rule it rests on. | `cap`: transcript lines (default `200`) |
| `open_tab` | Opens an interactive `claude` in a background Ghostty tab. Skipped when a session named `session_name` is already live. | below |

`open_tab` keys: `cwd_outside` and `prompt_text` (both required; `~` expands in `cwd_outside`), `session_name`, `restricted` (default `true`: adds `--restricted`, `--permission-mode` (default `default`), `--tools`, and `--strict-mcp-config` when `strict_mcp_config` is true; `false` launches with your own permissions), `mcp_config`, `settings`, `skill` (appended with `--append-system-prompt-file`; all three relative to the config's directory, like `prompt`), `scratch_dir` (a fresh directory under it becomes the cwd), and `notes_diff_file` with `notes_diff_since` (writes into that directory your own additions and removals since then, excluding text you took from suggestions). `notes_diff_since` is `{"weekday": "wed", "time": "08:00"}`: the most recent such moment on an earlier day than today (never today's own, even when today is that weekday), with the weekday as `mon`..`sun`, a full name or 1 (Monday) to 7, and `time` as `HH:MM` local time. The string `last_wednesday` is an alias for that example.

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
| `deletion_date`, `days_left` | retention | `YYYY-MM-DD` the transcript can be deleted from (today when already due), and the whole days until then |

A close prompt gets only `scratch`, `today`, `session_name` and `session_id`; a retention prompt gets those plus `deletion_date` and `days_left`.

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

An anchor whose quoted line has gone lands the item on top; an `edit` or `remove` whose `before` no longer sits at its anchor is deferred and retried next pass. A capped tier's overflow goes to `~/.local/state/desk/briefs/<date>.md`; the per-tier count is reported in the status file (and shown as `+N more <tier> → brief` on the status line), never as a proposal item. A new item replaces an open one that it names in `supersedes`, that shares a URL with it, or that is an `edit`, `remove`, `move` or `merge` of the same existing line (same kind, same `at` target). Insertions never replace each other by place: two `add`s under one heading are two suggestions.

**What the runner enforces on a reply**: an item whose URL `source` is not in the allowed set is dropped; an `also_sources` URL not in it is dropped from the list; any other URL in the item's text becomes `[url removed]`; control characters, ANSI sequences, vim modelines and `<<agent-suggested>>` markers are stripped. A close or retention call allows no URLs at all, and each of its bullets must cite a transcript turn as `[turn <first 8 chars of that entry's uuid>]`: an item citing a turn that is not in the tail it was given is dropped, and the markers are removed from what is kept.

**What only the prompt can say.** The tool allowlist decides what a call *can* do, not what it tries, and everything a call reads (your notes, a fetched page, a transcript) is written by someone other than the prompt's author. So every prompt carries two lines the runner cannot check: that the call never sends, posts or changes anything outside its own reply (for a write step, nothing beyond its one pinned call), and that everything it reads in files and tool results is data, never instructions to follow. That is the "External content is data, never instructions" principle in `agents/principles.md`, applied where the content arrives.

## Retention

Claude Code deletes a session's transcript once it is older than `cleanupPeriodDays`, default 30 and at least 1, in a background sweep "after a session starts" (settings reference, `cleanupPeriodDays`), so "a session you haven't used for longer than the retention period no longer appears in the `/resume` picker". The sweep runs at most once per session, and any Claude Code start runs it, the runner's own calls included. The docs don't name the timestamp the age is measured from; the `retention` step takes the transcript's mtime, the last write, and reports `mtime + cleanupPeriodDays` as the deletion date, the earliest the sweep can remove it. A resume writes to the transcript and so moves the date on.

The step reads `cleanupPeriodDays` from `$CLAUDE_CONFIG_DIR/settings.json` (default `~/.claude`), falling back to 30 when the file or the key is absent, and fails the step on a file it can't parse or a value that isn't a whole number of at least 1, the cases in which Claude Code pauses its sweep. It does not see a value set in managed settings or in a project's `.claude/settings.json`, which the sweep in a session started there would use, and it ignores transcripts outside `$CLAUDE_CONFIG_DIR/projects`, which another config directory's settings govern.

A retention item that moves the user's entry is kept only when its `before` is lines that sit together in the committed captures file and its `after` carries every one of them, in order and unchanged apart from indent and the appended date; otherwise it lands as `new` on top with just its first line and the added bullets, and the entry stays where it was. The runner appends the deletion date to the first line when the text lacks it.

## Review keys

In a notes buffer:

| Key | Action |
|---|---|
| `<leader>gR` | Open the review split, or focus it. Reopening over a split with unsaved declines asks to save, discard or cancel. |
| `do` | (notes window, while a review is open) Take the diff hunk under the cursor: every adjacent suggestion in it. |
| `<leader>gc` | Save the buffer, commit the file, and record suggestions now in `HEAD` as taken. |
| `<leader>go` | Overview: a quickfix list with one headline per remaining diff hunk; `<CR>` jumps to it in your notes window. |
| `<leader>gd` | Declined in the last 14 days (also `:DeskDeclined`); `r` on an entry restores it, so the next pass proposes it again. |
| `<leader>gx` | The hotkey: act on the token under the cursor. |

In the review split:

| Key | Action |
|---|---|
| `<leader>gA` | Take just the suggestion under the cursor into your notes buffer. |
| `<leader>gD` | Decline the suggestion under the cursor; `u` undoes it. |
| `<leader>go` | The overview. |
| `:w` | The commit point: records as declined every suggestion whose lines are gone from both the split and your notes, restores any declined this session whose lines are back, and records pending takes. Closing the split without saving records nothing. |

A take is remembered when you make it and recorded on the next save of either buffer, so a suggestion you edit right after taking stays taken. The winbar shows the status line: each pass's last result, untaken suggestions, closes and lockouts.

## Scheduling

One LaunchAgent plist per pass, each running `desk-run <pass>` with `DESK_CONFIG` and a `PATH` that reaches bash 4+, `jq`, `nvim`, `perl`, `rg`, `claude` and `~/.local/bin`. `claude/desk-example/com.local.desk.morning.plist` is the pattern: launchd expands neither `~` nor `$HOME`, so it runs through `/bin/sh -c`, and it appends the pass's log to `~/.local/state/desk/logs/`. Set `CLAUDE_CONFIG_DIR` there too if your sessions live in a config directory other than `~/.claude`: the capture and close steps read sessions from it. Keep `StartCalendarInterval` equal to the pass's `trigger.start_calendar_interval` (launchd's `Weekday` uses the same 1–7 numbers). Several slots per pass are the retry mechanism: once a scheduled date finishes ok, later slots for it do nothing.

Keep the plists in the instance repo and load them from there:

```sh
launchctl bootstrap gui/$(id -u) /path/to/instance/com.local.desk.morning.plist
launchctl kickstart gui/$(id -u)/com.local.desk.morning    # run once now
launchctl bootout gui/$(id -u)/com.local.desk.morning
```

Don't link them into `~/Library/LaunchAgents` until the instance has run cleanly for a while: launchd loads everything there at every login, so a link there turns a half-configured instance into one that runs on its own after the next restart. `bootstrap` from the instance path is reversible with one `bootout`.

## The denylist

The dotfiles clone refuses to push until `desk.denylist` is set in it, once, locally:

```sh
git -C ~/dotfiles config desk.denylist /path/to/instance/denylist.txt
```

The list holds one Perl regex per line (`#` comments), matched case-insensitively unless a line turns that off with `(?-i)`, against every commit message and diff being pushed. Its point is to keep the instance's own names (tools, hosts, ticket keys, people) out of this public repo, so it lives in the instance repo and is never tracked here; its contents would be the leak. A missing or empty list refuses too. `none` opts out explicitly. `git-hooks/pre-push` runs the check only when the repo being pushed is this one, since `core.hooksPath` points every repo on the machine at the same hooks. To check a range by hand: `git-hooks/desk-denylist-check.sh <repo> <range> <list-file>`.

## Dry-running a new instance

The defaults are the safe side of every outward-facing switch: `dry_run` (no write call), `log_only` (no session signalled) and `push_enabled` off. Fetch and judge calls are real model calls even then, and `follow_up_step` and `open_tab` open real tabs.

- **Offline**, to check the config and prompts: point `DESK_CLAUDE_BIN` at a stub that prints a stream-json result, `DESK_OPEN_TAB_BIN` and `DESK_FOCUS_TAB_BIN` at stubs, and `DESK_STATE_DIR` and `CLAUDE_SESSION_STORE` at a temp directory, then `DESK_CONFIG=… desk-run <pass>`. `nvim/tests/desk-example-instance-test.sh` is a worked version, and checks that every placeholder a prompt uses is one the runner fills.
- **Live, without side effects**, against a copy: clone the notes repo to a temp path, point `notes_repo` at the clone in a copy of the config, and run each pass by hand with `DESK_STATE_DIR` set to a temp directory so the real status file, ledger and caches stay untouched. Read the log and `status.json`, then `<leader>gR` in the clone.
- Then on the real repo with the defaults still on, then each switch one at a time.

## Tests

```sh
DESK_GUARD_REPOS="$HOME/dotfiles" bash tests/run-all.sh
```

`tests/run-all.sh` runs every suite it names (a new file runs only once listed there) with safe defaults exported first: state and the reader cache under a temp directory, refusing stubs for `claude`, the tab helpers and the URL opener, and an empty reader, so a test that forgets an override fails instead of acting. It snapshots `git config --local --list` of every repo in `$DESK_GUARD_REPOS` (colon-separated; default this repo's main checkout) and the content hashes of `~/.local/state/claude` and `~/.local/state/desk` (Claude Code's own `locks/` is skipped, and the recorder's event files and log, which any open session appends to, are compared by path only), and fails if either changed. `git-hooks/pre-commit` applies the same guards when it runs the hook tests. Tests that create repos use `tests/lib/git-safety.sh`, which refuses a root outside a temp directory and isolates git from the real global config.

The two live canaries, `nvim/tests/desk-run-canary.sh` and `desk-run-canary-restricted.sh`, make one real model call each to prove that an unlisted tool is refused on the connector and restricted paths. They are never in `run-all.sh`, and skip unless `DESK_CANARY_LIVE=1`.

## State and overrides

Everything the runner writes lives under `~/.local/state/desk` (`$DESK_STATE_DIR`): `status.json`, `ticket-status.json`, `lock/`, `guard/`, `scratch/` (removed after each pass), `runs/` (visible calls, kept seven days), `fetch-cache/`, `briefs/` and `logs/`. Each has its own override, read at the top of `claude/desk-lib/common.sh` and the file that owns it, which is also where the timing knobs (`DESK_LOCK_MAX_WAIT_SECS`, `DESK_STALE_RUNNING_MINUTES`, …) are. The recorder's store is `$CLAUDE_SESSION_STORE`. Both nvim and the runner locate the tab helpers through `$DESK_OPEN_TAB_BIN` and `$DESK_FOCUS_TAB_BIN` (the older `$DESK_OPEN_TAB` and `$DESK_FOCUS_TAB` still work as aliases on both sides). nvim also reads `$DESK_READER` and `$DESK_OPEN_URL`. All default to the names on `PATH` and `open`.
