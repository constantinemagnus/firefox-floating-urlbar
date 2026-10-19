#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/floating-urlbar-tests.XXXXXX")"
cd -- "$REPO_DIR"

run_suite() {
    local name="$1" status=0 started=$SECONDS
    shift
    "$@" </dev/null > "$LOG_DIR/$name.log" 2>&1 || status=$?
    if (( status )); then
        cat "$LOG_DIR/$name.log"
    elif [[ "$name" == node ]]; then
        grep -E '^# (tests|suites|pass|fail|cancelled|skipped|todo|duration_ms) ' "$LOG_DIR/$name.log"
    elif grep -q '^SKIP:' "$LOG_DIR/$name.log"; then
        cat "$LOG_DIR/$name.log"
    else
        # Shell assertions have no case counter; report the suite instead.
        printf 'Shell suites: 1 passed\n'
    fi
    printf '%s: duration=%ss exit=%s output=%s\n' \
        "$name" "$(( SECONDS - started ))" "$status" "$LOG_DIR/$name.log"
    return "$status"
}

run_suite node node --test --test-reporter=tap tests/urlbar.test.cjs
run_suite shell bash tests/shell.test.sh
run_suite package bash tests/package.test.sh
