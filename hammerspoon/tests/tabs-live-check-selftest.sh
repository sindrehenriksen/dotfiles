#!/usr/bin/env bash
# Offline self-test of hammerspoon/tests/tabs-live-check.sh's own parsing
# and exit logic: `hs` and the opener are stubs, the waits are zero, and
# nothing reaches Hammerspoon or Ghostty.
#   - a snapshot behind other hs output (a lazy-load line) is still read;
#   - an empty, unparseable, locked-screen or windowless first snapshot
#     aborts (exit 2) before the opener is ever called;
#   - a moved, resized or vanished window anywhere, a new window from
#     another app, a focus change, or the opened tab lingering is a FAIL;
#     a lingering tab is closed by its own id and nothing else is;
#   - any FAIL exits 1, and a clean run exits 0.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/tabs-live-check.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# The stub hs answers the Nth snapshot query with $ROOT/snap.N (verbatim,
# so a test can put other lines around the marker) and anything else with
# nothing.
cat > "$ROOT/hs" << STUB
#!/usr/bin/env bash
for a in "\$@"; do
	case "\$a" in
	*DESK_OPENER*)
		[ -f "$ROOT/old-opener" ] && echo "DESK_OPENER nil" || echo "DESK_OPENER function"
		exit 0
		;;
	*"close tab"*)
		printf '%s\n' "\$a" >> "$ROOT/closed"
		exit 0
		;;
	*DESK_SNAPSHOT*)
		n=\$(( \$(cat "$ROOT/count" 2> /dev/null || echo 0) + 1 ))
		echo "\$n" > "$ROOT/count"
		cat "$ROOT/snap.\$n" 2> /dev/null
		exit 0
		;;
	esac
done
exit 0
STUB
cat > "$ROOT/opener" << STUB
#!/usr/bin/env bash
echo called >> "$ROOT/opened"
exit 0
STUB
chmod +x "$ROOT/hs" "$ROOT/opener"

export DESK_TABS_LIVE=1 DESK_TABS_LIVE_HS="$ROOT/hs" DESK_TABS_LIVE_OPENER="$ROOT/opener"
export DESK_TABS_LIVE_SETTLE_SECS=0 DESK_TABS_LIVE_CLOSE_SECS=0

A="Ghostty|2663,-498,1136,700"
B="Ghostty|2663,212,1136,690"
C="Safari|0,33,1512,949"
N="Ghostty|1600,-400,900,600"

# snap <app> <focused> <visible-json> <tabs-json> [ghostty-ids-json]
snap() {
	printf 'DESK_SNAPSHOT {"app":"%s","focused":%s,"ghostty_front":"tab-group-a","ghostty_ids":%s,"ghostty_seen":2,"visible":%s,"by_ghostty":["tab-group-a|%s","tab-group-b|%s"],"tabs":%s}\n' \
		"$1" "$2" "${5:-[\"tab-group-a\",\"tab-group-b\"]}" "$3" "${A#Ghostty|}" "${B#Ghostty|}" "$4"
}
V0="[\"$A\",\"$B\",\"$C\"]"
T0='["tab-group-a tab-1"]'
T1='["tab-group-a tab-1","tab-group-a tab-2"]'

# run_case <name>; snapshots already written as $ROOT/snap.1..3
run_case() {
	rm -f "$ROOT/count" "$ROOT/opened" "$ROOT/closed"
	bash "$CHECK" 0 < /dev/null > "$ROOT/out.$1" 2>&1
	echo $? > "$ROOT/status.$1"
	rm -f "$ROOT"/snap.*
}
opened() { [ -f "$ROOT/opened" ] && wc -l < "$ROOT/opened" | tr -d ' ' || echo 0; }
closed() { [ -f "$ROOT/closed" ] && cat "$ROOT/closed" || true; }
status() { cat "$ROOT/status.$1"; }
has() { grep -c -- "$2" "$ROOT/out.$1"; }

echo "=== a clean run (a tab), with a lazy-load line ahead of the first snapshot ==="
{ echo "-- Loading extension: json"; snap Ghostty 175 "$V0" "$T0"; } > "$ROOT/snap.1"
snap Ghostty 175 "$V0" "$T1" > "$ROOT/snap.2"
snap Ghostty 175 "$V0" "$T0" > "$ROOT/snap.3"
run_case clean
assert_eq "exits 0" "0" "$(status clean)"
assert_eq "the opener was called once" "1" "$(opened)"
assert_eq "no FAIL lines" "0" "$(has clean '^FAIL')"
assert_eq "the focused window was read" "1" "$(has clean 'focused: Ghostty window 175; 3 visible windows, 2 of them')"
assert_eq "nothing was closed" "" "$(closed)"

echo
echo "=== a clean run that created a new window ==="
snap Ghostty 175 "$V0" "$T0" > "$ROOT/snap.1"
snap Ghostty 175 "[\"$A\",\"$B\",\"$C\",\"$N\"]" '["tab-group-a tab-1","tab-group-n tab-9"]' '["tab-group-a","tab-group-b","tab-group-n"]' > "$ROOT/snap.2"
snap Ghostty 175 "$V0" "$T0" > "$ROOT/snap.3"
run_case newwin
assert_eq "exits 0" "0" "$(status newwin)"
assert_eq "no FAIL lines" "0" "$(has newwin '^FAIL')"

for kind in empty garbage locked windowless novisible; do
	case "$kind" in
	empty) : > "$ROOT/snap.1" ;;
	garbage) echo "DESK_SNAPSHOT {not json" > "$ROOT/snap.1" ;;
	locked) snap loginwindow 0 "$V0" "$T0" > "$ROOT/snap.1" ;;
	windowless) echo 'DESK_SNAPSHOT {"app":"Ghostty","focused":0,"ghostty_ids":["x"],"ghostty_seen":0,"visible":["Safari|0,0,1,1"],"by_ghostty":{},"tabs":{}}' > "$ROOT/snap.1" ;;
	novisible) snap Ghostty 175 "[]" "$T0" > "$ROOT/snap.1" ;;
	esac
	run_case "$kind"
	echo
	echo "=== an unusable first snapshot ($kind) ==="
	assert_eq "exits 2" "2" "$(status "$kind")"
	assert_eq "the opener was never called" "0" "$(opened)"
	assert_eq "it says it aborted before opening" "1" "$(has "$kind" '^ABORT')"
done

echo
echo "=== Hammerspoon has an older opener loaded ==="
touch "$ROOT/old-opener"
snap Ghostty 175 "$V0" "$T0" > "$ROOT/snap.1"
run_case oldopener
rm -f "$ROOT/old-opener"
assert_eq "exits 2" "2" "$(status oldopener)"
assert_eq "the opener was never called" "0" "$(opened)"
assert_eq "it says why" "1" "$(has oldopener '^ABORT: the opener Hammerspoon has loaded predates')"

echo
echo "=== focus moved ==="
snap Ghostty 175 "$V0" "$T0" > "$ROOT/snap.1"
snap Ghostty 1524 "$V0" "$T1" > "$ROOT/snap.2"
snap Ghostty 1524 "$V0" "$T0" > "$ROOT/snap.3"
run_case moved
assert_eq "exits 1" "1" "$(status moved)"
assert_eq "names the focus failure" "1" "$(has moved '^FAIL - focus is still on the same window')"

echo
echo "=== the upper-mid window moved onto the lower-mid one's place ==="
snap Ghostty 175 "$V0" "$T0" > "$ROOT/snap.1"
snap Ghostty 175 "[\"$B\",\"$B\",\"$C\"]" "$T1" > "$ROOT/snap.2"
snap Ghostty 175 "[\"$B\",\"$B\",\"$C\"]" "$T0" > "$ROOT/snap.3"
run_case frame
assert_eq "exits 1" "1" "$(status frame)"
assert_eq "names what moved" "1" "$(has frame '^FAIL - windows moved, resized or vanished: Ghostty|2663,-498')"

echo
echo "=== another app gained a window ==="
snap Ghostty 175 "$V0" "$T0" > "$ROOT/snap.1"
snap Ghostty 175 "[\"$A\",\"$B\",\"$C\",\"Mail|1,1,1,1\"]" "$T1" > "$ROOT/snap.2"
snap Ghostty 175 "$V0" "$T0" > "$ROOT/snap.3"
run_case otherapp
assert_eq "exits 1" "1" "$(status otherapp)"

echo
echo "=== the snapshot after the open is unreadable ==="
snap Ghostty 175 "$V0" "$T0" > "$ROOT/snap.1"
: > "$ROOT/snap.2"
run_case after
assert_eq "exits 1" "1" "$(status after)"

echo
echo "=== the opened tab lingers ==="
snap Ghostty 175 "$V0" "$T0" > "$ROOT/snap.1"
snap Ghostty 175 "$V0" "$T1" > "$ROOT/snap.2"
snap Ghostty 175 "$V0" "$T1" > "$ROOT/snap.3"
run_case linger
assert_eq "exits 1" "1" "$(status linger)"
assert_eq "says so" "1" "$(has linger '^FAIL - the tab this check opened is still open')"
assert_eq "closes exactly that tab, by its id" "1" "$(closed | grep -c 'tab id \"tab-2\" of window id \"tab-group-a\"')"
assert_eq "and nothing else" "1" "$(closed | grep -c 'close tab')"

echo
echo "=== no new tab seen after the open ==="
snap Ghostty 175 "$V0" "$T0" > "$ROOT/snap.1"
snap Ghostty 175 "$V0" "$T0" > "$ROOT/snap.2"
snap Ghostty 175 "$V0" "$T0" > "$ROOT/snap.3"
run_case notab
assert_eq "exits 1" "1" "$(status notab)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
