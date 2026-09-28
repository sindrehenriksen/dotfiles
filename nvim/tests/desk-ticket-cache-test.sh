#!/usr/bin/env bash
# D8b test: claude/desk-lib/ticket-cache.sh — T's own two jobs (design.md
# §4 "Ticket status, both passes"): building the `key in (...)` JQL from
# ticket-like tokens in his notes, and parsing T's raw search results
# (both Cloud Jira shapes, prompts/README.md's own note) into the ticket
# cache nvim/lua/desk/annotate.lua reads. Fixtures throughout — no live
# Jira call.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../claude/desk-lib"

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
export DESK_STATE_DIR="$ROOT/state"
export DESK_TICKET_CACHE="$ROOT/state/ticket-status.json"

# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
# shellcheck source=../../claude/desk-lib/tool-results.sh
source "$LIB/tool-results.sh"
# shellcheck source=../../claude/desk-lib/ticket-cache.sh
source "$LIB/ticket-cache.sh"

tokens='[
  {"pattern": "^TICKET-([0-9]+)$", "case_insensitive": true, "handler": "url"},
  {"pattern": "^.+$", "case_insensitive": false, "handler": "session"}
]'

echo "=== desk_ticket_keys_from_text / desk_build_jql ==="
notes=$'Section A\n  working on ticket-123 today\n  also TICKET-45 and TICKET-123 again\n  a session token: my-session\n'
keys="$(desk_ticket_keys_from_text "$notes" "$tokens")"
assert_eq "two distinct keys, upper-cased and deduped" "$(printf 'TICKET-123\nTICKET-45')" "$keys"
jql="$(desk_build_jql "$notes" "$tokens")"
assert_true "the jql is a key-in clause over both keys" \
	"$([[ "$jql" == 'key in ('*'TICKET-123'*')' && "$jql" == *'TICKET-45'* ]] && echo true || echo false)"

no_tickets_jql="$(desk_build_jql "no tickets mentioned here" "$tokens")"
assert_true "no keys found still yields valid (harmless) JQL" \
	"$([[ "$no_tickets_jql" == 'key in ('*')' ]] && echo true || echo false)"

echo
echo "=== desk_parse_jira_issues: the interactive shape (issues[] + nextPageToken) ==="
interactive='{"issues":[{"key":"TICKET-123","fields":{"summary":"Do the thing","status":{"name":"In Progress"}}}],"nextPageToken":null}'
parsed="$(desk_parse_jira_issues "$interactive")"
assert_eq "key parsed" "TICKET-123" "$(jq -r '.key' <<< "$parsed")"
assert_eq "status.name parsed" "In Progress" "$(jq -r '.status' <<< "$parsed")"
assert_eq "summary parsed" "Do the thing" "$(jq -r '.summary' <<< "$parsed")"

echo
echo "=== desk_parse_jira_issues: the headless shape (issues.nodes + pageInfo) ==="
headless='{"issues":{"nodes":[{"key":"TICKET-45","fields":{"summary":"Ship it","status":{"name":"Done"}}}],"pageInfo":{"hasNextPage":false}}}'
parsed2="$(desk_parse_jira_issues "$headless")"
assert_eq "key parsed from the nodes shape" "TICKET-45" "$(jq -r '.key' <<< "$parsed2")"
assert_eq "status parsed from the nodes shape" "Done" "$(jq -r '.status' <<< "$parsed2")"

echo
echo "=== desk_build_ticket_cache: writes the pinned shape from real tool-uses/results ==="
uses_file="$ROOT/T-tool-uses.jsonl"
results_file="$ROOT/T-tool-results.jsonl"
cat > "$uses_file" <<'JSONL'
{"type":"tool_use","id":"u1","name":"mcp__example-tickets__search","input":{"jql":"key in (TICKET-123,TICKET-45)"}}
JSONL
cat > "$results_file" <<'JSONL'
{"type":"tool_result","tool_use_id":"u1","content":[{"type":"text","text":"{\"issues\":[{\"key\":\"TICKET-123\",\"fields\":{\"summary\":\"Do the thing\",\"status\":{\"name\":\"In Progress\"}}},{\"key\":\"TICKET-45\",\"fields\":{\"summary\":\"Ship it\",\"status\":{\"name\":\"Done\"}}}]}"}]}
JSONL
result="$(desk_build_ticket_cache "$uses_file" "$results_file" "mcp__example-tickets__search")"
assert_eq "reports ok" "ok" "$result"
assert_true "the cache file exists" "$([ -f "$DESK_TICKET_CACHE" ] && echo true || echo false)"
assert_eq "TICKET-123's status" "In Progress" "$(jq -r '.tickets["TICKET-123"].status' "$DESK_TICKET_CACHE")"
assert_eq "TICKET-45's status" "Done" "$(jq -r '.tickets["TICKET-45"].status' "$DESK_TICKET_CACHE")"
assert_true "checked_at is a number" "$(jq -e '.checked_at | type == "number"' > /dev/null 2>&1 "$DESK_TICKET_CACHE" && echo true || echo false)"

echo
echo "=== desk_build_ticket_cache: on failure the old cache stays ==="
before_cache="$(cat "$DESK_TICKET_CACHE")"
empty_results="$ROOT/empty-tool-results.jsonl"
: > "$empty_results"
empty_uses="$ROOT/empty-tool-uses.jsonl"
: > "$empty_uses"
result2="$(desk_build_ticket_cache "$empty_uses" "$empty_results" "mcp__example-tickets__search")"
assert_eq "reports failed" "failed" "$result2"
after_cache="$(cat "$DESK_TICKET_CACHE")"
assert_eq "the cache file is untouched" "$before_cache" "$after_cache"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
