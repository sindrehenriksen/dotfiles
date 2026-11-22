#!/usr/bin/env bash
# Exercises claude/hooks/lockfile-read.sh against invented PreToolUse input.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/lockfile-read.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; }

# expect <allow|deny> <label> <tool> <tool_input json>
expect() {
    local want="$1" label="$2" out got=allow
    out=$(jq -nc --arg t "$3" --argjson i "$4" '{hook_event_name: "PreToolUse", tool_name: $t, tool_input: $i}' | "$HOOK")
    [[ $out == *'"permissionDecision":"deny"'* ]] && got=deny
    if [ "$got" = "$want" ]; then ok "$label"; else bad "$label (got $got)"; fi
}

expect deny  "Read whole pnpm-lock.yaml"      Read '{"file_path":"/r/pnpm-lock.yaml"}'
expect deny  "Read lockfile, limit 2000"      Read '{"file_path":"/r/Cargo.lock","limit":2000}'
expect allow "Read lockfile, limit 150"       Read '{"file_path":"/r/uv.lock","offset":400,"limit":150}'
expect allow "Read ordinary file"             Read '{"file_path":"/r/src/main.ts"}'
expect deny  "cat lockfile"                   Bash '{"command":"cat pnpm-lock.yaml"}'
expect deny  "bat lockfile after cd"          Bash '{"command":"cd app && bat yarn.lock"}'
expect deny  "head -n 500"                    Bash '{"command":"head -n 500 package-lock.json"}'
expect allow "head -n 50"                     Bash '{"command":"head -n 50 package-lock.json"}'
expect allow "tail default"                   Bash '{"command":"tail go.sum"}'
expect deny  "sed -n 1,900p"                  Bash '{"command":"sed -n 1,900p poetry.lock"}'
expect allow "sed -n 100,200p"                Bash '{"command":"sed -n 100,200p poetry.lock"}'
expect allow "rg in lockfile"                 Bash '{"command":"rg -n lodash pnpm-lock.yaml"}'
expect allow "git diff --stat"                Bash '{"command":"git diff --stat -- pnpm-lock.yaml"}'
expect allow "wc -l"                          Bash '{"command":"wc -l pnpm-lock.yaml"}'
expect allow "cat piped to rg"                Bash '{"command":"cat pnpm-lock.yaml | rg lodash"}'
expect allow "cat redirected"                 Bash '{"command":"cat pnpm-lock.yaml > /tmp/x"}'
expect allow "pnpm why"                       Bash '{"command":"pnpm why lodash # see pnpm-lock.yaml"}'
expect allow "cat of other file"              Bash '{"command":"cat README.md"}'

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
