#!/usr/bin/env bash
# Runs the stale-skills mod's parsing test under node; see the .mjs beside
# this file for what it covers.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v node > /dev/null; then
    echo "FAIL - node is not on PATH"
    exit 1
fi

exec node "$HERE/stale-skills-test.mjs"
