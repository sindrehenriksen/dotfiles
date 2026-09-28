#!/usr/bin/env bash
# A generic, configurable pre-push content check — chained from git-hooks/
# pre-push. This repo is public, so it names no actual content of its own;
# `git config desk.denylist` points (locally, never tracked — the list's
# own contents would be the leak) at a file of patterns, one per line,
# matched case-insensitively unless a line embeds a PCRE `(?-i)` marker
# turning case-sensitivity back on from that point onward. Unset: prints
# one line and lets the push through. Set: checks every pushed ref's own
# range (commit messages and diffs together, via `git log -p`) against
# every pattern, failing closed on any git error or a configured-but-
# missing file — never silently letting a push through past a broken
# check. A brand-new branch (remote sha all zeros) has no remote tip to
# diff against, so its range falls back to `origin/main..<local ref>`.
#
# Reads git's own pre-push stdin protocol: one line per updated ref,
# "<local ref> <local sha> <remote ref> <remote sha>".
set -u

denylist="$(git config --get desk.denylist 2>/dev/null || true)"
if [ -z "$denylist" ]; then
	echo "desk-denylist-check: no desk.denylist configured — skipping"
	exit 0
fi
if [ ! -f "$denylist" ]; then
	echo "desk-denylist-check: desk.denylist is set to '$denylist' but that file doesn't exist — refusing to push" >&2
	exit 1
fi

zero_re='^0+$'
fail=0

while read -r local_ref local_sha remote_ref remote_sha; do
	[ -n "${local_sha:-}" ] || continue
	[[ "$local_sha" =~ $zero_re ]] && continue # a deleted ref: nothing pushed, nothing to check

	range="$remote_sha..$local_sha"
	[[ "${remote_sha:-}" =~ $zero_re ]] && range="origin/main..$local_sha"

	log_text=""
	if ! log_text="$(git log -p "$range" 2>&1)"; then
		echo "desk-denylist-check: 'git log -p $range' failed — refusing to push" >&2
		echo "$log_text" >&2
		fail=1
		continue
	fi

	while IFS= read -r pattern || [ -n "$pattern" ]; do
		[ -n "$pattern" ] || continue
		case "$pattern" in \#*) continue ;; esac
		if PATTERN="$pattern" perl -0777 -ne '
			my $p = $ENV{PATTERN};
			exit(0) if /(?i)$p/ms;
			exit(1);
		' <<< "$log_text"; then
			echo "desk-denylist-check: '$pattern' matched in $range ($local_ref) — refusing to push" >&2
			fail=1
		fi
	done < "$denylist"
done

exit "$fail"
