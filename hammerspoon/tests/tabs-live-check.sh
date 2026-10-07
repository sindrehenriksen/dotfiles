#!/usr/bin/env bash
# Live check of a background tab open, against the real Hammerspoon and
# Ghostty. It opens ONE real tab or window on screen, so it is never in
# tests/run-all.sh and skips unless DESK_TABS_LIVE=1. Run it by hand, once
# per case:
#   - typing in the upper_C Ghostty window (the tab must go elsewhere);
#   - another app frontmost (the tab goes into upper_C).
# Put focus where the case needs it during the countdown and leave it there.
# It also runs unattended (an agent's shell: no tty, stdin from /dev/null),
# checking whatever focus the user has at the time.
#
# It records the focused window and the frame of every visible window, opens
# a close-on-exit tab that says what it is and ends after 10s, then asserts:
# focus is where it was; no window anywhere moved, resized or vanished; a
# new window, if one was needed, is not over the window that had focus;
# (compared by position across all apps, and by Ghostty's own window id
# where Ghostty can name it); and the tab it opened is gone by the end, by
# that tab's own id. A tab that lingers is a failure, and that one tab,
# and nothing else, is then closed.
# A first snapshot it cannot read aborts the check before anything opens.
# Any failure exits 1; an abort exits 2.
#
# Usage: DESK_TABS_LIVE=1 hammerspoon/tests/tabs-live-check.sh [countdown-secs]
# hammerspoon/tests/tabs-live-check-selftest.sh runs this against stubs via
# DESK_TABS_LIVE_HS, DESK_TABS_LIVE_OPENER and the *_SECS waits below.
set -u

if [ "${DESK_TABS_LIVE:-}" != "1" ]; then
	echo "skipped: set DESK_TABS_LIVE=1 to run the live tab check (it opens a real tab)"
	exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS_BIN="${DESK_TABS_LIVE_HS:-hs}"
OPENER="${DESK_TABS_LIVE_OPENER:-$HERE/../desk-open-tab.sh}"
# Longer than the opener's focus watch (4s) and placement watch (2s).
SETTLE_SECS="${DESK_TABS_LIVE_SETTLE_SECS:-6}"
# The opened tab's command exits after 10s; this is from the first snapshot
# after the open, so together they cover it.
CLOSE_SECS="${DESK_TABS_LIVE_CLOSE_SECS:-6}"
countdown=${1:-8}

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}
finish() {
	echo
	echo "=== summary: $pass passed, $fail failed ==="
	[ "$fail" -eq 0 ] && exit 0
	exit 1
}

# stdin from /dev/null: hs otherwise reads a piped stdin as more commands.
hs_lua() { "$HS_BIN" -q -t 10 -c "$1" < /dev/null; }

# The snapshot is returned on one line behind this marker, because hs also
# prints other lines to stdout, such as "-- Loading extension: json" the
# first time an extension is used after a reload.
MARKER="DESK_SNAPSHOT "

# The focused window and app; every visible window as "app|frame"; Ghostty's
# window ids, key window and tab ids; and Ghostty windows' frames by
# Ghostty id where the title match can name them.
SNAPSHOT_LUA='
local front = hs.application.frontmostApplication()
local fw = hs.window.focusedWindow()
local ff = fw and fw:frame()
local saved_out = hs.execute("/usr/bin/defaults read com.mitchellh.ghostty NSWindowLastPosition 2> /dev/null")
local primary = hs.screen.primaryScreen()
local saved_ok = ff ~= nil and primary ~= nil
  and DeskTab.saved_position_is(DeskTab.parse_saved_position(saved_out), ff, primary:fullFrame().h)
local hs_list, visible = {}, {}
for _, w in ipairs(hs.window.orderedWindows()) do
  local app = w:application()
  local name = app and app:name() or "?"
  local f = w:frame()
  visible[#visible + 1] = string.format("%s|%d,%d,%d,%d", name, f.x, f.y, f.w, f.h)
  if name == "Ghostty" then
    hs_list[#hs_list + 1] = { id = w:id(), title = w:title(), frame = f }
  end
end
local ok, r = hs.osascript.applescript([[tell application "Ghostty" to get {id, name} of every window]])
local sw, ids = {}, {}
if ok and type(r) == "table" then
  for i, id in ipairs(r[1]) do sw[#sw + 1] = { id = id, name = r[2][i] }; ids[#ids + 1] = id end
end
local by_ghostty = {}
for _, w in ipairs(hs_list) do
  local gid = DeskTab.match_script_window(w.id, hs_list, sw)
  if gid then
    local f = w.frame
    by_ghostty[#by_ghostty + 1] = gid .. "|" .. string.format("%d,%d,%d,%d", f.x, f.y, f.w, f.h)
  end
end
local okf, front_gid = hs.osascript.applescript([[tell application "Ghostty" to get id of front window]])
local ok2, tabs = hs.osascript.applescript([[tell application "Ghostty"
set out to {}
repeat with w in windows
repeat with t in tabs of w
set end of out to ((id of w) & " " & (id of t))
end repeat
end repeat
return out
end tell]])
return "DESK_SNAPSHOT " .. hs.json.encode({
  app = front and front:name() or "",
  focused = fw and fw:id() or 0,
  focused_frame = ff and string.format("%d,%d,%d,%d", ff.x, ff.y, ff.w, ff.h) or "",
  saved_is_focused = saved_ok and true or false,
  ghostty_front = okf and front_gid or "",
  ghostty_ids = ids,
  ghostty_seen = #hs_list,
  visible = visible,
  by_ghostty = by_ghostty,
  tabs = (ok2 and type(tabs) == "table") and tabs or {},
})
'

# Prints the snapshot as normalised JSON (every list always an array), or
# fails with the reason on stderr.
snapshot() {
	local out line
	if ! out=$(hs_lua "$SNAPSHOT_LUA" 2>&1); then
		printf 'hs failed: %s\n' "$out" >&2
		return 1
	fi
	line=$(printf '%s\n' "$out" | grep "^$MARKER" | tail -n1)
	line=${line#"$MARKER"}
	if [ -z "$line" ]; then
		printf 'no snapshot in the hs output: %s\n' "$out" >&2
		return 1
	fi
	jq -ce '
		def arr: if type == "array" then . else [] end;
		if (.app | type) != "string" or .app == "" then error("no frontmost app") else . end
		| .visible |= arr | .by_ghostty |= arr | .ghostty_ids |= arr | .tabs |= arr
	' <<< "$line" 2> /dev/null || {
		printf 'unreadable snapshot: %s\n' "$line" >&2
		return 1
	}
}

lines() { jq -r ".$1[]" <<< "$2" | sort; }

# The check drives the opener that Hammerspoon has loaded, which is
# whatever init.lua it last read, not this checkout. An opener from before
# DeskTab.pick_free_slot can add a tab to a window whose frame is not
# Ghostty's saved position, which moves that window on screen, or leave a
# new window over the focused one, so the check refuses to drive it.
if [ "$(hs_lua 'return "DESK_OPENER " .. type(DeskTab and DeskTab.pick_free_slot)' 2> /dev/null | grep '^DESK_OPENER ' | tail -n1)" != "DESK_OPENER function" ]; then
	echo "ABORT: the opener Hammerspoon has loaded predates this check; merge and reload Hammerspoon first. Nothing was opened"
	exit 2
fi

echo "Put focus where this case needs it; recording in ${countdown}s..."
sleep "$countdown"

if ! before=$(snapshot); then
	echo "ABORT: could not read the window state before opening anything; nothing was opened"
	exit 2
fi
before_app=$(jq -r '.app' <<< "$before")
before_focused=$(jq -r '.focused' <<< "$before")
if [ "$before_app" = "loginwindow" ]; then
	echo "ABORT: the screen is locked, so the windows cannot be seen; nothing was opened"
	exit 2
fi
if [ "$(jq '.ghostty_ids | length' <<< "$before")" -gt 0 ] && [ "$(jq '.ghostty_seen' <<< "$before")" -eq 0 ]; then
	echo "ABORT: Ghostty has windows that Hammerspoon cannot see; nothing was opened"
	exit 2
fi
if [ "$(jq '.visible | length' <<< "$before")" -eq 0 ]; then
	echo "ABORT: no visible windows to compare; nothing was opened"
	exit 2
fi
echo "focused: $before_app window $before_focused; $(jq '.visible | length' <<< "$before") visible windows, $(jq '.ghostty_ids | length' <<< "$before") of them Ghostty's"

started=$(date '+%Y-%m-%d %H:%M:%S')
"$OPENER" "printf 'desk tab check: this tab closes itself in 10s\\n'; sleep 10" "" "${TMPDIR:-/tmp}" background,close > /dev/null
assert_eq "the opener reports success" "0" "$?"

sleep "$SETTLE_SECS"
if ! after=$(snapshot); then
	bad "could not read the window state after the open"
	finish
fi
assert_eq "focus is still in the same app" "$before_app" "$(jq -r '.app' <<< "$after")"
assert_eq "focus is still on the same window" "$before_focused" "$(jq -r '.focused' <<< "$after")"

new_windows=$(comm -13 <(lines ghostty_ids "$before") <(lines ghostty_ids "$after") | grep -c . || true)
created_tabs=$(comm -13 <(lines tabs "$before") <(lines tabs "$after"))
echo "the open created $new_windows new Ghostty window(s) and these tabs: $(printf '%s' "$created_tabs" | tr '\n' ';')"

# No frame anywhere may change: every window from before must still be at
# exactly the same place and size. Only a newly created Ghostty window may
# add a frame.
moved=$(comm -23 <(lines visible "$before") <(lines visible "$after"))
if [ -z "$moved" ]; then
	ok "no visible window moved, resized or vanished"
else
	bad "windows moved, resized or vanished: $(printf '%s' "$moved" | tr '\n' ';')"
fi
extra=$(comm -13 <(lines visible "$before") <(lines visible "$after"))
extra_other=$(printf '%s\n' "$extra" | grep -v '^Ghostty|' | grep -c . || true)
extra_ghostty=$(printf '%s\n' "$extra" | grep -c '^Ghostty|' || true)
assert_eq "no other app gained a window" "0" "$extra_other"
assert_eq "Ghostty gained a frame only for a window it newly created" "$new_windows" "$extra_ghostty"
# A new window must come up clear of the window that had focus.
focused_frame=$(jq -r '.focused_frame' <<< "$before")
overlapping=$(printf '%s\n' "$extra" | grep '^Ghostty|' | sed 's/^Ghostty|//' | awk -F, -v f="$focused_frame" '
	BEGIN { split(f, g, ",") }
	f != "" && $1 < g[1] + g[3] && g[1] < $1 + $3 && $2 < g[2] + g[4] && g[2] < $2 + $4 { print }')
if [ -z "$overlapping" ]; then
	ok "no new window is over the window that had focus"
else
	bad "a new window is over the window that had focus: $(printf '%s' "$overlapping" | tr '\n' ';')"
fi
# Ghostty moves every window it shows to its saved position, so that must
# again be the user's own Ghostty window, or the next tab there drags it.
if [ "$before_app" = "Ghostty" ]; then
	assert_eq "Ghostty's saved position is the focused window's again" "true" "$(jq -r '.saved_is_focused' <<< "$after")"
fi
changed=$(comm -23 <(lines by_ghostty "$before") <(lines by_ghostty "$after") | while IFS='|' read -r gid frame; do
	jq -e --arg g "$gid" '.by_ghostty[] | select(startswith($g + "|"))' <<< "$after" > /dev/null && echo "$gid"
done)
if [ -z "$changed" ]; then
	ok "every Ghostty window Ghostty could name kept its frame"
else
	bad "Ghostty windows changed frame: $(printf '%s' "$changed" | tr '\n' ' ')"
fi

sleep "$CLOSE_SECS"
if ! final=$(snapshot); then
	bad "could not read the window state at the end; check by hand for a tab saying 'desk tab check'"
	finish
fi
lingering=$(comm -12 <(printf '%s\n' "$created_tabs" | grep . | sort) <(lines tabs "$final"))
if [ -z "$created_tabs" ]; then
	bad "no new tab was seen after the open, so its closing could not be checked"
elif [ -z "$lingering" ]; then
	ok "the tab this check opened is gone"
else
	bad "the tab this check opened is still open: $(printf '%s' "$lingering" | tr '\n' ';')"
	if [ "$(printf '%s\n' "$created_tabs" | grep -c .)" -eq 1 ]; then
		read -r wid tid <<< "$lingering"
		hs_lua "hs.osascript.applescript([[tell application \"Ghostty\" to close tab (tab id \"$tid\" of window id \"$wid\")]])" > /dev/null
		echo "closed that tab ($tid), and nothing else"
	else
		echo "more than one new tab appeared, so none was closed; close the 'desk tab check' tab by hand"
	fi
fi
moved_end=$(comm -23 <(lines visible "$before") <(lines visible "$final"))
if [ -z "$moved_end" ]; then
	ok "after the tab closed, still no window moved"
else
	bad "after the tab closed, windows moved: $(printf '%s' "$moved_end" | tr '\n' ';')"
fi

echo
echo "opener log (Hammerspoon console since $started):"
hs_lua 'return hs.console.getConsole()' 2> /dev/null | grep 'DeskOpenTab' | awk -v s="$started" 'substr($0, 1, 19) >= s'

finish
