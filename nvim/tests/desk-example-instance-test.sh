#!/usr/bin/env bash
# The example instance in claude/desk-example/ is what a new instance gets
# copied from, so it has to keep working against the runner as the runner
# changes: every pass in its config runs through the real claude/desk-run,
# offline. A fake `claude` stands in for every model call and records what
# it was handed; the reader, the tab helper and the session recorder's store
# are all fakes or throwaway paths, and HOME itself points into the temp
# root, so the config's own `~/...` paths never reach real state.
#
# Checked: each pass finishes ok; every rendered prompt is non-empty and has
# no `{{placeholder}}` the runner left unfilled; the judge's cwd holds every
# file its `input_files` names; the weekly tab gets its notes-diff; and the
# plist's schedule matches the config's `trigger` mirror of it.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DESK_RUN="$REPO/claude/desk-run"
EXAMPLE="$REPO/claude/desk-example"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	local desc=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then ok "$desc"; else bad "$desc (expected [$expected], got [$actual])"; fi
}
assert_true() {
	local desc=$1 cond=$2
	if [ "$cond" = "true" ]; then ok "$desc"; else bad "$desc (got [$cond])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"

FAKE_HOME="$ROOT/home"
mkdir -p "$FAKE_HOME"
CALLS="$ROOT/calls"
mkdir -p "$CALLS"
TABS_LOG="$ROOT/tabs.log"
: > "$TABS_LOG"

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" << FAKE
#!/usr/bin/env bash
CALLS="$CALLS"
FAKE
cat >> "$FAKEBIN/claude" << 'FAKE'
n="$(find "$CALLS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
rec="$CALLS/$n"
mkdir -p "$rec"
pwd -P > "$rec/cwd"
ls -1 > "$rec/files"
cp prompt.txt "$rec/prompt.txt" 2> /dev/null
if [ -f open-items.json ]; then
	reply='{"items":[{"id":"w1","file":"notes.md","kind":"new","target":"top","before":"","after":"an example suggestion","source":"notes","headline":"example"}]}'
else
	reply='{"items":[]}'
fi
jq -nc --arg t "$reply" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'
echo '{"type":"result","subtype":"success","total_cost_usd":0}'
FAKE
chmod +x "$FAKEBIN/claude"

# One session, unrecorded and named in the notes with a
# transcript 25 days old, inside the retention margin under the default
# 30-day cleanup: the retention step makes its one call. The follow-up tab
# resolves nothing, an ordinary "ok".
OLD_TRANSCRIPT="$FAKE_HOME/.claude/projects/-example/0e0e0e0e-0000-0000-0000-000000000000.jsonl"
mkdir -p "$(dirname "$OLD_TRANSCRIPT")"
printf '%s\n' '{"uuid":"0e0e0e0e-1111","type":"user","message":{"role":"user","content":"hi"}}' > "$OLD_TRANSCRIPT"
perl -e 'utime(time - 25 * 86400, time - 25 * 86400, $ARGV[0]) or die' "$OLD_TRANSCRIPT"
cat > "$FAKEBIN/session-status.sh" << FAKE
#!/usr/bin/env bash
[ "\${1:-}" = "resolve" ] && { echo '[]'; exit 1; }
jq -cn --arg tp "$OLD_TRANSCRIPT" '{id:"0e0e0e0e-0000-0000-0000-000000000000", name:"example-session", name_source:"user", live:false, status:"unknown", has_start_event:false, ended:false, end_reason:null, transcript_path:\$tp}'
FAKE
chmod +x "$FAKEBIN/session-status.sh"

cat > "$FAKEBIN/open-tab" << FAKE
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "\$1" "\${2:-}" "\${3:-}" >> "$TABS_LOG"
FAKE
chmod +x "$FAKEBIN/open-tab"

export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN="$FAKEBIN/claude"
export DESK_OPEN_TAB_BIN="$FAKEBIN/open-tab"
export DESK_FOCUS_TAB_BIN="$FAKEBIN/open-tab"
export DESK_LOCK_MAX_WAIT_SECS=2
export DESK_LOCK_POLL_SECS=1
# Everything below derives from HOME (or DESK_STATE_DIR, which defaults
# under it) once HOME is the fake one; these are unset so an outer
# runner's safe defaults don't point a pass somewhere else instead.
unset DESK_STATE_DIR DESK_STATUS_FILE DESK_TICKET_CACHE DESK_LOCK_ROOT DESK_GUARD_ROOT \
	DESK_SCRATCH_ROOT DESK_LOG_DIR DESK_RUNS_ROOT DESK_FETCH_CACHE_ROOT DESK_BRIEF_DIR \
	CLAUDE_SESSION_STORE CLAUDE_SESSION_RECORDER_LOG
export CLAUDE_CONFIG_DIR="$FAKE_HOME/.claude"

# The config's own `notes_repo`, under the fake HOME.
notes="$FAKE_HOME/notes"
desk_test_assert_repo_under_root "$notes" "$ROOT"
mkdir -p "$notes"
git -C "$notes" init -q
printf 'Inbox\n  something to sort\n- example-session: the thing it was for\n' > "$notes/notes.md"
printf 'To read\n' > "$notes/reading.md"
: > "$notes/.desk-notes"
git -C "$notes" add notes.md reading.md .desk-notes
git -C "$notes" commit -q -m initial
git -C "$notes" branch -M main

# A copy with weekdays_only and same_day_only switched off, so the model
# steps run whatever day and hour the test runs at. The pass
# names are prefixed only to show nothing depends on them; every step,
# prompt and relative path is the example's own.
INSTANCE="$ROOT/instance"
cp -R "$EXAMPLE" "$INSTANCE"
jq '.passes |= with_entries(.key = "example-" + .key | .value.weekdays_only = false | del(.value.trigger.same_day_only))' "$EXAMPLE/config.json" > "$INSTANCE/config.json"
export DESK_CONFIG="$INSTANCE/config.json"

echo "=== every step names a prompt file that exists ==="
while IFS=$'\t' read -r step prompt; do
	assert_true "$step: $prompt exists" "$([ -f "$EXAMPLE/$prompt" ] && echo true || echo false)"
done < <(jq -r '.passes[].steps[] | select(.prompt) | [.id, .prompt] | @tsv' "$EXAMPLE/config.json")
assert_true "the sources file exists" \
	"$([ -f "$EXAMPLE/$(jq -r '.sources_file' "$EXAMPLE/config.json")" ] && echo true || echo false)"

for p in $(jq -r '.passes | keys[]' "$EXAMPLE/config.json"); do
	echo
	echo "=== pass $p ==="
	out="$(HOME="$FAKE_HOME" "$DESK_RUN" "example-$p" 2>&1)"
	rc=$?
	assert_eq "$p: desk-run exits 0" "0" "$rc"
	assert_true "$p: no unknown step kind" "$(grep -q 'unknown step kind' <<< "$out" && echo false || echo true)"
	assert_true "$p: finished ok" "$(grep -q 'done: ok' <<< "$out" && echo true || echo false)"
	[ "$rc" -eq 0 ] || sed 's/^/    /' <<< "$out"
done

echo
echo "=== rendered prompts ==="
n_calls="$(find "$CALLS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
assert_eq "one model call per model step (F-web, J, one retention call)" "3" "$n_calls"
for rec in "$CALLS"/*; do
	[ -d "$rec" ] || continue
	assert_true "call $(basename "$rec"): prompt is non-empty" "$([ -s "$rec/prompt.txt" ] && echo true || echo false)"
	left="$(grep -oE '\{\{[A-Za-z0-9_]+\}\}' "$rec/prompt.txt" | sort -u | tr '\n' ' ')"
	assert_eq "call $(basename "$rec"): every placeholder filled" "" "$left"
done

echo
echo "=== the judge's inputs ==="
judge_rec=""
for rec in "$CALLS"/*; do
	grep -qx 'open-items.json' "$rec/files" 2> /dev/null && judge_rec="$rec"
done
assert_true "a judge call ran" "$([ -n "$judge_rec" ] && echo true || echo false)"
while IFS= read -r f; do
	assert_true "judge cwd holds $f" "$(grep -qxF "$f" "$judge_rec/files" 2> /dev/null && echo true || echo false)"
done < <(jq -r '.passes.morning.steps[] | select(.kind == "judge") | .input_files[]' "$EXAMPLE/config.json")
proposal="$(git -C "$notes" show refs/desk/proposal:proposal.json 2> /dev/null)"
assert_true "the judge's item reached the proposal" \
	"$(jq -e '.items[] | select(.id | endswith("-w1"))' > /dev/null 2>&1 <<< "$proposal" && echo true || echo false)"
assert_eq "push_enabled is false, so nothing was pushed" "disabled" "$(jq -r '.push' "$FAKE_HOME/.local/state/desk/status.json")"

echo
echo "=== the weekly tab ==="
# Two tabs: the morning pass's follow-up, a status session here since the
# fake reader resolves no session, and the weekly one.
assert_eq "two tabs were asked for" "2" "$(wc -l < "$TABS_LOG" | tr -d ' ')"
assert_true "the morning follow-up is an interactive status session" \
	"$(grep -q "^DESK_HEADLESS=1 claude -n 'desk-example-morning-[0-9-]*-status'" "$TABS_LOG" && echo true || echo false)"
tab_cmd="$(grep -F weekly-review "$TABS_LOG" | cut -f1)"
tab_cwd="$(grep -F weekly-review "$TABS_LOG" | cut -f3)"
assert_true "it opens claude named weekly-review" \
	"$(grep -qF "'-n' 'weekly-review'" <<< "$tab_cmd" && echo true || echo false)"
assert_true "its cwd is a fresh dir under scratch_dir" \
	"$([[ "$tab_cwd" == "$FAKE_HOME/.local/state/desk/weekly/"* ]] && echo true || echo false)"
assert_true "the notes-diff is waiting there" "$([ -s "$tab_cwd/notes-diff.md" ] && echo true || echo false)"

echo
echo "=== the plist mirrors the morning trigger ==="
if command -v plutil > /dev/null 2>&1; then
	plist="$EXAMPLE/com.local.desk.morning.plist"
	assert_true "plutil -lint accepts it" "$(plutil -lint "$plist" > /dev/null 2>&1 && echo true || echo false)"
	from_plist="$(plutil -convert json -o - "$plist" | jq -c '[.StartCalendarInterval[] | {hour: .Hour, minute: .Minute} + (if .Weekday then {weekday: .Weekday} else {} end)]')"
	from_config="$(jq -c '.passes.morning.trigger.start_calendar_interval' "$EXAMPLE/config.json")"
	assert_eq "StartCalendarInterval equals trigger.start_calendar_interval" "$from_config" "$from_plist"
	assert_eq "it runs at load, so a login catches up a morning missed while off" "true" \
		"$(plutil -convert json -o - "$plist" | jq -r '.RunAtLoad')"
else
	echo "skipped: no plutil on this machine"
fi

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
