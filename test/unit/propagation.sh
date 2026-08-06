#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

NP_TRACE_DIR="$ROOT/.nptrace-test/propagation-$$"
rm -rf "$NP_TRACE_DIR"
np_trace_init --producer 'test@0.1' --token 't' --base-url 'http://127.0.0.1:1' --no-trap

wire() {
  for _w_f in "$NP_TRACE_DIR/spool"/*.json; do
    [ -f "$_w_f" ] || continue
    cat "$_w_f"
    printf '\n'
  done
}

TRACE='0198a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b'

# --- extract -------------------------------------------------------------

assert_eq "$(np_trace_extract "1|$TRACE|$TRACE")" "$TRACE $TRACE" \
  'extract splits a root carrier'

# A run_id may contain '~' and '@'; only '|' delimits.
DERIVED="$TRACE~build@0.0"
assert_eq "$(np_trace_extract "1|$TRACE|$DERIVED")" "$TRACE $DERIVED" \
  'extract keeps a derived run_id intact'

assert_eq "$(np_trace_extract "1|$TRACE")" "$TRACE $TRACE" \
  'a trace-only carrier yields the trace id for both'

assert_fail 'empty carrier is not context' np_trace_extract ''
assert_fail 'unversioned carrier is rejected' np_trace_extract "$TRACE|$TRACE"
assert_fail 'unknown version is rejected' np_trace_extract "2|$TRACE|$TRACE"

# Absent NP_TRACE must not be an error the caller has to guard.
( unset NP_TRACE 2>/dev/null || true
  assert_fail 'no NP_TRACE means no context' np_trace_extract )

# --- inject --------------------------------------------------------------

run=$(np_trace_run --trace-id "$TRACE" --run-id "$TRACE")
assert_eq "$(np_trace_inject "$run")" "1|$TRACE|$TRACE" 'inject packs a run'

step=$(np_trace_step "$run" build)
assert_eq "$(np_trace_inject "$step")" "1|$TRACE|$TRACE~build@0.0" \
  'inject packs a step at its derived id'

# Round-trip: what we inject is what a downstream process extracts.
assert_eq "$(np_trace_extract "$(np_trace_inject "$step")")" \
  "$TRACE $TRACE~build@0.0" 'inject and extract round-trip'

np_trace_complete "$step"
np_trace_complete "$run"

# --- adopt ---------------------------------------------------------------

# The case that matters: the np CLI exports NP_TRACE pointing at the workflow
# step it is running, and a scope script instruments itself inside that step.
rm -rf "$NP_TRACE_DIR"
np__state_init
NP_TRACE="1|$TRACE|$TRACE~assume-role@0.0"
export NP_TRACE

parent=$(np_trace_adopt)
assert_ok 'adopt returns a handle' np__is_handle "$parent"
assert_eq "$(np__node_get "$parent" run_id)" "$TRACE~assume-role@0.0" \
  'adopted node carries the upstream run_id'
assert_eq "$(np__spool_count)" 0 'adopting emits nothing for a node we do not own'

# Work started here must nest UNDER the CLI's step, not beside it.
child=$(np_trace_step "$parent" resolve-arn)
assert_eq "$(np__node_get "$child" run_id)" "$TRACE~assume-role@0.0~resolve-arn@0.0" \
  'our step derives beneath the adopted step'
np_trace_complete "$child"

assert_match "$(wire)" "*\"$TRACE~assume-role@0.0~resolve-arn@0.0\"*" \
  'the nested step reaches the wire'
assert_match "$(wire)" '*edge.parent*' 'containment edge is emitted'

# We may never speak for a node we adopted.
before=$(np__spool_count)
np_trace_complete "$parent"
assert_eq "$(np__spool_count)" "$before" 'completing an adopted node emits nothing'
assert_eq "$(np__node_get "$parent" closed)" '0' 'adopted node stays open'
np_trace_fail "$parent" 'nope'
assert_eq "$(np__spool_count)" "$before" 'failing an adopted node emits nothing'

# --- adopt with no upstream ----------------------------------------------

rm -rf "$NP_TRACE_DIR"
np__state_init
unset NP_TRACE 2>/dev/null || true
assert_fail 'adopt without context returns non-zero' np_trace_adopt
assert_eq "$(np__spool_count)" 0 'a failed adopt emits nothing'

# --- disabled SDK stays silent -------------------------------------------

NP_TRACE="1|$TRACE|$TRACE"
export NP_TRACE
NP_TRACE_ENABLED=0
assert_eq "$(np_trace_inject "$run")" '' 'inject is silent when disabled'
assert_fail 'adopt is a no-op when disabled' np_trace_adopt
NP_TRACE_ENABLED=1

rm -rf "$NP_TRACE_DIR"
. "$ROOT/test/lib/report.sh"
