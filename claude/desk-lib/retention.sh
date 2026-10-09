#!/usr/bin/env bash
# The retention kind: a warning, through the normal review, for each session
# the notes still name whose transcript Claude Code is about to delete.
#
# Claude Code deletes a transcript once it is older than `cleanupPeriodDays`
# (default 30), in a background sweep after a session starts; its docs say
# "a session you haven't used for longer than the retention period no longer
# appears in the /resume picker". Age is read here as the transcript's mtime,
# the last write, which a resume moves. The docs don't name the timestamp, so
# the deletion date given is the earliest it can happen: the sweep runs at
# any Claude Code start, the runner's own calls included.
#
# Nothing here writes to a transcript, resumes or closes a session: a write
# would move the mtime and silently reset the clock, which is the user's
# decision to make. The transcript is only stat'ed and its tail read.
set -u

# Claude Code's documented default for `cleanupPeriodDays` (settings
# reference: "Default: 30"), used when the settings file doesn't set it.
DESK_CLAUDE_DEFAULT_CLEANUP_DAYS=30

# desk_cleanup_period_days
# Prints `cleanupPeriodDays` from $CLAUDE_CONFIG_DIR/settings.json, or the
# documented default when the file or the key is absent. Refuses (logs,
# returns 1) on a file it can't parse or a value that isn't a whole number of
# at least 1: Claude Code pauses its sweep in both cases, and guessing a
# value would report a date that means nothing.
desk_cleanup_period_days() {
	local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
	if [ ! -e "$settings" ]; then
		echo "$DESK_CLAUDE_DEFAULT_CLEANUP_DAYS"
		return 0
	fi
	local v
	if ! v="$(jq -r '.cleanupPeriodDays // empty | tostring' "$settings" 2> /dev/null)"; then
		desk_log - "retention: can't parse $settings"
		return 1
	fi
	if [ -z "$v" ]; then
		echo "$DESK_CLAUDE_DEFAULT_CLEANUP_DAYS"
		return 0
	fi
	if ! [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
		desk_log - "retention: cleanupPeriodDays in $settings is not a whole number of days: $v"
		return 1
	fi
	echo "$v"
}

# desk_sessions_in_notes <repo> <entries_json> <file>...
# The reader entries the committed notes (HEAD of any configured file) name:
# by user-set name, or by the session id or a prefix of it of at least 8
# characters (what an unnamed capture carries), each as a whole token of
# letters, digits, `_` and `-`. Returns 1 if the repo has no HEAD.
desk_sessions_in_notes() {
	local repo="$1" entries_json="$2"
	shift 2
	git -C "$repo" rev-parse --verify -q HEAD > /dev/null 2>&1 || return 1
	local f text=""
	for f in "$@"; do
		text+="$(git -C "$repo" show "HEAD:$f" 2> /dev/null)"$'\n'
	done
	NOTES_TEXT="$text" perl -MJSON::PP -e '
		my $j = JSON::PP->new->canonical;
		my $entries = $j->decode(do { local $/; <STDIN> } || "[]");
		my $text = $ENV{NOTES_TEXT};
		my %tok;
		$tok{$1} = 1 while $text =~ /([A-Za-z0-9_-]+)/g;
		my @out = grep {
			my $e = $_;
			my ($name, $id) = ($e->{name} // "", $e->{id} // "");
			my $hit = 0;
			if (($e->{name_source} // "") eq "user" && $name ne "") {
				my $n = quotemeta($name);
				$hit = 1 if $text =~ /(?<![A-Za-z0-9_-])$n(?![A-Za-z0-9_-])/;
			}
			for (my $len = 8; !$hit && $len <= length($id); $len++) {
				$hit = 1 if $tok{substr($id, 0, $len)};
			}
			$hit;
		} @$entries;
		print $j->encode(\@out);
	' <<< "$entries_json"
}

# desk_retention_candidates <cutoff_days> <warn_days> <repo> <file>...
# Every session the notes still name (desk_sessions_in_notes), not
# live (being written to), not the runner's own, not ended as done (the
# reader's end_deliberate, except a close by a pass, which the user did not
# choose and which leaves the work the notes name unfinished), whose
# transcript sits under $CLAUDE_CONFIG_DIR/projects (the one the settings
# file read above governs) and is due for deletion within `warn_days`. Each
# gains `deletes_at` (epoch), `deletion_date` (local YYYY-MM-DD, today for
# one already past due) and `days_left`; soonest first.
desk_retention_candidates() {
	local cutoff_days="$1" warn_days="$2" repo="$3"
	shift 3
	local all
	all="$(session-status.sh 2> /dev/null | jq -s '.')" || return 1
	all="$(desk_sessions_in_notes "$repo" "$all" "$@")" || return 1
	local projects="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/"
	local eligible
	eligible="$(jq -c --arg runs_root "$DESK_RUNS_ROOT" --arg projects "$projects" \
		"$DESK_JQ_IS_DESK_RUN"'
		[ .[] | select(
			(.live != true)
			and (is_desk_run | not)
			and ((.end_deliberate == true and .end_reason != "closed-by-pass") | not)
			and ((.transcript_path // "") | startswith($projects))
		) ]
	' <<< "$all")" || return 1

	# stat and the date in one perl call: (stat)[9] reads the mtime without
	# touching the file, the same on macOS and Linux.
	jq -c '.[]' <<< "$eligible" | perl -MJSON::PP -MPOSIX=strftime -ne '
		BEGIN { ($cutoff, $warn, $now) = @ARGV[0..2]; @ARGV = (); $j = JSON::PP->new->canonical; @out = () }
		my $s = $j->decode($_);
		my @st = stat($s->{transcript_path});
		next unless @st;
		my $deletes_at = $st[9] + $cutoff * 86400;
		next if $deletes_at - $now > $warn * 86400;
		my $shown = $deletes_at > $now ? $deletes_at : $now;
		$s->{deletes_at} = $deletes_at;
		$s->{deletion_date} = strftime("%Y-%m-%d", localtime($shown));
		$s->{days_left} = int(($shown - $now) / 86400);
		push @out, $s;
		END { print $j->encode([sort { $a->{deletes_at} <=> $b->{deletes_at} } @out]) }
	' "$cutoff_days" "$warn_days" "$(desk_now)"
}

# desk_retention_label <session_json>
# What the item and the follow-up summary call a session: its user-set name, else the
# auto title with the short id the capture step labels it with.
desk_retention_label() {
	local sess="$1" name name_source id
	name="$(jq -r '.name // ""' <<< "$sess")"
	name_source="$(jq -r '.name_source // "ai_or_none"' <<< "$sess")"
	id="$(jq -r '.id' <<< "$sess")"
	if [ "$name_source" = "user" ] && [ -n "$name" ]; then
		printf '%s' "$name"
	else
		printf '%s · %s' "${name:-session}" "$(desk_short_session_id "$id")"
	fi
}

# desk_retention_finish_item <item_json> <head_text_file> <deletion_date>
# The checks on a capture call's item that only the runner can make. A
# `move` raises the user's own entry, so it must remove exactly lines that
# sit together in the committed notes and carry every one of them to the top
# unchanged (the first may gain the date, any may lose its indent);
# otherwise it becomes a `new` item on top holding just the added lines, and
# the user's entry stays where it was. Any kind other than `move` or `new`
# lands on top as `new`. The deletion date is appended to the first line
# when the text doesn't already carry it.
desk_retention_finish_item() {
	local item_json="$1" head_file="$2" deletion_date="$3"
	printf '%s' "$item_json" | perl -MJSON::PP -e '
		my ($head_file, $date) = @ARGV;
		my $j = JSON::PP->new->canonical;
		my $item = $j->decode(do { local $/; <STDIN> });
		my $head = do { local $/; open(my $fh, "<", $head_file) or die; <$fh> } // "";
		my $kind = $item->{kind} // "";
		my $before = $item->{before} // "";
		$before =~ s/\n+\z//;
		my @after = split /\n/, ($item->{after} // ""), -1;
		s/[ \t]+\z// for @after;
		pop @after while @after && $after[-1] eq "";
		my $strip = sub { my $l = shift; $l =~ s/^\s+//; $l };

		my $move_ok = 0;
		if ($kind eq "move" && $before ne "") {
			my @b = split /\n/, $before, -1;
			if (index("\n$head\n", "\n$before\n") >= 0) {
				$move_ok = 1;
				my $k = 0;
				for my $bl (@b) {
					my $want = $strip->($bl);
					$k++ while $k < @after && index($strip->($after[$k]), $want) != 0;
					if ($k >= @after) { $move_ok = 0; last }
					$k++;
				}
			}
			if ($move_ok) {
				$item->{target} = [{ at => $b[0] }, "top"];
				$item->{before} = $before;
			} else {
				my %own = map { ($strip->($_) => 1) } @b;
				my @kept = grep { !$own{$strip->($_)} } @after[1 .. $#after];
				@after = (@after ? ($after[0]) : (), @kept);
			}
		}
		if (!$move_ok) {
			$item->{kind} = "new";
			$item->{target} = "top";
			$item->{before} = "";
		}
		@after = ("") unless @after;
		$after[0] .= " (transcript deleted $date unless resumed)" if index(join("\n", @after), $date) < 0;
		$item->{after} = join("\n", @after);
		print $j->encode($item);
	' "$head_file" "$deletion_date"
}

# desk_step_retention <pass> <step_json> <config_json> <repo> <scheduled_date>
#   <caps_json> <file>...
# Per candidate, soonest deletion first: one capture call (the close kind's,
# desk_session_capture_call) over the end of its transcript, whose item
# raises the session's entry to the top of the notes, or adds a line there,
# with a few bullets on where it stood and the deletion date. Items carry
# tier `act` and are capped like a judge's under the pass's caps entry
# before any call is made; the overflow is named in the follow-up summary
# (desk_record_capped) and its count goes to $PASS_SCRATCH/<id>-overflow.json
# for the status file. A warning
# already proposed, taken or declined for the same session and deletion date
# is never repeated. Prints "ok", or "failed" when the settings, the reader,
# the notes or the ledger can't be read.
desk_step_retention() {
	local pass="$1" step_json="$2" config_json="$3" repo="$4" scheduled_date="$5" caps_json="$6"
	shift 6
	local files=("$@")
	local step_id
	step_id="$(jq -r '.id' <<< "$step_json")"

	local cutoff warn
	cutoff="$(desk_cleanup_period_days)" || {
		echo "failed"
		return
	}
	warn="$(jq -r '.retention_warn_days // 14' <<< "$config_json")"
	if ! [[ "$warn" =~ ^[0-9]+$ ]]; then
		desk_log "$pass" "retention: retention_warn_days is not a whole number: $warn"
		echo "failed"
		return
	fi

	local candidates
	candidates="$(desk_retention_candidates "$cutoff" "$warn" "$repo" "${files[@]}")" || {
		desk_log "$pass" "retention: reading the sessions or the notes failed"
		echo "failed"
		return
	}
	local ledger_state
	ledger_state="$(desk_nvim_cli ledger-state "$repo")" || {
		desk_log "$pass" "retention: ledger-state failed"
		echo "failed"
		return
	}
	candidates="$(jq -c --argjson ledger "$ledger_state" '
		[ .[] | . as $s
		  | select([$ledger.items[] | select(.session_id == $s.id
		      and .capture_kind == ("retention:" + $s.deletion_date))] | length == 0) ]
	' <<< "$candidates")"
	local n
	n="$(jq 'length' <<< "$candidates")"
	desk_log "$pass" "retention: $n session(s) in the notes due for deletion within ${warn}d (cleanupPeriodDays $cutoff)"

	# Capped before the calls, so an overflowing one costs no model call.
	local stubs="[]" i sess label
	for ((i = 0; i < n; i++)); do
		sess="$(jq -c ".[$i]" <<< "$candidates")"
		label="$(desk_retention_label "$sess")"
		stubs="$(jq -c --argjson s "$sess" --arg h "$label: transcript deleted $(jq -r '.deletion_date' <<< "$sess")" \
			'. + [{tier: "act", headline: $h, source: ("session:" + $s.id), session_id: $s.id}]' <<< "$stubs")"
	done
	local capped kept_ids
	capped="$(desk_apply_caps "$stubs" "$caps_json")"
	desk_record_capped "$(jq -c '.overflow' <<< "$capped")"
	kept_ids="$(jq -c '[.kept[].session_id]' <<< "$capped")"
	jq -c '{act: 0, worth_knowing: 0, wildcard: 0} + ([.overflow[] | .tier] | group_by(.) | map({(.[0]): length}) | add // {})' \
		<<< "$capped" > "$PASS_SCRATCH/$step_id-overflow.json"

	local captures head_file
	captures="${DESK_CAPTURES_FILE:-notes.md}"
	head_file="$PASS_SCRATCH/$step_id-head.txt"
	git -C "$repo" show "HEAD:$captures" > "$head_file" 2> /dev/null || : > "$head_file"

	local items="[]"
	for ((i = 0; i < n; i++)); do
		local id date days placeholders reply item
		sess="$(jq -c ".[$i]" <<< "$candidates")"
		id="$(jq -r '.id' <<< "$sess")"
		jq -e --arg id "$id" 'index($id) != null' > /dev/null <<< "$kept_ids" || continue
		label="$(desk_retention_label "$sess")"
		date="$(jq -r '.deletion_date' <<< "$sess")"
		days="$(jq -r '.days_left' <<< "$sess")"
		placeholders="$(jq -n --arg sn "$label" --arg sid "$id" --arg today "$(date +%F)" \
			--arg dd "$date" --arg dl "$days" \
			'{session_name: $sn, session_id: $sid, today: $today, deletion_date: $dd, days_left: $dl}')"
		reply="$(desk_session_capture_call "$pass" "$step_json" "$repo" "$scheduled_date" \
			"$sess" "retention-$id" "retention:$label" "$placeholders")" || continue
		item="$(desk_retention_finish_item "$(jq -c '.[0]' <<< "$reply")" "$head_file" "$date")" || continue
		item="$(jq -c --arg cf "$captures" --arg sid "$id" --arg ck "retention:$date" \
			--arg h "$label: transcript deleted $date" '
			.file = $cf | .source = ("session:" + $sid) | .headline = $h | .tier = "act"
			| .session_id = $sid | .capture_kind = $ck
		' <<< "$item")"
		items="$(jq -c --argjson it "$item" '. + [$it]' <<< "$items")"
	done

	local kept_n
	kept_n="$(jq 'length' <<< "$items")"
	if [ "$kept_n" -eq 0 ]; then
		echo "ok"
		return
	fi
	items="$(desk_validate_items "$items" "" "$repo")"
	local items_file sha
	items_file="$PASS_SCRATCH/$step_id-items.json"
	jq -n --argjson items "$items" '{items: $items}' > "$items_file"
	if ! sha="$(desk_stage_and_write_proposal "$repo" "$pass" "$scheduled_date" "$items_file" "${files[@]}")" || [ -z "$sha" ]; then
		desk_log "$pass" "retention: staging failed"
		echo "failed"
		return
	fi
	desk_log "$pass" "retention: staged $kept_n warning(s)"
	echo "ok"
}
