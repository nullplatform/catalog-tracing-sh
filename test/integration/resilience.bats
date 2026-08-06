#!/usr/bin/env bats
#
# THE availability invariant: a down, hanging, or erroring tracing API must be
# invisible to the instrumented program. Every case asserts the pipeline exits
# 0, within its budget.

load '../helper'

# Run a representative pipeline against $1 and report "<exit code> <seconds>".
# The pipeline runs under `set -eu` — the strict mode a real CI script uses —
# so a non-zero return anywhere inside the SDK would kill it.
run_pipeline() {
  local url=$1 budget=${2:-5} dir start code elapsed
  dir="$BATS_TEST_TMPDIR/pipe.$$.$RANDOM"
  start=$(date +%s)
  NP_TRACE_DIR="$dir" NP_TRACE_FLUSH_TIMEOUT="$budget" \
  "$NP_TEST_SHELL" -eu -c "
    . \"\$NPTRACE\"
    np_trace_init --producer 'resilience@0.1' --token 't' --base-url '$url' --no-trap
    run=\$(np_trace_run --trace-id 't1' --run-id 't1')
    np_trace_labels entity=test action=check
    np_trace_explain --title 'Resilience probe'
    step=\$(np_trace_step \"\$run\" work)
    np_trace_complete \"\$step\"
    np_trace_complete \"\$run\"
    np_trace_flush
  " >/dev/null 2>&1
  code=$?
  elapsed=$(( $(date +%s) - start ))
  rm -rf "$dir"
  printf '%s %s' "$code" "$elapsed"
}

# assert_pipeline_ok <result> <max seconds>
assert_pipeline_ok() {
  local code=${1%% *} elapsed=${1##* } limit=$2
  [ "$code" -eq 0 ] || { echo "pipeline exited $code" >&2; return 1; }
  [ "$elapsed" -le "$limit" ] || {
    echo "took ${elapsed}s, budget ${limit}s" >&2; return 1; }
}

@test "a refused connection is invisible to the pipeline" {
  assert_pipeline_ok "$(run_pipeline 'http://127.0.0.1:1')" 20
}

@test "an API that black-holes packets is bounded by the connect timeout" {
  assert_pipeline_ok "$(run_pipeline 'http://10.255.255.1')" 30
}

@test "an unresolvable host is invisible to the pipeline" {
  assert_pipeline_ok "$(run_pipeline 'http://tracing.invalid')" 30
}

@test "no credentials configured at all is not an error" {
  local dir="$BATS_TEST_TMPDIR/nocreds"
  NP_TRACE_DIR="$dir" run "$NP_TEST_SHELL" -eu -c '
    . "$NPTRACE"
    np_trace_init --producer "resilience@0.1" --base-url "http://127.0.0.1:1" --no-trap
    run=$(np_trace_run --trace-id t2 --run-id t2)
    np_trace_complete "$run"
    np_trace_flush
  '
  assert_ok
}

@test "an unwritable state dir degrades to a no-op instead of killing the caller" {
  NP_TRACE_DIR='/proc/nonexistent/nope' run "$NP_TEST_SHELL" -eu -c '
    . "$NPTRACE"
    np_trace_init --producer "resilience@0.1" --token t --no-trap
    run=$(np_trace_run --trace-id t3 --run-id t3)
    np_trace_labels entity=test
    np_trace_complete "$run"
    np_trace_flush
  '
  assert_ok
}

@test "a pipeline relying on the EXIT trap still exits 0, and does not hang" {
  local dir start code elapsed
  dir="$BATS_TEST_TMPDIR/trap"
  start=$(date +%s)
  NP_TRACE_DIR="$dir" NP_TRACE_FLUSH_TIMEOUT=3 \
  "$NP_TEST_SHELL" -eu -c '
    . "$NPTRACE"
    np_trace_init --producer "resilience@0.1" --token t --base-url "http://127.0.0.1:1"
    run=$(np_trace_run --trace-id t4 --run-id t4)
    np_trace_complete "$run"
  ' >/dev/null 2>&1
  code=$?
  elapsed=$(( $(date +%s) - start ))
  [ "$code" -eq 0 ] || { echo "trap pipeline exited $code" >&2; return 1; }
  [ "$elapsed" -le 20 ] || { echo "trap flush took ${elapsed}s" >&2; return 1; }
}
