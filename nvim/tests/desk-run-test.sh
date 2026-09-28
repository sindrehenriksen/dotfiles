#!/usr/bin/env bash
# D8 test: `claude/desk-run` against from-scratch fixtures — a throwaway
# notes repo, a local BARE remote standing in for the real one (never the
# real remote), and a fake `claude` on PATH that behaves however each case
# needs (hangs, fails, or succeeds) without ever making a real model call.
# Covers every design.md §10 D8 done-check case: a slept-through slot, an
# offline slot, a rejected push, a dead lock owner, HEAD off main / mid-
# rebase; and that desk-run never pulls, forces, or writes the working
# file. The one live call (the canary) is its own script,
# desk-run-canary.sh, kept separate so this suite never spends API budget.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESK_RUN="$HERE/../../claude/desk-run"

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	printf 'ok   - %s\n' "$1"
}
bad() {
	fail=$((fail + 1))
	printf 'FAIL - %s\n' "$1"
}
assert_eq() {
	local desc=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then
		ok "$desc"
	else
		bad "$desc (expected [$expected], got [$actual])"
	fi
}
assert_true() {
	local desc=$1 cond=$2
	if [ "$cond" = "true" ]; then
		ok "$desc"
	else
		bad "$desc (got [$cond])"
	fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'FAKE'
#!/usr/bin/env bash
# Fake claude for desk-run tests: behavior driven entirely by env vars, so
# a test never needs a real model call. $FAKE_CLAUDE_MODE selects it.
# The project-folder name it simulates matches desk_project_folder_name's
# own canonicalize-then-sanitize logic exactly (verified live against a
# real call — see the D8 canary and model-call.sh's own comment) so the
# "tool-result spill is cleaned up" case below is a real regression guard
# on that function, not just on this fake agreeing with itself.
_desk_test_cwd="$(pwd -P)"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$_desk_test_cwd" | tr -c 'A-Za-z0-9' '-')"
case "${FAKE_CLAUDE_MODE:-ok}" in
	hang)
		trap '' TERM
		sleep 600 &
		wait
		;;
	fail)
		echo '{"type":"result","subtype":"error"}'
		exit 1
		;;
	*)
		echo '{"type":"result","subtype":"success"}'
		exit 0
		;;
esac
FAKE
chmod +x "$FAKEBIN/claude"

export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN=claude

# Every desk-run state directory lives under this run's own tmp root —
# never ~/.local/state/desk.
STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export DESK_LOCK_MAX_WAIT_SECS=2
export DESK_LOCK_POLL_SECS=1
export DESK_KILL_GRACE_SECS=2

# --- fixture builders -------------------------------------------------------

# A fresh notes repo (notes.md/reading.md, HEAD=main) plus a local bare
# remote wired as its "origin" — the only remote desk-run ever pushes to
# in this suite.
new_notes_repo() {
	local dir="$1"
	local repo="$dir/notes"
	local remote="$dir/remote.git"
	desk_test_assert_repo_under_root "$dir" "$ROOT"
	git init -q --bare "$remote"
	mkdir -p "$repo"
	git -C "$repo" init -q
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config user.name "Desk Test"
	printf 'Section A\n  detail\n' > "$repo/notes.md"
	: > "$repo/reading.md"
	git -C "$repo" add notes.md reading.md
	git -C "$repo" commit -q -m initial
	git -C "$repo" branch -M main
	git -C "$repo" remote add origin "$remote"
	git -C "$repo" push -q origin main
	echo "$repo"
}

# A config with just a commit_push step (isolates the git behavior from
# any model call). push_enabled: true — several cases below exist
# specifically to exercise the push itself (a rejected push, never
# fetching/pulling); push_enabled's own default-false behavior is covered
# separately, in desk-push-test.sh.
write_commit_push_config() {
	local path="$1" repo="$2"
	jq -n --arg repo "$repo" '{
		notes_repo: $repo,
		push_enabled: true,
		files: ["notes.md", "reading.md"],
		passes: { testpass: { steps: [ { id: "commit-push", kind: "commit_push" } ] } }
	}' > "$path"
}

# A config with a commit_push step, then one fetch step (so a hang/failure
# in the model call is what the pass stops on).
write_fetch_config() {
	local path="$1" repo="$2" timeout="$3"
	local prompt="$ROOT/prompt.md"
	echo "a generic test prompt" > "$prompt"
	jq -n --arg repo "$repo" --arg prompt "$prompt" --argjson timeout "$timeout" '{
		notes_repo: $repo,
		push_enabled: true,
		files: ["notes.md", "reading.md"],
		passes: { testpass: { steps: [
			{ id: "commit-push", kind: "commit_push" },
			{ id: "F-test", kind: "fetch", prompt: $prompt, tools: ["Read"], connector: false, timeout: $timeout }
		] } }
	}' > "$path"
}

run_desk() {
	DESK_CONFIG="$1" "$DESK_RUN" "${2:-testpass}"
}

# ---------------------------------------------------------------------------

echo "=== a slept-through slot: a pass already ok today is a no-op ==="
rm -rf "$STATE"
repo="$(new_notes_repo "$ROOT/case1")"
cfg="$ROOT/case1/config.json"
write_commit_push_config "$cfg" "$repo"
run_desk "$cfg" > "$ROOT/case1.out" 2>&1
first_rc=$?
head_before="$(git -C "$repo" rev-parse HEAD)"
assert_eq "first run of the day exits ok" "0" "$first_rc"
run_desk "$cfg" > "$ROOT/case1b.out" 2>&1
second_rc=$?
assert_eq "a later slot the same day exits ok too (no-op)" "0" "$second_rc"
assert_true "the later slot never re-ran the pass" \
	"$([ "$(grep -c 'already ok today' "$ROOT/case1b.out")" -ge 1 ] && echo true || echo false)"
head_after="$(git -C "$repo" rev-parse HEAD)"
assert_eq "HEAD didn't move on the no-op slot" "$head_before" "$head_after"

echo
echo "=== an offline slot: a hung model call is killed at its timeout, flagged partial (a source failure never aborts the pass) ==="
rm -rf "$STATE"
repo="$(new_notes_repo "$ROOT/case2")"
cfg="$ROOT/case2/config.json"
write_fetch_config "$cfg" "$repo" 2
export FAKE_CLAUDE_MODE=hang
t0=$(date +%s)
run_desk "$cfg" > "$ROOT/case2.out" 2>&1
rc=$?
t1=$(date +%s)
unset FAKE_CLAUDE_MODE
assert_eq "a source (fetch) failure alone is never fatal to desk-run's own exit code" "0" "$rc"
elapsed=$((t1 - t0))
assert_true "it was killed near its timeout, not left hanging (elapsed ${elapsed}s)" \
	"$([ "$elapsed" -lt 30 ] && echo true || echo false)"
status_result="$(jq -r '.passes.testpass.result' "$DESK_STATUS_FILE")"
failed_sources="$(jq -c '.passes.testpass.failed_sources' "$DESK_STATUS_FILE")"
assert_eq "status shows the pass partial (not failed — a source failure alone never fails the pass)" "partial" "$status_result"
assert_eq "the failed source is named in failed_sources" '["F-test"]' "$failed_sources"

echo
echo "=== a rejected push: recorded, not retried, and doesn't crash the pass ==="
rm -rf "$STATE"
repo="$(new_notes_repo "$ROOT/case3")"
cfg="$ROOT/case3/config.json"
write_commit_push_config "$cfg" "$repo"
# Make a real change so there's something to commit, then diverge the
# remote so the push is rejected (non-fast-forward) — never touched via
# pull/fetch by desk-run itself.
printf 'Section A\n  detail\n  a change only he could have made\n' > "$repo/notes.md"
clone="$ROOT/case3/other-clone"
git clone -q "$ROOT/case3/remote.git" "$clone"
git -C "$clone" config user.email test@example.invalid
git -C "$clone" config user.name "Other Writer"
echo "someone else's commit" >> "$clone/notes.md"
git -C "$clone" commit -q -am "a divergent commit"
git -C "$clone" push -q origin main
run_desk "$cfg" > "$ROOT/case3.out" 2>&1
rc=$?
assert_eq "a rejected push doesn't fail the pass" "0" "$rc"
push_status="$(jq -r '.push' "$DESK_STATUS_FILE")"
assert_eq "status.push records the rejection" "failed" "$push_status"
assert_eq "local HEAD still has his committed text (not reset, not merged)" "1" \
	"$(git -C "$repo" show HEAD:notes.md | grep -c 'a change only he could have made')"
assert_eq "desk-run never fetched/pulled — no FETCH_HEAD written" "1" \
	"$([ ! -e "$repo/.git/FETCH_HEAD" ] && echo 1 || echo 0)"

echo
echo "=== a dead lock owner: broken immediately, the run proceeds ==="
rm -rf "$STATE"
repo="$(new_notes_repo "$ROOT/case4")"
cfg="$ROOT/case4/config.json"
write_commit_push_config "$cfg" "$repo"
mkdir -p "$STATE/lock"
# The lock is a single one shared across every pass (lock.sh's own
# DESK_LOCK_NAME), never named after this test's own "testpass".
mkdir -p "$STATE/lock/runner.lock"
dead_pid=$((70000 + RANDOM % 5000))
while kill -0 "$dead_pid" 2> /dev/null; do dead_pid=$((dead_pid + 1)); done
jq -n --argjson pid "$dead_pid" --argjson t 1 '{pid: $pid, started_at: $t}' \
	> "$STATE/lock/runner.lock/meta.json"
t0=$(date +%s)
run_desk "$cfg" > "$ROOT/case4.out" 2>&1
rc=$?
t1=$(date +%s)
assert_eq "the run succeeds despite the stale lock" "0" "$rc"
assert_true "it broke the dead lock rather than waiting out DESK_LOCK_MAX_WAIT_SECS" \
	"$([ $((t1 - t0)) -lt "$DESK_LOCK_MAX_WAIT_SECS" ] && echo true || echo false)"
assert_true "the lock is released again afterward" "$([ ! -d "$STATE/lock/runner.lock" ] && echo true || echo false)"

echo
echo "=== HEAD off main: the commit is skipped and reported, not attempted ==="
rm -rf "$STATE"
repo="$(new_notes_repo "$ROOT/case5")"
cfg="$ROOT/case5/config.json"
write_commit_push_config "$cfg" "$repo"
git -C "$repo" checkout -qb a-side-branch
printf 'Section A\n  detail\n  an edit while off main\n' > "$repo/notes.md"
head_before="$(git -C "$repo" rev-parse HEAD)"
run_desk "$cfg" > "$ROOT/case5.out" 2>&1
rc=$?
head_after="$(git -C "$repo" rev-parse HEAD)"
assert_eq "the run still exits ok (a skip, not a failure)" "0" "$rc"
assert_eq "HEAD never moved (no commit was made)" "$head_before" "$head_after"
assert_true "it says why in the log" \
	"$([ "$(grep -c 'skipped: HEAD is not main' "$ROOT/case5.out")" -ge 1 ] && echo true || echo false)"
current_branch="$(git -C "$repo" symbolic-ref --short HEAD)"
assert_eq "desk-run never switched the branch back itself" "a-side-branch" "$current_branch"

echo
echo "=== mid-rebase: the commit is skipped and reported ==="
rm -rf "$STATE"
repo="$(new_notes_repo "$ROOT/case6")"
cfg="$ROOT/case6/config.json"
write_commit_push_config "$cfg" "$repo"
git -C "$repo" checkout -q main
mkdir -p "$repo/.git/rebase-merge"
head_before="$(git -C "$repo" rev-parse HEAD)"
run_desk "$cfg" > "$ROOT/case6.out" 2>&1
rc=$?
head_after="$(git -C "$repo" rev-parse HEAD)"
assert_eq "the run still exits ok" "0" "$rc"
assert_eq "HEAD never moved" "$head_before" "$head_after"
assert_true "it says a rebase is in progress" \
	"$([ "$(grep -c 'a rebase is in progress' "$ROOT/case6.out")" -ge 1 ] && echo true || echo false)"

echo
echo "=== never writes the working file, whatever else happens ==="
rm -rf "$STATE"
repo="$(new_notes_repo "$ROOT/case7")"
cfg="$ROOT/case7/config.json"
write_commit_push_config "$cfg" "$repo"
# Seed a pending (laid-in) item so his-text has something to revert in the
# INDEX only — the working file must read exactly as it does right now,
# untouched, before and after.
CLI="$HERE/../lua/desk/cli.lua"
cat > "$ROOT/case7-recs.ndjson" <<EOF
{"type":"item","id":"p1","file":"notes.md","kind":"add","anchor":{"under":"Section A"},"before":"","after":"  a laid-in suggestion","source":"test","headline":"h","pass":"morning","proposed_at":1}
{"type":"round","file":"notes.md","at":1,"text":["Section A","  detail","  a laid-in suggestion"],"items":{"p1":{"kind":"add","ranges":[{"line":3,"count":1,"role":"edit"}]}}}
{"type":"laid_in","at":1,"proposal":"x","items":["p1"]}
EOF
nvim -l "$CLI" ledger-append-batch "$repo" "$ROOT/case7-recs.ndjson" > /dev/null
# His own new line, alongside the pending suggestion — so there's something
# genuinely his to commit once the suggestion alone is reverted back out.
# The suggestion has to sit exactly at its own anchor (right after
# "  detail", per {"under": "Section A"}) for the revert to find it there;
# his own line goes after it, never between the anchor and the suggestion.
printf 'Section A\n  detail\n  a laid-in suggestion\n  his own new line\n' > "$repo/notes.md"
worktree_before="$(cat "$repo/notes.md")"
run_desk "$cfg" > "$ROOT/case7.out" 2>&1
worktree_after="$(cat "$repo/notes.md")"
assert_eq "the working file's content is byte-for-byte unchanged" "$worktree_before" "$worktree_after"
index_content="$(git -C "$repo" show :notes.md)"
assert_true "but the INDEX no longer has the pending suggestion (reverted there instead)" \
	"$(printf '%s' "$index_content" | grep -q 'a laid-in suggestion' && echo false || echo true)"
assert_true "the INDEX does have his own new line" \
	"$(printf '%s' "$index_content" | grep -q 'his own new line' && echo true || echo false)"
assert_true "the pass committed his text (a real commit happened)" \
	"$([ "$(git -C "$repo" rev-list --count HEAD)" -gt 1 ] && echo true || echo false)"
assert_true "HEAD's own committed content also excludes the still-pending suggestion" \
	"$(git -C "$repo" show HEAD:notes.md | grep -q 'a laid-in suggestion' && echo false || echo true)"

echo
echo "=== the config dir's project folder (tool-result spill) is cleaned up ==="
rm -rf "$STATE"
repo="$(new_notes_repo "$ROOT/case9")"
cfg="$ROOT/case9/config.json"
write_fetch_config "$cfg" "$repo" 10
rm -rf "$ROOT/case9-claude-config"
export CLAUDE_CONFIG_DIR="$ROOT/case9-claude-config"
run_desk "$cfg" > "$ROOT/case9.out" 2>&1
rc=$?
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
assert_eq "the run succeeds" "0" "$rc"
project_dirs="$(find "$ROOT/case9-claude-config/projects" -mindepth 1 -maxdepth 1 2> /dev/null | wc -l | tr -d ' ')"
assert_eq "no project folder is left behind after the call" "0" "$project_dirs"

echo
echo "=== a later slot retries a partial pass (the guard only skips an 'ok' one) ==="
rm -rf "$STATE"
repo="$(new_notes_repo "$ROOT/case8")"
cfg="$ROOT/case8/config.json"
write_fetch_config "$cfg" "$repo" 2
export FAKE_CLAUDE_MODE=hang
run_desk "$cfg" > "$ROOT/case8a.out" 2>&1
unset FAKE_CLAUDE_MODE
assert_eq "the first (source-failing) slot is recorded as partial" "partial" \
	"$(jq -r '.passes.testpass.result' "$DESK_STATUS_FILE")"
run_desk "$cfg" > "$ROOT/case8b.out" 2>&1
rc=$?
assert_eq "a later slot the same day actually retries (succeeds this time)" "0" "$rc"
assert_eq "status now shows ok" "ok" "$(jq -r '.passes.testpass.result' "$DESK_STATUS_FILE")"
assert_true "the later slot did not treat it as already-done" \
	"$([ "$(grep -c 'already ok today' "$ROOT/case8b.out")" -eq 0 ] && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
