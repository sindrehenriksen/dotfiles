#!/usr/bin/env bash
# Live check of a background tab open, against the real Hammerspoon and
# Ghostty. It opens ONE real tab or window on screen, so it is never in
# tests/run-all.sh and skips unless DESK_TABS_LIVE=1. Run it by hand, once
# per case:
#   - typing in the upper_C Ghostty window (the tab must go elsewhere);
#   - another app frontmost (the tab goes into upper_C).
# Put focus where the case needs it during the countdown and leave it there.
#
# It records the focused window and every Ghostty window's frame, opens a
# tab whose command prints a marker and exits after a few seconds (so the
# tab closes itself), then asserts that focus is where it was and that no
# pre-existing Ghostty window moved, resized or vanished. A created tab still
# open at the end is closed only after its working directory proves it is
# the one this check opened; anything else is reported, never touched.
#
# Usage: DESK_TABS_LIVE=1 hammerspoon/tests/tabs-live-check.sh [countdown-secs]
set -u

if [ "${DESK_TABS_LIVE:-}" != "1" ]; then
	echo "skipped: set DESK_TABS_LIVE=1 to run the live tab check (it opens a real tab)"
	exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPEN_TAB_SH="$HERE/../desk-open-tab.sh"
countdown=${1:-8}

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

# stdin from /dev/null: hs otherwise reads a piped stdin as more commands.
hs_lua() { hs -t 10 -c "$1" < /dev/null; }

# One JSON line: the focused window and app, every Ghostty window with
# Ghostty's own id (matched the way the opener matches it) and frame, the
# upper_C window's Ghostty id, and every tab id.
SNAPSHOT_LUA='
local front = hs.application.frontmostApplication()
local fw = hs.window.focusedWindow()
local hs_list = {}
for _, w in ipairs(hs.window.orderedWindows()) do
  local app = w:application()
  if app and app:name() == "Ghostty" then
    hs_list[#hs_list + 1] = { id = w:id(), title = w:title(), frame = w:frame() }
  end
end
local ok, r = hs.osascript.applescript([[tell application "Ghostty" to get {id, name} of every window]])
local sw = {}
if ok and type(r) == "table" then
  for i, id in ipairs(r[1]) do sw[#sw + 1] = { id = id, name = r[2][i] } end
end
local windows = {}
for _, w in ipairs(hs_list) do
  local f = w.frame
  windows[#windows + 1] = {
    hs_id = w.id,
    ghostty_id = DeskTab.match_script_window(w.id, hs_list, sw) or "",
    frame = string.format("%d,%d,%d,%d", f.x, f.y, f.w, f.h),
  }
end
local ok2, tabs = hs.osascript.applescript([[tell application "Ghostty"
set out to {}
repeat with w in windows
repeat with t in tabs of w
set end of out to ((id of w) & " " & (id of t))
end repeat
end repeat
return out
end tell]])
return hs.json.encode({
  app = front and front:name() or "",
  focused = fw and fw:id() or 0,
  windows = windows,
  tabs = ok2 and tabs or {},
})
'

echo "Put focus where this case needs it; recording in ${countdown}s..."
sleep "$countdown"

before=$(hs_lua "$SNAPSHOT_LUA") || { echo "could not read the window state"; exit 1; }
before_app=$(jq -r '.app' <<< "$before")
before_focused=$(jq -r '.focused' <<< "$before")
echo "focused: $before_app window $before_focused; $(jq '.windows | length' <<< "$before") Ghostty windows"

marker_dir=$(mktemp -d "/tmp/desk-live-check.XXXXXX")
"$OPEN_TAB_SH" "echo desk-live-check; sleep 10" "" "$marker_dir" background > /dev/null
assert_eq "the opener reports success" "0" "$?"

# Longer than the opener's focus watch (4s) and placement watch (2s).
sleep 6
after=$(hs_lua "$SNAPSHOT_LUA") || { echo "could not read the window state"; exit 1; }
assert_eq "focus is still in the same app" "$before_app" "$(jq -r '.app' <<< "$after")"
assert_eq "focus is still on the same window" "$before_focused" "$(jq -r '.focused' <<< "$after")"

# Every pre-existing Ghostty window, by Ghostty's own id (stable across the
# opener adding a tab to it), must keep its exact frame.
while IFS=$'\t' read -r gid frame hs_id; do
	if [ -z "$gid" ]; then
		bad "window $hs_id could not be identified to Ghostty, so its frame could not be compared"
		continue
	fi
	now=$(jq -r --arg g "$gid" '.windows[] | select(.ghostty_id == $g) | .frame' <<< "$after")
	assert_eq "Ghostty window $gid (was $hs_id) kept its frame" "$frame" "$now"
done < <(jq -r '.windows[] | [.ghostty_id, .frame, (.hs_id | tostring)] | @tsv' <<< "$before")

# The tab's command exits after 10s and the tab closes itself; give it time.
sleep 6
final=$(hs_lua "$SNAPSHOT_LUA") || { echo "could not read the window state"; exit 1; }
leftover=$(jq -r --argjson b "$(jq '.tabs' <<< "$before")" '.tabs - $b | .[]' <<< "$final")
if [ -z "$leftover" ]; then
	ok "the tab this check opened has closed itself"
else
	while read -r wid tid; do
		[ -n "$tid" ] || continue
		dir=$(hs_lua "local ok, r = hs.osascript.applescript([[tell application \"Ghostty\" to get working directory of focused terminal of tab id \"$tid\" of window id \"$wid\"]]) return tostring(r)")
		if [ "$dir" = "$marker_dir" ] || [ "$dir" = "/private$marker_dir" ]; then
			hs_lua "hs.osascript.applescript([[tell application \"Ghostty\" to close tab (tab id \"$tid\" of window id \"$wid\")]])" > /dev/null
			echo "closed the tab this check opened ($tid)"
		else
			bad "a tab appeared that this check cannot prove it opened ($tid in $wid, cwd $dir); left alone"
		fi
	done <<< "$leftover"
fi
rmdir "$marker_dir" 2> /dev/null

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
