# The watch pass's diff: one run's fetched tickets and pull requests,
# compared with the snapshots in the watch state, become change lines
# queued per watched session. Called by claude/desk-lib/watch.sh on one
# input object (a file, since these run past what an argument holds) with:
#
#   entries        the watch list: {<session id>: {label, keys, related}}
#   $state          the previous watch state (see watch.sh)
#   $scope_issues   normalized tickets from the scope query, or null when it
#                   did not run this time
#   $change_issues  normalized tickets from the changes query, or null when
#                   that fetch failed
#   $prs            normalized pull requests, or null when that fetch failed
#   $now, $jira_since, $gh_since   epoch seconds; an item first seen with a
#                   creation time after its source's `since` counts as new
#   $baseline_jira, $baseline_gh   true on a source's first run: snapshots
#                   are recorded and nothing is queued
#   $queue_max      the most change lines a session's queue keeps
#
# Prints the new state. Every change it queues is one line of plain text a
# watch session reads; the message around them is built in watch.sh.


.entries as $entries | .state as $state
| .scope_issues as $scope_issues | .change_issues as $change_issues | .prs as $prs
| .now as $now | .jira_since as $jira_since | .gh_since as $gh_since
| .baseline_jira as $baseline_jira | .baseline_gh as $baseline_gh | .queue_max as $queue_max
|

# HTML comments (bots' hidden metadata) are dropped: they carry nothing a
# session reads, and opaque ids are what a copied message gets wrong.
def collapse: gsub("<!--[\\s\\S]*?-->"; "") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
def excerpt($n): collapse | if length > $n then .[0:$n] + "…" else . end;

# Jira and GitHub timestamps (2026-10-07T09:57:40.138+0300, ...Z) to epoch.
def ts:
	if . == null then null
	else try (
		capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") as $c
		| (($c.d + "Z") | fromdateiso8601)
		  - (($c.z // "Z") as $z
		     | if $z == "Z" then 0
		       else ($z | sub(":"; "")) as $zz
		       | (($zz[1:3] | tonumber) * 3600 + ($zz[3:5] | tonumber) * 60)
		         * (if $zz[0:1] == "+" then 1 else -1 end)
		       end)
	) catch null
	end;

def desc_sig: if . == null then null else (length | tostring) + ":" + .[0:200] + "|" + .[-200:] end;

# --- scope -------------------------------------------------------------------

def tracked($e): (($e.keys // []) + ($e.related // [])) | unique;
def all_keys: [$entries[] | (.keys // [])[]] | unique;

# children: {<tracked key>: [child keys]}; links: {<key>: [linked keys]}
def scope_maps:
	($state.scope // {children: {}, links: {}}) as $old
	| (if $scope_issues == null then $old
	   else {
		children: (reduce $scope_issues[] as $i ({};
			if $i.parent != null and (all_keys | index($i.parent)) != null
			then .[$i.parent] += [$i.key] else . end)),
		links: (reduce $scope_issues[] as $i ({}; .[$i.key] = [$i.links[].key]))
	   } end) as $base
	# A new child, or a new link, seen in this run's changes counts at once.
	| reduce ($change_issues // [])[] as $i ($base;
		(if $i.parent != null and (all_keys | index($i.parent)) != null
		 then .children[$i.parent] = ((.children[$i.parent] // []) + [$i.key] | unique) else . end)
		| .links[$i.key] = ([$i.links[].key] | unique));

def scope_of($e; $maps):
	tracked($e) as $t
	| ([($e.keys // [])[] as $k | $maps.children[$k] // [] | .[]]) as $kids
	| ((($e.keys // []) + $kids) | unique) as $roots
	| ($t + $kids + [$roots[] as $r | $maps.links[$r] // [] | .[]]) | unique;

# --- ticket changes -----------------------------------------------------------

def ticket_snapshot($prev):
	{
		summary, status, done, assignee, resolution, parent, labels,
		links: ([.links[] | "\(.rel) \(.key)"] | unique),
		updated
	}
	+ (if .has_desc then {desc_sig: (.desc | desc_sig)} else {desc_sig: $prev.desc_sig} end)
	+ (if .has_comments then {comment_ids: [.comments[].id]}
	   else {comment_ids: $prev.comment_ids} end)
	| with_entries(select(.value != null));

# A linked ticket only seen inside another ticket's links: enough to notice
# its status change later.
def link_seed: {summary, status, done} | with_entries(select(.value != null));

def field_changes($prev):
	. as $i
	| [
		(if ($prev | has("status")) and $prev.status != $i.status
		 then "status \($prev.status) → \($i.status)" else empty end),
		(if ($prev | has("summary")) and $prev.summary != $i.summary
		 then "renamed from \"\($prev.summary)\"" else empty end),
		(if ($prev | has("assignee")) and $prev.assignee != $i.assignee
		 then "assignee \($prev.assignee // "none") → \($i.assignee // "none")"
		 elif ($prev | has("assignee") | not) and ($prev | has("labels")) and $i.assignee != null
		 then "assigned to \($i.assignee)" else empty end),
		(if ($prev | has("resolution")) and $prev.resolution != $i.resolution
		 then "resolution \($prev.resolution // "none") → \($i.resolution // "none")"
		 elif ($prev | has("resolution") | not) and ($prev | has("labels")) and $i.resolution != null
		 then "resolved as \($i.resolution)" else empty end),
		(if ($prev | has("parent")) and $prev.parent != $i.parent
		 then "moved from \($prev.parent // "no parent") to \($i.parent // "no parent")" else empty end),
		(if ($prev | has("labels")) then
			(($i.labels - $prev.labels) | if length > 0 then "labels added: \(join(", "))" else empty end),
			(($prev.labels - $i.labels) | if length > 0 then "labels removed: \(join(", "))" else empty end)
		 else empty end),
		(if ($prev | has("links")) then
			([$i.links[] | "\(.rel) \(.key)"] | unique) as $now_links
			| (($now_links - $prev.links) | if length > 0 then "link added: \(join("; "))" else empty end),
			  (($prev.links - $now_links) | if length > 0 then "link removed: \(join("; "))" else empty end)
		 else empty end),
		(if $i.has_desc and ($prev.desc_sig != null) and $prev.desc_sig != ($i.desc | desc_sig)
		 then "description edited" else empty end)
	];

def comment_changes($prev):
	. as $i
	| if $i.has_comments | not then []
	  else ($prev.comment_ids) as $seen
	  | [ $i.comments[]
	      | . as $c
	      | if $seen != null then
	          if ($seen | index($c.id)) == null then
	            {at: ($c.created | ts), what: "new comment by \($c.author): \"\($c.body | excerpt(500))\""}
	          elif (($c.updated | ts) // 0) > $jira_since and $c.updated != $c.created then
	            {at: ($c.updated | ts), what: "comment by \($c.author) edited: \"\($c.body | excerpt(400))\""}
	          else empty end
	        elif (($c.created | ts) // 0) > $jira_since then
	          {at: ($c.created | ts), what: "new comment by \($c.author): \"\($c.body | excerpt(500))\""}
	        else empty end ]
	  end;

# Each ticket's change lines (empty when nothing moved), keyed by ticket.
def ticket_events:
	($state.tickets // {}) as $snap
	| (($scope_issues // []) + ($change_issues // [])) as $all
	# The changes query's copy of a ticket carries the most fields; it wins.
	| (reduce $all[] as $i ({}; .[$i.key] = ((.[$i.key] // {}) * $i))) as $by_key
	| ([($change_issues // [])[] | .key]) as $moved
	| [ $by_key[] | . as $i
	    | ($snap[$i.key] // null) as $prev
	    | if $baseline_jira then empty
	      # A ticket seen for the first time only through the scope query
	      # has not moved; it is a snapshot, not news.
	      elif $prev == null and ($moved | index($i.key)) == null then empty
	      elif $prev == null then
	        { key: $i.key, title: $i.summary, at: (($i.updated | ts) // $now),
	          what: ((if (($i.created | ts) // 0) > $jira_since then "created" else "first seen by the watcher" end)
	                 + " (\($i.type // "ticket"), \($i.status)\(if $i.assignee then ", " + $i.assignee else "" end))") },
	        ($i | comment_changes({}) | .[] | {key: $i.key, title: $i.summary} + .)
	      else
	        ($i | field_changes($prev)) as $f
	        | (if ($f | length) > 0
	           then {key: $i.key, title: $i.summary, at: (($i.updated | ts) // $now), what: ($f | join("; "))}
	           else empty end),
	          ($i | comment_changes($prev) | .[] | {key: $i.key, title: $i.summary} + .)
	      end ];

def new_ticket_snapshots:
	($state.tickets // {}) as $snap
	| (($scope_issues // []) + ($change_issues // [])) as $all
	| (reduce $all[] as $i ({}; .[$i.key] = ((.[$i.key] // {}) * $i))) as $by_key
	| reduce ($by_key | to_entries[]) as $e ($snap;
		.[$e.key] = ($e.value | ticket_snapshot($snap[$e.key] // {})))
	| reduce ([($scope_issues // [])[] | .links[]] | unique_by(.key))[] as $l (.;
		if has($l.key) then . else .[$l.key] = ($l | link_seed) end);

# --- pull request changes -------------------------------------------------------

def pr_snapshot($prev):
	{ title, state, draft, review, head, labels, body_sig: (.body | desc_sig),
	  failing: .checks.fail, checks_done: (.checks.pending == 0), updated }
	+ (if .comments != null then {seen: ([.comments[].id] + ($prev.seen // []) | unique)}
	   else {seen: $prev.seen} end)
	| with_entries(select(.value != null));

def checks_line:
	"checks: \(.checks.pass) passed"
	+ (if (.checks.fail | length) > 0 then ", \(.checks.fail | length) failed (\(.checks.fail | join(", ")))" else "" end)
	+ (if .checks.pending > 0 then ", \(.checks.pending) still running" else "" end);

def pr_field_changes($prev):
	. as $p
	| [
		(if $prev.state != $p.state then "now \($p.state | ascii_downcase)" else empty end),
		(if ($prev | has("draft")) and $prev.draft != $p.draft
		 then (if $p.draft then "back to draft" else "ready for review" end) else empty end),
		(if ($prev | has("review")) and $prev.review != $p.review
		 then "review decision \($prev.review // "none") → \($p.review // "none")" else empty end),
		(if $prev.title != $p.title then "retitled from \"\($prev.title)\"" else empty end),
		(if ($prev | has("head")) and $prev.head != $p.head
		 then "new commits (head \($prev.head[0:7]) → \($p.head[0:7]))" else empty end),
		(if ($prev | has("labels")) then
			(($p.labels - $prev.labels) | if length > 0 then "labels added: \(join(", "))" else empty end),
			(($prev.labels - $p.labels) | if length > 0 then "labels removed: \(join(", "))" else empty end)
		 else empty end),
		(if ($prev | has("body_sig")) and $prev.body_sig != ($p.body | desc_sig)
		 then "description edited: \"\($p.body | excerpt(600))\"" else empty end),
		# Checks are reported when the failing set changes, or when a run
		# finishes; a check that is merely still running is not movement.
		(if (($prev.failing // []) != $p.checks.fail) or ((($prev.checks_done // true) | not) and $p.checks.pending == 0)
		 then ($p | checks_line) else empty end)
	];

def pr_comment_changes($prev):
	. as $p
	| if $p.comments == null then []
	  else [ $p.comments[] | . as $c
	         | if ($prev.seen // null) != null then
	             (if (($prev.seen | index($c.id)) == null) then . else empty end)
	           elif (($c.at | ts) // 0) > $gh_since then .
	           else empty end
	         | {at: ($c.at | ts),
	            what: (if $c.kind == "review"
	                   then "review by \($c.author): \($c.state | ascii_downcase)\(if ($c.body // "") != "" then ", \"" + ($c.body | excerpt(500)) + "\"" else "" end)"
	                   else "comment by \($c.author): \"\($c.body | excerpt(500))\"" end)} ]
	  end;

def pr_events:
	($state.prs // {}) as $snap
	| [ ($prs // [])[] | . as $p
	    | ($snap[$p.id] // null) as $prev
	    | {key: $p.id, title: $p.title, pr_keys: $p.keys, url: $p.url} as $base
	    | if $baseline_gh then empty
	      elif $prev == null then
	        $base + {at: (($p.updated | ts) // $now),
	                 what: ((if (($p.created | ts) // 0) > $gh_since then "opened" else "first seen by the watcher" end)
	                        + " (\($p.state | ascii_downcase)\(if $p.draft then ", draft" else "" end), branch \($p.branch))")},
	        ($p | pr_comment_changes({}) | .[] | $base + .)
	      else
	        ($p | pr_field_changes($prev)) as $f
	        | (if ($f | length) > 0 then $base + {at: (($p.updated | ts) // $now), what: ($f | join("; "))} else empty end),
	          ($p | pr_comment_changes($prev) | .[] | $base + .)
	      end ];

def new_pr_snapshots:
	($state.prs // {}) as $snap
	| reduce ($prs // [])[] as $p ($snap; .[$p.id] = ($p | pr_snapshot($snap[$p.id] // {})));

# --- attribution and queues --------------------------------------------------

# How a ticket relates to a session's own keys, for the change line: "" for
# a tracked ticket, null for one unrelated to the session.
def relation($e; $maps; $issue):
	tracked($e) as $t
	| if ($t | index($issue.key)) != null then ""
	  elif $issue.parent != null and (($e.keys // []) | index($issue.parent)) != null then "child of \($issue.parent)"
	  else
	    ([($e.keys // [])[] as $k | $maps.children[$k] // [] | .[]]) as $kids
	    | ((($e.keys // []) + $kids) | unique) as $roots
	    | ([$roots[] as $r
	        | select((($maps.links[$r] // []) | index($issue.key)) != null
	                 or ((($issue.links // []) | map(.key)) | index($r)) != null)
	        | $r] | first) as $via
	    | if $via != null then "linked to \($via)"
	      else ([$t[] as $k | select(($issue.text // "") | test("\\b" + $k + "\\b"; "i")) | $k] | first) as $m
	      | if $m != null then "mentions \($m)" else null end
	      end
	  end;

def ticket_index:
	(($scope_issues // []) + ($change_issues // [])) as $all
	| reduce $all[] as $i ({}; .[$i.key] = ((.[$i.key] // {}) * $i
		| .text = ([.summary, .desc, (.comments // [])[].body] | map(select(. != null)) | join("\n"))));

scope_maps as $maps
| ticket_index as $tix
| ticket_events as $tev
| pr_events as $pev
| (if $change_issues == null and $scope_issues == null then ($state.tickets // {}) else new_ticket_snapshots end) as $tickets
| ($state.queues // {}) as $queues
| (reduce ($entries | to_entries[]) as $ent ({};
	$ent.key as $sid | $ent.value as $e
	| scope_of($e; $maps) as $scope
	| ([ $tev[] | . as $ev
	     | relation($e; $maps; ($tix[$ev.key] // {key: $ev.key})) as $rel
	     | select($rel != null)
	     | {at: ($ev.at // $now), ref: $ev.key, title: $ev.title, context: $rel, what: $ev.what} ]
	   + [ $pev[] | . as $ev
	       | ([$ev.pr_keys[] | . as $k | select(($scope | index($k)) != null)]) as $hit
	       | select(($hit | length) > 0)
	       | {at: ($ev.at // $now), ref: ("PR " + ($ev.key | sub("^.*#"; "#"))), title: $ev.title,
	          context: ($hit | join(", ")), what: $ev.what, url: $ev.url} ]) as $new
	| ($queues[$sid] // {changes: [], dropped: 0}) as $q
	| (($q.changes // []) + $new | sort_by(.at)) as $all
	| .[$sid] = ($q + {
		changes: (if ($all | length) > $queue_max then $all[-$queue_max:] else $all end),
		dropped: (($q.dropped // 0) + ([($all | length) - $queue_max, 0] | max)),
		new_this_run: ($new | length),
		scope: $scope })
	| if ($new | length) > 0 and (($q.changes // []) | length) == 0 then .[$sid].queued_since = $now else . end
  )) as $new_queues
| $state
| .scope = ($maps + {refreshed_at: (if $scope_issues != null then $now else ($state.scope.refreshed_at // null) end)})
| .tickets = $tickets
| .prs = (if $prs == null then ($state.prs // {}) else new_pr_snapshots end)
| .queues = $new_queues
# Everything a watch tracks is closed: the seam a later pass reads to
# suggest retiring the watch. The date it was first seen closed is kept.
| .all_closed = (reduce ($entries | to_entries[]) as $ent ({};
	(tracked($ent.value) | map($tickets[.].done // false)) as $done
	| if ($done | length) > 0 and ($done | all)
	  then .[$ent.key] = ($state.all_closed[$ent.key] // $now) else . end))
