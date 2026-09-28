#!/usr/bin/env bash
# Tests for desk-denylist-check.sh's two invocation forms: the hook form
# (git-hooks/pre-push chaining to it with no args, git config desk.denylist)
# via a real `git push` against a local bare repo this test creates and
# throws away — never a real remote — and the CLI form
# (<repo> <range> <list-file>, invoked directly, no git config involved)
# another repo's own thin wrapper calls.
# Run: bash git-hooks/test-desk-denylist.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DENYLIST_CHECK="$HERE/desk-denylist-check.sh"

# This test's own pre-commit hook (git-hooks/pre-commit) runs it FROM
# INSIDE a real `git commit`, which leaves GIT_DIR/GIT_WORK_TREE/
# GIT_INDEX_FILE etc pointing at the outer repo in this process's own
# environment — an explicit GIT_DIR wins over `-C`/cwd for repo discovery,
# so every nested `git init`/`git -C` below would otherwise silently
# operate on the real dotfiles-desk repo instead of the throwaway one this
# test creates. See tests/lib/git-safety.sh for the rest of what this
# guards against.
# shellcheck source=../tests/lib/git-safety.sh
source "$HERE/../tests/lib/git-safety.sh"
desk_test_git_env_isolate

# Second line of defense on top of the unset above: if isolation ever
# breaks anyway (a future edit re-introduces an inherited GIT_DIR, a new
# call site forgets -C, etc), abort loudly instead of silently running
# further git commands — commits, pushes, resets — against this real repo.
desk_test_git_guard_toplevel_init
REAL_TOPLEVEL="$DESK_TEST_GIT_GUARD_REAL_TOPLEVEL"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	local desc=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then ok "$desc"; else bad "$desc (expected [$expected], got [$actual])"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
desk_test_git_safety_init "$TMP"

bare="$TMP/origin.git"
desk_test_assert_repo_under_root "$bare" "$TMP"
git init -q --bare "$bare"
bare_gitdir="$(git -C "$bare" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [ "$bare_gitdir" = "$REAL_TOPLEVEL/.git" ]; then
	echo "ABORT: '$bare' resolves to this repo's .git instead of a throwaway one — refusing to continue" >&2
	exit 1
fi

work="$TMP/work"
desk_test_assert_repo_under_root "$work" "$TMP"
git init -q -b main "$work"
desk_test_guard_not_real_repo "$work"
git -C "$work" config user.email "test@example.com"
git -C "$work" config user.name "Test"
git -C "$work" config core.hooksPath "$HERE"
git -C "$work" remote add origin "$bare"

commit() { # msg content
	printf '%s\n' "$2" >> "$work/file.txt"
	git -C "$work" add file.txt
	git -C "$work" commit -q -m "$1"
}

remote_main_sha() { git -C "$bare" rev-parse --verify -q main 2> /dev/null || echo "(none)"; }

echo "=== no desk.denylist configured: refuses (fails closed), remote untouched ==="
commit "first commit" "hello world"
out="$(git -C "$work" push origin main 2>&1)"
status=$?
[ "$status" -ne 0 ] && ok "push is refused" || bad "push was NOT refused (exited 0)"
printf '%s\n' "$out" | grep -q "desk.denylist is not set" \
	&& ok "prints the not-set refusal" || bad "missing not-set refusal (got: $out)"
printf '%s\n' "$out" | grep -q "git config desk.denylist" \
	&& ok "says how to set it" || bad "doesn't say how to set it (got: $out)"
printf '%s\n' "$out" | grep -q "desk.denylist none" \
	&& ok "says how to opt out explicitly" || bad "doesn't say how to opt out (got: $out)"
assert_eq "remote main was never created" "(none)" "$(remote_main_sha)"

echo
echo "=== desk.denylist explicitly set to 'none': opts out, push goes through ==="
git -C "$work" config desk.denylist none
out="$(git -C "$work" push origin main 2>&1)"
status=$?
assert_eq "push exits 0" "0" "$status"
printf '%s\n' "$out" | grep -q "opted out" && ok "prints the opted-out status line" \
	|| bad "missing opted-out status line (got: $out)"
assert_eq "remote main advanced" "$(git -C "$work" rev-parse main)" "$(remote_main_sha)"
git -C "$work" config --unset desk.denylist

echo
echo "=== desk.denylist set, no pattern matches: push goes through ==="
deny="$TMP/denylist.txt"
printf 'invented-secret-marker\n' > "$deny"
git -C "$work" config desk.denylist "$deny"
commit "second commit" "nothing interesting here"
out="$(git -C "$work" push origin main 2>&1)"
status=$?
assert_eq "push exits 0 with a non-matching denylist" "0" "$status"
assert_eq "remote main advanced again" "$(git -C "$work" rev-parse main)" "$(remote_main_sha)"

echo
echo "=== a matching pattern in a new commit refuses the push ==="
before_sha="$(remote_main_sha)"
commit "leaky commit" "this line names invented-secret-marker in the clear"
out="$(git -C "$work" push origin main 2>&1)"
status=$?
[ "$status" -ne 0 ] && ok "push is refused" || bad "push was NOT refused (exited 0)"
printf '%s\n' "$out" | grep -q "invented-secret-marker" \
	&& ok "refusal names the matched pattern" || bad "refusal message missing the pattern (got: $out)"
assert_eq "remote main did NOT advance" "$before_sha" "$(remote_main_sha)"

# Drop the leaky commit locally so later tests push clean history again.
git -C "$work" reset -q --hard HEAD~1

echo
echo "=== a matching pattern in the commit MESSAGE (not just the diff) also refuses ==="
before_sha="$(remote_main_sha)"
printf 'clean content\n' >> "$work/file.txt"
git -C "$work" add file.txt
git -C "$work" commit -q -m "mentions invented-secret-marker in its own subject"
out="$(git -C "$work" push origin main 2>&1)"
status=$?
[ "$status" -ne 0 ] && ok "push is refused on a message-only match" || bad "push was NOT refused (exited 0)"
assert_eq "remote main did NOT advance" "$before_sha" "$(remote_main_sha)"
git -C "$work" reset -q --hard HEAD~1

echo
echo "=== case-insensitive by default ==="
before_sha="$(remote_main_sha)"
commit "mixed case" "INVENTED-SECRET-MARKER in caps"
out="$(git -C "$work" push origin main 2>&1)"
status=$?
[ "$status" -ne 0 ] && ok "a different-case match is still refused (case-insensitive default)" \
	|| bad "different-case match was NOT refused"
assert_eq "remote main did NOT advance" "$before_sha" "$(remote_main_sha)"
git -C "$work" reset -q --hard HEAD~1

echo
echo "=== (?-i) marker: case-sensitive from that point on ==="
printf 'invented-secret-marker\n(?-i)CaseSensitiveMarker\n' > "$deny"
before_sha="$(remote_main_sha)"
commit "wrong case for the sensitive marker" "casesensitivemarker, lowercase"
out="$(git -C "$work" push origin main 2>&1)"
status=$?
assert_eq "a lowercase mismatch against a (?-i) pattern is NOT refused" "0" "$status"
assert_eq "remote main advanced" "$(git -C "$work" rev-parse main)" "$(remote_main_sha)"

before_sha="$(remote_main_sha)"
commit "exact case for the sensitive marker" "CaseSensitiveMarker, exact case"
out="$(git -C "$work" push origin main 2>&1)"
status=$?
[ "$status" -ne 0 ] && ok "an exact-case match against a (?-i) pattern IS refused" \
	|| bad "exact-case match was NOT refused"
assert_eq "remote main did NOT advance" "$before_sha" "$(remote_main_sha)"
git -C "$work" reset -q --hard HEAD~1

echo
echo "=== desk.denylist set to a missing file: fails closed ==="
git -C "$work" config desk.denylist "$TMP/does-not-exist.txt"
commit "innocuous commit" "nothing to see here"
out="$(git -C "$work" push origin main 2>&1)"
status=$?
[ "$status" -ne 0 ] && ok "a missing denylist file refuses the push" || bad "missing file did NOT refuse the push"
printf '%s\n' "$out" | grep -q "doesn't exist" && ok "refusal explains the file is missing" \
	|| bad "refusal doesn't explain the missing file (got: $out)"
git -C "$work" reset -q --hard HEAD~1
git -C "$work" config --unset desk.denylist

echo
echo "=== a brand-new branch (no remote tip) falls back to origin/main..<ref> ==="
printf 'invented-secret-marker\n' > "$deny"
git -C "$work" config desk.denylist "$deny"
git -C "$work" checkout -q -b feature
commit "feature commit with a match" "leaky invented-secret-marker again"
out="$(git -C "$work" push origin feature 2>&1)"
status=$?
[ "$status" -ne 0 ] && ok "a new branch's match is still caught via the origin/main fallback" \
	|| bad "new-branch fallback did NOT catch the match"
git -C "$bare" show-ref --verify -q refs/heads/feature \
	&& bad "the new branch was pushed anyway" || ok "the new branch was never created on the remote"

git -C "$work" reset -q --hard HEAD~1
out="$(git -C "$work" push origin feature 2>&1)"
status=$?
assert_eq "a clean new branch still pushes fine" "0" "$status"
git -C "$bare" show-ref --verify -q refs/heads/feature && ok "the clean new branch landed on the remote" \
	|| bad "the clean new branch never landed"

echo
echo "=== CLI form: <repo> <range> <list-file> — no git config, no stdin ==="
cli_repo="$TMP/cli-repo"
desk_test_assert_repo_under_root "$cli_repo" "$TMP"
git init -q -b main "$cli_repo"
git -C "$cli_repo" config user.email "test@example.com"
git -C "$cli_repo" config user.name "Test"
git -C "$cli_repo" config core.hooksPath "$HERE"
git -C "$cli_repo" commit -q --allow-empty -m "root"
printf 'hello world\n' >> "$cli_repo/file.txt"
git -C "$cli_repo" add file.txt
git -C "$cli_repo" commit -q -m "first commit"

cli_deny="$TMP/cli-denylist.txt"
printf 'invented-secret-marker\n' > "$cli_deny"

status=0
"$DENYLIST_CHECK" "$cli_repo" "HEAD~1..HEAD" "$cli_deny" > /dev/null 2>&1 || status=$?
assert_eq "a non-matching range exits 0" "0" "$status"

printf 'this line names invented-secret-marker in the clear\n' >> "$cli_repo/file.txt"
git -C "$cli_repo" add file.txt
git -C "$cli_repo" commit -q -m "leaky commit"
status=0
out="$("$DENYLIST_CHECK" "$cli_repo" "HEAD~1..HEAD" "$cli_deny" 2>&1)" || status=$?
[ "$status" -ne 0 ] && ok "the CLI form catches a match and exits non-zero" || bad "the CLI form did NOT catch the match"
printf '%s\n' "$out" | grep -q "invented-secret-marker" && ok "the CLI form's refusal names the matched pattern" \
	|| bad "the CLI form's refusal doesn't name the pattern (got: $out)"

status=0
"$DENYLIST_CHECK" "$cli_repo" "not-a-real-ref..HEAD" "$cli_deny" > /dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] && ok "the CLI form fails closed on a bad ref" || bad "the CLI form did NOT fail closed on a bad ref"

status=0
"$DENYLIST_CHECK" "$cli_repo" "HEAD~1..HEAD" "$TMP/does-not-exist.txt" > /dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] && ok "the CLI form fails closed on a missing list file" \
	|| bad "the CLI form did NOT fail closed on a missing list file"

empty_deny="$TMP/empty-denylist.txt"
: > "$empty_deny"
status=0
"$DENYLIST_CHECK" "$cli_repo" "HEAD~1..HEAD" "$empty_deny" > /dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] && ok "the CLI form fails closed on an empty list file" \
	|| bad "the CLI form did NOT fail closed on an empty list file"

comments_only_deny="$TMP/comments-only-denylist.txt"
printf '# just a comment\n\n' > "$comments_only_deny"
status=0
"$DENYLIST_CHECK" "$cli_repo" "HEAD~1..HEAD" "$comments_only_deny" > /dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] && ok "the CLI form fails closed on a comments/blank-only list file" \
	|| bad "the CLI form did NOT fail closed on a comments/blank-only list file"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
