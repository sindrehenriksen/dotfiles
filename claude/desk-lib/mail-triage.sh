#!/usr/bin/env bash
# Mail triage (docs/desk.md, "Mail triage"): a fetch step with a
# `mail_triage` key lists the mailbox with one query the instance fixes, and
# the runner, not the model, reads the raw result and sorts every thread:
#
#   noise       every message matches one of the instance's rules for
#               automated mail; the write step trashes these, unattended
#   protected   starred, an invitation for an event not yet past (it may
#               still want a reply), a thread where a person wrote and the
#               user's own message is not the newest, or one the listing
#               showed only part of; never trashed, never offered, except
#               that `offer_starred` offers a starred one
#   candidate   the rest of the inbox (of the whole listing with
#               `offer_outside_inbox`, or of what `offer_query` lists when
#               it is set), handed to the judge as inbox.json; what it
#               lists as no longer useful is only offered to the user,
#               never trashed by the pass
#
# With `offer_query`, the step runs a second listing: `query` can then
# reach the whole mailbox for noise, while only what `offer_query` lists is
# ever offered, so the judge's listing stays the size the instance chose.
#
# Nothing here asks a model which thread is which: every rule is a property
# of the listing. Files, in $PASS_SCRATCH and named after the step:
#   <id>-mail-triage.jsonl   the sorted listing (one JSON object)
set -u

# desk_mail_triage_config <step_json>: the step's `mail_triage` with its
# defaults filled in, or nothing when it has none or no query.
desk_mail_triage_config() {
	jq -c '
		.mail_triage // empty
		| select((.query // "") != "")
		| { query,
		    page_size: (.page_size // 20),
		    trash_tool: (.trash_tool // "mcp__claude_ai_Gmail__trash_thread"),
		    self: ((.self // []) | map(ascii_downcase)),
		    automated_senders: (.automated_senders // [
		        "(^|[._-])(no-?reply|do[._-]?not[._-]?reply|notifications?|mailer-daemon)([+._-][^@]*)?@",
		        "^calendar-notification@google\\.com$"]),
		    invitation_subject: (.invitation_subject // "^(updated )?invitation( with note)?:"),
		    noise: [(.noise // [])[] | select(((.from // "") != "") or ((.subject // "") != ""))],
		    offer_outside_inbox: (.offer_outside_inbox == true),
		    offer_query: (if (.offer_query // "") == "" then null else .offer_query end),
		    offer_starred: (.offer_starred == true),
		    max_trash: (.max_trash // 100),
		    max_offer: (.max_offer // 25) }' <<< "$1" 2> /dev/null
}

# The placeholders the step's prompt gets.
desk_mail_triage_placeholders() {
	jq -c '{mail_triage_query: .query, mail_triage_offer_query: (.offer_query // ""),
		mail_triage_page_size: (.page_size | tostring)}' <<< "$1"
}

# One listed thread to the shape triage works on, given $cfg and $today.
_DESK_MAIL_TRIAGE_SORT='
	def addr: (. // "") | ascii_downcase | ((capture("<(?<a>[^>]+)>") | .a) // .) | gsub("^\\s+|\\s+$"; "");
	def pad2: tostring | if length < 2 then "0" + . else . end;
	def month: ascii_downcase[0:3] as $m
		| ["jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec"] | index($m) | . + 1;
	# The latest date an event subject names after its last " @ " ("@ Fri 9
	# Oct 2026 12:00", "@ Wed Oct 14, 2026 10am"), as YYYY-MM-DD; null for
	# none (a recurring event, or no event at all).
	def event_date:
		(split(" @ ") | if length > 1 then last else null end) as $tail
		| if $tail == null then null else
			[ ($tail | match("\\b([0-9]{1,2}) (jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.? ([0-9]{4})\\b"; "gi")
			     | .captures | {d: .[0].string, m: .[1].string, y: .[2].string}),
			  ($tail | match("\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.? ([0-9]{1,2}),? ([0-9]{4})\\b"; "gi")
			     | .captures | {m: .[0].string, d: .[1].string, y: .[2].string}) ]
			| map("\(.y)-\(.m | month | pad2)-\(.d | pad2)") | max end;
	def rule_ok($r; $t; $m):
		(($r.from // "") == "" or ($m.from | test($r.from; "i")))
		and (($r.subject // "") == "" or ($m.subject | test($r.subject; "i")))
		and ($r.read != true or ($t.unread | not))
		and ($r.past_event != true or (($m.subject | event_date) as $d | $d != null and $d < $today));
	def automated($m): any($cfg.automated_senders[]; . as $p | $m.from | test($p; "i"));
	def is_self($m): ($cfg.self | index($m.from)) != null;
	{ id, offered: (.offered != false),
	  partial: ((.messageCount // null) != null and (.messageCount > ((.messages // []) | length))),
	  view_url: (.viewUrl // null),
	  message_count: ([.messageCount // 0, ((.messages // []) | length)] | max),
	  messages: [(.messages // [])[] | {from: (.sender | addr), subject: (.subject // ""),
	      date: (.date // null), labels: (.labelIds // []),
	      labelled: ((.labelIds | type) == "array" and (.labelIds | length) > 0), snippet: (.snippet // "")}] }
	| select(.id != null and (.messages | length) > 0)
	| ([.messages[].labels[]] | unique) as $labels
	| . + { subject: .messages[0].subject,
	        unread: ($labels | index("UNREAD") != null),
	        # Read only when every message carries labels and none is UNREAD:
	        # a message listed without them may be unread.
	        read: (all(.messages[]; .labelled) and ($labels | index("UNREAD") == null)),
	        starred: ($labels | index("STARRED") != null),
	        in_inbox: ($labels | index("INBOX") != null) }
	| . as $t
	| (first($cfg.noise[] | . as $r | select(all($t.messages[]; rule_ok($r; $t; .))) | .name // .subject // .from) // null) as $rule
	# Any digest rule matching, whichever rule matched first, so a broader
	# rule above one never trashes a digest unread.
	| any($cfg.noise[] | select(.digest == true); . as $r | all($t.messages[]; rule_ok($r; $t; .))) as $digest
	| (any($t.messages[]; (.subject | test($cfg.invitation_subject; "i"))
	       and ((.subject | event_date) as $d | $d == null or $d >= $today))) as $awaiting
	| (any($t.messages[]; (is_self(.) | not) and (automated(.) | not))
	   and (is_self($t.messages[-1]) | not)) as $person
	| . + { class: (if $t.partial then "partial"
	                elif $awaiting then "invitation"
	                elif $t.starred and (($cfg.offer_starred | not) or ($t.offered | not) or $person) then "starred"
	                elif $t.starred then "candidate"
	                elif $rule != null then "noise"
	                elif ($t.offered | not) then "outside"
	                elif $cfg.offer_query == null and ($t.in_inbox | not) and ($cfg.offer_outside_inbox | not) then "outside"
	                elif $person then "person"
	                else "candidate" end),
	        rule: $rule, digest: $digest,
	        answered_by_user: is_self($t.messages[-1]) }'

# desk_mail_triage_collect <pass> <id> <cfg> <search_tool> <today>
# After the call: every thread the results of the calls whose query is
# exactly the configured one (or the configured offer_query) listed (a saved oversized page read back from
# the call's spill directory), sorted, written as <id>-mail-triage.jsonl.
# Non-zero, failing the step as a source, when no page of that query came
# back or one could not be read: nothing is trashed on a listing that did
# not happen. A listing cut short (a last page that names a next one) is
# still sorted, since each thread is decided on its own, and says so.
desk_mail_triage_collect() {
	local pass="$1" id="$2" cfg="$3" tool="$4" today="$5" out="$PASS_SCRATCH/$id-mail-triage.jsonl"
	_desk_follow_resolve_spills "$PASS_SCRATCH/$id-tool-results.jsonl" "$PASS_SCRATCH/$id-spill" \
		> "$PASS_SCRATCH/$id-mail-triage-results.json" 2> /dev/null
	local pairs listing
	pairs="$(desk_tool_call_pairs "$PASS_SCRATCH/$id-tool-uses.jsonl" "$PASS_SCRATCH/$id-mail-triage-results.json" "$tool")"
	rm -f "$PASS_SCRATCH/$id-mail-triage-results.json"
	listing="$(jq -c --argjson cfg "$cfg" --arg today "$today" "
		def pages(\$q): [.[] | select(.input.query == \$q) | .text | (try fromjson catch null)];
		def unread(\$p): (\$p | length) == 0 or any(\$p[]; type != \"object\" or ((.threads // []) | type) != \"array\");
		def whole(\$p): (\$p | last | .nextPageToken // \"\") == \"\";
		pages(\$cfg.query) as \$pages
		| (if \$cfg.offer_query == null then null else pages(\$cfg.offer_query) end) as \$offer
		| if unread(\$pages) or (\$offer != null and unread(\$offer)) then null
		  else ([(\$offer // [])[] | (.threads // [])[] | .id]) as \$offered
		  | { complete: (whole(\$pages) and (\$offer == null or whole(\$offer))),
		      pages: ((\$pages + (\$offer // [])) | length),
		      threads: ([\$pages[], (\$offer // [])[] | (.threads // [])[]]
		                | reduce .[] as \$t ({seen: {}, out: []};
		                    if .seen[\$t.id | tostring] then . else .seen[\$t.id | tostring] = true | .out += [\$t] end)
		                | .out
		                | map(. + {offered: (\$offer == null or (.id as \$i | \$offered | index(\$i)) != null)})
		                | map($_DESK_MAIL_TRIAGE_SORT)) } end" \
		<<< "$pairs" 2> /dev/null)"
	if [ -z "$listing" ] || [ "$listing" = "null" ]; then
		desk_log "$pass" "$id: mail triage: the listing query did not come back, or a page could not be read — nothing sorted"
		desk_run_note "$id's mailbox listing did not come back, so no mail was sorted or trashed this pass."
		return 1
	fi
	jq -c --argjson cfg "$cfg" '
		.threads as $t
		| ([$t | to_entries[] | select(.value.class == "noise")]
		   | sort_by([(.value.messages[-1].date // ""), -.key]) | reverse | map(.value)) as $noise
		| { query: $cfg.query, offer_query: $cfg.offer_query, complete, pages, listed: ($t | length),
		    outside_offered: $cfg.offer_outside_inbox,
		    noise: [$noise[:$cfg.max_trash][] | {id, from: .messages[-1].from, subject, date: .messages[-1].date, unread, read, digest, message_count, rule}],
		    noise_held: ([$noise[$cfg.max_trash:][]] | length),
		    protected: ([$t[] | select(.class | IN("starred", "partial", "invitation", "person")) | .class]
		                | group_by(.) | map({(.[0]): length}) | add // {}),
		    outside: ([$t[] | select(.class == "outside")] | length),
		    candidates: [$t[] | select(.class == "candidate")
		        | { thread_id: .id, from: .messages[-1].from,
		            senders: ([.messages[].from] | unique), subject,
		            date: .messages[-1].date, messages: (.messages | length), unread,
		            in_inbox, starred, answered_by_user,
		            snippet: (.messages[-1].snippet | if length > 200 then .[0:200] + " …" else . end) }] }' \
		<<< "$listing" > "$out"
	desk_log "$pass" "$id: mail triage: $(jq -r '"\(.listed) thread(s) listed\(if .complete then "" else " (cut short: a last page named another)" end): \(.noise | length) noise\(if .noise_held > 0 then " (+\(.noise_held) over max_trash)" else "" end), \(.candidates | length) for the judge, protected \(.protected | to_entries | map("\(.key) \(.value)") | join(", ") | if . == "" then "none" else . end)"' "$out")"
	while IFS=$'\t' read -r tid from subj rule; do
		[ -n "$tid" ] && desk_log "$pass" "$id: mail triage: noise ($rule): $tid from $from: $subj"
	done < <(jq -r '.noise[] | [.id, .from, .subject, .rule] | @tsv' "$out")
	if [ "$(jq -r '.complete' "$out")" != "true" ]; then
		desk_run_note "$id's mailbox listing was cut short, so only the threads it listed were sorted; the rest wait for the next pass."
	fi
	return 0
}

# desk_mail_triage_file <pass_scratch> <pass_config>: the sorted listing of
# the pass's mail triage step, or nothing when it has none or never wrote one.
desk_mail_triage_file() {
	local scratch="$1" pass_config="$2" id
	id="$(jq -r '[(.steps // [])[] | select(.kind == "fetch" and .mail_triage)][0].id // empty' <<< "$pass_config")"
	[ -n "$id" ] && [ -s "$scratch/$id-mail-triage.jsonl" ] && printf '%s' "$scratch/$id-mail-triage.jsonl"
}

# desk_mail_triage_judge_file <triage file> <dest>: what the judge reads as
# inbox.json: the candidates only, with a line on coverage.
desk_mail_triage_judge_file() {
	jq '{ coverage: ("\(.listed) thread(s) listed\(if .complete then "" else ", the listing cut short" end); "
	                 + "\(.noise | length) automated one(s) trashed by rule and the protected ones left out, so these are the rest of "
	                 + (if .offer_query then "what \(.offer_query) lists, in the inbox or not (in_inbox says which)"
	                    elif .outside_offered then "the listing, in the inbox or not (in_inbox says which)" else "the inbox" end)
	                 + (if any(.candidates[]; .starred) then "; a starred one says so (starred), and is never trashed by rule" else "" end)),
	      threads: .candidates }' "$1" > "$2"
}

# desk_mail_triage_offer <judge reply text> <triage file> <max_offer>
# The judge's `mail_cleanup` kept only where it names a candidate, each
# once, at most max_offer, with the listing's own sender and subject beside
# its one-line reason (control characters out, cut at 140). Printed as a
# JSON array, `[]` when there is none or nothing valid.
desk_mail_triage_offer() {
	local reply="$1" triage="$2" max="$3"
	jq -c --slurpfile t "$triage" --argjson max "$max" '
		($t[0].candidates | map({(.thread_id): .}) | add // {}) as $c
		| [ (if type == "object" then (.mail_cleanup // []) else [] end)[]
		    | select(type == "object" and (.thread_id | type) == "string" and $c[.thread_id] != null) ]
		| unique_by(.thread_id)[:$max]
		| map($c[.thread_id] as $x
		      | { thread_id, from: $x.from, subject: $x.subject, date: $x.date,
		          why: ((.why // "") | tostring | gsub("[\\u0000-\\u001f\\u007f]"; " ")
		                | if length > 140 then .[0:140] + " …" else . end) })' <<< "$reply" 2> /dev/null || echo '[]'
}
