#!/usr/bin/env bash
# Tests for desk-denylist-check.sh's two invocation forms, and for
# git-hooks/pre-push's own routing in front of the hook form.
#
# The user's `core.hooksPath` points every repo on the machine at THIS repo's
# git-hooks dir, so pre-push must fire the denylist check only when the
# repo actually being pushed is this repo — every other repo passes
# straight through regardless of its own (unset, or leftover) `desk.denylist`.
# Two throwaway setups below model that:
#   - "self" repo: its own git-hooks dir is a copy of this repo's,
#     living INSIDE itself, with core.hooksPath pointing at that copy —
#     the repo being pushed IS the repo the hooks belong to, same as the
#     real dotfiles-desk arrangement. The denylist check must fire here.
#   - "other" repo: an unrelated throwaway repo whose core.hooksPath
#     points at THIS repo's real git-hooks dir — modelling the user's global
#     hooksPath pointing every other repo at these same hooks. The
#     denylist check must never fire here, regardless of what
#     `desk.denylist` says (including a leftover config naming a pattern
#     that would otherwise match), and a brand-new branch with no
#     `origin/main` yet must push cleanly.
#
# All via a real `git push` against a local bare repo each setup creates
# and throws away — never a real remote. The CLI form
# (<repo> <range> <list-file>, invoked directly, no git config, no hook
# routing involved) is tested separately at the bottom.
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

commit() { # workdir msg content
	local wd="$1" msg="$2" content="$3"
	printf '%s\n' "$content" >> "$wd/file.txt"
	git -C "$wd" add file.txt
	git -C "$wd" commit -q -m "$msg"
}

# =============================================================================
# "self" repo: hooks live inside the repo being pushed, same arrangement as
# the real dotfiles-desk — the denylist check MUST fire.
# =============================================================================

self_bare="$TMP/self-origin.git"
desk_test_assert_repo_under_root "$self_bare" "$TMP"
git init -q --bare "$self_bare"
self_bare_gitdir="$(git -C "$self_bare" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [ "$self_bare_gitdir" = "$REAL_TOPLEVEL/.git" ]; then
	echo "ABORT: '$self_bare' resolves to this repo's .git instead of a throwaway one — refusing to continue" >&2
	exit 1
fi

self_repo="$TMP/self-repo"
desk_test_assert_repo_under_root "$self_repo" "$TMP"
git init -q -b main "$self_repo"
desk_test_guard_not_real_repo "$self_repo"
git -C "$self_repo" config user.email "test@example.com"
git -C "$self_repo" config user.name "Test"
self_hooks="$self_repo/.git-hooks-copy"
mkdir -p "$self_hooks"
cp -p "$HERE/pre-push" "$HERE/desk-denylist-check.sh" "$self_hooks/"
git -C "$self_repo" config core.hooksPath "$self_hooks"
git -C "$self_repo" remote add origin "$self_bare"

self_remote_main_sha() { git -C "$self_bare" rev-parse --verify -q main 2> /dev/null || echo "(none)"; }

echo "=== self repo, no desk.denylist configured: refuses (fails closed), remote untouched ==="
commit "$self_repo" "first commit" "hello world"
out="$(git -C "$self_repo" push origin main 2>&1)"
status=$?
[ "$status" -ne 0 ] && ok "push is refused" || bad "push was NOT refused (exited 0)"
printf '%s\n' "$out" | grep -q "desk.denylist is not set" \
	&& ok "prints the not-set refusal" || bad "missing not-set refusal (got: $out)"
printf '%s\n' "$out" | grep -q "git config desk.denylist" \
	&& ok "says how to set it" || bad "doesn't say how to set it (got: $out)"
printf '%s\n' "$out" | grep -q "desk.denylist none" \
	&& ok "says how to opt out explicitly" || bad "doesn't say how to opt out (got: $out)"
assert_eq "remote main was never created" "(none)" "$(self_remote_main_sha)"

echo
echo "=== self repo, desk.denylist explicitly set to 'none': opts out, push goes through ==="
git -C "$self_repo" config desk.denylist none
out="$(git -C "$self_repo" push origin main 2>&1)"
status=$?
assert_eq "push exits 0" "0" "$status"
printf '%s\n' "$out" | grep -q "opted out" && ok "prints the opted-out status line" \
	|| bad "missing opted-out status line (got: $out)"
assert_eq "remote main advanced" "$(git -C "$self_repo" rev-parse main)" "$(self_remote_main_sha)"
git -C "$self_repo" config --unset desk.denylist

echo
echo "=== self repo, desk.denylist set, no pattern matches: push goes through ==="
self_deny="$TMP/self-denylist.txt"
printf 'invented-secret-marker\n' > "$self_deny"
git -C "$self_repo" config desk.denylist "$self_deny"
commit "$self_repo" "second commit" "nothing interesting here"
out="$(git -C "$self_repo" push origin main 2>&1)"
status=$?
assert_eq "push exits 0 with a non-matching denylist" "0" "$status"
assert_eq "remote main advanced again" "$(git -C "$self_repo" rev-parse main)" "$(self_remote_main_sha)"

echo
echo "=== self repo, a matching pattern in a new commit refuses the push ==="
before_sha="$(self_remote_main_sha)"
commit "$self_repo" "leaky commit" "this line names invented-secret-marker in the clear"
out="$(git -C "$self_repo" push origin main 2>&1)"
status=$?
[ "$status" -ne 0 ] && ok "push is refused" || bad "push was NOT refused (exited 0)"
printf '%s\n' "$out" | grep -q "invented-secret-marker" \
	&& ok "refusal names the matched pattern" || bad "refusal message missing the pattern (got: $out)"
assert_eq "remote main did NOT advance" "$before_sha" "$(self_remote_main_sha)"
git -C "$self_repo" reset -q --hard HEAD~1

echo
echo "=== self repo, a matching pattern in the commit MESSAGE also refuses ==="
before_sha="$(self_remote_main_sha)"
printf 'clean content\n' >> "$self_repo/file.txt"
git -C "$self_repo" add file.txt
git -C "$self_repo" commit -q -m "mentions invented-secret-marker in its own subject"
out="$(git -C "$self_repo" push origin main 2>&1)"
status=$?
[ "$status" -ne 0 ] && ok "push is refused on a message-only match" || bad "push was NOT refused (exited 0)"
assert_eq "remote main did NOT advance" "$before_sha" "$(self_remote_main_sha)"
git -C "$self_repo" reset -q --hard HEAD~1

echo
echo "=== self repo, case-insensitive by default ==="
before_sha="$(self_remote_main_sha)"
commit "$self_repo" "mixed case" "INVENTED-SECRET-MARKER in caps"
out="$(git -C "$self_repo" push origin main 2>&1)"
status=$?
[ "$status" -ne 0 ] && ok "a different-case match is still refused (case-insensitive default)" \
	|| bad "different-case match was NOT refused"
assert_eq "remote main did NOT advance" "$before_sha" "$(self_remote_main_sha)"
git -C "$self_repo" reset -q --hard HEAD~1

echo
echo "=== self repo, (?-i) marker: case-sensitive from that point on ==="
printf 'invented-secret-marker\n(?-i)CaseSensitiveMarker\n' > "$self_deny"
before_sha="$(self_remote_main_sha)"
commit "$self_repo" "wrong case for the sensitive marker" "casesensitivemarker, lowercase"
out="$(git -C "$self_repo" push origin main 2>&1)"
status=$?
assert_eq "a lowercase mismatch against a (?-i) pattern is NOT refused" "0" "$status"
assert_eq "remote main advanced" "$(git -C "$self_repo" rev-parse main)" "$(self_remote_main_sha)"

before_sha="$(self_remote_main_sha)"
commit "$self_repo" "exact case for the sensitive marker" "CaseSensitiveMarker, exact case"
out="$(git -C "$self_repo" push origin main 2>&1)"
status=$?
[ "$status" -ne 0 ] && ok "an exact-case match against a (?-i) pattern IS refused" \
	|| bad "exact-case match was NOT refused"
assert_eq "remote main did NOT advance" "$before_sha" "$(self_remote_main_sha)"
git -C "$self_repo" reset -q --hard HEAD~1

echo
echo "=== self repo, desk.denylist set to a missing file: fails closed ==="
git -C "$self_repo" config desk.denylist "$TMP/does-not-exist.txt"
commit "$self_repo" "innocuous commit" "nothing to see here"
out="$(git -C "$self_repo" push origin main 2>&1)"
status=$?
[ "$status" -ne 0 ] && ok "a missing denylist file refuses the push" || bad "missing file did NOT refuse the push"
printf '%s\n' "$out" | grep -q "doesn't exist" && ok "refusal explains the file is missing" \
	|| bad "refusal doesn't explain the missing file (got: $out)"
git -C "$self_repo" reset -q --hard HEAD~1
git -C "$self_repo" config --unset desk.denylist

echo
echo "=== self repo, a brand-new branch (no remote tip) falls back to origin/main..<ref> ==="
printf 'invented-secret-marker\n' > "$self_deny"
git -C "$self_repo" config desk.denylist "$self_deny"
git -C "$self_repo" checkout -q -b feature
commit "$self_repo" "feature commit with a match" "leaky invented-secret-marker again"
out="$(git -C "$self_repo" push origin feature 2>&1)"
status=$?
[ "$status" -ne 0 ] && ok "a new branch's match is still caught via the origin/main fallback" \
	|| bad "new-branch fallback did NOT catch the match"
git -C "$self_bare" show-ref --verify -q refs/heads/feature \
	&& bad "the new branch was pushed anyway" || ok "the new branch was never created on the remote"

git -C "$self_repo" reset -q --hard HEAD~1
out="$(git -C "$self_repo" push origin feature 2>&1)"
status=$?
assert_eq "a clean new branch still pushes fine" "0" "$status"
git -C "$self_bare" show-ref --verify -q refs/heads/feature && ok "the clean new branch landed on the remote" \
	|| bad "the clean new branch never landed"
git -C "$self_repo" config --unset desk.denylist

# =============================================================================
# "other" repo: an unrelated throwaway repo whose core.hooksPath points at
# THIS repo's real git-hooks dir (modelling the global hooksPath setting) —
# the denylist check must never fire, no matter what desk.denylist says.
# =============================================================================

other_bare="$TMP/other-origin.git"
desk_test_assert_repo_under_root "$other_bare" "$TMP"
git init -q --bare "$other_bare"
other_bare_gitdir="$(git -C "$other_bare" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [ "$other_bare_gitdir" = "$REAL_TOPLEVEL/.git" ]; then
	echo "ABORT: '$other_bare' resolves to this repo's .git instead of a throwaway one — refusing to continue" >&2
	exit 1
fi

other_repo="$TMP/other-repo"
desk_test_assert_repo_under_root "$other_repo" "$TMP"
git init -q -b main "$other_repo"
desk_test_guard_not_real_repo "$other_repo"
git -C "$other_repo" config user.email "test@example.com"
git -C "$other_repo" config user.name "Test"
git -C "$other_repo" config core.hooksPath "$HERE"
git -C "$other_repo" remote add origin "$other_bare"

other_remote_main_sha() { git -C "$other_bare" rev-parse --verify -q main 2> /dev/null || echo "(none)"; }

echo
echo "=== other repo, no desk.denylist configured at all: push goes through untouched ==="
commit "$other_repo" "first commit" "hello world"
out="$(git -C "$other_repo" push origin main 2>&1)"
status=$?
assert_eq "push exits 0 with no denylist configured for this repo" "0" "$status"
assert_eq "remote main advanced" "$(git -C "$other_repo" rev-parse main)" "$(other_remote_main_sha)"
printf '%s\n' "$out" | grep -q "denylist" && bad "denylist check ran for another repo (got: $out)" \
	|| ok "the denylist check never ran (no mention of it in the output)"

echo
echo "=== other repo, desk.denylist set to a MATCHING pattern: still passes through (never enforced here) ==="
other_deny="$TMP/other-denylist.txt"
printf 'invented-secret-marker\n' > "$other_deny"
git -C "$other_repo" config desk.denylist "$other_deny"
commit "$other_repo" "leaky-looking commit" "this line names invented-secret-marker in the clear"
out="$(git -C "$other_repo" push origin main 2>&1)"
status=$?
assert_eq "push exits 0 even though the pattern would match" "0" "$status"
assert_eq "remote main advanced" "$(git -C "$other_repo" rev-parse main)" "$(other_remote_main_sha)"
git -C "$other_repo" config --unset desk.denylist

echo
echo "=== a brand-new branch in a repo with no origin/main yet must not break ==="
fresh_bare="$TMP/fresh-origin.git"
desk_test_assert_repo_under_root "$fresh_bare" "$TMP"
git init -q --bare "$fresh_bare"
fresh_bare_gitdir="$(git -C "$fresh_bare" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [ "$fresh_bare_gitdir" = "$REAL_TOPLEVEL/.git" ]; then
	echo "ABORT: '$fresh_bare' resolves to this repo's .git instead of a throwaway one — refusing to continue" >&2
	exit 1
fi

fresh_repo="$TMP/fresh-repo"
desk_test_assert_repo_under_root "$fresh_repo" "$TMP"
git init -q -b main "$fresh_repo"
desk_test_guard_not_real_repo "$fresh_repo"
git -C "$fresh_repo" config user.email "test@example.com"
git -C "$fresh_repo" config user.name "Test"
git -C "$fresh_repo" config core.hooksPath "$HERE"
git -C "$fresh_repo" remote add origin "$fresh_bare"
git -C "$fresh_repo" checkout -q -b feature
commit "$fresh_repo" "feature's first commit" "hello from a brand-new branch"
# main was NEVER pushed here — no origin/main exists locally or on the
# remote at all. desk-denylist-check.sh's own hook-form would error
# resolving that fallback if it ran; it must not run here.
out="$(git -C "$fresh_repo" push origin feature 2>&1)"
status=$?
assert_eq "the push succeeds with no origin/main anywhere" "0" "$status"
git -C "$fresh_bare" show-ref --verify -q refs/heads/feature && ok "the new branch landed on the remote" \
	|| bad "the new branch never landed (got: $out)"

echo
echo "=== CLI form: <repo> <range> <list-file> — no git config, no stdin, no hook routing ==="
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
