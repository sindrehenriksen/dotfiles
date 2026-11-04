#!/usr/bin/env bash
# Says why a live session would be worth restarting, for the offer
# Hammerspoon makes when its tab is focused (hammerspoon/init.lua,
# DeskStale). Cheap enough to run on every such focus: a few small files
# are read, and the process table and transcripts only once there is a
# reason to offer.
#
# Usage: session-stale.sh <session-id> [<reasons last offered>]
#            With the reasons last offered or dismissed (the lines this
#            printed then), reasons that still match are printed with exit
#            4 and none of the checks below run: they read the process
#            table and the whole transcript, which a tab focused for a while
#            would otherwise pay for again and again.
#        session-stale.sh --pid <pid> <config-dir>...
#            Names the session a live pid holds, for Hammerspoon, which has
#            only a tab's foreground pid: `<id>\t<config dir>\t<name>` from
#            the first config dir whose pid file names it and passes the
#            liveness check below, else exit 1.
#
# Reasons, one line each, `<kind>: <what changed>`:
#   version  its pid file's `version` is not the installed Claude Code
#            (the version the ~/.local/bin/claude link points at, else what
#            `claude --version` says).
#   shell    a file a fresh login shell is made of (DESK_SHELL_FILES in
#            desk-lib/start-state.sh) has other contents than when its
#            process started, by the hashes the recorder noted then (for
#            ~/.secrets.env, only its size and mtime), so its
#            environment, PATH and `claude` function predate the change. A
#            rewrite that changes nothing is no change; one that changes
#            only what another platform reads still counts. A session whose
#            start noted no hashes is not flagged.
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
# shellcheck source=desk-lib/liveness.sh
source "$HERE/desk-lib/liveness.sh"
# shellcheck source=desk-lib/start-state.sh
source "$HERE/desk-lib/start-state.sh"

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CONFIG_DIR="${CONFIG_DIR%/}"
STORE_DIR="${CLAUDE_SESSION_STORE:-$HOME/.local/state/claude/session-events}"
CLAUDE_BIN="${SESSION_STALE_CLAUDE_BIN:-$HOME/.local/bin/claude}"


usage() {
	echo "usage: session-stale.sh <session-id> [<reasons last offered>] | --pid <pid> <config-dir>..." >&2
	exit 2
}

# A pid file counts only when its process is the one it names: alive, a
# claude, and started when the pid file says (desk-lib/liveness.sh, the
# check session-status.sh makes).
pidfile_live() { # pidfile -> sets pf_id, pf_pid, pf_name; 0 when live
	local procstart
	IFS=$'\t' read -r pf_id pf_pid procstart pf_name < <(jq -r \
		'[(.sessionId // ""), (.pid // "" | tostring), (.procStart // ""), (.name // "")] | @tsv' "$1" 2> /dev/null) || return 1
	[[ "$pf_pid" =~ ^[0-9]+$ ]] || return 1
	check_live "$pf_pid" "$procstart"
	[ "$live" = true ]
}

if [ "${1:-}" = --pid ]; then
	[ $# -ge 3 ] && [[ "$2" =~ ^[0-9]+$ ]] || usage
	want="$2"
	shift 2
	for dir in "$@"; do
		dir="${dir%/}"
		[ -f "$dir/sessions/$want.json" ] || continue
		if pidfile_live "$dir/sessions/$want.json" && [ "$pf_pid" = "$want" ] && [ -n "$pf_id" ]; then
			printf '%s\t%s\t%s\n' "$pf_id" "$dir" "$pf_name"
			exit 0
		fi
	done
	exit 1
fi

id="${1:-}"
known="${2:-}"
[ $# -ge 1 ] && [ $# -le 2 ] && [ -n "$id" ] || usage
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
	grep -q "$id" "$f" 2> /dev/null || continue
	pidfile_live "$f" && [ "$pf_id" = "$id" ] && pids+=("$pf_pid")
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


# What the process started under: its own start (startup or resume), not a
# clear or compaction since, which load nothing.
IFS=$'\x1f' read -r loaded started_shell < <(jq -r --argjson pid "$pid" \
	'select(.event == "start" and .pid == $pid and .source != "clear" and .source != "compact")
	| "\(.account // "")\u001f\(.shell // {} | tojson)"' \
	"$STORE_DIR/$id.jsonl" 2> /dev/null | tail -n 1)

if [ -n "${started_shell:-}" ] && [ "$started_shell" != "{}" ]; then
	changed="$(jq -r -n --argjson was "$started_shell" --argjson now "$(desk_shell_hashes)" \
		'[$was | keys_unsorted[] | select($now[.] != $was[.]) | "~/\(.)"] | join(", ")' 2> /dev/null)"
	[ -z "$changed" ] || reasons+=("shell: $changed changed since it started")
fi

current="$(desk_current_account "${CLAUDE_CONFIG_DIR:-}")"
if [ -n "$current" ] && [ -n "$loaded" ] && [ "$current" != "$loaded" ]; then
	reasons+=("account: its connectors are another account's than the one logged in now")
fi

[ "${#reasons[@]}" -gt 0 ] || exit 0
if [ -n "$known" ] && [ "$(printf '%s\n' "${reasons[@]}")" = "${known%$'\n'}" ]; then
	printf '%s\n' "${reasons[@]}"
	exit 4
fi

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
