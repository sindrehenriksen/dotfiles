#!/usr/bin/env bash
# Mail triage (claude/desk-lib/mail-triage.sh and the write step in
# claude/desk-run): a fetch step's mailbox listing is sorted by the
# instance's rules with no model involved; noise is trashed by the write
# step, pinned per tool, and only under dry_run false; a second offer
# listing scopes what is offered and can offer starred mail, and a write
# step with only the trash tool marks nothing read; starred mail, an
# invitation still ahead, a person's unanswered mail and a partly listed
# thread are never trashed or offered; the judge sees only the rest, and
# its `mail_cleanup` is offered to the follow-up tab only where it names one
# of those. One fake `claude` keyed off its own scratch cwd; no live Gmail
# call, and nothing outside the temp root is touched.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESK_RUN="$HERE/../../claude/desk-run"
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
ROOT="$(cd "$ROOT" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

# shellcheck source=../../tests/lib/git-safety.sh
source "$HERE/../../tests/lib/git-safety.sh"
desk_test_git_safety_init "$ROOT"

SEARCH=mcp__claude_ai_Gmail__search_threads
UNLABEL=mcp__claude_ai_Gmail__unlabel_thread
TRASH=mcp__claude_ai_Gmail__trash_thread
export SEARCH UNLABEL TRASH

# The listing, two pages. msg <id> <sender> <subject> <labels json> [messageCount]
msg() {
	jq -cn --arg id "$1" --arg s "$2" --arg sub "$3" --argjson l "$4" --argjson n "${5:-1}" \
		'{id: $id, messageCount: $n, viewUrl: ("https://mail.example/" + $id),
		  messages: [{sender: $s, subject: $sub, date: "2026-10-01T08:00:00Z", labelIds: $l, snippet: ("about " + $id)}]}'
}
PAGE1="$ROOT/page1.json"
PAGE2="$ROOT/page2.json"
jq -cn --argjson t "$(printf '%s\n' \
	"$(msg n1 notifications@ci.example '[org/repo] Run failed: build (abc123)' '["UNREAD","INBOX"]')" \
	"$(msg n2 'Kari <kari@corp.example>' 'Accepted: Weekly sync @ Fri 2 Oct 2026 10:00 - 10:30 (CEST) (Me)' '["UNREAD","INBOX"]')" \
	"$(msg n3 kari@corp.example 'Invitation: Planning @ Wed 14 Oct 2099 10:00 - 11:00 (CEST) (Me)' '["UNREAD","INBOX"]')" \
	"$(msg n4 ola@corp.example 'Updated invitation: Retro @ Thu 1 Oct 2020 13:00 - 13:45 (CEST) (Me)' '["INBOX"]')" \
	"$(msg n5 notifications@ci.example '[org/repo] Run failed: deploy (def456)' '["INBOX","STARRED"]')" \
	"$(msg p1 'Per <per@corp.example>' 'Can you review the plan?' '["UNREAD","INBOX"]')" | jq -s .)" \
	'{threads: $t, nextPageToken: "tok-2"}' > "$PAGE1"
answered="$(jq -cn '{id: "a1", messageCount: 2, messages: [
	{sender: "per@corp.example", subject: "Question", date: "2026-09-30T08:00:00Z", labelIds: ["INBOX"], snippet: "q"},
	{sender: "Me <me@corp.example>", subject: "Re: Question", date: "2026-09-30T09:00:00Z", labelIds: ["INBOX"], snippet: "a"}]}')"
jq -cn --argjson t "$(printf '%s\n' "$answered" \
	"$(msg c1 no-reply@vendor.example 'Your monthly newsletter' '["INBOX"]')" \
	"$(msg d1 digest@news.example 'The daily digest' '["Label_9"]')" \
	"$(msg d2 digest@news.example 'The daily digest' '["UNREAD","Label_9"]')" \
	"$(msg x1 notifications@ci.example '[org/repo] Run failed: lint (0a0a0a)' '["INBOX"]' 3)" | jq -s .)" \
	'{threads: $t}' > "$PAGE2"
# The offer listing, when the config has an offer_query: the answered thread
# and the newsletter from the inbox, an unread mail archived out of it, and
# a starred CI run that a rule would otherwise trash.
OFFER="$ROOT/offer.json"
jq -cn --argjson t "$(printf '%s\n' "$answered" \
	"$(msg c1 no-reply@vendor.example 'Your monthly newsletter' '["INBOX"]')" \
	"$(msg o1 no-reply@vendor.example 'Your trial ends soon' '["UNREAD","Label_3"]')" \
	"$(msg s1 notifications@ci.example '[org/repo] Run failed: release (5e5e5e)' '["INBOX","STARRED"]')" \
	"$(jq -cn '{id: "n9", messageCount: 1, messages: [{sender: "kari@corp.example", subject: "Declined: Retro @ Thu 1 Oct 2020 13:00 (Me)", date: "2026-10-02T08:00:00Z", labelIds: ["INBOX"], snippet: "no"}]}')" | jq -s .)" \
	'{threads: $t}' > "$OFFER"
export PAGE1 PAGE2 OFFER

FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" << 'FAKE'
#!/usr/bin/env bash
cwd="$(pwd -P)"
result() { # id, text
	jq -nc --arg id "$1" --arg t "$2" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:$id,content:[{type:"text",text:$t}]}]}}'
}
use() { # id, name, input json
	jq -nc --arg id "$1" --arg n "$2" --argjson i "$3" '{type:"assistant",message:{content:[{type:"tool_use",id:$id,name:$n,input:$i}]}}'
}
case "$cwd" in
	*-F-private*)
		q="$(sed -n 's/^digest_query=//p' prompt.txt)"
		use s1 "$SEARCH" "$(jq -cn --arg q "$q" '{query: $q}')"
		result s1 "${FAKE_DIGEST_RESULT:-{\}}"
		n=0
		for tid in ${FAKE_OPEN:-}; do
			n=$((n + 1))
			use "g$n" mcp__claude_ai_Gmail__get_thread "$(jq -cn --arg t "$tid" '{threadId: $t}')"
			result "g$n" '{"messages":[{"plaintextBody":"the digest"}]}'
		done
		[ "${FAKE_FPRIVATE:-}" = fail ] && exit 1
		;;
	*-F-inbox*)
		q="$(sed -n 's/^mail_triage_query=//p' prompt.txt)"
		use s1 "$SEARCH" "$(jq -cn --arg q "$q" '{query: $q, pageSize: 20}')"
		result s1 "$(cat "$PAGE1")"
		use s2 "$SEARCH" "$(jq -cn --arg q "$q" '{query: $q, pageSize: 20, pageToken: "tok-2"}')"
		result s2 "$(cat "$PAGE2")"
		oq="$(sed -n 's/^mail_triage_offer_query=//p' prompt.txt)"
		if [ -n "$oq" ]; then
			use s3 "$SEARCH" "$(jq -cn --arg q "$oq" '{query: $q, pageSize: 20}')"
			result s3 "$(cat "$OFFER")"
		fi
		;;
	*-J*)
		cp inbox.json "$J_INBOX_COPY"
		reply='{"items":[],"mail_cleanup":[{"thread_id":"c1","why":"an old newsletter"},{"thread_id":"a1","why":"answered already"},{"thread_id":"p1","why":"protected"},{"thread_id":"n1","why":"noise"},{"thread_id":"zz","why":"made up"}]}'
		jq -nc --arg t "$reply" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'
		;;
	*-W*)
		cp pinned-args.json "$W_PINS_COPY"
		# A well-behaved call: every pinned call, once, unless the case
		# asks it to skip the trash calls.
		n=0
		while IFS=$'\t' read -r tool input; do
			[ "$tool" = "$TRASH" ] && [ "${FAKE_W_MODE:-}" = "skip-trash" ] && continue
			n=$((n + 1))
			use "w$n" "$tool" "$input"
			result "w$n" '{}'
		done < <(jq -r 'to_entries[] | .key as $k | .value[] | [$k, tojson] | @tsv' pinned-args.json)
		;;
esac
echo '{"type":"result","subtype":"success"}'
FAKE
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
export DESK_CLAUDE_BIN=claude
export J_INBOX_COPY="$ROOT/j-inbox.json" W_PINS_COPY="$ROOT/w-pins.json"

STATE="$ROOT/state"
export DESK_STATE_DIR="$STATE"
export DESK_STATUS_FILE="$STATE/status.json"
export DESK_LOCK_ROOT="$STATE/lock"
export DESK_GUARD_ROOT="$STATE/guard"
export DESK_SCRATCH_ROOT="$STATE/scratch"
export DESK_LOG_DIR="$STATE/logs"
export DESK_RUNS_ROOT="$STATE/runs"
export CLAUDE_CONFIG_DIR="$ROOT/claude-config"
export DESK_LOCK_MAX_WAIT_SECS=2
export DESK_LOCK_POLL_SECS=1

repo="$ROOT/notes"
desk_test_assert_repo_under_root "$repo" "$ROOT"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Desk Test"
printf 'Section A\n' > "$repo/notes.md"
: > "$repo/reading.md"
git -C "$repo" add notes.md reading.md
git -C "$repo" commit -q -m initial
git -C "$repo" branch -M main

mkdir -p "$ROOT/instance"
echo 'digest_query={{digest_query}}' > "$ROOT/instance/f-private.md"
printf 'mail_triage_query={{mail_triage_query}}\nmail_triage_offer_query={{mail_triage_offer_query}}\n' > "$ROOT/instance/f-inbox.md"
echo 'judge' > "$ROOT/instance/j.md"
echo 'mark read: {{thread_ids}} trash: {{trash_thread_ids}}' > "$ROOT/instance/w.md"
echo '{"permissions":{"ask":["mcp__claude_ai_Gmail__trash_thread"]}}' > "$ROOT/instance/follow-up-settings.json"

cfg() { # dry_run [offer_outside_inbox] [offer listing and starred offers: true] [W's tools: trash-only] [digest rule: true]
	jq -n --arg repo "$repo" --argjson dry "$1" --argjson outside "${2:-false}" --argjson offer "${3:-false}" --arg wtools "${4:-}" \
		--argjson digest "${5:-false}" \
		--arg s "$SEARCH" --arg u "$UNLABEL" --arg t "$TRASH" '
	def steps: [
		{id: "F-private", kind: "fetch", prompt: "f-private.md", tools: [$s, "mcp__claude_ai_Gmail__get_thread"], connector: true, timeout: 30},
		{id: "F-inbox", kind: "fetch", prompt: "f-inbox.md", tools: [$s], connector: true, timeout: 30,
		 mail_triage: ({query: "in:inbox OR label:digest", self: ["me@corp.example"], offer_outside_inbox: $outside,
		   automated_senders: ["^no-?reply@", "^notifications@", "^digest@"],
		   noise: [
		     {name: "calendar reply", subject: "^(accepted|declined):"},
		     {name: "past event notice", subject: "^(updated )?invitation:", past_event: true},
		     {name: "CI run", from: "^notifications@ci\\.example$", subject: "\\] run failed:"},
		     (if $digest then
		        # A broader rule above the digest rule, which must not trash a digest unread.
		        ({name: "news sender", from: "^digest@news\\.example$"}, {name: "digest", from: "^digest@news\\.example$", digest: true})
		      else {name: "read digest", from: "^digest@news\\.example$", read: true} end),
		     {name: "no condition at all"}]}
		 + (if $offer then {offer_query: "in:inbox OR is:unread", offer_starred: true} else {} end))},
		{id: "J", kind: "judge", prompt: "j.md", tools: ["Read"], connector: false, timeout: 30,
		 input_files: ["notes.md", "inbox.json"]},
		{id: "W", kind: "write", prompt: "w.md", tools: (if $wtools == "trash-only" then [$t] else [$u, $t] end), connector: true, pinned_label: "UNREAD", timeout: 30}
	];
	{ notes_repo: $repo, timezone: "UTC", files: ["notes.md", "reading.md"],
	  ticket_search_tool: "mcp__example-tickets__search", mail_search_tool: $s,
	  ticket_status_step_id: "T", mail_fetch_step_id: "F-private",
	  dry_run: $dry, follow_up_settings: "follow-up-settings.json",
	  passes: {dry: {steps: steps}, live: {steps: steps}, short: {steps: steps}, outside: {steps: steps}, offer: {steps: steps}, trashonly: {steps: steps},
	    digestfail: {steps: steps}, digestrace: {steps: steps}, digestok: {steps: steps},
	    triage_only: {steps: [steps[] | select(.id != "F-private")]}} }' > "$ROOT/instance/config.json"
}

echo "=== the sort: by rule, with every protection ahead of the rules ==="
cfg true
DESK_CONFIG="$ROOT/instance/config.json" "$DESK_RUN" dry > "$ROOT/dry.out" 2>&1
assert_eq "the dry pass exits ok" "0" "$?"
noise_ids="$(grep -o 'would trash [a-z0-9]* ([^)]*)' "$ROOT/dry.out" | sort | paste -sd'|' -)"
assert_eq "noise: the CI run, the calendar reply, the past notice and the read digest, each by its rule" \
	"would trash d1 (read digest)|would trash n1 (CI run)|would trash n2 (calendar reply)|would trash n4 (past event notice)" "$noise_ids"
assert_eq "noise keeps the listing's order, newest first, not the thread ids" "n1 n2 n4 d1" \
	"$(grep -o 'would trash [a-z0-9]*' "$ROOT/dry.out" | awk '{print $3}' | paste -sd' ' -)"
assert_true "the summary line counts the protected ones by reason" \
	"$(grep -q 'protected invitation 1, partial 1, person 1, starred 1' "$ROOT/dry.out" && echo true || echo false)"
assert_true "both pages were read: the listing is whole" \
	"$(grep -q 'mail triage: 11 thread(s) listed: 4 noise' "$ROOT/dry.out" && echo true || echo false)"
assert_eq "the judge sees only the answered thread and the newsletter" "a1 c1" \
	"$(jq -r '[.threads[].thread_id] | sort | join(" ")' "$J_INBOX_COPY")"
assert_eq "the answered one is marked as answered by the user" "true" \
	"$(jq -r '.threads[] | select(.thread_id == "a1") | .answered_by_user' "$J_INBOX_COPY")"
assert_true "dry_run: W made no call" "$([ ! -e "$W_PINS_COPY" ] && echo true || echo false)"
assert_true "dry_run: the log says what it would have done" \
	"$(grep -q 'W: dry_run — logged 0 id(s) to mark read and 4 to trash, no model call made' "$ROOT/dry.out" && echo true || echo false)"
assert_true "the judge's offer keeps only the candidates it named" \
	"$(grep -q 'judge J: offers 2 mail thread(s) as no longer useful' "$ROOT/dry.out" && echo true || echo false)"

echo
echo "=== live: W trashes exactly the noise and nothing else, pinned per tool ==="
cfg false
DESK_CONFIG="$ROOT/instance/config.json" "$DESK_RUN" live > "$ROOT/live.out" 2>&1
assert_eq "the live pass exits ok" "0" "$?"
assert_eq "the trash tool is pinned to the noise" "d1 n1 n2 n4" \
	"$(jq -r --arg t "$TRASH" '[.[$t][].threadId] | sort | join(" ")' "$W_PINS_COPY")"
assert_eq "the unlabel tool is pinned to the opened digests (none here)" "0" \
	"$(jq --arg u "$UNLABEL" '.[$u] | length' "$W_PINS_COPY")"
assert_true "no protected or offered thread is pinned anywhere" \
	"$(jq -e '[.. | .threadId? // empty] | any(. == "n3" or . == "n5" or . == "p1" or . == "x1" or . == "a1" or . == "c1") | not' "$W_PINS_COPY" > /dev/null && echo true || echo false)"
rm -f "$W_PINS_COPY"

echo
echo "=== live: a call that trashes fewer than it was pinned fails the pass ==="
FAKE_W_MODE=skip-trash DESK_CONFIG="$ROOT/instance/config.json" "$DESK_RUN" short > "$ROOT/short.out" 2>&1
assert_eq "the pass exits non-zero" "1" "$?"
assert_true "the mismatch is named in the log" \
	"$(grep -q 'trashed thread ids don.t match the pinned set (W count mismatch)' "$ROOT/short.out" && echo true || echo false)"

echo
echo "=== live, with no digest search in the pass: W only trashes ==="
rm -f "$W_PINS_COPY"
DESK_CONFIG="$ROOT/instance/config.json" "$DESK_RUN" triage_only > "$ROOT/triage-only.out" 2>&1
assert_eq "the pass exits ok" "0" "$?"
assert_true "the log says there is no digest to mark read" \
	"$(grep -q 'W: no F-private step in this pass, so no digest to mark read' "$ROOT/triage-only.out" && echo true || echo false)"
assert_eq "the trash tool is pinned to the noise" "d1 n1 n2 n4" \
	"$(jq -r --arg t "$TRASH" '[.[$t][].threadId] | sort | join(" ")' "$W_PINS_COPY")"
assert_eq "and the unlabel tool to nothing" "0" "$(jq --arg u "$UNLABEL" '.[$u] | length' "$W_PINS_COPY")"
rm -f "$W_PINS_COPY"

echo
echo "=== offer_outside_inbox: threads outside the inbox become candidates too ==="
cfg true true
rm -f "$J_INBOX_COPY"
DESK_CONFIG="$ROOT/instance/config.json" "$DESK_RUN" outside > "$ROOT/outside.out" 2>&1
assert_eq "the pass exits ok" "0" "$?"
assert_eq "the judge also sees the unread digest outside the inbox; the read one is still noise" "a1 c1 d2" \
	"$(jq -r '[.threads[].thread_id] | sort | join(" ")' "$J_INBOX_COPY")"
assert_eq "each says whether it is in the inbox" "false" \
	"$(jq -r '.threads[] | select(.thread_id == "d2") | .in_inbox' "$J_INBOX_COPY")"
assert_true "the coverage line says these are the listing, not the inbox" \
	"$(jq -r '.coverage' "$J_INBOX_COPY" | grep -q 'the rest of the listing, in the inbox or not' && echo true || echo false)"
assert_true "the protections still hold" \
	"$(grep -q 'protected invitation 1, partial 1, person 1, starred 1' "$ROOT/outside.out" && echo true || echo false)"

echo
echo "=== offer_query: noise from the whole listing, offers only from the offer listing, starred ones offered ==="
cfg true false true
rm -f "$J_INBOX_COPY"
DESK_CONFIG="$ROOT/instance/config.json" "$DESK_RUN" offer > "$ROOT/offer.out" 2>&1
assert_eq "the pass exits ok" "0" "$?"
assert_eq "noise comes from both listings, the starred CI run not among it" \
	"would trash d1 (read digest)|would trash n1 (CI run)|would trash n2 (calendar reply)|would trash n4 (past event notice)|would trash n9 (calendar reply)" \
	"$(grep -o 'would trash [a-z0-9]* ([^)]*)' "$ROOT/offer.out" | sort | paste -sd'|' -)"
assert_eq "noise goes newest first across both listings, the listing's order breaking ties" "n9 n1 n2 n4 d1" \
	"$(grep -o 'would trash [a-z0-9]*' "$ROOT/offer.out" | awk '{print $3}' | paste -sd' ' -)"
assert_eq "the judge sees only what the offer listing listed, the archived unread mail included" "a1 c1 o1 s1" \
	"$(jq -r '[.threads[].thread_id] | sort | join(" ")' "$J_INBOX_COPY")"
assert_eq "a starred one is offered marked starred, the rest not" "s1" \
	"$(jq -r '[.threads[] | select(.starred) | .thread_id] | join(" ")' "$J_INBOX_COPY")"
assert_true "a starred thread outside the offer listing stays protected, and the person's mail outside it is left alone" \
	"$(grep -q 'protected invitation 1, partial 1, starred 1$' "$ROOT/offer.out" && echo true || echo false)"
assert_true "the coverage line names the offer listing and the starred flag" \
	"$(jq -r '.coverage' "$J_INBOX_COPY" | grep -q 'what in:inbox OR is:unread lists, in the inbox or not.*a starred one says so' && echo true || echo false)"

echo
echo "=== a write step with only the trash tool marks nothing read and only trashes ==="
cfg false false false trash-only
rm -f "$W_PINS_COPY"
DESK_CONFIG="$ROOT/instance/config.json" "$DESK_RUN" trashonly > "$ROOT/trash-only.out" 2>&1
assert_eq "the pass exits ok" "0" "$?"
assert_true "the log says it marks none read" \
	"$(grep -q 'W: no tool to mark digests read among its tools, so it marks none read' "$ROOT/trash-only.out" && echo true || echo false)"
assert_eq "only the trash tool is pinned, to the noise" "$TRASH:d1 n1 n2 n4" \
	"$(jq -r 'to_entries | map("\(.key):\([.value[].threadId] | sort | join(" "))") | join("|")' "$W_PINS_COPY")"
rm -f "$W_PINS_COPY"

echo
echo "=== a digest rule: a digest is trashed only once read, by the user or by this run's digest fetch ==="
# dg_read is read already; dg_in the digest fetch returned and opened;
# dg_skip it returned and did not open; dg_late landed after it, so it
# never saw it; dg_nolabel came without labels, so whether it is read is
# unknown; dg_two has two messages, and the read it got held one. The
# listing stays the same on the second pass, as Gmail's would for the
# digests still there.
D1="$(if [ "$(uname)" = Linux ]; then date -u -d '2026-10-20 12:00' +%s; else date -u -j -f '%Y-%m-%d %H:%M' '2026-10-20 12:00' +%s; fi)"
D2=$((D1 + 86400))
dmsg() { # id date labels(json, or none) [messages]
	jq -cn --arg id "$1" --arg d "$2" --arg l "$3" --argjson n "${4:-1}" '
		({sender: "digest@news.example", subject: "The daily digest", date: $d, snippet: "digest"}
		 + (if $l == "none" then {} else {labelIds: ($l | fromjson)} end)) as $m
		| {id: $id, messageCount: $n, messages: [range($n) | $m]}'
}
PAGE2_DIG="$ROOT/page2-digest.json"
jq -cn --argjson t "$(printf '%s\n' "$(dmsg dg_read 2026-10-19T07:00:00Z '["Label_9"]')" \
	"$(dmsg dg_in 2026-10-19T08:00:00Z '["UNREAD","Label_9"]')" "$(dmsg dg_skip 2026-10-19T09:00:00Z '["UNREAD","Label_9"]')" \
	"$(dmsg dg_late 2026-10-20T12:30:00Z '["UNREAD","Label_9"]')" "$(dmsg dg_nolabel 2026-10-19T06:00:00Z none)" \
	"$(dmsg dg_two 2026-10-19T05:00:00Z '["UNREAD","Label_9"]' 2)" | jq -s .)" '{threads: $t}' > "$PAGE2_DIG"
cfg false false false trash-only true
digest_run() { # pass now
	rm -f "$W_PINS_COPY"
	DESK_NOW="$2" PAGE2="$PAGE2_DIG" DESK_CONFIG="$ROOT/instance/config.json" "$DESK_RUN" "$1" > "$ROOT/$1-$2.out" 2>&1
}
trashed() { jq -r --arg t "$TRASH" '[(.[$t] // [])[].threadId] | sort | join(" ")' "$W_PINS_COPY" 2> /dev/null; }
SEARCHED='{"threads":[{"id":"dg_in"},{"id":"dg_skip"},{"id":"dg_two"}]}'
FAKE_DIGEST_RESULT="$SEARCHED" FAKE_OPEN="dg_in dg_two" digest_run digestok "$D1"
assert_eq "the fetch whole: the read digest and the one it opened go; the unread, unlabelled and half-read ones stay, the broader rule above notwithstanding" \
	"dg_in dg_read n1 n2 n4" "$(trashed)"
assert_true "the half-read and unlabelled ones are held too" \
	"$(grep -q 'W: holding dg_two' "$ROOT/digestok-$D1.out" && grep -q 'W: holding dg_nolabel' "$ROOT/digestok-$D1.out" && echo true || echo false)"
assert_true "each one held is logged as unread and why" \
	"$(grep -q 'W: holding dg_skip (The daily digest) — an unread digest, and F-private did not open it' "$ROOT/digestok-$D1.out" \
		&& grep -q 'W: holding dg_late (The daily digest) — an unread digest, and F-private did not open it' "$ROOT/digestok-$D1.out" && echo true || echo false)"
FAKE_DIGEST_RESULT='{}' digest_run digestok "$D2"
assert_eq "the next pass: the late and skipped digests, unread and now dated before its window, still stay" \
	"dg_read n1 n2 n4" "$(trashed)"
FAKE_FPRIVATE=fail FAKE_DIGEST_RESULT="$SEARCHED" FAKE_OPEN="dg_in" digest_run digestfail "$D1"
assert_eq "the digest fetch failed: only the read digest goes, even the one it opened stays" \
	"dg_read n1 n2 n4" "$(trashed)"
assert_true "logged as held because the fetch failed" \
	"$(grep -q 'W: holding dg_in (The daily digest) — an unread digest, and F-private failed this pass' "$ROOT/digestfail-$D1.out" && echo true || echo false)"
FAKE_DIGEST_RESULT="$SEARCHED" digest_run digestfail "$D2"
assert_eq "and on the pass after, with the fetch back but opening nothing, the unread ones still stay" \
	"dg_read n1 n2 n4" "$(trashed)"
assert_eq "the held ones reach the brief by id, in mail-noise.json, all unread ones with nothing opened" "dg_in dg_late dg_nolabel dg_skip dg_two" \
	"$(DESK_NOW="$D2" PAGE2="$PAGE2_DIG" FAKE_DIGEST_RESULT="$SEARCHED" bash -c '
		cfgp="$1"; jq ".passes.digestbrief = (.passes.digestok | .brief = {input_files: [\"notes.md\"], instructions: [\"j.md\"], send: {prompt: \"j.md\"}})" "$cfgp" > "$cfgp.b" && mv -f "$cfgp.b" "$cfgp"
		DESK_CONFIG="$cfgp" "$2" digestbrief > /dev/null 2>&1
		jq -r "[.held_unread[].thread_id] | sort | join(\" \")" "$DESK_RUNS_ROOT/digestbrief-$(date -u -r "$DESK_NOW" +%F 2> /dev/null || date -u -d "@$DESK_NOW" +%F)/mail-noise.json"' _ "$ROOT/instance/config.json" "$DESK_RUN")"
D3=$((D2 + 86400))
assert_eq "and so they do when the trash fails, with no noise listed as trashed" "dg_in dg_late dg_nolabel dg_skip dg_two|0" \
	"$(DESK_NOW="$D3" PAGE2="$PAGE2_DIG" FAKE_W_MODE=skip-trash bash -c '
		DESK_CONFIG="$1" "$2" digestbrief > /dev/null 2>&1
		jq -r "([.held_unread[].thread_id] | sort | join(\" \")) + \"|\" + (.threads | length | tostring)" \
			"$DESK_RUNS_ROOT/digestbrief-$(date -u -r "$DESK_NOW" +%F 2> /dev/null || date -u -d "@$DESK_NOW" +%F)/mail-noise.json"' _ "$ROOT/instance/config.json" "$DESK_RUN")"
rm -f "$W_PINS_COPY"

echo
echo "=== the run status names what the write step does ==="
status_steps() { # pass
	bash -c 'source "$1/common.sh"; for f in status timeout model-call git-ops tool-results validate lock steps mail-triage; do source "$1/$f.sh"; done
		DESK_CONFIG="$2" desk_follow_up_run_status "$3"' _ "$LIB" "$ROOT/instance/config.json" "$1"
}
assert_true "a write step with only the trash tool: trashing automated mail, nothing about marking read" \
	"$(status_steps live | grep -q 'W (mail triage: trashing automated mail)' && echo true || echo false)"
cfg false
assert_true "one that also marks digests read says so" \
	"$(status_steps live | grep -q 'W (mail triage: marking the fetched digests read and trashing automated mail)' && echo true || echo false)"

echo
echo "=== the deny hook: one tool cannot be called with the other's pins ==="
hook="$LIB/deny-unlisted-tool.sh"
pins="$ROOT/pins.json"
jq -n --arg u "$UNLABEL" --arg t "$TRASH" '{($u): [{threadId: "d9", labelIds: ["UNREAD"]}], ($t): [{threadId: "n1"}]}' > "$pins"
call() { jq -nc --arg n "$1" --argjson i "$2" '{tool_name: $n, tool_input: $i}' | bash "$hook" --pinned "$pins" -- "$UNLABEL" "$TRASH" 2> /dev/null; echo $?; }
assert_eq "trash of a pinned noise thread is allowed" "0" "$(call "$TRASH" '{"threadId":"n1"}')"
assert_eq "trash with a digest's pin is denied" "2" "$(call "$TRASH" '{"threadId":"d9","labelIds":["UNREAD"]}')"
assert_eq "trash of an unpinned thread is denied" "2" "$(call "$TRASH" '{"threadId":"d9"}')"
assert_eq "unlabel of a pinned digest is allowed" "0" "$(call "$UNLABEL" '{"threadId":"d9","labelIds":["UNREAD"]}')"

echo
echo "=== the follow-up tab gets the noise, the offer and its settings ==="
# shellcheck source=../../claude/desk-lib/common.sh
source "$LIB/common.sh"
for f in status timeout model-call git-ops tool-results validate lock steps mail-triage; do
	# shellcheck disable=SC1090
	source "$LIB/$f.sh"
done
export DESK_CONFIG="$ROOT/instance/config.json"
PASS_SCRATCH="$ROOT/pass-scratch"
mkdir -p "$PASS_SCRATCH"
echo '{"action":"would_trash","threads":[{"from":"notifications@ci.example","subject":"[org/repo] Run failed: build","rule":"CI run"}],"held_over_cap":0}' > "$PASS_SCRATCH/mail-noise.json"
echo '[{"thread_id":"c1","from":"no-reply@vendor.example","subject":"Your monthly newsletter","why":"old"}]' > "$PASS_SCRATCH/mail-offer.json"
ph="$(desk_follow_up_placeholders live 2026-10-09 "")"
assert_eq "mail_noise carries the would-trash list" "CI run" "$(jq -r '.mail_noise | fromjson | .threads[0].rule' <<< "$ph")"
assert_eq "mail_offer carries the offered thread" "c1" "$(jq -r '.mail_offer | fromjson | .[0].thread_id' <<< "$ph")"
rm -f "$PASS_SCRATCH/mail-noise.json" "$PASS_SCRATCH/mail-offer.json"
ph="$(desk_follow_up_placeholders live 2026-10-09 "")"
assert_eq "with no triage they are empty" '{}|[]' "$(jq -r '.mail_noise + "|" + .mail_offer' <<< "$ph")"
assert_eq "the tab's command carries the configured settings" \
	" --settings '$ROOT/instance/follow-up-settings.json'" "$(desk_follow_up_settings_arg live)"
echo '{}' > "$ROOT/no-settings.json"
assert_eq "no follow_up_settings, no flag" "" "$(DESK_CONFIG="$ROOT/no-settings.json" desk_follow_up_settings_arg live)"
assert_true "the generic summary prompt says to trash only on the user's yes" \
	"$(grep -q 'Never trash a thread without that yes' "$LIB/follow-up-summary.md" && echo true || echo false)"

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
