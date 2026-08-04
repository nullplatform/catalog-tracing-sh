#!/bin/sh
# Test runner. Usage: test/run.sh [unit|integration|all]
set -u
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export ROOT
SUITE=${1:-unit}

TOTAL_RUN=0
TOTAL_FAIL=0

run_dir() {
  for suite in "$ROOT/test/$1"/*.sh; do
    [ -f "$suite" ] || continue
    printf '\n== %s\n' "${suite##*/}"
    # Each suite runs in its own shell so a crash can't take down the runner.
    out=$("$NP_TEST_SHELL" "$suite" 2>&1)
    code=$?
    printf '%s\n' "$out" | grep -v '^__COUNTS__ ' || :
    counts=$(printf '%s\n' "$out" | sed -n 's/^__COUNTS__ //p')
    ran=${counts%% *}
    failed=${counts##* }
    [ -n "$ran" ] || ran=0
    [ -n "$failed" ] || failed=0
    TOTAL_RUN=$((TOTAL_RUN + ran))
    TOTAL_FAIL=$((TOTAL_FAIL + failed))
    if [ "$code" -ne 0 ] && [ "$failed" -eq 0 ]; then
      TOTAL_FAIL=$((TOTAL_FAIL + 1))
      printf 'FAIL: suite %s exited %s with no reported failures\n' "${suite##*/}" "$code" >&2
    fi
  done
}

NP_TEST_SHELL=${NP_TEST_SHELL:-/bin/sh}
export NP_TEST_SHELL

case "$SUITE" in
  unit) run_dir unit ;;
  integration) run_dir integration ;;
  all) run_dir unit; run_dir integration ;;
  *) printf 'unknown suite: %s\n' "$SUITE" >&2; exit 2 ;;
esac

printf '\n%s assertions, %s failures\n' "$TOTAL_RUN" "$TOTAL_FAIL"
[ "$TOTAL_FAIL" -eq 0 ]
