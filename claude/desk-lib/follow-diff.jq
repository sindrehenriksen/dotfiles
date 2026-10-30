# The follow pass's diff: one run's fetched tickets and pull requests,
# compared with the snapshots in the follow state, become change lines
# queued per followed session. Called by claude/desk-lib/follow.sh on one
# input object (a file, since these run past what an argument holds) with:
#
#   entries        the follow list: {<session id>: {label, keys, related}}
#   $state          the previous follow state (see follow.sh)
#   $scope_issues   normalized tickets from the scope query, or null when it
#                   did not run this time
#   $change_issues  normalized tickets from the changes query, or null when
#                   that fetch failed
#   $prs            normalized pull requests, or null when that fetch failed
#   seed_prs        the open PRs of a repo just followed: snapshotted only
#   runs            the followed repos' failed CI runs (follow.sh's
#                   desk_follow_fetch_runs), or null when that fetch failed
#   follow_repos    {<repo, lowercased>: {default_branch}} for the followed
#                   repos, kept in the state as it is
#   $now, $jira_since, $gh_since   epoch seconds; an item first seen with a
#                   creation time after its source's `since` counts as new
#   $baseline_jira, $baseline_gh   true on a source's first run: snapshots
#                   are recorded and nothing is queued
#   $queue_max      the most change lines a session's queue keeps
#   skip            {bot_authors, bot_signatures}: regexes for an automated
#                   account's name, and for the opening of a post a bot makes
#                   through a person's account
#   self            the user's names and logins: the user's own posts, a
#                   ticket the user created in the window, and a PR the user
#                   opened in the window that only the user committed to are
#                   counted, not sent; on an older PR of the user's, only its
#                   state moves are
#   own_check       "off" (no changelog read: a ticket the user created in
#                   the window is counted on its creator alone), "pending"
#                   (the first diff of a run that reads changelogs: such a
#                   ticket is forwarded and marked for the read) or "done"
#   own_field_moves with "done", {<ticket key>: "own" | "clean"} from the
#                   changelog read: "own" when every entry in the window is
#                   the user's, "clean" when there is none. Field moves count
#                   as the user's only on "own"; a ticket the user created
#                   in the window on either
#   lookback        true for a --lookback-minutes run with no snapshots to
#                   compare against
#
# Only substantive changes are queued: new human content, a change to scope
# or plan, a ticket or PR new to the follow; and for a session following a
# whole repo (an entry's `repos`), that repo's merges and failed CI runs.
# The rest (a status or state move with nothing else, a bot's post or PR,
# labels, check results, a ticket only first seen) is counted per kind in
# the queue's `skipped`, which the message's footer reports.
#
# Prints the new state. Every change it queues is one line of plain text a
# follow session reads; the message around them is built in follow.sh.


.entries as $entries | .state as $state
| .scope_issues as $scope_issues | .change_issues as $change_issues | .prs as $prs
| .now as $now | .jira_since as $jira_since | .gh_since as $gh_since
| .baseline_jira as $baseline_jira | .baseline_gh as $baseline_gh | .queue_max as $queue_max
| (.skip.bot_authors // []) as $bot_authors | (.skip.bot_signatures // []) as $bot_signatures
| (.lookback // false) as $lookback
| (.self // []) as $self
| (.seed_prs // []) as $seed_prs | .runs as $runs | (.follow_repos // {}) as $follow_repos
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

# A post is a bot's when its author matches a bot account, or when it opens
# with a bot's signature (a bot posting through a person's account). A
# person quoting bot output further down is still a person.
def is_bot($author; $body):
	(($author // "") as $a | any($bot_authors[]; . as $re | $a | test($re; "i")))
	or (($body // "") | sub("^\\s+"; "") as $b | any($bot_signatures[]; . as $re | $b | test($re)));

def is_self($who): ($who // "") as $w | any($self[]; ascii_downcase == ($w | ascii_downcase));

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

# A session's own tickets: its keys and their children. Its related keys
# and links are not its own.
def own_of($e; $maps):
	(($e.keys // []) + [($e.keys // [])[] as $k | $maps.children[$k] // [] | .[]]) | unique;

# What the other followed sessions own, as {keys, own}: keys alone too, so
# a ticket the children map has not seen yet still counts by its parent.
def claimed_elsewhere($sid; $maps):
	[$entries | to_entries[] | select(.key != $sid) | .value] as $others
	| {keys: ([$others[] | (.keys // [])[]] | unique),
	   own: ([$others[] | own_of(.; $maps)[]] | unique)};

def is_claimed($claimed; $key; $parent):
	($claimed.own | index($key)) != null
	or ($parent != null and ($claimed.keys | index($parent)) != null);

# A link one hop out can land on another followed session's own ticket;
# that one is left to the session it belongs to.
# Whether a session has a ticket: as one of its keys or related keys, or as
# a child of a key (by its parent too, as is_claimed counts it).
def has_ticket($e; $maps; $key; $parent):
	((tracked($e) + own_of($e; $maps)) | index($key)) != null
	or ($parent != null and (($e.keys // []) | index($parent)) != null);

# The other followed sessions that also have a change's ticket, or for a
# PR any of its keys: the receiving session is then not alone with it.
def also_having($sid; $maps; $keys; $parent):
	[$entries | to_entries[] | select(.key != $sid) | .key as $o | .value as $e
	 | select(any($keys[]; has_ticket($e; $maps; .; $parent))) | $o];

def scope_of($e; $maps; $claimed):
	tracked($e) as $t
	| own_of($e; $maps) as $roots
	| ($t + $roots
	   + [$roots[] as $r | $maps.links[$r] // [] | .[] | . as $l | select(($claimed.own | index($l)) == null)])
	| unique;

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

# Each change as {text, skip}: skip names the kind a skipped change is
# counted under, null for a substantive one.
def field_changes($prev):
	. as $i
	| [
		(if ($prev | has("status")) and $prev.status != $i.status
		 then {text: "status \($prev.status) → \($i.status)", skip: "status moves"} else empty end),
		(if ($prev | has("summary")) and $prev.summary != $i.summary
		 then {text: "renamed from \"\($prev.summary)\"", skip: null} else empty end),
		(if ($prev | has("assignee")) and $prev.assignee != $i.assignee
		 then {text: "assignee \($prev.assignee // "none") → \($i.assignee // "none")", skip: null}
		 elif ($prev | has("assignee") | not) and ($prev | has("labels")) and $i.assignee != null
		 then {text: "assigned to \($i.assignee)", skip: null} else empty end),
		(if ($prev | has("resolution")) and $prev.resolution != $i.resolution
		 then {text: "resolution \($prev.resolution // "none") → \($i.resolution // "none")", skip: "status moves"}
		 elif ($prev | has("resolution") | not) and ($prev | has("labels")) and $i.resolution != null
		 then {text: "resolved as \($i.resolution)", skip: "status moves"} else empty end),
		(if ($prev | has("parent")) and $prev.parent != $i.parent
		 then {text: "moved from \($prev.parent // "no parent") to \($i.parent // "no parent")", skip: null} else empty end),
		(if ($prev | has("labels")) then
			(($i.labels - $prev.labels) | if length > 0 then {text: "labels added: \(join(", "))", skip: "label changes"} else empty end),
			(($prev.labels - $i.labels) | if length > 0 then {text: "labels removed: \(join(", "))", skip: "label changes"} else empty end)
		 else empty end),
		(if ($prev | has("links")) then
			([$i.links[] | "\(.rel) \(.key)"] | unique) as $now_links
			| (($now_links - $prev.links) | if length > 0 then {text: "link added: \(join("; "))", skip: null} else empty end),
			  (($prev.links - $now_links) | if length > 0 then {text: "link removed: \(join("; "))", skip: null} else empty end)
		 else empty end),
		(if $i.has_desc and ($prev.desc_sig != null) and $prev.desc_sig != ($i.desc | desc_sig)
		 then {text: "description edited", skip: null} else empty end)
	];

# One event for a ticket's or PR's field changes: substantive when any
# change is, carrying every change's text; otherwise skipped under the
# first change's kind.
def field_event($f):
	if ($f | length) == 0 then empty
	elif any($f[]; .skip == null) then {what: ([$f[].text] | join("; ")), skip: null}
	else {what: ([$f[].text] | join("; ")), skip: $f[0].skip} end;

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
	        else empty end
	      | . + {author: $c.author, skip: (if is_bot($c.author; $c.body) then "bot comments" else null end)} ]
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
	        # A ticket new to the follow: created in the window, or under a
	        # tracked key (a new child), is news. One only first seen, with
	        # no snapshot to compare (a mention, a lookback run), is counted:
	        # what moved on it shows as its comments.
	        ((($i.created | ts) // 0) > $jira_since) as $created
	        | { key: $i.key, title: $i.summary, at: (($i.updated | ts) // $now), creator: (if $created then $i.creator else null end),
	            skip: (if $created or (($i.parent != null) and (all_keys | index($i.parent)) != null and ($lookback | not))
	                   then null else "first-seen tickets" end),
	            what: ((if $created then "created" else "new under the follow" end)
	                   + " (\($i.type // "ticket"), \($i.status)\(if $i.assignee then ", " + $i.assignee else "" end))") },
	          ($i | comment_changes({}) | .[] | {key: $i.key, title: $i.summary} + .)
	      else
	        (($i | field_changes($prev)) as $f | field_event($f)
	         | {key: $i.key, title: $i.summary, at: (($i.updated | ts) // $now), field: true} + .),
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
	{ title, state, draft, review, requested, assignees, head, labels, body_sig: (.body | desc_sig), branch, author, url,
	  failing: .checks.fail, checks_done: (.checks.pending == 0), updated }
	+ (if .comments != null then {seen: ([.comments[].id] + ($prev.seen // []) | unique)}
	   else {seen: $prev.seen} end)
	| with_entries(select(.value != null));

def checks_line:
	"checks: \(.checks.pass) passed"
	+ (if (.checks.fail | length) > 0 then ", \(.checks.fail | length) failed (\(.checks.fail | join(", ")))" else "" end)
	+ (if .checks.pending > 0 then ", \(.checks.pending) still running" else "" end);

def asks_user: is_self(.) or startswith("team ");
def asks_text($what; $kind):
	{text: "\($what) \(if is_self(.) then "the user (\(.))" else . end)", skip: (if asks_user then null else $kind end)};

def pr_field_changes($prev):
	. as $p
	| [
		(if $prev.state != $p.state then {kind: (if $p.state == "MERGED" then "merged" else "state" end), text: "now \($p.state | ascii_downcase)", skip: "PR state changes"} else empty end),
		(if ($prev | has("draft")) and $prev.draft != $p.draft
		 then {kind: (if $p.draft then "draft" else "ready" end), text: (if $p.draft then "back to draft" else "ready for review" end), skip: "PR state changes"} else empty end),
		(if ($prev | has("review")) and $prev.review != $p.review
		 then {text: "review decision \($prev.review // "none") → \($p.review // "none")", skip: "PR state changes"} else empty end),
		# A review request (a re-request after a review too, since a review
		# clears it) or an assignment naming the user waits on them, as does
		# one to a team, whose members the listing does not say; one naming
		# someone else is counted.
		(if ($prev | has("requested")) then
			(($p.requested - $prev.requested)[] | asks_text("review requested from"; "review requests")),
			(($prev.requested - $p.requested) | if length > 0 then {text: "review request removed: \(join(", "))", skip: "review requests"} else empty end)
		 else empty end),
		(if ($prev | has("assignees")) then
			(($p.assignees - $prev.assignees)[] | asks_text("assigned to"; "PR assignee changes")),
			(($prev.assignees - $p.assignees) | if length > 0 then {text: "unassigned: \(join(", "))", skip: "PR assignee changes"} else empty end)
		 else empty end),
		(if $prev.title != $p.title then {kind: "update", text: "retitled from \"\($prev.title)\"", skip: null} else empty end),
		(if ($prev | has("head")) and $prev.head != $p.head
		 then {kind: "update", text: "new commits (head \($prev.head[0:7]) → \($p.head[0:7]))", skip: null} else empty end),
		(if ($prev | has("labels")) then
			(($p.labels - $prev.labels) | if length > 0 then {text: "labels added: \(join(", "))", skip: "label changes"} else empty end),
			(($prev.labels - $p.labels) | if length > 0 then {text: "labels removed: \(join(", "))", skip: "label changes"} else empty end)
		 else empty end),
		(if ($prev | has("body_sig")) and $prev.body_sig != ($p.body | desc_sig)
		 then {kind: "update", text: "description edited: \"\($p.body | excerpt(600))\"", skip: null} else empty end),
		# Checks are reported when the failing set changes, or when a run
		# finishes; a check that is merely still running is not movement.
		(if (($prev.failing // []) != $p.checks.fail) or ((($prev.checks_done // true) | not) and $p.checks.pending == 0)
		 then {text: ($p | checks_line), skip: "check results"} else empty end)
	];

def pr_comment_changes($prev):
	. as $p
	| if $p.comments == null then []
	  else [ $p.comments[] | . as $c
	         | if ($prev.seen // null) != null then
	             (if (($prev.seen | index($c.id)) == null) then . else empty end)
	           elif (($c.at | ts) // 0) > $gh_since then .
	           else empty end
	         | {at: ($c.at | ts), author: $c.author,
	            skip: (if is_bot($c.author; $c.body) then (if $c.kind == "review" then "bot reviews" else "bot comments" end) else null end),
	            what: (if $c.kind == "review"
	                   then "review by \($c.author): \($c.state | ascii_downcase)\(if ($c.body // "") != "" then ", \"" + ($c.body | excerpt(500)) + "\"" else "" end)"
	                   else "comment by \($c.author): \"\($c.body | excerpt(500))\"" end)} ]
	  end;

def pr_events:
	($state.prs // {}) as $snap
	| [ ($prs // [])[] | . as $p
	    | ($snap[$p.id] // null) as $prev
	    | {key: $p.id, title: $p.title, pr_keys: $p.keys, url: $p.url, pr_author: ($p.author // null), repo: ($p.repo // ($p.id | sub("#[0-9]+$"; "")))} as $base
	    | if $baseline_gh then empty
	      elif $prev == null then
	        # A PR opened in the window is news; one only first seen (it
	        # was already open when it came into scope) is counted.
	        # One that already asks the user for a review is forwarded with it;
	        # one a bot opened is counted.
	        ((($p.created | ts) // 0) > $gh_since) as $opened
	        | ([($p.requested // [])[] | select(asks_user) | asks_text("review requested from"; null).text]
	           + [($p.assignees // [])[] | select(is_self(.)) | asks_text("assigned to"; null).text]) as $asks
	        | $base + {at: (($p.updated | ts) // $now),
	                   skip: (if ($asks | length) > 0 then null elif $opened and is_bot($p.author; "") then "bot PRs"
	                          elif $opened then null else "first-seen PRs" end),
	                   opened: $opened, commits: $p.commits,
	                   what: ((if $opened then "opened" else "new under the follow" end)
	                          + " (\($p.state | ascii_downcase)\(if $p.draft then ", draft" else "" end), branch \($p.branch))"
	                          + ($asks | map("; " + .) | join("")))},
	          ($p | pr_comment_changes({}) | .[] | $base + .)
	      else
	        (($p | pr_field_changes($prev)) as $f
	         | field_event($f) | $base + {at: (($p.updated | ts) // $now), kinds: [$f[].kind // empty]} + .),
	          ($p | pr_comment_changes($prev) | .[] | $base + .)
	      end
	    # How a session following the PR's whole repo counts it: a merge is
	    # news there, unless a bot opened the PR.
	    | .repo_skip = (if ((.kinds // []) | index("merged")) == null then .skip
	                    elif is_bot(.pr_author; "") then "bot PRs" else null end) ];

def new_pr_snapshots:
	($state.prs // {}) as $snap
	| reduce ($seed_prs[] | select($snap[.id] == null)) as $p ($snap; .[$p.id] = ($p | pr_snapshot({})))
	| reduce ($prs // [])[] as $p (.; .[$p.id] = ($p | pr_snapshot($snap[$p.id] // {})));

# --- CI runs in followed repos ---------------------------------------------------

def follows_repo($e; $repo): ($repo | ascii_downcase) as $r | any(($e.repos // [])[]; ascii_downcase == $r);

# A failed run that ended in the window and was not seen before: on the
# repo's default branch, or on an open PR's branch, under that PR (by the
# snapshots, so a PR open before the follow counts). Another branch's is
# left out; one on a PR a bot opened is counted.
def run_events($snaps):
	($state.runs_seen // []) as $seen
	| if $runs == null or $baseline_gh then []
	  else [ $runs[] | . as $r
	         | select(($seen | index($r.id)) == null and ((($r.ended | ts) // 0) > $gh_since))
	         | ($r.repo | ascii_downcase + "#") as $prefix
	         | ([$snaps | to_entries[] | select((.key | ascii_downcase | startswith($prefix)) and .value.state == "OPEN" and .value.branch == $r.branch)]
	            | first) as $pr
	         | "\($r.workflow) \($r.conclusion | gsub("_"; " "))\(if $r.attempt > 1 then " (attempt \($r.attempt))" else "" end): \($r.url)" as $what
	         | if $r.on_default then
	             {at: ($r.ended | ts), ref: $r.branch, title: $r.title, repo: $r.repo, group: "\($r.repo)@\($r.branch)",
	              what: "CI failed on \($r.branch): \($what)", skip: null}
	           elif $pr != null then
	             {at: ($r.ended | ts), ref: ("PR " + ($pr.key | sub("^.*#"; "#"))), title: $pr.value.title, repo: $r.repo,
	              group: $pr.key, url: $pr.value.url, what: "CI failed: \($what)",
	              skip: (if is_bot($pr.value.author; "") then "bot CI failures" else null end)}
	           else empty end ]
	  end;

# The other followed sessions a PR change also reaches: by a key, or by
# following its repo.
def also_pr($sid; $maps; $keys; $repo):
	[$entries | to_entries[] | select(.key != $sid) | .key as $o | .value as $e
	 | select(any($keys[]; has_ticket($e; $maps; .; null)) or follows_repo($e; $repo)) | $o];

# --- attribution and queues --------------------------------------------------

# How a ticket relates to a session's own keys, for the change line: "" for
# a tracked ticket, null for one unrelated to the session. A ticket another
# followed session owns reaches this one only when this one owns it too, or
# lists it among its related keys.
def relation($e; $maps; $issue; $claimed):
	tracked($e) as $t
	| own_of($e; $maps) as $roots
	| if ($t | index($issue.key)) != null then ""
	  elif $issue.parent != null and (($e.keys // []) | index($issue.parent)) != null then "child of \($issue.parent)"
	  elif ($roots | index($issue.key)) == null and is_claimed($claimed; $issue.key; $issue.parent) then null
	  else
	    ([$roots[] as $r
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

# The user's own moves are counted. A ticket's own creation is told apart by
# its creator and its comments by their author; its field moves, which a
# search result gives no author, by its changelog (follow.sh's
# desk_follow_own_field_moves).
(.own_field_moves // {}) as $own_field_moves
| (.own_check // "off") as $own_check
|
def skip_unless($kind): if .skip == null then .skip = $kind else . end;
def own_ticket_rules:
	if .author != null and is_self(.author) then skip_unless("own posts")
	elif .creator != null and is_self(.creator) then
		if $own_check == "off" or ($own_check == "done" and ($own_field_moves[.key] | IN("own", "clean")))
		then skip_unless("own tickets")
		elif $own_check == "pending" then .field = true
		else . end
	elif .field == true and $own_check == "done" and $own_field_moves[.key] == "own" then skip_unless("own field moves")
	else . end;
def others_committed:
	if .opened != true then false
	elif .commits == null then true
	# Each commit by its author, the first entry: gh lists co-authors from
	# the commit's trailers after it. No author counts as someone else.
	else any(.commits[]; (.authors // [])[0] as $a | $a == null or (is_self($a) | not)) end;
# Counted the same way for a session following the PR's repo (repo_skip).
def own_pr_kind:
	if .author != null then (if is_self(.author) then "own posts" else null end)
	# On the user's own PR, a state move (merged, closed, draft, ready) is the
	# user's; new commits, a retitle or a description edit may be someone
	# else's, so the follow pass forwards an event carrying one, and the
	# user's newly opened PR when anyone else has committed to it (or its
	# commits could not be read).
	elif is_self(.pr_author) and ((.kinds // []) | index("update") | not) and (others_committed | not) then "own PR moves"
	else null end;
def own_pr_rules:
	own_pr_kind as $k
	| if $k == null then . else .skip = (.skip // $k) | .repo_skip = (.repo_skip // $k) end;
scope_maps as $maps
| ticket_index as $tix
| [ticket_events[] | own_ticket_rules] as $tev
| [pr_events[] | own_pr_rules] as $pev
| new_pr_snapshots as $pr_snaps
| run_events($pr_snaps) as $rev
| (if $change_issues == null and $scope_issues == null then ($state.tickets // {}) else new_ticket_snapshots end) as $tickets
| ($state.queues // {}) as $queues
| (reduce ($entries | to_entries[]) as $ent ({};
	$ent.key as $sid | $ent.value as $e
	| claimed_elsewhere($sid; $maps) as $claimed
	| scope_of($e; $maps; $claimed) as $scope
	| ([ $tev[] | . as $ev
	     | relation($e; $maps; ($tix[$ev.key] // {key: $ev.key}); $claimed) as $rel
	     | select($rel != null)
	     | also_having($sid; $maps; [$ev.key]; ($tix[$ev.key].parent // null)) as $also
	     | {at: ($ev.at // $now), ref: $ev.key, title: $ev.title, context: $rel, what: $ev.what, skip: $ev.skip}
	       + (if $ev.field == true then {field_run: $now} else {} end)
	       + (if ($also | length) > 0 then {also: $also} else {} end) ]
	   # A PR matched both by a key and by its repo is one change, counted
	   # as the repo follow counts it.
	   + [ $pev[] | . as $ev
	       | ([$ev.pr_keys[] | . as $k | select(($scope | index($k)) != null)]) as $hit
	       | follows_repo($e; $ev.repo) as $via_repo
	       | select(($hit | length) > 0 or $via_repo)
	       | also_pr($sid; $maps; $ev.pr_keys; $ev.repo) as $also
	       | {at: ($ev.at // $now), ref: ("PR " + ($ev.key | sub("^.*#"; "#"))), title: $ev.title,
	          context: (if ($hit | length) > 0 then ($hit | join(", ")) else "in \($ev.repo)" end),
	          what: $ev.what, url: $ev.url, group: $ev.key, skip: (if $via_repo then $ev.repo_skip else $ev.skip end)}
	         + (if ($also | length) > 0 then {also: $also} else {} end) ]
	   + [ $rev[] | . as $ev
	       | select(follows_repo($e; $ev.repo))
	       | also_pr($sid; $maps; []; $ev.repo) as $also
	       | {at: ($ev.at // $now), ref: $ev.ref, title: $ev.title, context: "in \($ev.repo)",
	          what: $ev.what, group: $ev.group, skip: $ev.skip}
	         + (if $ev.url then {url: $ev.url} else {} end)
	         + (if ($also | length) > 0 then {also: $also} else {} end) ]) as $events
	| [$events[] | select(.skip == null) | del(.skip)] as $new
	| ($queues[$sid] // {changes: [], dropped: 0}) as $q
	| (($q.changes // []) + $new | sort_by(.at)) as $all
	| .[$sid] = ($q + {
		skipped: (reduce ($events[] | select(.skip != null) | .skip) as $k ($q.skipped // {}; .[$k] += 1)),
		changes: (if ($all | length) > $queue_max then $all[-$queue_max:] else $all end),
		dropped: (($q.dropped // 0) + ([($all | length) - $queue_max, 0] | max)),
		new_this_run: ($new | length),
		scope: $scope })
	| if ($new | length) > 0 and (($q.changes // []) | length) == 0 then .[$sid].queued_since = $now else . end
  )) as $new_queues
| $state
| .scope = ($maps + {refreshed_at: (if $scope_issues != null then $now else ($state.scope.refreshed_at // null) end)})
| .tickets = $tickets
| .prs = $pr_snaps
| .queues = $new_queues
| .runs_seen = (if $runs == null then ($state.runs_seen // []) else (($state.runs_seen // []) + [$runs[].id] | reduce .[] as $i ([]; if index($i) then . else . + [$i] end) | .[-500:]) end)
| .follow_repos = $follow_repos
# Everything a follow tracks is closed: the seam a later pass reads to
# suggest retiring the follow. The date it was first seen closed is kept.
| .all_closed = (reduce ($entries | to_entries[]) as $ent ({};
	(tracked($ent.value) | map($tickets[.].done // false)) as $done
	| if ($done | length) > 0 and ($done | all)
	  then .[$ent.key] = ($state.all_closed[$ent.key] // $now) else . end))
