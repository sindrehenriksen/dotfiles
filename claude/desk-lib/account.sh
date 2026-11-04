#!/usr/bin/env bash
# The claude.ai account a config dir is logged in as, for the session
# recorder (claude/hooks/session-recorder.sh), which notes it at each start,
# and claude/session-stale.sh, which compares a session's with the current
# one. Sourced.
set -u

# desk_current_account [config dir]: prints oauthAccount.accountUuid from
# the dir's .claude.json, or nothing. Only that field is read, so nothing
# else in the file (tokens included) is ever printed. Claude Code keeps the
# file inside $CLAUDE_CONFIG_DIR when that is set, at ~/.claude.json when
# not, so an empty argument means the latter.
desk_current_account() {
	local file="$HOME/.claude.json"
	[ -n "${1:-}" ] && file="${1%/}/.claude.json"
	jq -r '.oauthAccount.accountUuid // empty' "$file" 2> /dev/null
}
