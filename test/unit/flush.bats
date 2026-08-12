#!/usr/bin/env bats
#
# Delivery against a dead API. The governing rule is the availability
# invariant: if the tracing API is down, the caller's pipeline must carry on
# unaffected — bounded in time, and never losing events to silence.

load '../helper'

# Spool n synthetic events, then run the given code. 127.0.0.1:1 is unroutable,
# so every delivery attempt fails the way a dead API would.
seed_and() {
  local n=$1 code=$2
  np_sh_state '
    n=$1
    i=1
    while [ "$i" -le "$n" ]; do
      printf "{\"id\":\"e%s\"}" "$i" >"$NP_TRACE_DIR/spool/e$i.json"
      i=$((i + 1))
    done
    '"$code" "$n"
}

@test "flush returns 0 against a dead API and retains the spool" {
  # Retained, not dropped: a network failure is transient by assumption.
  seed_and 3 '
    np_trace_flush || { echo "flush returned non-zero"; exit 1; }
    printf "%s" "$(np__spool_count)"
  '
  assert_out '3'
}

@test "flush against a dead API stays inside its time budget" {
  seed_and 3 '
    start=$(date +%s)
    np_trace_flush
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -le 12 ]; then echo bounded; else echo "${elapsed}s"; fi
  '
  assert_out 'bounded'
}

@test "the attempt counter starts at 1 and advances per flush" {
  seed_and 3 '
    np_trace_flush
    [ -f "$NP_TRACE_DIR/spool/e1.json.attempts" ] || { echo "no sidecar"; exit 1; }
    first=$(cat "$NP_TRACE_DIR/spool/e1.json.attempts")
    np_trace_flush
    printf "%s %s" "$first" "$(cat "$NP_TRACE_DIR/spool/e1.json.attempts")"
  '
  assert_out '1 2'
}

@test "an event that exhausts its retries moves to failed/ and is logged" {
  # Otherwise a permanently-rejected event would be retried forever.
  seed_and 3 '
    np_trace_flush          # attempt 1
    np_trace_flush          # attempt 2
    NP_TRACE_MAX_RETRIES=1  # now already past the cap
    np_trace_flush
    [ -f "$NP_TRACE_DIR/failed/e1.json" ] || { echo "not moved to failed/"; exit 1; }
    [ ! -f "$NP_TRACE_DIR/spool/e1.json" ] || { echo "still in spool"; exit 1; }
    [ ! -f "$NP_TRACE_DIR/spool/e1.json.attempts" ] || { echo "sidecar left"; exit 1; }
    cat "$NP_TRACE_DIR/drops.log"
  '
  assert_out_match '*gave up*'
}

@test "flushing an empty spool is fine" {
  np_sh_state '
    np_trace_flush || { echo "non-zero"; exit 1; }
    printf "%s" "$(np__spool_count)"
  '
  assert_out '0'
}

@test "a tight budget cuts a long drain short and keeps the events" {
  seed_and 12 '
    NP_TRACE_FLUSH_TIMEOUT=1
    start=$(date +%s)
    np_trace_flush
    elapsed=$(( $(date +%s) - start ))
    [ "$(np__spool_count)" -gt 0 ] || { echo "events lost"; exit 1; }
    if [ "$elapsed" -le 8 ]; then echo "cut short"; else echo "${elapsed}s"; fi
  '
  assert_out 'cut short'
}

@test "flush when disabled does nothing at all" {
  seed_and 3 '
    NP_TRACE_ENABLED=0
    np_trace_flush || { echo "non-zero"; exit 1; }
    printf "%s" "$(np__spool_count)"
  '
  assert_out '3'
}

@test "shutdown drains within its budget and removes the state dir" {
  seed_and 3 '
    NP_TRACE_FLUSH_TIMEOUT=1
    np_trace_shutdown || { echo "non-zero"; exit 1; }
    [ ! -d "$NP_TRACE_DIR" ] && echo removed || echo "state dir survived"
  '
  assert_out 'removed'
}
