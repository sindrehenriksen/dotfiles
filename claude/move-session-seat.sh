#!/usr/bin/env bash
# Moves a session to another seat of the work account, so it can be resumed
# there (claude-work-2 --resume <id>) when the seat it was on is out of usage.
#
# Usage: move-session-seat.sh <session-id> <seat>
#   <seat> is 1 (~/.claude-work) or n (~/.claude-work-<n>).
#
# What a resume needs is the transcript alone: it is copied to the same
# projects/<slug>/ path under the target seat, with the session's own
# directory beside it (subagent transcripts, saved tool results) and its
# file history when there are any. The original transcript is renamed
# <id>.jsonl.moved-to-<seat>, which the reader (session-status.sh) does not
# list, so the session shows once, on the seat that holds it. Refuses a live
# session (close it first: close-session.sh), a target that already has the
# session, and a session found on no seat. Prints the command that resumes it.
#
# Overrides (tests): $HOME, $DESK_READER.
set -u

READER="${DESK_READER:-session-status.sh}"
id="${1:-}"
seat="${2:-}"
die() {
	printf 'move-session-seat: %s\n' "$1" >&2
	exit "${2:-1}"
}
[ $# -eq 2 ] || die "usage: move-session-seat.sh <session-id> <seat: 1, 2, ...>" 2
[[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "not a session id" 2
[[ "$seat" =~ ^[0-9]+$ ]] || die "seat is a number: 1 for ~/.claude-work, 2 for ~/.claude-work-2" 2

target="$HOME/.claude-work"
[ "$seat" = 1 ] || target="$HOME/.claude-work-$seat"
[ -d "$target" ] || die "$target does not exist (run install_symlinks.sh and log in there first)"

live="$("$READER" < /dev/null 2> /dev/null | jq -r --arg id "$id" 'select(.id == $id) | .live' 2> /dev/null)" \
	|| die "the session reader ($READER) failed"
[ "$live" != true ] || die "the session is live; close it first (close-session.sh)"

src=""
for d in "$HOME/.claude-work" "$HOME"/.claude-work-[0-9]*; do
	for t in "$d"/projects/*/"$id".jsonl; do
		[ -f "$t" ] || continue
		[ -z "$src" ] || die "the transcript is under more than one seat ($src and $t)"
		src="$t"
	done
done
[ -n "$src" ] || die "no transcript for that session on any work seat"
from="${src%/projects/*}"
[ "$from" != "$target" ] || die "it is already on seat $seat"
slug="$(basename "$(dirname "$src")")"
dest="$target/projects/$slug"
[ ! -e "$dest/$id.jsonl" ] || die "seat $seat already has a transcript for it"

mkdir -p "$dest" || die "could not create $dest"
cp -p "$src" "$dest/$id.jsonl" || die "could not copy the transcript"
[ ! -d "$(dirname "$src")/$id" ] || cp -Rp "$(dirname "$src")/$id" "$dest/$id" || die "could not copy $id/ beside the transcript"
if [ -d "$from/file-history/$id" ]; then
	mkdir -p "$target/file-history" && cp -Rp "$from/file-history/$id" "$target/file-history/$id" 2> /dev/null
fi
mv "$src" "$src.moved-to-$seat" || die "copied, but could not mark the original as moved"

cwd="$(jq -r 'select(.cwd != null) | .cwd' "$dest/$id.jsonl" 2> /dev/null | head -n 1)"
printf 'moved %s from %s to %s\nresume: cd %q && claude-work%s --resume %s\n' \
	"$id" "${from##*/}" "${target##*/}" "${cwd:-<its directory>}" "$([ "$seat" = 1 ] || printf -- '-%s' "$seat")" "$id"
