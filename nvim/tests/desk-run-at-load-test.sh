#!/usr/bin/env bash
# A pass whose LaunchAgent has RunAtLoad starts once at login as well as at
# its calendar slots. The once-a-day guard keeps that to one run a day: a
# login run after the day's first slot time, then the next slot the same
# morning, makes one pass; the next day's login runs again. A login before
# the day's first slot belongs to the previous day's last slot, so it is a
# no-op once that day finished ok. Drives desk-run itself with the clock
# pinned through $DESK_NOW and a fake claude that counts calls.
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

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
CALLS="$ROOT/calls.log"
: > "$CALLS"
cat > "$FAKEBIN/claude" << FAKE
#!/usr/bin/env bash
echo call >> "$CALLS"
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"{}"}]}}'
echo '{"type":"result","subtype":"success","total_cost_usd":0}'
FAKE
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN=claude

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export DESK_RUNS_ROOT="$STATE/runs"
export DESK_FETCH_CACHE_ROOT="$STATE/fetch-cache"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"

repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q
printf 'Section A\n' > "$repo/notes.md"
: > "$repo/reading.md"
git -C "$repo" add notes.md reading.md
git -C "$repo" commit -q -m initial
git -C "$repo" branch -M main

prompt="$ROOT/prompt.md"
echo "a generic test prompt" > "$prompt"
cfg="$ROOT/config.json"
jq -n --arg repo "$repo" --arg prompt "$prompt" '{
	notes_repo: $repo,
	timezone: "UTC",
	ticket_search_tool: "none-t", mail_search_tool: "none-m",
	ticket_status_step_id: "no-t", mail_fetch_step_id: "no-m",
	files: ["notes.md", "reading.md"],
	passes: {
		morning: {
			trigger: { start_calendar_interval: [
				{ hour: 6, minute: 0 }, { hour: 7, minute: 0 }, { hour: 8, minute: 0 },
				{ hour: 9, minute: 0 }, { hour: 10, minute: 0 }, { hour: 11, minute: 0 }
			] },
			steps: [ { id: "F", kind: "fetch", prompt: $prompt, tools: ["Read"], connector: false, timeout: 30 } ]
		}
	}
}' > "$cfg"
export DESK_CONFIG="$cfg"

at() { # YYYY-MM-DD HH:MM, local time -> epoch
	if [ -r /proc/stat ]; then date -d "$1 $2:00" +%s; else date -j -f '%Y-%m-%d %H:%M:%S' "$1 $2:00" +%s; fi
}
run_at() { DESK_NOW="$(at "$1" "$2")" "$DESK_RUN" morning >> "$ROOT/runs.log" 2>&1; }
calls() { wc -l < "$CALLS" | tr -d ' '; }

# 2026-10-14 and -15 are a Wednesday and a Thursday: weekdays, so the
# morning pass's weekday default never skips its step.
echo "=== a login at 07:20, then the 08:00 slot: one run ==="
run_at 2026-10-14 07:20
assert_eq "the login run made its call" "1" "$(calls)"
assert_eq "it ran as that day's pass" "2026-10-14" "$(jq -r '.passes.morning.scheduled_date' "$DESK_STATUS_FILE")"
run_at 2026-10-14 08:00
assert_eq "the 08:00 slot was a no-op" "1" "$(calls)"
assert_eq "and said so" "1" "$(grep -c 'already ok today (scheduled 2026-10-14)' "$ROOT/runs.log")"

echo
echo "=== the next day's login runs again ==="
run_at 2026-10-15 09:05
assert_eq "a second call, for the new day" "2" "$(calls)"

echo
echo "=== a login before the day's first slot is the previous day's, already done ==="
run_at 2026-10-16 05:30
assert_eq "no call: the 15th already finished ok" "2" "$(calls)"
run_at 2026-10-16 06:00
assert_eq "the first slot runs the 16th" "3" "$(calls)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
