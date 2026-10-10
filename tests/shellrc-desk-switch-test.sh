#!/usr/bin/env bash
# .shellrc's desk instance switch, in bash and zsh: the shell gets the default
# account's instance, claude-personal / claude-work / claude give the session
# their account's, a DESK_CONFIG set by hand wins, and bare claude keeps the
# account a CLAUDE_CONFIG_DIR names. HOME is a temp dir, so
# no ~/.shellrc.early, secrets file or mise is read, and `claude` is a stub
# that prints what it was started with.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELLRC="$HERE/../.shellrc"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }
assert_eq() {
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/home" "$ROOT/bin"
cat > "$ROOT/bin/claude" << 'STUB'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${DESK_CONFIG-unset}" "${DESK_STATE_DIR-unset}" "${CLAUDE_CONFIG_DIR##*/}"
STUB
chmod +x "$ROOT/bin/claude"

# in_shell <shell> <script>: runs script after sourcing .shellrc, with only the
# variables given on the command line (VAR=value ...) set beforehand.
in_shell() {
	local sh=$1 script=$2
	shift 2
	env -i HOME="$ROOT/home" PATH="$ROOT/bin:/usr/bin:/bin" TERM=dumb "$@" \
		"$sh" -c ". '$SHELLRC' > /dev/null 2>&1; $script" 2> /dev/null
}
shell_env='printf "%s|%s\n" "${DESK_CONFIG-unset}" "${DESK_STATE_DIR-unset}"'
printf '. %q > /dev/null 2>&1; %s\n' "$SHELLRC" "$shell_env" > "$ROOT/nested.sh"
both=(DESK_PERSONAL_CONFIG=/p/config.json DESK_WORK_CONFIG=/w/config.json DESK_WORK_STATE_DIR=/w/state)

for sh in bash zsh; do
	command -v "$sh" > /dev/null || { echo "skipped: no $sh"; continue; }
	echo "=== $sh ==="
	assert_eq "$sh: the shell gets the personal instance by default, with the runner's own state dir" \
		"/p/config.json|unset" "$(in_shell "$sh" "$shell_env" "${both[@]}")"
	assert_eq "$sh: claude-work gives its session the work instance and state dir" \
		"/w/config.json|/w/state|.claude-work" "$(in_shell "$sh" 'claude-work' "${both[@]}")"
	assert_eq "$sh: claude-personal gives the personal one" \
		"/p/config.json||.claude" "$(in_shell "$sh" 'claude-personal' "${both[@]}")"
	assert_eq "$sh: DEFAULT_ACCOUNT=work gives the shell the work instance" \
		"/w/config.json|/w/state" "$(in_shell "$sh" "$shell_env" "${both[@]}" DEFAULT_ACCOUNT=work)"
	assert_eq "$sh: DESK_DEFAULT_ACCOUNT overrides it for desk alone" \
		"/p/config.json|unset" "$(in_shell "$sh" "$shell_env" "${both[@]}" DEFAULT_ACCOUNT=work DESK_DEFAULT_ACCOUNT=personal)"
	assert_eq "$sh: bare claude follows the default account" \
		"/w/config.json|/w/state|.claude-work" "$(in_shell "$sh" 'claude' "${both[@]}" DEFAULT_ACCOUNT=work)"
	assert_eq "$sh: bare claude under the work config dir is the work account, with its instance" \
		"/w/config.json|/w/state|.claude-work" "$(in_shell "$sh" 'CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude' "${both[@]}")"
	assert_eq "$sh: ...and under any other dir, the default account" \
		"/p/config.json||.claude" "$(in_shell "$sh" 'CLAUDE_CONFIG_DIR=/elsewhere claude' "${both[@]}")"
	assert_eq "$sh: an account with no instance gets none" \
		"||.claude" "$(in_shell "$sh" 'claude-personal' DESK_WORK_CONFIG=/w/config.json DESK_WORK_STATE_DIR=/w/state)"
	assert_eq "$sh: with no instances set, the shell exports nothing" \
		"unset|unset" "$(in_shell "$sh" "$shell_env")"

	assert_eq "$sh: an exported DESK_CONFIG wins in the shell, with its own state dir" \
		"/x/config.json|/x/state" "$(in_shell "$sh" "$shell_env" "${both[@]}" DESK_CONFIG=/x/config.json DESK_STATE_DIR=/x/state)"
	assert_eq "$sh: ...and in a session of either account" \
		"/x/config.json|/x/state|.claude-work" "$(in_shell "$sh" 'claude-work' "${both[@]}" DESK_CONFIG=/x/config.json DESK_STATE_DIR=/x/state)"
	assert_eq "$sh: one set on the command line wins over the switch's own" \
		"/x/config.json||.claude-work" "$(in_shell "$sh" 'DESK_CONFIG=/x/config.json claude-work' "${both[@]}")"
	assert_eq "$sh: a nested shell does not mistake the switch's value for one set by hand" \
		"/w/config.json|/w/state" \
		"$(in_shell "$sh" "DEFAULT_ACCOUNT=work $sh '$ROOT/nested.sh'" "${both[@]}")"
	assert_eq "$sh: a session started inside a session switches account" \
		"/p/config.json||.claude" \
		"$(in_shell "$sh" "DESK_CONFIG=/w/config.json __DESK_SWITCHED_CONFIG=/w/config.json DESK_STATE_DIR=/w/state claude-personal" "${both[@]}")"
done

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
