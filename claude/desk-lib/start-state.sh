#!/usr/bin/env bash
# What a session's process started under, for the session recorder
# (claude/hooks/session-recorder.sh), which notes it at each start, and
# claude/session-stale.sh, which compares it with what holds now. Sourced.
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

# What a fresh login shell in a tab is made of, as this repo sets one up,
# relative to $HOME: zsh reads ~/.zprofile (login) and ~/.zshrc
# (interactive); .zprofile reads ~/.profile, which puts ~/.local/bin on
# PATH, and .zshrc reads ~/.shellrc, which holds the PATH, the environment
# and the `claude` account switcher shared with bash, and reads the
# machine-local ~/.shellrc.early and ~/.secrets.env. A session's
# environment, PATH and the flags its `claude` function gave it all come
# from these. The plugins, fzf and the prompt are left out: they shape the
# shell, not what a session runs with.
DESK_SHELL_FILES=(.zprofile .zshrc .profile .shellrc .shellrc.early .secrets.env)

# desk_shell_hashes: a JSON object of each of those files' content hash, the
# first 16 hex digits of its SHA-256 (enough to tell an edit, and too little
# to say anything about a secrets file's contents), "-" for one that is
# missing. Content, not mtime, so a rewrite that changes nothing is no
# change.
desk_shell_hashes() {
	local f h
	for f in "${DESK_SHELL_FILES[@]}"; do
		h="$({ sha256sum < "$HOME/$f" || shasum -a 256 < "$HOME/$f"; } 2> /dev/null | cut -c1-16)"
		[ -e "$HOME/$f" ] && [ -n "$h" ] || h="-"
		printf '%s\t%s\n' "$f" "$h"
	done | jq -c -R -n '[inputs | split("\t") | {(.[0]): .[1]}] | add'
}
