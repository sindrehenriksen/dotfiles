# Sourced by the session tests, for what differs between macOS and Linux.
#
# proc_start_of <pid> prints the procStart a Claude Code pid file holds for
# that process on this platform: on Linux its start in clock ticks since boot
# (field 22 of /proc/<pid>/stat), on macOS its start as a UTC ctime string.
proc_start_of() {
	if [ -r /proc/stat ]; then
		local stat
		read -r stat < "/proc/$1/stat" || return 1
		# shellcheck disable=SC2086 # split into fields on purpose
		set -- ${stat##*) }
		printf '%s' "${20}"
	else
		local lstart lepoch
		lstart=$(ps -o lstart= -p "$1" | awk '{$1=$1; print}')
		lepoch=$(date -j -f "%a %b %d %T %Y" "$lstart" +%s)
		date -u -r "$lepoch" +"%a %b %d %T %Y"
	fi
}

# The other platform's shape for the same process, so the reader's parse of
# a ctime string is still exercised on Linux.
proc_start_ctime_of() {
	local lstart lepoch
	lstart=$(ps -o lstart= -p "$1" | awk '{$1=$1; print}')
	if [ -r /proc/stat ]; then
		lepoch=$(date -d "$lstart" +%s)
		date -u -d "@$lepoch" +"%a %b %d %T %Y"
	else
		lepoch=$(date -j -f "%a %b %d %T %Y" "$lstart" +%s)
		date -u -r "$lepoch" +"%a %b %d %T %Y"
	fi
}

# on_a_terminal <program> [args...]: runs it on a pseudo-terminal of its own,
# as a tab gives Claude Code. BSD script takes the command after the
# typescript file; util-linux's takes one string, run by $SHELL -c.
on_a_terminal() {
	if script --version 2> /dev/null | grep -q util-linux; then
		local cmd
		printf -v cmd '%q ' "$@"
		SHELL=/bin/bash script -q -e -c "$cmd" /dev/null
	else
		script -q /dev/null "$@"
	fi
}
