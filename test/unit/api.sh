#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

NP_TRACE_DIR="$ROOT/.nptrace-test/api-$$"
rm -rf "$NP_TRACE_DIR"
np_trace_init --producer 'test@0.1' --token 't' --base-url 'http://127.0.0.1:1' --no-trap

# Read every spooled envelope, concatenated. The wire is the assertion surface.
wire() {
  for _w_f in "$NP_TRACE_DIR/spool"/*.json; do
    [ -f "$_w_f" ] || continue
    cat "$_w_f"
    printf '\n'
  done
}

run=$(np_trace_run --trace-id 'tr1' --run-id 'tr1')
assert_ok 'run returns a handle' np__is_handle "$run"
assert_eq "$(np__node_get "$run" run_id)" 'tr1' 'run records its run_id'
assert_eq "$(np__node_get "$run" trace_id)" 'tr1' 'run records its trace_id'

# Lazy started: nothing on the wire until something must follow it.
assert_eq "$(np__spool_count)" 0 'opening a run emits nothing yet'
np_trace_labels entity=build action=publish
np_trace_explain --title 'Build checkout-api' --what 'CI build'
assert_eq "$(np__spool_count)" 0 'staging context emits nothing'

step=$(np_trace_step "$run" compile)
assert_eq "$(np__node_get "$step" run_id)" 'tr1~compile@0.0' 'step id is derived'
assert_eq "$(np__node_get "$step" key)" 'compile' 'step records its key'
assert_eq "$(np__node_get "$step" attempt)" 0 'step defaults attempt to 0'
assert_eq "$(np__node_get "$step" iteration)" 0 'step defaults iteration to 0'
assert_eq "$(np__node_get "$step" trace_id)" 'tr1' 'step inherits the trace id'

# Opening a child forces the parent started, and emits the child + parent edge.
started_wire=$(wire)
assert_match "$started_wire" '*"status":"started"*' 'the parent started went out'
assert_match "$started_wire" '*"entity":"build"*' 'context staged before start landed on started'
assert_match "$started_wire" '*"edge.parent"*' 'a parent edge was emitted'
assert_match "$started_wire" '*"tr1~compile@0.0"*' 'the derived child id is on the wire'

np_trace_complete "$step"
assert_match "$(wire)" '*"status":"completed"*' 'the step completed'

np_trace_complete "$run"

# The run terminal must carry the staged labels and explain.
final=$(wire)
assert_match "$final" '*"entity":"build"*' 'labels reached the wire'
assert_match "$final" '*"action":"publish"*' 'second label reached the wire'
assert_match "$final" '*"tracing.explain"*' 'the explain facet reached the wire'
assert_match "$final" '*"Build checkout-api"*' 'the explain title reached the wire'
assert_match "$final" '*"tracing.timing"*' 'the timing facet is auto-stamped'

# Every envelope must be valid JSON and structurally legal.
if command -v jq >/dev/null 2>&1; then
  bad=0
  for f in "$NP_TRACE_DIR/spool"/*.json; do
    [ -f "$f" ] || continue
    jq -e . "$f" >/dev/null 2>&1 || bad=$((bad + 1))
  done
  assert_eq "$bad" 0 'every spooled envelope is valid JSON'

  # Node events carry status; edge events carry from/to and never labels.
  for f in "$NP_TRACE_DIR/spool"/*.json; do
    [ -f "$f" ] || continue
    t=$(jq -r '.type' "$f")
    case "$t" in
      node.*) jq -e '.data.run_id' "$f" >/dev/null || bad=$((bad + 1)) ;;
      edge.*)
        jq -e '.data.from and .data.to' "$f" >/dev/null || bad=$((bad + 1))
        jq -e 'has("labels") | not' "$f" >/dev/null || bad=$((bad + 1))
        ;;
    esac
  done
  assert_eq "$bad" 0 'node and edge events have their required shapes'
fi

# A terminal on a closed node is a no-op, never a second terminal.
before=$(np__spool_count)
np_trace_complete "$run"
assert_eq "$(np__spool_count)" "$before" 'double terminal is a no-op'

# --- fail cascades to still-open child steps; complete does not -------------
rm -f "$NP_TRACE_DIR"/spool/*.json 2>/dev/null || :
r2=$(np_trace_run --trace-id 'tr2' --run-id 'tr2')
s2=$(np_trace_step "$r2" outer)
s3=$(np_trace_step "$s2" inner)
assert_eq "$(np__node_get "$s3" run_id)" 'tr2~outer@0.0~inner@0.0' 'sub-step derives under its parent step'
np_trace_fail "$r2" 'boom'
cascade=$(wire)
assert_eq "$(np__node_get "$s2" closed)" 1 'fail cascaded to the open child step'
assert_eq "$(np__node_get "$s3" closed)" 1 'fail cascaded to the open grandchild step'
assert_match "$cascade" '*"status":"failed"*' 'failure reached the wire'
assert_match "$cascade" '*"tracing.error"*' 'the error facet reached the wire'
assert_match "$cascade" '*boom*' 'the error message reached the wire'

# --- attempts and iterations produce distinct nodes -------------------------
r3=$(np_trace_run --trace-id 'tr3' --run-id 'tr3')
a0=$(np_trace_step "$r3" flaky)
np_trace_fail "$a0" 'first try'
a1=$(np_trace_step "$r3" flaky --attempt 1)
assert_eq "$(np__node_get "$a1" run_id)" 'tr3~flaky@1.0' 'a retry is a distinct derived id'
np_trace_complete "$a1"
np_trace_complete "$r3"

# --- the ambient sugar targets the innermost open node ----------------------
r4=$(np_trace_run --trace-id 'tr4' --run-id 'tr4')
s4=$(np_trace_step "$r4" work)
np_trace_labels stage=inner        # no handle -> the step
assert_match "$(np__node_get "$s4" labels)" '*inner*' 'ambient labels hit the innermost node'
assert_eq "$(np__node_get "$r4" labels)" '' 'ambient labels did not hit the parent'
np_trace_complete "$s4"
np_trace_labels stage=outer        # the step closed -> back to the run
assert_match "$(np__node_get "$r4" labels)" '*outer*' 'ambient falls back to the parent after a terminal'
np_trace_complete "$r4"

# --- every public function returns 0, even given nonsense -------------------
assert_ok 'labels on a non-handle returns 0'    np_trace_labels 'not-a-handle' 'k=v'
assert_ok 'complete on a non-handle returns 0'  np_trace_complete 'not-a-handle'
assert_ok 'step with an illegal key returns 0'  np_trace_step "$run" 'bad key!'
assert_ok 'run with an illegal trace id returns 0' np_trace_run --trace-id 'a~b' --run-id 'ok'
assert_ok 'run with an illegal run id returns 0'  np_trace_run --trace-id 'ok' --run-id 'a~b'
assert_ok 'explain with no title returns 0'     np_trace_explain "$run"
assert_ok 'waiting on a non-handle returns 0'   np_trace_waiting 'nope'
assert_ok 'skip on a non-handle returns 0'      np_trace_skip 'nope'

# Client-detectable contract violations are recorded as drops, not crashes.
drops=$(cat "$NP_TRACE_DIR/drops.log" 2>/dev/null || printf '')
assert_match "$drops" '*key*' 'an illegal key is recorded as a drop'
assert_match "$drops" '*trace_id must be*' 'an illegal trace id is recorded as a drop'
assert_match "$drops" '*run_id must be*' 'an illegal run id is recorded as a drop'
assert_match "$drops" '*title*' 'a missing explain title is recorded as a drop'
# An illegal id must NOT have produced a node.
assert_eq "$(np_trace_run --trace-id 'a~b' --run-id 'a~b')" '' 'a rejected run returns no handle'

# --- disabled mode is a real no-op ------------------------------------------
NP_TRACE_ENABLED=0
before=$(np__spool_count)
d1=$(np_trace_run --trace-id 'off' --run-id 'off')
np_trace_labels x=y
np_trace_complete "$d1"
assert_eq "$(np__spool_count)" "$before" 'disabled mode emits nothing'
NP_TRACE_ENABLED=1

rm -rf "$NP_TRACE_DIR"
. "$ROOT/test/lib/report.sh"
