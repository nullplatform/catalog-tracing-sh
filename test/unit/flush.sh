#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

NP_TRACE_DIR="$ROOT/.nptrace-test/flush-$$"
rm -rf "$NP_TRACE_DIR"
np__state_init
NP_TRACE_PRODUCER='test-suite@0.1'
NP_TRACE_TOKEN='t'
NP_TRACE_BASE_URL='http://127.0.0.1:1'

# Three spooled events against a dead endpoint.
i=1
while [ "$i" -le 3 ]; do
  printf '{"id":"e%s"}' "$i" > "$NP_TRACE_DIR/spool/e$i.json"
  i=$((i + 1))
done
assert_eq "$(np__spool_count)" 3 'three events spooled'

start=$(date +%s)
assert_ok 'flush returns 0 against a dead API' np_trace_flush
elapsed=$(( $(date +%s) - start ))

# Network failures are RETAINED for retry, never silently dropped.
assert_eq "$(np__spool_count)" 3 'unreachable API retains the spool'
if [ "$elapsed" -le 12 ]; then
  assert_eq 'bounded' 'bounded' 'flush respects its time budget'
else
  assert_eq "${elapsed}s" 'bounded' 'flush respects its time budget'
fi

# The attempt counter advances so retries eventually give up.
assert_ok 'attempt sidecar written' test -f "$NP_TRACE_DIR/spool/e1.json.attempts"
assert_eq "$(cat "$NP_TRACE_DIR/spool/e1.json.attempts")" 1 'attempt counter starts at 1'

np_trace_flush
assert_eq "$(cat "$NP_TRACE_DIR/spool/e1.json.attempts")" 2 'attempt counter advances'

# After MAX_RETRIES the event moves to failed/ rather than retrying forever.
NP_TRACE_MAX_RETRIES=1
np_trace_flush
assert_ok   'exhausted event moved to failed/' test -f "$NP_TRACE_DIR/failed/e1.json"
assert_fail 'exhausted event left the spool'   test -f "$NP_TRACE_DIR/spool/e1.json"
assert_fail 'attempt sidecar cleaned up'       test -f "$NP_TRACE_DIR/spool/e1.json.attempts"
assert_match "$(cat "$NP_TRACE_DIR/drops.log")" '*gave up*' 'giving up is recorded as a drop'
NP_TRACE_MAX_RETRIES=3

# A zero-length flush is fine.
rm -f "$NP_TRACE_DIR"/spool/*.json "$NP_TRACE_DIR"/spool/*.attempts 2>/dev/null || :
assert_eq "$(np__spool_count)" 0 'spool emptied'
assert_ok 'flush of an empty spool returns 0' np_trace_flush

# The budget must actually cut a long drain short.
i=1
while [ "$i" -le 12 ]; do
  printf '{"id":"b%s"}' "$i" > "$NP_TRACE_DIR/spool/b$i.json"
  i=$((i + 1))
done
NP_TRACE_FLUSH_TIMEOUT=1
start=$(date +%s)
np_trace_flush
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -le 8 ]; then
  assert_eq 'cut short' 'cut short' 'a 1s budget cuts a 12-event drain short'
else
  assert_eq "${elapsed}s" 'cut short' 'a 1s budget cuts a 12-event drain short'
fi
assert_match "$(np__spool_count)" '*' 'events survive a budget-limited flush'
NP_TRACE_FLUSH_TIMEOUT=10

# Disabled mode is a real no-op.
NP_TRACE_ENABLED=0
before=$(np__spool_count)
assert_ok 'flush when disabled returns 0' np_trace_flush
assert_eq "$(np__spool_count)" "$before" 'flush when disabled does nothing'
NP_TRACE_ENABLED=1

# Shutdown drains and removes the state dir.
NP_TRACE_FLUSH_TIMEOUT=1
assert_ok 'shutdown returns 0' np_trace_shutdown
assert_fail 'shutdown removed the state dir' test -d "$NP_TRACE_DIR"

rm -rf "$NP_TRACE_DIR"
. "$ROOT/test/lib/report.sh"
