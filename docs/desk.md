# Desk

Desk is a notes file you edit by hand, plus scheduled passes that read it alongside whatever sources an instance configures and *propose* changes to it. A proposal never touches the file: it waits as a commit beside it, and you review it as a diff in nvim, taking or declining one suggestion at a time. Around that sit a recorder and reader for Claude Code sessions, so the notes can name a session and a pass can capture or close one, and a hotkey that acts on whatever token is under the cursor.

This repo holds the mechanism only. Everything that makes it someone's (which sources, which tools, which ticket keys, the prompts, the schedule) is an **instance**, kept in a private repo and pointed at by `$DESK_CONFIG`. Nothing about an instance belongs here; `claude/desk-example/` is a complete, work-free instance to start from, and `nvim/tests/desk-example-instance-test.sh` keeps it runnable.

It runs on macOS and Linux. On macOS, tabs open in Ghostty through Hammerspoon and passes run from launchd; on Linux, passes run from systemd user timers and every tab is a new Ghostty window, since opening a window is the one thing Ghostty there takes from outside. So on Linux a session opens in a window of its own, which may take focus even when opened in the background; the hotkey cannot bring a live session's window forward, and says the session is running instead; and a session closed from outside leaves its window open. [Tabs](#how-it-works) and [Scheduling](#scheduling) have the details.

## Day to day

- **Passes run on their own.** A scheduled pass reads its sources and leaves suggestions for your notes; its follow-up tab opens in the background (no focus taken) on a plain summary of what it proposed, what it left out, and what it needs from you. Reply there.
- **Review suggestions** in your notes: `␣gR` opens them above your notes. `n`/`N` (or `]c`/`[c`) move between them, `dp` takes one into your notes, `␣gA`/`␣gD` take or decline the one under the cursor, `u` undoes. `␣go` lists them all (`t` take, `x` decline, `q` close the list, `Q` end the review). `␣gc` commits. Leaving one alone means "not now": it comes back next time.
- **Sessions** suggest notes changes the same way, with `desk-propose`; they edit your notes directly only when you ask for that edit.
- **Follow tickets** by saying "follow this epic" in the session that works on it. The follow pass then sends that session the news, and the session rings the bell (🔔 in its tab title) only when you're needed.
- **Ending a session:** Ctrl+C twice or `/exit` marks it done. Closing its tab leaves it open, so it is reopened after a restart (ask for "reopen my sessions"). A pass with a `close` step ends a session left idle for days the same way, after staging a note on where it stood, and closes its tab when it can tell which one it is. `␣gx` on a session name in your notes jumps to its tab or resumes it.
- **Mail**, when the instance has a [mail triage](#mail-triage): automated noise is trashed by fixed rules, and the follow-up tab lists mail that looks finished with and trashes it only when you say yes.
- **When something looks off:** the bar above your notes shows each pass's last result; the logs are in `~/.local/state/desk/logs/`.

Everything below is reference: how it works, and every setting.

## How it works

**The notes repo.** A private git repo holding `notes.md` and `reading.md` at its root, on branch `main`, with an empty `.desk-notes` marker file. The marker, not a path, tells nvim a buffer is a desk notes file, so this repo never names where the notes live. nvim attaches to the config's `files` (default those two names), and session captures land in `captures_file` (default the first entry of `files`).

**Passes.** `desk-run <pass>` runs one pass from the config: an ordered list of steps, each of one kind (below). Every model call is a headless `claude -p` with an exact tool allowlist, from a scratch directory outside any repo, under a timeout and a spend cap. A pass ends by writing `~/.local/state/desk/status.json`, which the status line reads. Every pass but the follow pass takes one shared lock; a run that cannot get it within 30 minutes gives up, and the lockout is counted in the status file.

**The proposal.** A pass that suggests anything writes one commit to `refs/desk/proposal` in the notes repo: its parent is your `HEAD` at pass time, its tree is the configured files with every suggestion applied, plus `proposal.json` listing the items. The next pass rebuilds it from your newest `HEAD`, plus the previous items you neither took nor declined, plus its own new ones, so leaving a suggestion alone means "not now". A pass's own items sit above those carried from earlier passes and keep the order of the steps that staged them, so the order of `steps` decides what reads first and which of several items landing at one spot goes in first. What you decided lives on `refs/desk/ledger`: declines (by item id, by source URL, and by content — file, kind, target and normalised before/after — so a declined link or a regenerated copy is never proposed again) and takes (so a taken suggestion's text is recognised as agent-written later, even after you edit or move it).

**The review.** In a notes buffer, `<leader>gR` merges your buffer with the proposal and opens the result in a diff-mode split above your notes: you work in the proposal, and your notes below show the result, coloured like a git diff. Taking is an ordinary diff take; declining makes the suggestion equal your text; nothing is recorded until you save the review split. The keys are in [Review keys](#review-keys).

**Edits from sessions.** A Claude Code session changes a notes file directly only when the user asks for that edit; a change that is its own idea it stages for review with `desk-propose [--pass <name>] [--date <YYYY-MM-DD>] [--dry-run] <items.json>` (`claude/desk-propose`), in the reply's item shape ([The prompt contract](#the-prompt-contract)), never by writing it in or offering in chat to apply it. `desk-propose --help` is the contract: the proposal is rebuilt the way a pass rebuilds it, one item that does not fit the shape fails the whole call, and URLs are kept, since the session shows the user its items before staging them. The instance tells its sessions this in the notes repo's own `AGENTS.md` (with a `CLAUDE.md` link), along with what the user's own markup means and that `HEAD` holds the reviewed text.

**Links.** Agent text writes a long link as `[short label](url)` and a session name exactly as the session is named, so marks and the hotkey find it. In a notes buffer nvim conceals the URL, showing the label and revealing the URL on the cursor line. The runner's URL check treats a labelled link as one unit: kept whole when its URL is an allowed source, reduced to `label [url removed]` when not.

**Sessions.** `claude/hooks/session-recorder.sh` (the `SessionStart` and `SessionEnd` hooks in `claude/settings.json`) appends a start and an end event per session to `~/.local/state/claude/session-events/<session id>.jsonl`, and `claude/session-status.sh` (the reader) joins those with Claude Code's own pid files and transcripts under `$CLAUDE_CONFIG_DIR` into one JSON line per session, documented in its header. `session-status.sh resolve <token>` finds one session by its name, its id, or a unique id prefix of 8 or more characters (what an unnamed capture is labelled with); several matches are reported, never ranked. Sessions the runner starts are recorded with source `desk-run` and never captured, except the tabs it opens for you to work in (an `open_tab` session, a follow-up tab), which start as yours so a restart reopens them; a capture still skips a follow-up tab by its `desk-` name and its cwd under `runs/`. A `restricted` `open_tab` loads no hooks, so it records nothing.

A session can be open in two processes at once, when it is resumed in a second window while the first still runs. It is `ended` only once none of its processes is live. While two are live, `duplicate_pids` is true and the hotkey and the close step refuse to act on it, and the recorder's `SessionStart` hook shows a warning naming the other process (it never blocks the start).

**How a session ended.** For an ended session the reader reports `end_deliberate`, from Claude Code's `SessionEnd` reason. Leaving at the prompt (Ctrl+C twice, Ctrl+D, `/exit`), `/clear`, `/resume`, `/logout` and a close by the close step or `close-session.sh` (`closed-by-pass`) are deliberate. Closing the tab, quitting Ghostty, a restart or shutdown and Claude Code's own error exits are not, and SIGKILL records no end at all. `left_open` is a session with a start event, not live and not started by a scheduled call, whose latest run stopped without a deliberate end: the session to reopen after a restart. A tab closed on purpose reads exactly like a shutdown, so it counts as left open. `DELIBERATE_END_REASONS` in the reader holds the list.

**Marks and the hotkey.** Each token in a notes buffer that the config's `tokens` table classifies gets virtual text: a session name shows that session's state from the reader, a ticket-like token its status from the ticket cache a pass writes. `<leader>gx` acts on the token under the cursor, in your notes and in the review split, read without surrounding markdown emphasis or a trailing colon (so `**name:**` is the session `name`, and a line written that way heads its section):

- a URL token opens its templated URL; a template that yields a bare word, with neither a scheme nor a dot, is reported as not a link rather than handed to the system opener;
- a session token that heads a section elsewhere in the buffer jumps there;
- otherwise the session is resolved through the reader: if live, its Ghostty tab is focused by tty (on Linux, where it cannot be, the hotkey says the session is running), if not, it is resumed with `claude --resume <id>` in a new tab in its recorded cwd. An ambiguous name or a failed focus is reported rather than guessed past, since a second process on a live transcript is worse than no tab;
- a token that is neither, on a markdown link, follows the link as `gx` does in any markdown buffer (`nvim/lua/mdlink.lua`): `#anchor` jumps to the heading with that GitHub slug, a relative path opens the file at its anchor, a URL opens in the browser, and a bare word is never handed to the system opener.

**Tabs.** `hammerspoon/desk-open-tab.sh` and `desk-focus-tab.sh` call `DeskOpenTab` and `DeskFocusTab` in `hammerspoon/init.lua` over `hs -c`; the mechanism is commented there. A new tab opens in the Ghostty window centred in the ultrawide's `upper_C` slot; a background open never goes into the window being typed in, so then it uses the `lower_C` window, and with neither a new window. With no ultrawide, the frontmost window stands in for `upper_C` if it is Ghostty's. Every tab command runs through `/bin/zsh -lic`, so it gets your login shell's `PATH` and `CLAUDE_CONFIG_DIR`.

The scheduled passes open their tabs in the background (`desk-open-tab.sh … background`); the notes hotkey opens and focuses in the foreground. An open never moves or resizes an existing window, and when it is not certain it can add a tab without doing so, it opens a new window instead, placed clear of the focused one. A background open hands focus back for a few seconds afterwards; a keystroke in that moment can still land in the new tab. `background,close` closes the tab when its command exits; without it the tab stays, so a finished session can still be read. With the screen locked nothing opens and the helper exits 1, leaving the tab to a later retry slot. Each `hs` call has a hard limit of `DESK_HS_TIMEOUT_SECS` (default 6), after which it fails with exit 124.

**On Linux** the three helpers are in `linux/desk/`, under the same names, with the same arguments and exit codes. Ghostty there takes one command from outside, a new window in the running instance (`ghostty +new-window`, over D-Bus), so every open is a window, its command run through `/bin/zsh -lic` as on macOS and the cwd its working directory. Whether it takes focus is the window manager's call, so `background` changes nothing. Without `close` the window waits for a key after its command exits, so a finished session can still be read. `desk-focus-tab.sh` focuses nothing: it exits 1, saying the session is running, so the hotkey reports that and never resumes a second process. `desk-close-tab.sh` never names a window, so `close-session.sh` ends the session and leaves its window open, saying why. Nothing checks for a locked screen: a window opened then is there on unlocking. `ghostty` gets `DESK_TAB_TIMEOUT_SECS` (default 6) to return before the open fails with exit 124.

**Reopening after a restart.** `claude/reopen-sessions.sh`, run by an agent through the `reopen-sessions` skill, resumes in background tabs the sessions the reader reports `left_open` whose latest run is in the previous boot or this one (older orphans only with `--all-boots`): active ones are opened, idle ones (by `close_after_working_days`) listed. Its header documents the flags, output and overrides.

**Closing a session and its tab.** `claude/close-session.sh <session id>` ends a live session on purpose from outside it: it records the close (`closed-by-pass`, so the session is not reopened), sends `SIGTERM`, re-checks that the process is gone (a survivor is recorded as a failed close and its tab left alone), and closes the Ghostty tab it ran in (`hammerspoon/desk-close-tab.sh`), moving no window; on Linux the window stays open. It refuses an id that is not a full UUID, a session that is not live, one two processes hold, one in the config's `keep_open`, and the session running the command. Anything short of certain about which tab leaves it open, and the output says why. Its header documents the output and overrides. The `close` step ends a session through it too, so a session closed by a pass and one closed by hand end the same way.

## What an instance provides

| Piece | Where it lives | Notes |
|---|---|---|
| Config file | the private instance repo; `$DESK_CONFIG` points at it | [Config reference](#config-reference) |
| Prompts | beside the config, paths relative to its directory | [The prompt contract](#the-prompt-contract) |
| Sources file | beside the config (`sources_file`) | free-form JSON, handed to prompts verbatim |
| Notes repo | anywhere, named by `notes_repo` | `notes.md`, `reading.md`, `.desk-notes`, branch `main` |
| Schedule: LaunchAgent plists, or systemd user units | the instance repo | [Scheduling](#scheduling) |
| Denylist | the instance repo, untracked here | [The denylist](#the-denylist) |

## Setting up an instance

1. **Install the pieces.** `install_symlinks.sh` links `desk-run`, `desk-follow`, `desk-propose`, `session-status.sh`, `reopen-sessions.sh`, `close-session.sh`, `desk-open-tab.sh`, `desk-focus-tab.sh` and `desk-close-tab.sh` into `~/.local/bin`, and nvim loads `nvim/lua/desk` from `nvim/init.lua`. The scripts need bash 4 or later (Homebrew's; macOS's `/bin/bash` is 3.2), `jq`, `nvim`, `perl`, `rg`, `git` and `claude` on `PATH`. On macOS the tabs need Hammerspoon with `hs.ipc` loaded (as `hammerspoon/init.lua` does); on Linux, a Ghostty whose `+new-window` reaches the running instance over D-Bus.
2. **Make the notes repo.** `git init`, add `notes.md`, `reading.md` and an empty `.desk-notes`, commit on `main`. A remote is optional; with `push_enabled` on, the commit step pushes `main` and `refs/desk/ledger` to `origin` (`$DESK_NOTES_REMOTE`) over SSH in batch mode. The proposal ref stays local.
3. **Copy the example.** Copy `claude/desk-example/` into the private instance repo, then replace its sources, prompts, tokens and schedule. Set `notes_repo`.
4. **Name the instance for its account** in `~/.shellrc.early`: `DESK_PERSONAL_CONFIG` or `DESK_WORK_CONFIG` ([Instances and accounts](#instances-and-accounts)). `.shellrc` exports it as `DESK_CONFIG` to shells of the default account, and nvim reads the token table from it, so without it marks and the hotkey have nothing to classify against. A `DESK_CONFIG` exported there instead still works. Also link the config to `${XDG_CONFIG_HOME:-~/.config}/desk/config.json`, which `desk-run`, `desk-follow` and `desk-propose` use when `DESK_CONFIG` is unset (a shell started before the export, an agent's Bash tool). The instance's installer makes the link; this repo never names the instance's path. `DESK_CONFIG_DEFAULT` overrides the default path, which is how the tests keep a real instance out of reach.
5. **Check the recorder hooks.** `claude/settings.json` already wires them, as `$HOME/dotfiles/claude/hooks/session-recorder.sh`, so they need the clone at `~/dotfiles`. Sessions started before the hooks existed have no start event and are never captured or closed.
6. **Set the denylist** in the dotfiles clone (below), before the next push from it.
7. **Dry-run each pass by hand** (below), then load the plists or enable the timers ([Scheduling](#scheduling)).

## Instances and accounts

An instance belongs to a Claude Code account, and `.shellrc` picks it the way it picks the account's config directory. `DESK_PERSONAL_CONFIG` and `DESK_WORK_CONFIG`, machine-local in `~/.shellrc.early`, name each account's config, and `DESK_PERSONAL_STATE_DIR` and `DESK_WORK_STATE_DIR` its state directory, the runner's default when unset. The pair for the account reaches everything as `DESK_CONFIG` and `DESK_STATE_DIR`:

- a plain shell, and the nvim started from it, gets `$DESK_DEFAULT_ACCOUNT`'s, else `$DEFAULT_ACCOUNT`'s, else personal;
- `claude-personal` and `claude-work` give their session their account's, and bare `claude` the account a `CLAUDE_CONFIG_DIR` names, else the default;
- a scheduled unit or plist sets the pair itself, and a tab a pass opens starts with the pass's own `CLAUDE_CONFIG_DIR`, `DESK_CONFIG` and `DESK_STATE_DIR`, so its session lands on the pass's account and instance whatever the machine's default.

An account with no instance gets none, and the commands fall back to the default link. A `DESK_CONFIG` set by hand wins over the switch, with whatever `DESK_STATE_DIR` came with it. nvim's status line and marks read `status.json` and `ticket-status.json` from `DESK_STATE_DIR` (`DESK_STATUS_FILE` and `DESK_TICKET_CACHE` override them).

## A second instance on one machine

Instances coexist by sharing nothing mutable. Each has its own config, its own state directory (status file, lock, guard, runs, caches and the follow list), its own notes repo, and its own schedule (different plist labels, or unit names). On one machine they are one per account, set as above; since an unset state directory is the runner's default, at least one of the two needs its own. What they share is the machine's Claude Code sessions: every instance's capture and close steps see all of them, including ones the other's notes name. Give them disjoint `keep_open` lists and expect a session to be captured or closed by whichever pass gets to it first.

Any headless `claude -p` started outside desk (a script, a CI-style helper) records a start event with no deliberate end, and may therefore show up as a `dropped` capture. Desk's own calls are tagged and excluded; others are not.

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
| `dry_run` | `true` | The write step logs the ids it would act on (digests to mark read, noise to trash) and makes no call; the follow-up tab is told each mail it would trash. |
| `log_only` | `true` | The close step queues its closure notes and never ends a session. |
| `close_after_working_days` | `3` | Idle threshold for closing, in Mon–Fri days since your last message in that session. |
| `keep_open` | `[]` | Session names never closed. |
| `max_closes` | `3` | Real closes per pass. |
| `away_days` | `5` | A pass more than this many days after the pass last ran to its end, ok, partial or failed, closes nothing. |
| `retention_warn_days` | `14` | How many days before Claude Code deletes a transcript the `retention` step warns about it. |
| `caps.<name>` | none | `{act, worth_knowing, wildcard}`: how many tiered items a judge may keep. Which entry a pass uses is its `caps` key; absent, `weekly` for a pass named `weekly` and `daily` for every other. |
| `default_max_budget_usd` | `$DESK_DEFAULT_MAX_BUDGET_USD`, `2` | Spend cap for a model call whose step has no `max_budget_usd`. |
| `tokens` | `[]` | The token table, below. |
| `sources_file` | `sources.json` | Relative to the config's directory. Substituted whole into `{{sources}}` and copied to the judge as `sources.json`. |
| `digest_gmail_label` | `Digest` | The label in `{{digest_query}}`, as the mail search tool matches it in `label:`. Check it with a search: the Gmail connector's own description says it takes label IDs, but in use it matches the display name. |
| `gmail_window_lookback_secs` | `172800` | Fetch window on a pass's first run; afterwards the window starts where the last fully successful fetch ended. A retry that reuses an earlier slot's fetch ends where that fetch's window did, so nothing between the two slots is skipped. |
| `slack_workspace_url` | none | When set, a Slack message found in a fetch's raw calls also allows its rebuilt permalink (`<url>/archives/<channel>/p<ts without the dot>`) as a source, since a Slack result carries no permalink. The channel comes from the call's own `channel_id` argument, the ts from the result (a `Message TS:` line, or a JSON `ts`) or a thread call's `message_ts`. A window bound (`oldest`, `latest`) is never a message. |
| `follow_up_settings` | none | A settings file (relative to the config's directory) a follow-up tab and its status session start with as `--settings`, on top of your own. A tab that offers to trash mail needs the trash tool on `ask` there: under auto mode an unlisted tool is left to the classifier. A configured file that is missing is logged and left out. |

The five required tool and step-id fields have no defaults on purpose: this repo cannot ship an instance's tool names. An instance without mail or tickets still sets them, to ids no step uses, as the example does.

### Passes

| Key | Meaning |
|---|---|
| `steps` | Ordered list of step objects. A step that fails (other than a fetch) stops the pass. |
| `trigger.start_calendar_interval` | `[{hour, minute, weekday?}]`, `weekday` 1 = Monday … 7 = Sunday, mirroring the plist's or timer's schedule (the runner reads neither). It decides which slot a run belongs to, and the once-a-day guard is keyed on that slot's date: an evening slot that only fires at next morning's wake counts as yesterday's, and a later slot for a date that finished ok is a no-op. Without it, the run's own date is used. |
| `trigger.same_day_only` | Boolean, default `false`. `true`: a run whose slot falls on an earlier day than the run itself is a no-op, so a login or a wake only ever catches up today's slot ([Missed slots](#scheduling)). |
| `weekdays_only` | Boolean. `true`: when the slot's scheduled date is a Saturday or Sunday, every step but `commit_push` is skipped. Absent: `true` for a pass named `morning`, `false` otherwise. |
| `caps` | Name of the top-level `caps` entry this pass's judge uses. Absent: `weekly` for a pass named `weekly`, else `daily`. |
| `kind` | `"follow"` makes the pass the follow pass, which takes none of the keys here: its own are in [The follow pass](#the-follow-pass). Absent for every other pass. |
| `follow_up_step` | A step id. After the pass, whatever its result, the most recent `visible` call of that step opens in a background tab with `claude --resume` (a live session is left in its tab), once per scheduled date and never for a weekend slot of a `weekdays_only` pass. First the session is resumed headless, with no tools, no MCP servers and `--restricted`, for one plain-language turn to the user; if that turn fails or replies in JSON, the tab opens on the step's own reply and the log says so. When no call of the step ran or its session cannot be found, the tab opens a fresh interactive `claude` named `desk-<pass>-<date>-status`, whose first turn reports the run. |

The pass names `morning` and `weekly` only supply the defaults of `weekdays_only` and `caps`; nothing else about a pass depends on its name.

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
| `visible` | `false` | Persist the session under the name `desk-<pass>-<date>-<id>`, with its cwd kept under `~/.local/state/desk/runs/` for seven days, so it can be resumed. A session you carried on in (resumed, or opened by the follow-up tab) is yours: its cwd and transcript stay until Claude Code's own retention removes the transcript ([Retention](#retention)). |

A judge, close or retention step whose `tools` include `Read` gets it narrowed to its own scratch directory, by the allowlist and again by the deny hook.

| Kind | What it does | Kind-specific keys |
|---|---|---|
| `commit_push` | Commits the configured files exactly as they are on disk, only when `HEAD` is `main` with no rebase or merge in progress; records suggestions now in `HEAD` as taken; pushes if `push_enabled`. Never pulls, merges, rebases or force-pushes. | none |
| `fetch` | One model call. A failure flags the pass `partial` instead of stopping it; a later slot the same scheduled date reruns only the fetches that failed, reusing the ones that succeeded. If its id is `ticket_status_step_id`, it gets `{{jql}}` and its `ticket_search_tool` results become the ticket cache. | `ticket_digest` (optional): the step also runs the [ticket digest](#the-ticket-digest)'s query; `ticket_search` (optional): the step runs the [ticket search](#the-ticket-search)'s query, and its `<id>.json` is the runner's reading of the result |
| `judge` | Seeds its input files, makes one call, validates the reply, caps tiered items and builds the proposal. A reply that is not the items shape fails the pass. | `input_files` (default: all eight names listed below) |
| `write` | A pinned write on mail threads. It removes a label (`pinned_label`) from exactly the threads the `mail_fetch_step_id` step's digest search returned and that step then opened (another call named the thread's id and got a result that was not an error); a thread judged from its snippet alone stays unread, and the log names it. When the pass has a [mail triage](#mail-triage) and `tools` holds its `trash_tool`, it also trashes exactly the threads the triage sorted as noise. The deny hook refuses any call whose input is not one of that tool's pinned set (`{threadId, labelIds}` per digest, `{threadId}` per noise thread), and the pass fails if the ids a tool acted on (calls that came back without an error) differ from its pinned set. With nothing to act on, no call is made. Refuses outright if the digest fetch failed, its search query was not exactly `{{digest_query}}`, or the result was neither a `threads` list nor `{}`. | `pinned_label` (default `UNREAD`); `tools`: the unlabel tool, plus the triage's trash tool |
| `capture` | No model call. Adds a line on top of the captures file for each recorded session that is live (`running`) or left open (`dropped`, the reader's `left_open`; see "How a session ended" under [How it works](#how-it-works)), once per session and kind. A named session the notes already mention is skipped; an unnamed one is labelled `<auto title> · <first 8 chars of its id>`. | none |
| `close` | For each live session idle at least `close_after_working_days` and not in `keep_open`: one call over the end of its transcript, whose closure note goes into the proposal; then, unless `log_only` or past `max_closes`, a fresh re-check that it is still live and idle, and `close-session.sh` ([Closing a session and its tab](#how-it-works)): the close recorded, `SIGTERM`, the tab closed only when identified for certain. The run status says `closed, tab closed` or `closed, tab left (not identified)` per session. A survivor is recorded as a failed close and not retried. | `cap`: transcript lines (default `200`) |
| `retention` | Warns before Claude Code deletes a transcript the notes still need. Selects every session the committed notes name (by name, id or an 8+ character id prefix) that is not live, not a `desk-run` session and not ended as done (`end_deliberate`, other than a close by a pass, which leaves the work unfinished), whose transcript under `$CLAUDE_CONFIG_DIR/projects` is due for deletion within `retention_warn_days`. Per session, soonest first, one call over the end of its transcript (the call `close` makes) whose item moves the session's entry to the top of the notes, or adds its name there, with where it stood and the deletion date. Items are tier `act`, capped under the pass's `caps` before any call is made. A warning already proposed, taken or declined for the same session and date is not repeated. Nothing writes to a session, since a write would reset the transcript's clock. | `cap`: transcript lines (default `200`) |
| `open_tab` | Opens an interactive `claude` in a background Ghostty tab. Skipped when a session named `session_name` (placeholders filled) is already live. | below |

`open_tab` keys:

- `cwd`, `prompt_text`: required; `~` expands in `cwd`. `session_name` names the session.
- `restricted` (default `true`): adds `--restricted`, `--permission-mode` (default `default`), `--tools`, and `--strict-mcp-config` when `strict_mcp_config` is true. `false` launches with your own permissions.
- `mcp_config`, `settings`, `skill` (appended with `--append-system-prompt-file`): relative to the config's directory.
- `scratch_dir`: a fresh directory under it holds the step's files; the cwd stays `cwd`.
- `notes_diff_file` with `notes_diff_since`: writes into that directory your own additions and removals since then, excluding text you took from suggestions. `notes_diff_since` is `{"weekday": "wed", "time": "08:00"}`, the most recent such moment on an earlier day than today (weekday as `mon`..`sun`, a full name or 1–7; `time` local `HH:MM`), or `last_wednesday` for that example.
- Placeholders: `{{date}}` in `session_name` and `prompt_text` is the pass's scheduled date (`YYYY-MM-DD`), so a weekly session gets a name of its own each week; `{{notes_diff}}` in `prompt_text` is the notes diff's absolute path.

### Tokens

An ordered list; the first entry whose pattern matches the whole token wins.

```json
{ "pattern": "^ABC-([0-9]+)$", "case_insensitive": true, "handler": "url", "template": "https://tickets.example.com/browse/ABC-{1}" }
```

- `handler`: `url` opens `template` with `{1}`, `{2}`, … replaced by the pattern's captures, and marks the token with its ticket status; `session` resolves the token (or its first capture) as a session name. A last entry of `^.+$` with `session` makes every other token a session lookup.
- `pattern` is read by two engines: nvim reads it as a Lua pattern in which a bare `-` is literal, and the runner reads `url` patterns as an extended regex (anchors dropped, word boundaries added) to find ticket keys in the notes. Keep `url` patterns to what both read the same way: literals, `[...]` classes, `.`, `+`, `*`, `?`, `(...)`, `^`, `$`. Not `%d` (Lua only), and not `\d`, `{n}` or `|` (regex only).

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
| `thread_ids`, `trash_thread_ids` | write | the pinned digest ids to mark read, and the noise ids to trash, one per line |
| `mail_triage_query`, `mail_triage_page_size` | a fetch step with `mail_triage` | the listing query, which the call must run character for character, and the page size to ask for |
| `session_name`, `session_id` | close, retention | the session being closed or warned about |
| `pass`, `run_status` | the follow-up summary and status | the pass's name, and a paragraph on how its run went: its steps, and whether all ran, which sources failed, or where it stopped, then a sentence from each step that ran without acting (the write step under `dry_run`, the close step under `log_only` or past `max_closes`, digest threads the write left unread because the fetch never opened them) |
| `items`, `item_count`, `open_note` | the follow-up summary and status | the pass's own staged items as a JSON array (`file`, `kind`, `headline`, `tier`, `source`, `before`, `after`, and a closure note's `capture_kind`, `would_close` for a session left open), how many, and a line about older items still waiting, or empty |
| `dropped` | the follow-up summary and status | the items the runner threw out because their URL `source` was in no fetch result, a JSON array (`headline`, `source`, `tier`), `[]` when none were |
| `capped`, `near_misses` | the follow-up summary and status | what the pass held back, each a JSON array, `[]` when empty: items over the caps (`tier`, `headline`, `source`, and for a judge's `file`, `kind`, `after`), and the judge's `near_misses` |
| `mail_noise`, `mail_offer` | the follow-up summary and status | the [mail triage](#mail-triage)'s noise as the write step acted on it, `{action, threads: [{from, subject, rule}], held_over_cap}` with `action` `trashed` or `would_trash` (`{}` when it trashed nothing), and the mail the judge offers for trashing, `[{thread_id, from, subject, date, why}]` (`[]` when none) |
| `deletion_date`, `days_left` | retention | `YYYY-MM-DD` the transcript can be deleted from (today when already due), and the whole days until then |
| `ticket_digest_jql`, `ticket_digest_fields` | a fetch step with `ticket_digest` | the digest's query, which the call must run character for character, and the fields to ask for |
| `ticket_search_jql`, `ticket_search_fields` | a fetch step with `ticket_search` | the ticket search's query, which the call must run character for character, and the fields to ask for |

A close prompt gets only `scratch`, `today`, `session_name` and `session_id`, and a retention prompt those plus `deletion_date` and `days_left`. The follow-up summary runs as a turn of the session it summarises, so it has that conversation and no input files; the status prompt is the first turn of an interactive session with the user's own permissions.

**Fetch steps.** What counts is the raw tool results, never the reply's prose: every URL that appears verbatim in any fetch step's tool *results* is what a judge may cite, and a URL only in a call's arguments (the address passed to WebFetch) does not count unless a result repeats it. Any fetch step's reply becomes `<its id, lowercased>.json` (id `F-web` gives `f-web.json`), and the `mail_fetch_step_id` step's also becomes `f-private.json`, each only if it is valid JSON; a judge reads them by listing those names in `input_files`. The ticket step must call `ticket_search_tool` with `{{jql}}`; its results are read in either Jira search shape, `{"issues": [...]}` or `{"issues": {"nodes": [...]}}`, and its reply is ignored. The mail step must search with `{{digest_query}}` exactly, and the write step reads `threads[].id` from that result, keeping the threads the same call then opened.

**Judge input files**, chosen by `input_files`:

| File | Contents |
|---|---|
| each name in `files` (`notes.md`, `reading.md`) | the committed file, with each line you took from a suggestion suffixed `  <<agent-suggested>>` |
| `sources.json` | the sources file |
| `f-private.json`, `<id>.json` (e.g. `f-web.json`) | those fetch replies, `{}` when absent or invalid (`f-` names); for a step with `ticket_search`, the runner's `{window, tickets, coverage}` instead ([The ticket search](#the-ticket-search)) |
| `tickets.json` | `[{key, summary, status, previous_status}]` for tickets whose status changed since the last check |
| `sessions.json` | `[{name, status}]` from the reader |
| `open-items.json` | suggestions still waiting on you, in the item shape below, with their runner-assigned ids |
| `ticket-digest.json` | the [ticket digest](#the-ticket-digest), `{}` when its step failed |
| `inbox.json` | the [mail triage](#mail-triage)'s candidates, `{coverage, threads}`, `{}` when the pass has none or its listing failed |
| `declined.json` | the 50 suggestions you most recently declined, same shape; a declined suggestion is also blocked by content (file, kind, target, normalised before/after), so a regenerated copy under a new id is dropped even without a URL source |
| an object `{name, path, sections}` in `input_files` | the file at `path` (relative to the config's directory), seeded as `name`, a plain file name. With `sections`, a list of Markdown heading texts, only those sections: each from its heading to the next at its level or above, in the file's order. A missing file, or a heading not found, is logged and left out. |

A close or retention call's cwd holds `session.json` (its reader entry), `transcript-tail.jsonl` and the captures file (`notes.md` by default).

**The reply** of a judge, close or retention call is its final message: one JSON object `{"items": [...]}` (a bare array is accepted too), nothing else. A judge's object may also carry `near_misses`, `[{"headline", "why_not"}]`: candidates it judged just below the bar. The runner keeps at most five, as one-line plain text, for the follow-up summary; they are never proposed. It may carry `mail_cleanup`, `[{"thread_id", "why"}]`: threads from `inbox.json` it judges no longer useful, which are only offered ([Mail triage](#mail-triage)).

| Field | Meaning |
|---|---|
| `id` | unique within the reply; the runner rewrites it to `<pass>-<scheduled date>-<n>-<id>` |
| `file` | one of `files` |
| `kind` | `new`, `add`, `link` (insert); `edit`, `remove` (in place); `move`, `merge` (remove in one place, insert in another) |
| `target` | `"top"`, `{"under": line}` (end of the block that line heads), `{"after": line}` (end of the block containing it), or `{"at": line}`, the first line of `before`, for `edit` and `remove`; `move` and `merge` take `[{"at": …}, <landing anchor>]`. A quoted line is a whole line, matched exactly, at least three characters, and an `at` is the first line of `before`: `desk-propose` refuses an item whose `at` is shorter or is another line, and a pass drops it, naming it in the log. An `at` that is shorter and still reaches the proposal is found by its `before` lines instead. |
| `before` | the exact existing lines for in-place and moving kinds, else `""` |
| `after` | the new text, `""` for `remove` |
| `source` | a URL from the fetch results, or a non-URL tag such as `notes` or `ticket:ABC-1` |
| `headline` | a few words for the overview |
| `tier` | optional: `act`, `worth_knowing` or `wildcard`; only tiered items are capped |
| `also_sources` | optional: other URLs for the same story |
| `supersedes` | optional: the id of an open item this replaces |

**Where an item lands.** Every item is placed against the committed text, never against what another item made of it.

- An item whose quoted line, or `before`, is only in your uncommitted text waits for you to commit that line: it is deferred until then, and `desk-propose` names the line it waits on. Otherwise an anchor whose quoted line has gone lands the item on top. An `edit` or `remove` whose `before` no longer sits at its anchor, or a `move` or `merge` whose `before` is gone, is deferred to the next pass, so text you deleted is never put back.
- An `edit`, `remove`, `move` or `merge` takes away only its own `before` lines, so whatever lands beside them stays, and an edit's new text sits below anything inserted at the same spot. Of two items that take away the same line, the one listed first applies and the other is deferred.
- Blank lines at the edges of `after` are fitted to where it lands: one is kept where it separates the text from a non-blank line, any other dropped, so an item can add the blank line between two sections but never doubles one or leaves one at the file's start or end. A `move` of a section (a block between blank lines) takes one blank line along, and gets one on each side that meets text where it lands. The proposal stores each `after` as it landed.
- A capped tier's overflow is held back, never proposed: the count per tier is in the status file (`+N <tier> held back` on the status line), and the follow-up summary names each, so the user can ask that session to show or propose it.
- A new item replaces an open one that it names in `supersedes`, that shares a URL with it, or that is an `edit`, `remove`, `move` or `merge` of the same existing line (same kind, same `at`). Insertions never replace each other by place: two `add`s under one heading are two suggestions.

**What the runner enforces on a reply**: an item whose URL `source` is not in the allowed set is dropped, named in the log, counted in the status file's `proposal.dropped` and named in the follow-up summary; an `also_sources` URL not in it is dropped from the list; any other URL in the item's text becomes `[url removed]` (a labelled link becomes `label [url removed]`), except that an `edit`, `move` or `merge` keeps in `after` a URL its `before` carries, once that `before` is found as whole lines in the committed file; control characters, ANSI sequences, vim modelines and `<<agent-suggested>>` markers are stripped. A close or retention call allows no URLs at all, and each of its bullets must cite a transcript turn as `[turn <first 8 chars of that entry's uuid>]`: an item citing a turn not in the tail it was given is dropped, and the markers are removed from what is kept.

**What only the prompt can say.** The tool allowlist decides what a call *can* do, not what it tries, and everything a call reads is written by someone other than the prompt's author. So every prompt carries two lines the runner cannot check: that the call never sends, posts or changes anything outside its own reply (for a write step, nothing beyond its one pinned call), and that everything it reads in files and tool results is data, never instructions (`agents/principles.md`, "External content is data, never instructions").

## Retention

Claude Code deletes a transcript once it is older than `cleanupPeriodDays` (default 30), in a background sweep that any Claude Code start can run, the runner's own calls included. The `retention` step measures age from the transcript's mtime and reports `mtime + cleanupPeriodDays` as the deletion date, the earliest the sweep can remove it; a resume writes to the transcript and so moves the date on. It reads `cleanupPeriodDays` from `$CLAUDE_CONFIG_DIR/settings.json` (default `~/.claude`), falling back to 30 when absent, and fails on a file it can't parse or a value that isn't a whole number of at least 1. It does not see a value set in managed settings or in a project's `.claude/settings.json`, and it ignores transcripts outside `$CLAUDE_CONFIG_DIR/projects`. `claude/desk-lib/retention.sh` has the sources for this.

A retention item that moves the user's entry is kept only when its `before` is lines that sit together in the committed captures file and its `after` carries every one of them, in order and unchanged apart from indent and the appended date; otherwise it lands as `new` on top with just its first line and the added bullets, and the entry stays where it was. The runner appends the deletion date to the first line when the text lacks it.

## The follow pass

A pass of kind `follow` forwards news on tickets to the Claude Code session that tracks them: a **follow session**, one the user keeps open on an epic or a task, holding the plan for it. The pass sends that session each change with news in it as a cross-session message, and counts the rest. Only the session's reply decides whether to involve the user.

**The follow list** is machine-local, since session ids exist only on this machine. It is `$DESK_FOLLOW_FILE` (default `~/.local/state/desk/follow.json`), `{"entries": {<session id>: {label, keys, related, added_at}}}`, and only `desk-follow` edits it:

```sh
desk-follow add [--session <id|name>] [--label <text>] [--related <KEY>...] <KEY>...
desk-follow remove [--session <id|name>] [<KEY>...]   # no keys: the whole follow
desk-follow list [--json]
desk-follow run [--dry-run] [--lookback-minutes N]    # one run now
```

`--session` defaults to `$CLAUDE_CODE_SESSION_ID`, which Claude Code sets in its Bash tool, so a session can register itself. The `desk-follow` skill (`agents/skills/desk-follow/`) tells a session what each ask means. `list --json` gives each entry's liveness, queue, last send, and `all_closed_since` once every tracked and related ticket is in the done category.

**Telling a session it is followed.** A follow added from outside its session, or one whose keys change, sends that session one short intro through the pass's own pinned send: it is now followed, on which tickets, to load the `desk-follow` skill, and that a handoff carries what the skill's "Before compacting" lists. Run inside the target session, `add` sends nothing; adding the same keys again, and removing, send nothing either. When the session is not running or the send fails outright, the intro waits on the entry (`intro_due_at`) and leads the session's first update instead.

**What a run reads**, read-only:

- **Tickets**, in one restricted model call whose only tool is the configured search tool, running two queries the runner builds. The scope query, every `scope_refresh_minutes` or when the keys change, fetches the tracked keys, the related keys and the children of the tracked keys. A session's scope is those, plus every ticket linked to a tracked key or a child (one hop, any project), except a ticket another followed session owns (one of its tracked keys or their children): that ticket's news goes only to its owner, so two sessions on neighbouring work don't hear about each other's tickets. A ticket two sessions both track goes to both, and so does one a session lists among its related keys. The changes query fetches every ticket in a scope, every child, and every ticket whose text mentions a tracked or related key, updated within the window. Results count only from calls whose `jql` is exactly the one the runner built.
- **Pull requests**, through `gh pr list` and `gh pr view` only (any other `gh` subcommand is refused), in each of `github_repos`, updated within the window, whose title or branch carries a key in some session's scope. A listing holds at most 100, oldest update first; one that reaches that is logged, and the window moves only to the newest update it listed. Comments and reviews are fetched only for a PR that moved since its snapshot.

**What counts as a change.** Each ticket and PR is snapshotted in `$DESK_FOLLOW_STATE_FILE` (default `~/.local/state/desk/follow-state.json`), and a change is a difference from the snapshot. For a ticket: status, summary, assignee, resolution, parent, labels, links, a description edit, and new or edited comments. For a PR: state, draft, review decision, title, new commits, labels, a description edit, a change in the failing checks or a check run finishing, and new comments and reviews. The window runs from the last fetch of that source that came back, with five minutes of overlap that comment and review ids keep from repeating anything. A source's first run records snapshots and sends nothing; a failed fetch keeps that source's window where it was.

**What is forwarded, and what is only counted.** The runner decides, not a model, since every rule is a property of the data. What is not forwarded is counted in the message's footer, by kind, so nothing goes missing silently.

| Forwarded | Counted, not listed |
|---|---|
| New or edited comments, reviews and PR comments by people | Comments and reviews by bots (`bot comments`, `bot reviews`) |
| A description edit, a rename or retitle, new commits on a PR | A status or resolution move with nothing else on that ticket (`status moves`); a PR merging, closing, going draft or ready, or changing review decision (`PR state changes`) |
| A reassignment, a move to another parent, a link added or removed | Labels (`label changes`), and check results (`check results`) |
| A ticket created in the window, a new child under a tracked key, a PR opened in the window | A ticket or PR only seen for the first time, with no snapshot to compare (`first-seen tickets`, `first-seen PRs`). This covers a ticket that merely mentions a key, and every ticket in a `--lookback-minutes` run. Its comments in the window are still forwarded. |

A ticket's field changes travel together: when any of them is forwarded, the line carries all of them, the status move included. A post is a bot's when its author matches one of the pass's `skip.bot_authors`, or its body opens with one of `skip.bot_signatures` (a bot posting through a person's account); a person quoting bot output further down is still a person. A run that has only counted changes sends nothing; its counts carry over into the footer of the next message, and reset once that message is confirmed.

**Delivery.** Changes queue per session. The address is the session's current name, so the message goes only when the session is live and its name resolves back to the same id; a session that isn't running, or whose name another live session shares, keeps its queue and gets everything in one message once it is reachable. The send is one restricted model call whose only tool is SendMessage, with the deny hook pinning `to` and `message` to the resolved name and the runner-built text, so it can reach no other peer. The queue empties only when that exact call ran and its result confirms a delivery (`follow.sh` has the parsing). A call that never ran, or a result of `success: false`, sent nothing: the queue stays and scheduled tries back off, doubling from `interval_minutes` up to four hours (a manual run always tries). A call that ran without a confirming result may have delivered, so after a second such send the changes count as sent, `last_sent` records `confirmed: false`, and the log says so.

**The message** starts with `[desk-follow] Update for <label>: …. Not from the user.`, the marker a hook can tell a follow turn by, then the instance's standing `preamble`, so a session handles it correctly even after compaction, then the forwarded changes oldest first, one line each: time, ticket or PR, title, how it relates to the session's keys, and what moved. A line on a ticket another followed session also has (as a key, a child of one or a related key; for a PR, any of its keys) says `(also followed by <name>)`. Past `message_max_chars`, later lines are named by ticket only. The last line is the footer: `Skipped since the last update, not listed: 4 status moves, 9 bot comments.`, or `nothing`. The preamble states the bar for involving the user and the reply contract: `[needs-you]` and a plain-language line on what needs the user, or one quiet line. `claude/hooks/input-bell.sh` rings on an idle turn whose reply has a line starting with `[needs-you]` or ends on a direct question, so a quiet reply must do neither.

**Permission class.** Every call runs with `--permission-mode dontAsk`, which Claude Code counts with the prompting modes. A sender and receiver in different classes (bypass against prompting) have their messages held for the receiver's approval, then dropped after five minutes, so neither the follow pass nor a follow session may run in bypass mode.

**Its own path.** `desk-run <pass>` hands a follow pass to `claude/desk-lib/follow.sh` before anything else: no once-a-day guard, no shared runner lock (it takes its own, `follow`, and waits at most a minute for another follow run), no notes repo, no status file. `--scheduled` (what the plist or service passes) skips a run less than `interval_minutes` after the last one; a manual run always runs. `--dry-run` fetches, prints each message it would send, and sends and writes nothing. `--lookback-minutes N` sets the window to the last N minutes without moving the stored windows; with `--dry-run`, that previews real traffic on a machine with no state yet.

| Key (under the pass) | Default | Meaning |
|---|---|---|
| `kind` | required | `"follow"` |
| `interval_minutes` | `15` | The schedule's spacing. Values under 15 are clamped to 15, with a log line. Keep the plist's `StartInterval`, or the timer's `OnUnitActiveSec`, at this interval. |
| `scope_refresh_minutes` | `60` | How often the scope query reruns. |
| `jira.tool`, `jira.prompt` | required | The search tool and the prompt that runs the two queries. The prompt gets `{{scope_jql}}` and `{{changes_jql}}` (each `none` when it doesn't run), `{{scope_fields}}`, `{{changes_fields}}` and `{{today}}`. |
| `jira.mcp_config`, `jira.model`, `jira.timeout`, `jira.max_budget_usd` | none, the account's default, `300`, `1` | As for a step. |
| `jira.max_output_tokens` | `2000` | Passed as `MAX_MCP_OUTPUT_TOKENS`, so a search result past it is saved to a file the runner reads ([runner-read results](#runner-read-results)). Keep each query under the 100 results one page holds. |
| `github_repos` | `[]` | `owner/name` repos whose PRs are matched. |
| `send.prompt` | required to send | Gets `{{to}}` and `{{message}}`. It must tell the call to send exactly that, once. |
| `send.model`, `send.timeout`, `send.max_budget_usd` | the account's default, `180`, `1` | |
| `preamble` | `prompts/follow-preamble.md` | The standing preamble, relative to the config's directory. |
| `message_max_chars` | `8000` | The send call copies the message into its tool call, and the deny hook refuses any copy that is not exact, so a shorter message is likelier to go through first time. |
| `queue_max` | `200` | Per session; older changes past it are counted, not kept. |
| `skip.bot_authors` | `[]` | Regexes, case-insensitive, for the author names of automated accounts: a GitHub login, or a Jira display name. |
| `skip.bot_signatures` | `[]` | Regexes for the opening of a post a bot makes through a person's account, matched against the raw body after leading whitespace. |

## The ticket digest

The follow pass covers the tickets a follow session holds, within minutes. The ticket digest covers the rest of a project's tickets and a repo's pull requests, once a pass: what changed on them since the pass's last good fetch, for the judge to weigh like any other candidate. Between them they carry what the ticket tracker's and the code host's own notifications would, so those can be muted. Neither covers chat.

A fetch step with a `ticket_digest` key runs the digest's query beside its own work, with `{{ticket_digest_jql}}` and `{{ticket_digest_fields}}`; its prompt tells the call to run that query exactly and leave the result alone. The window is capped at `max_window_days`, so a pass after a long absence covers only its last days. Pull requests come from `gh pr list` and `gh pr view` in each of `github_repos`, every one updated in the window.

<a id="runner-read-results"></a>**Runner-read results.** For the digest, the ticket search and the follow pass's ticket call, the runner reads the search result, not the model. A result past Claude Code's output limit reaches the stream only as a saved file, which the runner copies out of the call's spill directory (`desk_call_model --spill-dir`), so the tickets' text stays out of the model's context: cheaper, and nothing for that text to steer. The cost is pagination, since the call can't see a next-page token in a saved result: a result whose last page says more follow counts as failed.

**What counts as a change** is the follow pass's diff, run against the digest's own snapshots, with the same `skip` rules and these differences:

- Everything a followed session covers is left to the follow pass: a ticket in a session's scope or under one of its tracked keys, and a PR carrying any such key. The count goes in `left_to_follows`.
- The user's own comments and reviews (`self`, matched against Jira display names and GitHub logins) are counted, and so are the state moves of a PR the user opened.
- A PR whose author matches `pr_skip_authors` (a dependency bot) is counted, unless its title or a label matches `pr_keep`.
- For a PR, opening, ready for review, merging and closing are news, with reviews and comments by people. New commits, a retitle and description edits are counted, as are review-decision changes, labels and checks.
- A ticket created in the window is counted as `new tickets`, since a new-tickets fetch reports those, and one first seen with no snapshot is counted as the follow pass counts it; its comments in the window are still listed.

**What the judge gets**, as `ticket-digest.json`: `{window: {since, until}, entries, more, counted, left_to_follows}`. Each entry is one ticket (`kind: "ticket"`, `key`, `summary`, `type`, `status`, `assignee`, `parent`) or one PR (`kind: "pr"`, `pr`, `title`, `url`, `state`, `draft`, `author`, `keys`), with its `changes` oldest first (`at`, `what`), at most `max_changes` of them, and `earlier_changes` counting the rest. Entries with a person's post come first, then the most recently moved, up to `max_entries`; `more` names the ones past the cap. A listed PR's `url` is an allowed source for the judge's items, since the runner read it from `gh` itself; a ticket is cited as `ticket:<KEY>`.

**Snapshots** are kept in `ticket-digest-state.json` under the state directory and installed only when the pass's fetch window moves, so a failed pass that is retried compares against the same snapshots, and a retry slot reuses the cached fetch. One left unmoved for 180 days is dropped. The follow list and follow state are only read.

| Key (under `ticket_digest`) | Default | Meaning |
|---|---|---|
| `jql` | required | The tickets to cover, e.g. `project = ABC`. The runner adds `AND updated >= -<minutes>m`. |
| `github_repos` | the follow pass's | `owner/name` repos whose PRs are covered. |
| `skip.bot_authors`, `skip.bot_signatures` | none | Added to the follow pass's `skip` lists. |
| `self` | `[]` | The user's names and logins. |
| `pr_skip_authors`, `pr_keep` | `[]`, none | Regexes, case-insensitive. |
| `max_window_days` | `4` | The window's floor. |
| `max_entries`, `max_changes` | `25`, `6` | The caps on what the judge gets. |
| `pr_limit` | `200` | PRs listed per repo; a listing that reaches it is logged as cut short. |

## The ticket search

The ticket search lists the tickets created in the pass's window, for the judge to weigh as new work. A fetch step with a `ticket_search` key gets `{{ticket_search_jql}}` and `{{ticket_search_fields}}`; its prompt tells the call to run that query exactly, paging until no page says more follow, and to leave the result alone. The runner reads the result ([runner-read results](#runner-read-results)); the step's reply is not used.

The query is the configured `jql` with `AND created >= -<minutes>m` added, five minutes wider than the window so the tracker's own time zone never shifts it; the runner then keeps the tickets created in the window exactly. The window reaches back at most `max_window_days`, and the coverage line says when it was cut. The step's `<id>.json` (`f-tickets.json` for id `F-tickets`) is `{window: {since, until}, tickets, coverage}`: each ticket as `key`, `summary`, `type`, `status`, `creator`, `assignee`, `priority`, `created`, `parent` (`{key, summary}`), `labels` and `description` (cut at `max_description_chars`), with `user_part` `assigned` or `mentioned` when one of the `self` names is its assignee or appears in its summary or description. A ticket is cited as `ticket:<KEY>`.

When the query did not come back whole (no result, one that cannot be read, or a last page saying more follow), the step fails as a source: the pass reads `partial` with the step among its failed sources, the follow-up summary is told, and the judge still gets the file, with no tickets and a `coverage` starting `FAILED:`, so new tickets read as unchecked rather than none.

| Key (under `ticket_search`) | Default | Meaning |
|---|---|---|
| `jql` | required | The tickets to list, e.g. `project = ABC AND creator != currentUser()`. |
| `fields` | `summary`, `status`, `issuetype`, `creator`, `assignee`, `created`, `parent`, `labels`, `priority`, `description` | Passed to the prompt as `{{ticket_search_fields}}`. |
| `self` | `[]` | The user's names, for `user_part`. |
| `max_window_days` | `4` | How far back the query reaches at most. |
| `max_description_chars` | `1500` | Where a description is cut. |

## Mail triage

A fetch step with a `mail_triage` key lists the mailbox with one query, and the runner sorts every thread it lists, by rules, with no model deciding:

- **Noise**: every message in the thread matches one of the `noise` rules, the same rule throughout. The write step trashes these, up to `max_trash` a pass in listing order, newest first; the rest wait for the next pass. Each one is logged with its sender, subject and rule, and the follow-up tab is told every one, as trashed or, under `dry_run`, as what would be.
- **Protected**, never trashed or offered, whatever a rule says: a starred thread; an invitation (`invitation_subject`) whose event is today or later or names no date, since it may still want a reply; a thread the listing showed only part of (`messageCount` above the messages it carried); and, among the rest, one where a person wrote (a sender neither in `self` nor matching `automated_senders`) and the newest message is not the user's.
- **Candidates**: what is left of the inbox (threads without the `INBOX` label are only ever noise or left alone). The judge reads them as `inbox.json` and may list the ones it judges no longer useful in its reply's `mail_cleanup`; the runner keeps those naming a candidate, at most `max_offer`, and the follow-up tab offers to trash them. Nothing in the pass trashes them: the tab's session does, on the user's yes, which is why its `follow_up_settings` keep the trash tool on `ask`.

An event's date is read from the subject after its last ` @ `, in either `Fri 9 Oct 2026` or `Oct 9, 2026` order; with several, the latest counts, and an event is past only when that date is before today. Results count only from calls whose query is exactly the configured one, read by the runner ([runner-read results](#runner-read-results)), so a page too large for the call is still sorted, though the call cannot page past it. A listing cut short (its last page names another) is sorted as far as it got and the run status says so; one that did not come back fails the step as a source, and nothing is trashed.

| Key (under `mail_triage`) | Default | Meaning |
|---|---|---|
| `query` | required | The listing, e.g. `in:inbox OR label:"Digest"`. Its prompt runs it exactly, paging to the end. |
| `page_size` | `20` | `{{mail_triage_page_size}}`. Small enough that a page fits in the call's output, so it can see the next page's token. |
| `trash_tool` | the Gmail connector's `trash_thread` | The write step trashes with it only when it is among that step's `tools`. |
| `self` | `[]` | The user's addresses, matched exactly, case-insensitively. |
| `automated_senders` | no-reply, notification and mailer-daemon addresses | Regexes, case-insensitive, for senders that are not a person. |
| `invitation_subject` | `^(updated )?invitation( with note)?:` | Regex, case-insensitive. |
| `noise` | `[]` | Rules, `{name, from, subject, read, past_event}`: `from` and `subject` regexes (case-insensitive) on each message's sender address and subject, `read: true` for a thread with nothing unread, `past_event: true` for an event before today. Every condition given must hold, and a rule needs `from` or `subject`. |
| `max_trash`, `max_offer` | `100`, `25` | Per pass. |

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
| `<leader>gR` | Once this file has no suggestion left, move the review to the other file, in the same two windows, asking first about unsaved declines; with some left it says how many. Over a proposal that changed since the review was built, it reloads the review instead, asking about unsaved declines first, as below. The bar shows what waits there, as in `reading.md: 2 more ␣gR`. When another nvim has the other file open (its swap file is there), it says so in one line, with that nvim's pid, and the review stays as it was. |
| `zo`/`zc`, `zR`/`zM` | Open or close the fold of unchanged lines under the cursor; open or close them all. |
| `:w` | The commit point: records as declined every suggestion whose lines are gone from both the split and your notes, restores any declined this session whose lines are back, and records pending takes. A suggestion you edited in the split and have not taken is neither: it stays waiting. |
| `<leader>gq` | End the review, from either window: unsaved declines ask to save, discard or cancel, and you are left in your notes. The overview goes with it. Notes the review took into are saved too, which records the takes, and it says so in one line: `saved notes.md with your takes`. Your own edits there are saved along with them; a file it took nothing into is left as it is. Only the notes window's bar names it; the split's is full. |
| `:q`, `:wq` | `:q` from either window ends the review and leaves you in your notes, its takes unsaved there; `:wq` in the review split also saves declines, and saves the notes it took into as `<leader>gq` does. Quitting the split without saving records nothing; quitting your notes window over unsaved declines asks to save, discard or cancel, and cancelling puts your notes back below the split. A review that moved to the other file ends in the file it started from, as you left it. |

In your notes window while a review is open, keys that go when it ends. The suggestions' own lines are grey filler on this side, so a key here acts on the hunk the cursor is in: the one over the cursor line, else the filler just above it, else just below.

| Key | Action |
|---|---|
| `n`/`N`, `]c`/`[c` | As in the review split, wrapping around. |
| `do` | Take the diff hunk: every adjacent suggestion in it. |
| `<leader>gA` | Take just one suggestion of the hunk, the topmost; pressed again it takes the next. |
| `<leader>gD` | Decline one suggestion of the hunk, the topmost, which goes from the split; pressed again it declines the next. Recorded on the split's save, as a decline there is. |
| `u` | Undo the latest `<leader>gA` or `<leader>gD` made here while nothing has changed since, else plain undo, which is how a `do` take is undone. |
| `<leader>gq` | End the review, as in the review split. |

Not taking something is either a decline, from either window, or leaving it alone: an untaken suggestion comes back with the next pass. A take is remembered when you make it and recorded on the next save of either buffer, or when the review ends through `:wq`, `Q` or `<leader>gq`, so a suggestion you edit right after taking stays taken.

When the notes file changes on disk while you have unsaved edits in it and a review is open, the disk merge (README, Neovim) waits: it says so in one line and opens once the review ends, so the notes window is never in two diffs at once.

A `move` or `merge` shows as two hunks, its removal at the old place and its landing at the new one, and is only ever taken or declined whole: every take key on either hunk takes both places and says so (`took the whole move: removed here, added under Section C`), and the decline keys decline both. One already taken in one place gets the other place on its next take, and declining it removes just its landing, leaving your notes as they are.

A pass, or a session staging with `desk-propose`, can replace the proposal while a review is open. Entering either review window or the overview notices, and so does every take or decline. With nothing unsaved in the split, the review is rebuilt in its own windows, the cursor on the line it was on, and says so; a take or decline that noticed does nothing that once, so you look and press again. With unsaved declines the split stays as it is, says the proposal changed, and refuses to take or decline until `<leader>gR` has them saved or discarded and reloads it. A new proposal that shows the same suggestions as the same text is taken over silently.

The notes window's bar shows the status line: each pass's last result, untaken suggestions, closes and lockouts. While a review is open its count is that review's own, as in `30 left (34 saved)`: first the suggestions in this file neither taken nor declined, counting unsaved takes and declines, then what the ledger and `HEAD` say, which moves on a save or a commit. With no review open it is the recorded count over both files, `proposal pending (34 untaken)`, recounted when you enter the notes or come back to nvim, so a suggestion staged while the notes sat open shows on your return. Every bar has its keys on the left and its count on the right.

## Scheduling

On macOS, one LaunchAgent plist per pass, each running `desk-run <pass>` with `DESK_CONFIG` and a `PATH` that reaches bash 4+, `jq`, `nvim`, `perl`, `rg`, `claude` and `~/.local/bin`. `claude/desk-example/com.local.desk.morning.plist` is the pattern: launchd expands neither `~` nor `$HOME`, so it runs through `/bin/sh -c`, and it appends the pass's log to `~/.local/state/desk/logs/`. Set `CLAUDE_CONFIG_DIR` there too if your sessions live in a config directory other than `~/.claude`: the capture and close steps read sessions from it. Keep `StartCalendarInterval` equal to the pass's `trigger.start_calendar_interval` (launchd's `Weekday` uses the same 1–7 numbers). Several slots per pass are the retry mechanism: once a scheduled date finishes ok, later slots for it do nothing.

**Missed slots.** launchd runs a slot missed while the Mac slept once it wakes (several coalesce into one run), but not one missed while it was off. `RunAtLoad`, as in the example plist, closes that gap: the job also runs at every login, and the once-a-day guard makes the day's later slots no-ops. A login before the day's first slot belongs to the previous day's last slot, so it runs only if that day never finished; `trigger.same_day_only` makes it a no-op instead. A weekly pass with `RunAtLoad` needs `same_day_only`, or the first login of any day after a missed slot runs it. `RunAtLoad` fires at `launchctl bootstrap` too, so enabling such a job runs its pass straight away.

A follow pass's plist uses `StartInterval` (seconds, `interval_minutes` × 60) instead, and runs `desk-run <pass> --scheduled`. The first interval after a wake covers the whole gap, since the window runs from the last fetch that came back.

**Loading.** A job loaded with `launchctl bootstrap` stays loaded until a `bootout` or the next logout; at login, launchd loads only what is in `~/Library/LaunchAgents`. So a job that should survive restarts is linked there from the instance repo, and enabled by bootstrapping the link:

```sh
ln -s /path/to/instance/com.local.desk.morning.plist ~/Library/LaunchAgents/ \
  && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.desk.morning.plist
launchctl kickstart gui/$(id -u)/com.local.desk.morning    # run once now
launchctl bootout gui/$(id -u)/com.local.desk.morning \
  && rm ~/Library/LaunchAgents/com.local.desk.morning.plist
```

Link a job only once its instance runs cleanly by hand: from then on it runs at every login. Until then, `bootstrap` straight from the instance path tries it for one login session, and one `bootout` undoes it.

**On Linux**, systemd user units take the plist's place: per pass, a `.service` that runs `desk-run <pass>` and a `.timer` that starts it. `claude/desk-example/desk-morning.service` and `desk-morning.timer` are the pattern. The service sets `DESK_CONFIG`, `CLAUDE_CONFIG_DIR` and `PATH` itself, since the user manager's environment is not the login shell's, and appends to the same log. The timer's `OnCalendar` lines mirror `trigger.start_calendar_interval`, a weekday going first by name (`Mon *-*-* 08:30:00`). It is wanted by `graphical-session.target`, so like a LaunchAgent it runs only while you are logged in to the desktop, where the follow-up window opens.

Missed slots work as on macOS but for one case. A slot that falls while the machine is suspended fires on resume, several coalescing into one run. One missed while it was off or logged out fires once when the timer next starts, at the next login (`Persistent=true`), where launchd drops it and leaves `RunAtLoad` to catch up. `OnActiveSec` stands in for `RunAtLoad`: the pass also runs whenever the timer starts, at every login and at `enable --now`, so `same_day_only` matters exactly as it does there. A login after a missed slot can fire both; the second waits on the lock and finds the date done. Neither wakes a suspended machine, and a user timer cannot (`WakeSystem=` takes a system unit): waking for a slot is a system timer at the same times, after which the user timer fires on resume.

A follow pass's timer uses `OnActiveSec` with `OnUnitActiveSec` (`interval_minutes`) instead of `OnCalendar`, and its service runs `desk-run <pass> --scheduled`.

**Loading.** A unit is found in `~/.config/systemd/user`, so link it there from the instance repo and enable the timer:

```sh
ln -s /path/to/instance/desk-morning.service /path/to/instance/desk-morning.timer ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now desk-morning.timer
systemctl --user start desk-morning.service    # run once now
systemctl --user disable --now desk-morning.timer \
  && rm ~/.config/systemd/user/desk-morning.service ~/.config/systemd/user/desk-morning.timer
```

As with a plist, enable a timer only once its instance runs cleanly by hand; until then `systemctl --user start desk-morning.timer` tries it for this login only.

## The denylist

The dotfiles clone refuses to push until `desk.denylist` is set in it, once, locally:

```sh
git -C ~/dotfiles config desk.denylist /path/to/instance/denylist.txt
```

The list holds one Perl regex per line (`#` comments), matched case-insensitively unless a line turns that off with `(?-i)`, against every commit message and diff being pushed. It keeps the instance's own names (tools, hosts, ticket keys, people) out of this public repo, so it lives in the instance repo and is never tracked here: its contents would be the leak. A missing or empty list refuses too; `none` opts out explicitly. `git-hooks/pre-push` runs the check only when the repo being pushed is this one, since `core.hooksPath` points every repo on the machine at the same hooks. To check a range by hand: `git-hooks/desk-denylist-check.sh <repo> <range> <list-file>`.

## Dry-running a new instance

The defaults are the safe side of every outward-facing switch: `dry_run` (no write call, so no mail marked read or trashed), `log_only` (no session ended) and `push_enabled` off. Fetch and judge calls are real model calls even then, `follow_up_step` makes one more for its summary turn, and it and `open_tab` open real tabs.

- **Offline**, to check the config and prompts: point `DESK_CLAUDE_BIN` at a stub that prints a stream-json result, `DESK_OPEN_TAB_BIN` and `DESK_FOCUS_TAB_BIN` at stubs, and `DESK_STATE_DIR` and `CLAUDE_SESSION_STORE` at a temp directory, then `DESK_CONFIG=… desk-run <pass>`. `nvim/tests/desk-example-instance-test.sh` is a worked version, and checks that every placeholder a prompt uses is one the runner fills.
- **Live, without side effects**, against a copy: clone the notes repo to a temp path, point `notes_repo` at the clone in a copy of the config, and run each pass by hand with `DESK_STATE_DIR` set to a temp directory so the real status file, ledger and caches stay untouched. Read the log and `status.json`, then `<leader>gR` in the clone.
- Then on the real repo with the defaults still on, then each switch one at a time.

## Tests

```sh
DESK_GUARD_REPOS="$HOME/dotfiles" bash tests/run-all.sh
```

`tests/run-all.sh` runs every suite it names (a new file runs only once listed there) with safe defaults exported first: state and the reader cache under a temp directory, refusing stubs for `claude`, the tab helpers and the URL opener, and an empty reader, so a test that forgets an override fails instead of acting. It fails if the local git config of any repo in `$DESK_GUARD_REPOS` (colon-separated; default this repo's main checkout) or the content of `~/.local/state/claude` and `~/.local/state/desk` changed during the run; `tests/lib/git-safety.sh` says what that comparison skips. `git-hooks/pre-commit` applies the same guards. Tests that create repos use `tests/lib/git-safety.sh`, which refuses a root outside a temp directory and isolates git from the real global config.

The live checks are never in `run-all.sh`. `nvim/tests/desk-run-canary.sh` and `desk-run-canary-restricted.sh` make one real model call each to prove an unlisted tool is refused on the connector and restricted paths, and skip unless `DESK_CANARY_LIVE=1`; `desk-run-canary-selftest.sh`, which is in the suite, checks the first one's judgement against a fake `claude`. `hammerspoon/tests/tabs-live-check.sh` opens one real background tab that closes itself and checks that no focus or window changed (its header lists the checks), skipping unless `DESK_TABS_LIVE=1`; `tabs-live-check-selftest.sh` checks it offline. The Linux helpers have only `linux/desk/tests/tabs-test.sh`, against a stub `ghostty`, so what a real window does is checked by hand.

## State and overrides

Everything the runner writes lives under `~/.local/state/desk` (`$DESK_STATE_DIR`): `status.json`, `ticket-status.json`, `ticket-digest-state.json` (`$DESK_TICKET_DIGEST_STATE_FILE`), `lock/`, `guard/`, `scratch/` (removed after each pass), `runs/` (visible calls, kept seven days unless you carried on in one), `fetch-cache/` and `logs/`. Each has its own override, read at the top of `claude/desk-lib/common.sh` and the file that owns it, which is also where the timing knobs (`DESK_LOCK_MAX_WAIT_SECS`, `DESK_LOCK_POLL_SECS`, …) are. The recorder's store is `$CLAUDE_SESSION_STORE`. nvim and the runner find the tab helpers through `$DESK_OPEN_TAB_BIN` and `$DESK_FOCUS_TAB_BIN` (`close-session.sh` its own through `$DESK_CLOSE_TAB_BIN`), and nvim also reads `$DESK_READER` and `$DESK_OPEN_URL`. All default to the names on `PATH`, and the URL opener to `open` on macOS, `xdg-open` elsewhere. The Linux tab helpers run `$DESK_GHOSTTY_BIN` (default `ghostty`).
