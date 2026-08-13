#!/usr/bin/env bats
#
# The public API. The wire is the assertion surface throughout: what matters is
# the bytes the API would receive, not the SDK's internal bookkeeping.

load '../helper'

@test "opening a run records its identity but emits nothing yet" {
  # Lazy started: nothing goes out until something must follow it, so late
  # context still lands on the started event.
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np__is_handle "$run" || { echo "no handle"; exit 1; }
    np_trace_labels entity=build action=publish
    np_trace_explain --title "Build checkout-api" --what "CI build"
    printf "%s %s %s" "$(np__node_get "$run" run_id)" \
      "$(np__node_get "$run" trace_id)" "$(np__spool_count)"
  '
  assert_out 'tr1 tr1 0'
}

@test "a step derives its id and inherits the trace" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    step=$(np_trace_step "$run" compile)
    printf "%s %s %s %s %s" \
      "$(np__node_get "$step" run_id)" "$(np__node_get "$step" key)" \
      "$(np__node_get "$step" attempt)" "$(np__node_get "$step" iteration)" \
      "$(np__node_get "$step" trace_id)"
  '
  assert_out 'tr1~compile@0.0 compile 0 0 tr1'
}

@test "opening a child forces the parent started and emits the containment edge" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_labels entity=build
    np_trace_step "$run" compile >/dev/null
    wire
  '
  assert_out_match '*"status":"started"*'
  assert_out_match '*"entity":"build"*'
  assert_out_match '*"edge.parent"*'
  assert_out_match '*"tr1~compile@0.0"*'
}

@test "the run terminal carries staged labels, explain and auto-stamped timing" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_labels entity=build action=publish
    np_trace_explain --title "Build checkout-api" --what "CI build"
    step=$(np_trace_step "$run" compile)
    np_trace_complete "$step"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"entity":"build"*'
  assert_out_match '*"action":"publish"*'
  assert_out_match '*"tracing.explain"*'
  assert_out_match '*"Build checkout-api"*'
  assert_out_match '*"tracing.timing"*'
  assert_out_match '*"status":"completed"*'
}

@test "every envelope is valid JSON with the right shape for its type" {
  require jq
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    step=$(np_trace_step "$run" compile)
    np_trace_complete "$step"
    np_trace_complete "$run"
    bad=0
    for f in "$NP_TRACE_DIR/spool"/*.json; do
      [ -f "$f" ] || continue
      jq -e . "$f" >/dev/null 2>&1 || bad=$((bad + 1))
      case "$(jq -r .type "$f")" in
        node.*) jq -e ".data.run_id" "$f" >/dev/null || bad=$((bad + 1)) ;;
        edge.*)
          jq -e ".data.from and .data.to" "$f" >/dev/null || bad=$((bad + 1))
          # An edge is a relationship, never a carrier of node context.
          jq -e "has(\"labels\") | not" "$f" >/dev/null || bad=$((bad + 1)) ;;
      esac
    done
    printf "%s" "$bad"
  '
  assert_out '0'
}

@test "a terminal on a closed node is a no-op, never a second terminal" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_step "$run" compile >/dev/null
    np_trace_complete "$run"
    before=$(np__spool_count)
    np_trace_complete "$run"
    printf "%s %s" "$before" "$(np__spool_count)"
  '
  [ "${output% *}" = "${output#* }" ] || {
    echo "spool count changed on double terminal: $output" >&2; return 1; }
}

@test "fail cascades to every still-open descendant" {
  np_sh_state '
    r2=$(np_trace_run --trace-id tr2 --run-id tr2)
    s2=$(np_trace_step "$r2" outer)
    s3=$(np_trace_step "$s2" inner)
    [ "$(np__node_get "$s3" run_id)" = "tr2~outer@0.0~inner@0.0" ] || {
      echo "bad sub-step id: $(np__node_get "$s3" run_id)"; exit 1; }
    np_trace_fail "$r2" boom
    printf "%s %s" "$(np__node_get "$s2" closed)" "$(np__node_get "$s3" closed)"
  '
  assert_out '1 1'
}

@test "a failure puts its status, error facet and message on the wire" {
  np_sh_state '
    r2=$(np_trace_run --trace-id tr2 --run-id tr2)
    s2=$(np_trace_step "$r2" outer)
    np_trace_step "$s2" inner >/dev/null
    np_trace_fail "$r2" boom
    wire
  '
  assert_out_match '*"status":"failed"*'
  assert_out_match '*"tracing.error"*'
  assert_out_match '*boom*'
}

@test "a retry is a distinct derived id" {
  np_sh_state '
    r3=$(np_trace_run --trace-id tr3 --run-id tr3)
    a0=$(np_trace_step "$r3" flaky)
    np_trace_fail "$a0" "first try"
    a1=$(np_trace_step "$r3" flaky --attempt 1)
    printf "%s" "$(np__node_get "$a1" run_id)"
  '
  assert_out 'tr3~flaky@1.0'
}

@test "ambient sugar targets the innermost open node, then falls back" {
  np_sh_state '
    r4=$(np_trace_run --trace-id tr4 --run-id tr4)
    s4=$(np_trace_step "$r4" work)
    np_trace_labels stage=inner          # no handle -> the step
    case "$(np__node_get "$s4" labels)" in *inner*) ;; *) echo "step missed"; exit 1 ;; esac
    [ "$(np__node_get "$r4" labels)" = "" ] || { echo "leaked to parent"; exit 1; }
    np_trace_complete "$s4"
    np_trace_labels stage=outer          # step closed -> back to the run
    case "$(np__node_get "$r4" labels)" in *outer*) echo ok ;; *) echo "no fallback"; exit 1 ;; esac
  '
  assert_out 'ok'
}

@test "every public verb returns 0, even given nonsense" {
  # The availability invariant: a broken call must never take the caller down.
  np_sh_state '
    set -e
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_labels "not-a-handle" "k=v"
    np_trace_complete "not-a-handle"
    np_trace_step "$run" "bad key!" >/dev/null
    np_trace_run --trace-id "a~b" --run-id ok >/dev/null
    np_trace_run --trace-id ok --run-id "a~b" >/dev/null
    np_trace_explain "$run"
    np_trace_waiting nope
    np_trace_skip nope
    echo ok
  '
  assert_out 'ok'
}

@test "contract violations are recorded as drops, and produce no node" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_step "$run" "bad key!" >/dev/null
    np_trace_run --trace-id "a~b" --run-id ok >/dev/null
    np_trace_run --trace-id ok --run-id "a~b" >/dev/null
    np_trace_explain "$run"
    printf "[%s]" "$(np_trace_run --trace-id "a~b" --run-id "a~b")"
    cat "$NP_TRACE_DIR/drops.log" 2>/dev/null || :
  '
  assert_out_match '\[\]*'
  assert_out_match '*key*'
  assert_out_match '*trace_id must be*'
  assert_out_match '*run_id must be*'
  assert_out_match '*title*'
}

@test "disabled mode is a real no-op" {
  np_sh_state '
    NP_TRACE_ENABLED=0
    d1=$(np_trace_run --trace-id off --run-id off)
    np_trace_labels x=y
    np_trace_complete "$d1"
    printf "%s" "$(np__spool_count)"
  '
  assert_out '0'
}
