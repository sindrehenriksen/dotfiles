#!/usr/bin/env bash
# The runner takes what used to be hardcoded names from the config:
#   - a fetch step's reply is seeded as <its id, lowercased>.json for any id;
#   - a pass's `weekdays_only` decides the weekend skip, whatever its name;
#   - a pass's `caps` picks which top-level caps entry its judge uses;
#   - the config's `files` are the notes files (any names), and
#     `captures_file` is where session captures land;
#   - the tab-helper env var accepts both of its names.
# The weekend skip follows the slot's scheduled date, not the run date: a
# Saturday slot is skipped and a Friday 16:30 slot that fires on Saturday's
# wake still runs. The run date is faked as a Saturday through a `date`
# wrapper, so neither case depends on when the test runs.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESK_RUN="$HERE/../../claude/desk-run"

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
CALLS="$ROOT/calls"
TABS_LOG="$ROOT/tabs.log"
mkdir -p "$FAKE_HOME" "$CALLS"
: > "$TABS_LOG"

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
REAL_DATE="$(command -v date)"
cat > "$FAKEBIN/date" << FAKE
#!/usr/bin/env bash
if [ "\$*" = "+%u" ]; then echo 6; else exec "$REAL_DATE" "\$@"; fi
FAKE
chmod +x "$FAKEBIN/date"

cat > "$FAKEBIN/claude" << FAKE
#!/usr/bin/env bash
CALLS="$CALLS"
FAKE
cat >> "$FAKEBIN/claude" << 'FAKE'
n="$(find "$CALLS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
rec="$CALLS/$n"
mkdir -p "$rec"
ls -1 > "$rec/files"
cp prompt.txt "$rec/prompt.txt" 2> /dev/null
if [ -f open-items.json ]; then
	reply='{"items":[
	 {"id":"a","file":"a.md","kind":"new","target":"top","before":"","after":"one","source":"notes","headline":"one","tier":"act"},
	 {"id":"b","file":"a.md","kind":"new","target":"top","before":"","after":"two","source":"notes","headline":"two","tier":"act"}]}'
else
	reply='{"fetched":true}'
fi
jq -nc --arg t "$reply" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'
echo '{"type":"result","subtype":"success","total_cost_usd":0}'
FAKE
chmod +x "$FAKEBIN/claude"

cat > "$FAKEBIN/session-status.sh" << 'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = "resolve" ] && { echo '[]'; exit 1; }
exit 0
FAKE
chmod +x "$FAKEBIN/session-status.sh"

cat > "$FAKEBIN/open-tab" << FAKE
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$TABS_LOG"
FAKE
chmod +x "$FAKEBIN/open-tab"

export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN="$FAKEBIN/claude"
export DESK_LOCK_MAX_WAIT_SECS=2
export DESK_LOCK_POLL_SECS=1
unset DESK_STATE_DIR DESK_STATUS_FILE DESK_TICKET_CACHE DESK_LOCK_ROOT DESK_GUARD_ROOT \
	DESK_SCRATCH_ROOT DESK_LOG_DIR DESK_RUNS_ROOT DESK_FETCH_CACHE_ROOT DESK_TICKET_DIGEST_STATE_FILE \
	CLAUDE_SESSION_STORE CLAUDE_SESSION_RECORDER_LOG
export DESK_OPEN_TAB_BIN="$FAKEBIN/open-tab"
export DESK_FOCUS_TAB_BIN="$FAKEBIN/open-tab"
export CLAUDE_CONFIG_DIR="$FAKE_HOME/.claude"

notes="$FAKE_HOME/notes"
desk_test_assert_repo_under_root "$notes" "$ROOT"
mkdir -p "$notes"
git -C "$notes" init -q
printf 'alpha\n' > "$notes/a.md"
printf 'beta\n' > "$notes/b.md"
: > "$notes/.desk-notes"
git -C "$notes" add a.md b.md .desk-notes
git -C "$notes" commit -q -m initial
git -C "$notes" branch -M main

INSTANCE="$ROOT/instance"
mkdir -p "$INSTANCE"
echo '{}' > "$INSTANCE/sources.json"
printf 'Fetch.\n' > "$INSTANCE/f.md"
printf 'Judge. Caps: {{caps}}\n' > "$INSTANCE/j.md"
cat > "$INSTANCE/config.json" << CONFIG
{
  "notes_repo": "$notes",
  "files": ["a.md", "b.md"],
  "captures_file": "b.md",
  "timezone": "UTC",
  "ticket_search_tool": "none-t", "mail_search_tool": "none-m",
  "ticket_status_step_id": "no-t", "mail_fetch_step_id": "no-m",
  "caps": { "daily": { "act": 9 }, "tight": { "act": 1 } },
  "passes": {
    "weekend-off": {
      "weekdays_only": true,
      "trigger": { "start_calendar_interval": [{ "hour": 8, "minute": 0, "weekday": 6 }] },
      "steps": [
        { "id": "commit-push", "kind": "commit_push" },
        { "id": "Feed", "kind": "fetch", "prompt": "f.md", "tools": ["WebSearch"] }
      ]
    },
    "friday-late": {
      "weekdays_only": true,
      "trigger": { "start_calendar_interval": [{ "hour": 16, "minute": 30, "weekday": 5 }] },
      "steps": [
        { "id": "Feed", "kind": "fetch", "prompt": "f.md", "tools": ["WebSearch"] }
      ]
    },
    "morning": {
      "weekdays_only": false,
      "caps": "tight",
      "steps": [
        { "id": "Feed", "kind": "fetch", "prompt": "f.md", "tools": ["WebSearch"] },
        { "id": "J", "kind": "judge", "prompt": "j.md", "tools": ["Read"],
          "input_files": ["a.md", "b.md", "feed.json", "open-items.json"] },
        { "id": "tab", "kind": "open_tab", "cwd": "~", "restricted": false, "prompt_text": "hi" }
      ]
    }
  }
}
CONFIG
export DESK_CONFIG="$INSTANCE/config.json"

echo "=== weekdays_only: true skips the model steps on a weekend, whatever the pass is called ==="
out="$(HOME="$FAKE_HOME" "$DESK_RUN" weekend-off 2>&1)"
assert_true "the fetch step was skipped" "$(grep -q 'step Feed (fetch): skipped (weekend' <<< "$out" && echo true || echo false)"
assert_eq "no model call was made" "0" "$(find "$CALLS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

echo
echo "=== weekdays_only: false runs on a weekend, even for a pass named morning ==="
out="$(HOME="$FAKE_HOME" "$DESK_RUN" morning 2>&1)"
assert_true "the pass finished ok" "$(grep -q 'done: ok' <<< "$out" && echo true || echo false)"
assert_eq "fetch and judge each made a call" "2" "$(find "$CALLS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

judge_rec=""
for rec in "$CALLS"/*; do
	grep -qx 'open-items.json' "$rec/files" 2> /dev/null && judge_rec="$rec"
done
echo
echo "=== the judge's inputs come from files and the fetch id ==="
for f in a.md b.md feed.json; do
	assert_true "judge cwd holds $f" "$(grep -qxF "$f" "$judge_rec/files" 2> /dev/null && echo true || echo false)"
done

echo
echo "=== the pass's own caps entry is used ==="
assert_true "the judge prompt shows the tight cap" "$(grep -qF 'ACT ≤1' "$judge_rec/prompt.txt" && echo true || echo false)"
proposal="$(git -C "$notes" show refs/desk/proposal:proposal.json 2> /dev/null)"
assert_eq "the second act item overflowed: counted in the status file" "1" "$(jq -r '.proposal.overflow.act' "$FAKE_HOME/.local/state/desk/status.json")"
assert_true "and no overflow summary item is in the proposal" \
	"$(jq -e '[.items[] | select(.headline | test("more act"))] | length == 0' > /dev/null 2>&1 <<< "$proposal" && echo true || echo false)"

echo
echo "=== the tab helper is found by its alias name ==="
assert_eq "the open_tab step reached the helper" "1" "$(wc -l < "$TABS_LOG" | tr -d ' ')"

echo
echo "=== a weekdays-only Friday slot firing on a Saturday wake still runs ==="
calls_before="$(find "$CALLS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
out="$(HOME="$FAKE_HOME" "$DESK_RUN" friday-late 2>&1)"
assert_true "the fetch step was not skipped as a weekend" "$(grep -q 'skipped (weekend' <<< "$out" && echo false || echo true)"
assert_eq "its model call was made" "$((calls_before + 1))" "$(find "$CALLS" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
