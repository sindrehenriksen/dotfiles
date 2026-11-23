# The follow pass's Slack source: which reads a run makes, and what the
# results hold that is new. Called by claude/desk-lib/follow-slack.sh on one
# input object:
#
#   refs           every followed Slack source: a channel id, or
#                  "<channel id>:<parent ts>" for one thread
#   state          the previous run's `slack` state: {sources: {<ref>:
#                  {name, title, seen, threads: {<parent ts>: {sig, seen}}}}}
#   now            epoch seconds
#   since          epoch seconds for a --lookback-minutes run, else null
#   since_local    the same moment as "YYYY-MM-DD HH:MM:SS" in the instance's
#                  time zone, which is how a channel read dates a thread's
#                  latest reply
#   channel_pairs, thread_pairs   the {input, text} of the reads made so far
#   final          true once no further read follows: a thread still unread
#                  then counts as failed
#
# With $mode "plan" it prints the first call's reads, [{tool: "channel" |
# "thread", args}]. Otherwise it prints {ok, failed, notes, thread_calls,
# events, state}: thread_calls are the reads of a channel's threads that the
# channel read showed have moved, to make before asking again.
#
# A channel read asks for the channel's newest 100 messages, with no start
# time: given one, Slack answers with the oldest 100 after it, which on a
# busy channel are not the new ones. Each message carries its thread's size
# and latest reply, so a thread among those 100 whose `sig` moved is read for
# its replies, however old its first message is.
#
# A source is new from its `seen`, the newest message ts the pass has read
# there, kept as Slack's own string since a float does not hold one exactly.
# A source read for the first time is only recorded. One whose read did not
# come back keeps its state, so the next run asks from the same place.
#
# A result is the connector's rendering of the messages as text, parsed by
# its headers. Text shaped like a header inside a message can at worst pass
# itself off as another message of the same untrusted kind; a ts ahead of
# the clock is ignored, so it cannot move `seen` past real messages.

. as $in
| ($in.state.sources // {}) as $prev
| $in.now as $now
| $in.since as $since
| ($in.channel_pairs // []) as $cp
| ($in.thread_pairs // []) as $tp
|

def tsstr: "\(.).000000";
($now | tsstr) as $nowstr
| (($now + 600) | tsstr) as $maxts
| (if $since != null then ($since | tsstr) else null end) as $sincestr
|

def chan_args($c): {channel_id: $c, limit: 100, response_format: "detailed"};
def thread_args($c; $p; $oldest):
	{channel_id: $c, message_ts: $p, oldest: $oldest, limit: 200, response_format: "detailed"};

def result_of($pairs; $args): [$pairs[] | select(.input == $args)] | last;
def blob: (try fromjson catch null) | if type == "object" and (.messages | type) == "string" then . else null end;

def mentions: gsub("<(?<s>[@#])[A-Z0-9]+\\|(?<n>[^<>]+)>"; "\(.s)\(.n)");
def title: mentions | gsub("\\s+"; " ") | sub("^ "; "") | if length > 60 then .[0:60] + "…" else . end;
def who: sub(" <[^<>]*>"; "") | sub(" \\([A-Z0-9]+\\)\\s*$"; "");
def epoch: split(".")[0] | tonumber;

# A message's text without the lines the connector adds under it: its
# reactions, and on a channel's message its thread's size.
def tail_meta:
	{b: sub("\\s+$"; ""), replies: 0, latest: null}
	| reduce range(2) as $_ (.;
		(.b | capture("^(?<b>[\\s\\S]*?)\\n?Thread: (?<n>[0-9]+) repl(?:y|ies) \\(latest: (?<l>[^)\\n]*)\\)$") // null) as $t
		| (if $t != null then .b = ($t.b | sub("\\s+$"; "")) | .replies = ($t.n | tonumber) | .latest = $t.l else . end)
		| .b |= (sub("(^|\\n)Reactions: [^\\n]*$"; "") | sub("\\s+$"; "")));

def message($m): ($m.body | tail_meta) as $t
	| {ts: $m.ts, author: ($m.who | who), body: ($t.b | mentions), replies: $t.replies, latest: $t.latest};

# A channel read's text: "Channel: <name> (<id>)", then per message
# "=== Message from <who> at <time> ===", "Message TS: <ts>" and its text.
def channel_msgs:
	(capture("^Channel: (?<n>[^\\n]*?) \\([A-Z0-9]+\\)") // {n: null}) as $h
	| (split("\n=== Message from ") | .[1:]) as $chunks
	| reduce $chunks[] as $c ([];
		($c | capture("^(?<who>[^\\n]*) at [^\\n]*? ===[ \\t]*\\nMessage TS: (?<ts>[0-9]{10}\\.[0-9]{6})\\n?(?<body>[\\s\\S]*)$") // null) as $m
		| if $m != null then . + [$m]
		  elif length > 0 then .[-1].body += "\n=== Message from " + $c
		  else . end)
	| {name: $h.n, msgs: map(message(.))};

# A thread read's text: the parent under "=== THREAD PARENT MESSAGE ===",
# then each reply under "--- Reply <n> of <total> ---", both as "From:",
# "Time:", "Message TS:" and the text.
def thread_msgs:
	def one: capture("^From: (?<who>[^\\n]*)\\nTime: [^\\n]*\\nMessage TS: (?<ts>[0-9]{10}\\.[0-9]{6})\\n?(?<body>[\\s\\S]*)$") // null;
	split("\n=== THREAD REPLIES (") as $halves
	| ($halves[0] | sub("^\\s*=== THREAD PARENT MESSAGE ===[ \\t]*\\n"; "") | one) as $p
	| ([($halves[1:] | join("\n=== THREAD REPLIES (")) | splits("(^|\\n)--- Reply [0-9]+ of [0-9]+ ---[ \\t]*\\n")] | .[1:]
	   | reduce .[] as $c ([];
		($c | one) as $m
		| if $m != null then . + [$m] elif length > 0 then .[-1].body += "\n" + $c else . end)) as $r
	| {parent: (if $p != null then message($p) else null end), replies: ($r | map(message(.)))};

def more: ((.pagination_info // "") | test("There are more "; "i"));
def why_not($res): if $res == null then "no call read it" else "its read came back as: " + (($res.text // "") | gsub("\\s+"; " ") | .[0:160]) end;
def is_system: test("^@[^\\n]* has (joined|left) the channel$");

# One thread's reply events and its `seen` after them.
def replies_since($from; $thread): [$thread.replies[] | select(.ts > $from and .ts <= $maxts)];

def do_channel($c):
	$prev[$c] as $p
	| result_of($cp; chan_args($c)) as $res
	| ($res | if . != null then (.text | blob) else null end) as $b
	| if $b == null then {ref: $c, ok: false, failed: ["\($c): \(why_not($res))"], state: $p}
	  else ($b.messages | channel_msgs) as $cm
	  | [$cm.msgs[] | select(.ts <= $maxts)] as $msgs
	  | if ($cm.msgs | length) == 0 and ($b.messages | test("Message TS: ")) then
	      {ref: $c, ok: false, failed: ["\($c): its messages could not be read out of the result"], state: $p}
	    else
	      ($sincestr // $p.seen) as $from
	      | [$msgs[] | select(.replies > 0) | . as $m
	         | $p.threads[$m.ts] as $snap
	         | "\($m.replies)|\($m.latest)" as $sig
	         | ($snap.seen // $p.seen // $nowstr) as $stored
	         | ($sincestr // $stored) as $read_from
	         | {ts: $m.ts, sig: $sig, stored: $stored, read_from: $read_from, title: ($m.body | title),
	            due: ($from != null and (($snap.sig // "") != $sig
	                  or ($in.since_local != null and ($m.latest // "") >= $in.since_local)))}
	         | if .due then
	             thread_args($c; .ts; .read_from) as $args
	             | result_of($tp; $args) as $tres
	             | ($tres | if . != null then (.text | blob) else null end) as $tb
	             | ($tb | if . != null then (.messages | thread_msgs) else null end) as $t
	             | . + (if $tres == null and ($in.final | not) then {pending: $args}
	                    elif $t == null or $t.parent == null then {bad: "\($c) thread \(.ts): \(why_not($tres))"}
	                    else {new: replies_since(.read_from; $t), more: ($tb | more)} end)
	           else . end] as $ths
	      | {ref: $c, ok: all($ths[]; .bad == null),
	         failed: [$ths[] | .bad | values],
	         notes: ((if $from != null and ($msgs | length) >= 100 and all($msgs[]; .ts > $from)
	                  then ["\($c) has more than 100 new messages; only the newest 100 were read"] else [] end)
	                 + [$ths[] | select(.more == true) | "\($c) thread \(.ts) has more than 200 new replies; the next run reads on from there"]),
	         thread_calls: [$ths[] | .pending | values],
	         events: ([$msgs[] | select($from != null and .ts > $from)
	                   | {src: $c, cid: $c, name: $cm.name, ts, at: (.ts | epoch), author, body, kind: "message",
	                      thread: null, title: null, system: (.body | is_system)}]
	                  + [$ths[] | . as $th | (.new // [])[]
	                     | {src: $c, cid: $c, name: $cm.name, ts, at: (.ts | epoch), author, body, kind: "reply",
	                        thread: $th.ts, title: $th.title, system: false}]),
	         state: {name: $cm.name,
	                 seen: ([($p.seen // $nowstr), ($msgs | map(.ts) | max // "")] | max),
	                 threads: ([$ths[] | {key: .ts, value: (
	                     if .bad != null or .pending != null then {sig: "", seen: .stored}
	                     else {sig: (if .more == true then "" else .sig end),
	                           seen: ([.stored, ((.new // []) | map(.ts) | max // "")] | max)} end)}] | from_entries)}}
	    end
	  end;

def do_thread($r):
	($r | split(":")) as [$c, $pts]
	| $prev[$r] as $p
	| ($sincestr // $p.seen) as $from
	| ($prev[$c].name // null) as $name
	| if $from == null then {ref: $r, ok: true, state: {seen: $nowstr}}
	  else result_of($tp; thread_args($c; $pts; $from)) as $res
	  | ($res | if . != null then (.text | blob) else null end) as $b
	  | ($b | if . != null then (.messages | thread_msgs) else null end) as $t
	  | if $t == null or $t.parent == null then {ref: $r, ok: false, failed: ["\($c) thread \($pts): \(why_not($res))"], state: $p}
	    else replies_since($from; $t) as $new
	    | {ref: $r, ok: true,
	       notes: (if ($b | more) then ["\($c) thread \($pts) has more than 200 new replies; the next run reads on from there"] else [] end),
	       events: [$new[] | {src: $r, cid: $c, name: $name, ts, at: (.ts | epoch), author, body, kind: "reply",
	                          thread: $pts, title: ($t.parent.body | title), system: false}],
	       state: {title: ($t.parent.body | title),
	               seen: ([($p.seen // $nowstr), ($new | map(.ts) | max // "")] | max)}}
	    end
	  end;

if $mode == "plan" then
	[$in.refs[] | . as $r
	 | if test(":") then
	     ($r | split(":")) as [$c, $pts]
	     | ($sincestr // $prev[$r].seen) as $from
	     | if $from == null then empty else {tool: "thread", args: thread_args($c; $pts; $from)} end
	   else {tool: "channel", args: chan_args($r)} end]
else
	[$in.refs[] | . as $r | if test(":") then do_thread($r) else do_channel($r) end] as $done
	| {ok: all($done[]; .ok),
	   failed: [$done[] | (.failed // [])[]],
	   notes: [$done[] | (.notes // [])[]],
	   thread_calls: [$done[] | (.thread_calls // [])[]],
	   events: ([$done[] | (.events // [])[]] | sort_by(.ts)),
	   state: {sources: ([$done[] | select(.state != null) | {key: .ref, value: .state}] | from_entries)}}
end
