#!/usr/bin/env bash
# A generic, configurable content check for denylisted patterns. This repo
# is public, so it names no actual content of its own — the pattern list
# itself is always external and untracked.
#
# Two invocation forms share one matching core (desk_denylist_check_range
# below):
#
#   1. Hook form (no args): chained from git-hooks/pre-push. Reads git's own
#      pre-push stdin protocol, one line per updated ref — "<local ref>
#      <local sha> <remote ref> <remote sha>" — and resolves the pattern
#      list via `git config desk.denylist` in the current repo. One-time
#      install step for a personal clone: `git config desk.denylist
#      <path-to-your-private-pattern-list>` (set it locally, never tracked
#      — the list's own contents would be the leak). Unset: refuses to
#      push; set to the
#      literal "none" to opt out explicitly instead. Set but the file's
#      missing: refuses to push.
#
#   2. CLI form: `desk-denylist-check.sh <repo> <range> <list-file>` — all
#      three explicit, no git config, no stdin. For another repo's own
#      thin wrapper to call (its own repo, its own revision range, its
#      own pattern file) without needing to be a git hook itself.
#
# Both scan `git log -p` over the given range — commit messages and diffs
# together, every commit in the range (not just a net start/end diff, so a
# word added and later removed within the same range is still caught) —
# against every pattern in the list, matched case-insensitively unless a
# line embeds a PCRE `(?-i)` marker turning case-sensitivity back on from
# that point onward. Fails closed: a git error (a bad ref, an unreachable
# range, a range built from a zero sha with nothing to fall back to), a
# missing list file, or a list file with no actual patterns (blank/comment
# lines only — an empty list is far more likely a mistake than a
# deliberate allow-everything) all refuse rather than silently pass.
set -u

# desk_denylist_check_range <repo> <range> <list_file>
desk_denylist_check_range() {
	local repo="$1" range="$2" list_file="$3"

	if [ ! -f "$list_file" ]; then
		echo "desk-denylist-check: denylist file '$list_file' doesn't exist — refusing" >&2
		return 1
	fi
	if ! grep -vE '^[[:space:]]*(#|$)' "$list_file" > /dev/null 2>&1; then
		echo "desk-denylist-check: denylist file '$list_file' has no patterns — refusing (an empty list is likely a mistake)" >&2
		return 1
	fi

	local log_text
	if ! log_text="$(git -C "$repo" log -p "$range" 2>&1)"; then
		echo "desk-denylist-check: 'git -C $repo log -p $range' failed — refusing" >&2
		echo "$log_text" >&2
		return 1
	fi

	local fail=0 pattern
	while IFS= read -r pattern || [ -n "$pattern" ]; do
		[ -n "$pattern" ] || continue
		case "$pattern" in \#*) continue ;; esac
		if PATTERN="$pattern" perl -0777 -ne '
			my $p = $ENV{PATTERN};
			exit(0) if /(?i)$p/ms;
			exit(1);
		' <<< "$log_text"; then
			echo "desk-denylist-check: '$pattern' matched in $range ($repo) — refusing" >&2
			fail=1
		fi
	done < "$list_file"

	return "$fail"
}

# --- CLI form ----------------------------------------------------------------
if [ "$#" -gt 0 ]; then
	repo="${1:?usage: desk-denylist-check.sh <repo> <range> <list-file>}"
	range="${2:?usage: desk-denylist-check.sh <repo> <range> <list-file>}"
	list_file="${3:?usage: desk-denylist-check.sh <repo> <range> <list-file>}"
	desk_denylist_check_range "$repo" "$range" "$list_file"
	exit $?
fi

# --- hook form (no args): chained from git-hooks/pre-push --------------------
denylist="$(git config --get desk.denylist 2>/dev/null || true)"
if [ -z "$denylist" ]; then
	# Fails closed: an unconfigured denylist must never read
	# as "nothing to check, let it through" — that's exactly the state a
	# fresh clone starts in, and the one a push should never silently run
	# under. Refuse until it's set, one way or the other.
	echo "desk-denylist-check: desk.denylist is not set — refusing to push" >&2
	echo "  Set it: git config desk.denylist <path-to-your-private-pattern-list>" >&2
	echo "  Or opt out explicitly: git config desk.denylist none" >&2
	exit 1
fi
if [ "$denylist" = "none" ]; then
	echo "desk-denylist-check: desk.denylist explicitly set to 'none' — skipping (opted out)"
	exit 0
fi

zero_re='^0+$'
fail=0

while read -r local_ref local_sha remote_ref remote_sha; do
	[ -n "${local_sha:-}" ] || continue
	[[ "$local_sha" =~ $zero_re ]] && continue # a deleted ref: nothing pushed, nothing to check

	range="$remote_sha..$local_sha"
	[[ "${remote_sha:-}" =~ $zero_re ]] && range="origin/main..$local_sha"

	desk_denylist_check_range "." "$range" "$denylist" || fail=1
done

exit "$fail"
