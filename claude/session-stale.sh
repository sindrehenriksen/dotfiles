#!/usr/bin/env bash
# Says why a live session would be worth restarting, for the offer
# Hammerspoon makes when its tab is focused (hammerspoon/init.lua,
# DeskStale). Cheap enough to run on every such focus: a few small files
# are read, and the process table and transcripts only once there is a
# reason to offer.
#
# Usage: session-stale.sh <session-id>
#
# Reasons, one line each, `<kind>: <what changed>`:
#   version  its pid file's `version` is not the installed Claude Code
#            (the version the ~/.local/bin/claude link points at, else what
#            `claude --version` says).
#   shell    a file that shapes a fresh login shell changed after its
#            process started (SHELL_FILES below), so its environment, PATH
#            and `claude` function predate the change.
#   account  the claude.ai account its process loaded its connectors under
#            is not the one its config dir is logged in as now. A running
#            session follows a /login made elsewhere for its usage, but its
#            connectors stay the ones it loaded, so this compares the
#            account at the process's own start (startup or resume, as
#            claude/hooks/session-recorder.sh records it) with the current
#            one, and switching back clears it. A session started before the
#            recorder noted accounts has none to compare and is not flagged.
#            Assumed, not tested: that a restart under the account it
#            loaded with brings back working connectors.
#
# Exit 0 with reasons: restart-session.sh would accept it now (the shared
# checks in desk-lib/restartable.sh: idle with nothing running, nothing
# scheduled in the process, a tab a prompt outlives, flags it can carry).
# Exit 0 with nothing printed: nothing to restart for. Exit 3 with reasons:
# its tab would close with it (a tab opened before tabs left a prompt), so
# it cannot be restarted in place. Exit 1, nothing printed and why on
# stderr: it cannot be judged or restarted now (not live, not idle, held by
# two processes). Exit 2: usage.
#
# Overrides (tests): $CLAUDE_CONFIG_DIR, $CLAUDE_SESSION_STORE,
# $SESSION_STALE_CLAUDE_BIN (default ~/.local/bin/claude),
# $RESTART_SESSION_PS and $RESTART_SESSION_QUIET_MINS as restart-session.sh
# reads them.
set -u

script_dir() {
	local src="${BASH_SOURCE[0]}" dir
	while [ -h "$src" ]; do
		dir="$(cd -P "$(dirname "$src")" && pwd)"
		src="$(readlink "$src")"
		[[ "$src" != /* ]] && src="$dir/$src"
	done
	cd -P "$(dirname "$src")" && pwd
}
HERE="$(script_dir)"
# shellcheck source=desk-lib/restartable.sh
source "$HERE/desk-lib/restartable.sh"
# shellcheck source=desk-lib/account.sh
source "$HERE/desk-lib/account.sh"

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CONFIG_DIR="${CONFIG_DIR%/}"
STORE_DIR="${CLAUDE_SESSION_STORE:-$HOME/.local/state/claude/session-events}"
CLAUDE_BIN="${SESSION_STALE_CLAUDE_BIN:-$HOME/.local/bin/claude}"

# What a fresh login shell in a tab is made of, as this repo sets one up:
# zsh reads ~/.zprofile (login) and ~/.zshrc (interactive); .zprofile reads
# ~/.profile, which puts ~/.local/bin on PATH, and .zshrc reads ~/.shellrc,
# which holds the PATH, the environment and the `claude` account switcher
# shared with bash, and reads the machine-local ~/.shellrc.early and
# ~/.secrets.env. A session's environment, PATH and the flags its `claude`
# function gave it all come from these. The plugins, fzf and the prompt are
# left out: they shape the shell, not what a session runs with.
SHELL_FILES=(.zprofile .zshrc .profile .shellrc .shellrc.early .secrets.env)

id="${1:-}"
if [ $# -ne 1 ] || [ -z "$id" ]; then
	echo "usage: session-stale.sh <session-id>" >&2
	exit 2
fi
not_now() {
	echo "session-stale: $1" >&2
	exit 1
}
[[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
	|| not_now "not a session id"

# The live claude process holding it, from the pid files Claude Code keeps.
pids=()
for f in "$CONFIG_DIR"/sessions/*.json; do
	[ -f "$f" ] || continue
	p="$(jq -r --arg id "$id" 'select(.sessionId == $id) | .pid' "$f" 2> /dev/null)"
	[[ "$p" =~ ^[0-9]+$ ]] || continue
	case "$(ps -o comm= -p "$p" 2> /dev/null)" in
		claude | */claude) pids+=("$p") ;;
	esac
done
[ "${#pids[@]}" -gt 0 ] || not_now "no live process holds it"
[ "${#pids[@]}" -eq 1 ] || not_now "more than one process holds it"
pid="${pids[0]}"
pidfile="$CONFIG_DIR/sessions/$pid.json"
started=$(($(jq -r '.startedAt // 0' "$pidfile" 2> /dev/null) / 1000))
[ "$started" -gt 0 ] || not_now "its pid file says nothing of when it started"

reasons=()

running="$(jq -r '.version // empty' "$pidfile" 2> /dev/null)"
installed="$(basename "$(readlink "$CLAUDE_BIN" 2> /dev/null)")"
[[ "$installed" =~ ^[0-9]+\.[0-9]+ ]] \
	|| installed="$("$CLAUDE_BIN" --version 2> /dev/null < /dev/null | awk '{ print $1; exit }')"
if [ -n "$running" ] && [ -n "$installed" ] && [ "$running" != "$installed" ]; then
	reasons+=("version: $running running, $installed installed")
fi

changed=""
for f in "${SHELL_FILES[@]}"; do
	m="$(stat -L -c %Y "$HOME/$f" 2> /dev/null || stat -L -f %m "$HOME/$f" 2> /dev/null)"
	[ -n "$m" ] && [ "$m" -gt "$started" ] && changed="${changed:+$changed, }~/$f"
done
[ -z "$changed" ] || reasons+=("shell: $changed changed since it started")

current="$(desk_current_account "${CLAUDE_CONFIG_DIR:-}")"
loaded="$(jq -r --argjson pid "$pid" \
	'select(.event == "start" and .pid == $pid and .source != "clear" and .source != "compact") | .account // ""' \
	"$STORE_DIR/$id.jsonl" 2> /dev/null | tail -n 1)"
if [ -n "$current" ] && [ -n "$loaded" ] && [ "$current" != "$loaded" ]; then
	reasons+=("account: its connectors are another account's than the one logged in now")
fi

[ "${#reasons[@]}" -gt 0 ] || exit 0

# --- would restart-session.sh accept it ---

restartable_procs || not_now "could not list processes"
transcripts=() subagents=()
for t in "$CONFIG_DIR"/projects/*/"$id".jsonl; do
	[ -f "$t" ] || continue
	transcripts+=("$t")
	subagents+=("$(dirname "$t")/$id/subagents")
done
[ "${#transcripts[@]}" -gt 0 ] || not_now "no transcript, so no way to tell whether subagents are running"
restartable_idle "$pid" "$pidfile" "${subagents[@]}" || not_now "$restartable_why"
restartable_schedules "$pidfile" "${transcripts[@]}" || not_now "$restartable_why"
if ! restartable_prompt "$pid"; then
	printf '%s\n' "${reasons[@]}"
	exit 3
fi
cwd="$(jq -r '.cwd // empty' "$pidfile" 2> /dev/null)"
restartable_flags "$pid" "${cwd:-/}" || not_now "$restartable_why"
printf '%s\n' "${reasons[@]}"
