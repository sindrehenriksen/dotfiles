#!/usr/bin/env bash
# A step's hard timeout, killing its whole process group. Neither `timeout` nor
# `gtimeout` nor `setsid` ships on this machine (no coreutils/util-linux),
# so this uses bash's own job control instead: `set -m` puts a background
# job in its own process group whose pgid equals the job's pid, and
# `kill -- -$pid` (a negative pid) signals that whole group — the model
# call and anything it shells out to, not just the immediate child.
set -u

# run_with_timeout <timeout_secs> <outfile> <cmd> [args...]
# Runs the command with stdout redirected to <outfile> and stderr to
# <outfile>.stderr — NOT merged (2>&1) into the same file: <outfile> is
# stream-json, read back one JSON object per line by desk_extract_final_text
# et al, some of them (desk_extract_final_text's own `jq -cs`) in slurp
# mode, where a single non-JSON line anywhere in the file fails the whole
# parse. A stray warning on claude's own stderr — a deprecation notice, a
# hook's own diagnostic — would otherwise silently take down every
# downstream extraction from that call, not just the one line. Returns its
# exit code, or 124 if it had to be killed. On a timeout: SIGTERM to the
# group, a grace period ($DESK_KILL_GRACE_SECS), then SIGKILL to whatever's
# left — a command that traps and ignores SIGTERM (or a child that never
# sees it) still dies within the grace window.
run_with_timeout() {
	local timeout_secs="$1" outfile="$2"
	shift 2
	local pid rc waited=0 grace_waited=0

	(
		set -m
		"$@" > "$outfile" 2> "$outfile.stderr" &
		inner_pid=$!
		echo "$inner_pid" > "$outfile.pid"
		wait "$inner_pid" # `wait` with no args always returns 0; naming the pid is what preserves cmd's real exit code
	) &
	local wrapper_pid=$!

	# The wrapper subshell writes the real job's pid before waiting on it;
	# poll briefly for that file rather than assuming it's there instantly.
	local tries=0
	while [ ! -s "$outfile.pid" ] && [ "$tries" -lt 50 ]; do
		sleep 0.1
		tries=$((tries + 1))
	done
	pid="$(cat "$outfile.pid" 2>/dev/null || true)"
	rm -f "$outfile.pid"

	if [ -z "$pid" ]; then
		# Never got a pid at all — treat as an immediate failure rather than
		# hang forever on nothing.
		wait "$wrapper_pid" 2>/dev/null
		return 1
	fi

	while desk_pid_alive "$pid"; do
		if [ "$waited" -ge "$timeout_secs" ]; then
			kill -TERM -- "-$pid" 2>/dev/null
			while desk_pid_alive "$pid" && [ "$grace_waited" -lt "$DESK_KILL_GRACE_SECS" ]; do
				sleep 1
				grace_waited=$((grace_waited + 1))
			done
			if desk_pid_alive "$pid"; then
				kill -KILL -- "-$pid" 2>/dev/null
			fi
			wait "$wrapper_pid" 2>/dev/null
			return 124
		fi
		sleep 1
		waited=$((waited + 1))
	done
	wait "$wrapper_pid" 2>/dev/null
	rc=$?
	return "$rc"
}
