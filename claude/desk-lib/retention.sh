#!/usr/bin/env bash
# The retention kind: lists, for the pass's brief, each session the notes
# still name whose transcript Claude Code is about to delete. The central
# session decides what of each, if anything, belongs in the notes, and
# stages it itself; nothing here writes to the notes.
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
# gains `deletes_at` (epoch), `deletion_date` (local YYYY-MM-DD, the real
# date even for one already past due, since a warning is keyed on it) and
# `days_left` (0 once due); soonest first.
desk_retention_candidates() {
	local cutoff_days="$1" warn_days="$2" repo="$3"
	shift 3
	local all
	all="$(session-status.sh 2> /dev/null | jq -s '.')" || return 1
	all="$(desk_sessions_in_notes "$repo" "$all" "$@")" || return 1
	local projects="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/"
	local eligible
	eligible="$(jq -c --arg runs_root "$DESK_RUNS_ROOT" --arg scratch_root "$DESK_SCRATCH_ROOT" --arg projects "$projects" \
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
		$s->{deletes_at} = $deletes_at;
		$s->{deletion_date} = strftime("%Y-%m-%d", localtime($deletes_at));
		$s->{days_left} = $deletes_at > $now ? int(($deletes_at - $now) / 86400) : 0;
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

# desk_step_retention <pass> <step_json> <config_json> <repo> <scheduled_date> <file>...
# No model call. Per candidate (desk_retention_candidates), soonest deletion
# first, writes `retention/<session id>/` in the run directory: `session.json`
# (the reader entry with `label`, `deletion_date` and `days_left`) and
# `transcript.txt` (desk_write_transcript_copy), and lists them all in
# `retention/candidates.json`. A session whose warning for that deletion date
# the ledger already holds (an item with its `session_id` and `capture_kind`
# `retention:<date>`, proposed, taken or declined) is not listed again. A pass
# with no brief has nobody to decide, so it lists none. Prints "ok", or
# "failed" when the settings, the reader, the notes or the ledger can't be
# read.
desk_step_retention() {
	local pass="$1" step_json="$2" config_json="$3" repo="$4" scheduled_date="$5"
	shift 5
	local files=("$@")
	local dir="$DESK_RUNS_ROOT/$pass-$scheduled_date/retention"
	rm -rf "$dir"
	if ! jq -e --arg p "$pass" '.passes[$p].brief | type == "object"' > /dev/null 2>&1 <<< "$config_json"; then
		desk_log "$pass" "retention: this pass has no brief, so there is nobody to decide on the warnings — listing none"
		echo "ok"
		return
	fi

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

	local candidates ledger_state
	candidates="$(desk_retention_candidates "$cutoff" "$warn" "$repo" "${files[@]}")" || {
		desk_log "$pass" "retention: reading the sessions or the notes failed"
		echo "failed"
		return
	}
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
	local n i listed='[]'
	n="$(jq 'length' <<< "$candidates")"
	desk_log "$pass" "retention: $n session(s) in the notes due for deletion within ${warn}d (cleanupPeriodDays $cutoff)"
	mkdir -p "$dir"
	for ((i = 0; i < n; i++)); do
		local sess id label sdir lines
		sess="$(jq -c ".[$i]" <<< "$candidates")"
		id="$(jq -r '.id' <<< "$sess")"
		label="$(desk_retention_label "$sess")"
		sdir="$dir/$id"
		mkdir -p "$sdir"
		jq -c --arg l "$label" '. + {label: $l}' <<< "$sess" > "$sdir/session.json"
		lines="$(desk_write_transcript_copy "$(jq -r '.transcript_path // empty' <<< "$sess")" \
			"$sdir/transcript.txt" "${PASS_SCRATCH:-$sdir}/retention-$id-transcript.jsonl")"
		[ -n "${PASS_SCRATCH:-}" ] || rm -f "$sdir/retention-$id-transcript.jsonl"
		listed="$(jq -c --argjson s "$sess" --arg l "$label" --arg d "$sdir" --argjson lines "${lines:-0}" '
			. + [{session_id: $s.id, name: $l, deletion_date: $s.deletion_date, days_left: $s.days_left,
			      transcript_lines: $lines, dir: $d}]' <<< "$listed")"
	done
	printf '%s\n' "$listed" > "$dir/candidates.json"
	echo "ok"
}
