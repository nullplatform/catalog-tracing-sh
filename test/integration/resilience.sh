#!/bin/sh
# THE availability invariant: a down, hanging, or erroring tracing API must be
# invisible to the instrumented program. Every case asserts the pipeline exits
# 0, within its budget.
set -u
. "$ROOT/test/lib/assert.sh"

# Run a representative pipeline against $1 and return its exit code. The
# pipeline runs under `set -eu` — the strict mode a real CI script uses — so a
# non-zero return anywhere inside the SDK would kill it.
run_pipeline() {
  _rp_dir=$(mktemp -d)
  NP_TRACE_DIR="$_rp_dir" \
  NP_TRACE_FLUSH_TIMEOUT="${2:-5}" \
  "${NP_TEST_SHELL:-/bin/sh}" -eu -c "
    . $ROOT/nptrace.sh
    np_trace_init --producer 'resilience@0.1' --token 't' --base-url '$1' --no-trap
    run=\$(np_trace_run --trace-id 't1' --run-id 't1')
    np_trace_labels entity=test action=check
    np_trace_explain --title 'Resilience probe'
    step=\$(np_trace_step \"\$run\" work)
    np_trace_complete \"\$step\"
    np_trace_complete \"\$run\"
    np_trace_flush
  " >/dev/null 2>&1
  _rp_code=$?
  rm -rf "$_rp_dir"
  return $_rp_code
}

# 1. Connection refused.
start=$(date +%s)
run_pipeline 'http://127.0.0.1:1'
code=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "$code" 0 'pipeline exits 0 when the API refuses connections'
if [ "$elapsed" -le 20 ]; then
  assert_eq 'bounded' 'bounded' 'refused-connection run stays within budget'
else
  assert_eq "${elapsed}s" 'bounded' 'refused-connection run stays within budget'
fi

# 2. A host that black-holes packets, bounded by --connect-timeout.
start=$(date +%s)
run_pipeline 'http://10.255.255.1'
code=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "$code" 0 'pipeline exits 0 when the API hangs'
if [ "$elapsed" -le 30 ]; then
  assert_eq 'bounded' 'bounded' 'hanging-API run stays within budget'
else
  assert_eq "${elapsed}s" 'bounded' 'hanging-API run stays within budget'
fi

# 3. A DNS name that does not resolve.
run_pipeline 'http://tracing.invalid'
assert_eq "$?" 0 'pipeline exits 0 when the API host does not resolve'

# 4. No credentials configured at all.
_nc_dir=$(mktemp -d)
NP_TRACE_DIR="$_nc_dir" "${NP_TEST_SHELL:-/bin/sh}" -eu -c "
  . $ROOT/nptrace.sh
  np_trace_init --producer 'resilience@0.1' --base-url 'http://127.0.0.1:1' --no-trap
  run=\$(np_trace_run --trace-id 't2' --run-id 't2')
  np_trace_complete \"\$run\"
  np_trace_flush
" >/dev/null 2>&1
assert_eq "$?" 0 'pipeline exits 0 with no credentials configured'
rm -rf "$_nc_dir"

# 5. A completely unwritable state dir must not break the caller either.
NP_TRACE_DIR='/proc/nonexistent/nope' "${NP_TEST_SHELL:-/bin/sh}" -eu -c "
  . $ROOT/nptrace.sh
  np_trace_init --producer 'resilience@0.1' --token 't' --no-trap
  run=\$(np_trace_run --trace-id 't3' --run-id 't3')
  np_trace_labels entity=test
  np_trace_complete \"\$run\"
  np_trace_flush
" >/dev/null 2>&1
assert_eq "$?" 0 'pipeline exits 0 when the state dir cannot be created'

# 6. The trap path: a pipeline that never calls flush explicitly still exits 0
#    against a dead API, and does not hang.
_tp_dir=$(mktemp -d)
start=$(date +%s)
NP_TRACE_DIR="$_tp_dir" NP_TRACE_FLUSH_TIMEOUT=3 "${NP_TEST_SHELL:-/bin/sh}" -eu -c "
  . $ROOT/nptrace.sh
  np_trace_init --producer 'resilience@0.1' --token 't' --base-url 'http://127.0.0.1:1'
  run=\$(np_trace_run --trace-id 't4' --run-id 't4')
  np_trace_complete \"\$run\"
" >/dev/null 2>&1
code=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "$code" 0 'pipeline relying on the EXIT trap exits 0'
if [ "$elapsed" -le 20 ]; then
  assert_eq 'bounded' 'bounded' 'the EXIT trap flush stays within budget'
else
  assert_eq "${elapsed}s" 'bounded' 'the EXIT trap flush stays within budget'
fi
rm -rf "$_tp_dir"

. "$ROOT/test/lib/report.sh"
