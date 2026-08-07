#!/usr/bin/env bats
#
# Cross-process trace context. The carrier format is shared with the Go and JS
# SDKs, so it is pinned literally.

load '../helper'

TRACE='0198a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b'

@test "extract splits a root carrier" {
  np_sh "np_trace_extract '1|$TRACE|$TRACE'"
  assert_out "$TRACE $TRACE"
}

@test "extract keeps a derived run_id intact" {
  # A run_id may contain '~' and '@'; only '|' delimits.
  np_sh "np_trace_extract '1|$TRACE|$TRACE~build@0.0'"
  assert_out "$TRACE $TRACE~build@0.0"
}

@test "a trace-only carrier yields the trace id for both" {
  np_sh "np_trace_extract '1|$TRACE'"
  assert_out "$TRACE $TRACE"
}

@test "malformed carriers are not context" {
  np_sh 'np_trace_extract ""'; assert_nok
  np_sh "np_trace_extract '$TRACE|$TRACE'"; assert_nok
  np_sh "np_trace_extract '2|$TRACE|$TRACE'"; assert_nok
}

@test "an absent NP_TRACE is not an error the caller must guard" {
  np_sh 'unset NP_TRACE 2>/dev/null || true; np_trace_extract'
  assert_nok
}

@test "inject packs a run, and a step at its derived id" {
  np_sh_state "
    run=\$(np_trace_run --trace-id $TRACE --run-id $TRACE)
    step=\$(np_trace_step \"\$run\" build)
    printf '%s\n%s' \"\$(np_trace_inject \"\$run\")\" \"\$(np_trace_inject \"\$step\")\"
  "
  assert_out "1|$TRACE|$TRACE
1|$TRACE|$TRACE~build@0.0"
}

@test "inject and extract round-trip" {
  np_sh_state "
    run=\$(np_trace_run --trace-id $TRACE --run-id $TRACE)
    step=\$(np_trace_step \"\$run\" build)
    np_trace_extract \"\$(np_trace_inject \"\$step\")\"
  "
  assert_out "$TRACE $TRACE~build@0.0"
}

# --- adopt -----------------------------------------------------------------
# The case that matters: the np CLI exports NP_TRACE pointing at the workflow
# step it is running, and a scope script instruments itself inside that step.

@test "adopt carries the upstream run_id and emits nothing" {
  np_sh_state "
    NP_TRACE='1|$TRACE|$TRACE~assume-role@0.0'
    export NP_TRACE
    parent=\$(np_trace_adopt)
    np__is_handle \"\$parent\" || { echo 'no handle'; exit 1; }
    printf '%s %s' \"\$(np__node_get \"\$parent\" run_id)\" \"\$(np__spool_count)\"
  "
  assert_out "$TRACE~assume-role@0.0 0"
}

@test "work started after adopt nests UNDER the adopted step" {
  np_sh_state "
    NP_TRACE='1|$TRACE|$TRACE~assume-role@0.0'
    export NP_TRACE
    parent=\$(np_trace_adopt)
    child=\$(np_trace_step \"\$parent\" resolve-arn)
    np_trace_complete \"\$child\"
    printf '%s\n' \"\$(np__node_get \"\$child\" run_id)\"
    wire
  "
  assert_out_match "$TRACE~assume-role@0.0~resolve-arn@0.0*"
  assert_out_match '*edge.parent*'
}

@test "an adopted node is never closed by us" {
  # It belongs to the process that created it. Emitting a terminal would
  # assert a state we did not observe, and race the real owner.
  np_sh_state "
    NP_TRACE='1|$TRACE|$TRACE~assume-role@0.0'
    export NP_TRACE
    parent=\$(np_trace_adopt)
    child=\$(np_trace_step \"\$parent\" resolve-arn)
    np_trace_complete \"\$child\"
    before=\$(np__spool_count)
    np_trace_complete \"\$parent\"
    np_trace_fail \"\$parent\" nope
    printf '%s %s %s' \"\$before\" \"\$(np__spool_count)\" \"\$(np__node_get \"\$parent\" closed)\"
  "
  # count unchanged by the two terminals, and the node still open
  [ "$(echo "$output" | cut -d' ' -f1)" = "$(echo "$output" | cut -d' ' -f2)" ] || {
    echo "an adopted node emitted a terminal: $output" >&2; return 1; }
  [ "$(echo "$output" | cut -d' ' -f3)" = "0" ] || {
    echo "an adopted node was closed: $output" >&2; return 1; }
}

@test "adopt without upstream context returns non-zero and emits nothing" {
  np_sh_state 'unset NP_TRACE 2>/dev/null || true; np_trace_adopt'
  assert_nok
  np_sh_state 'unset NP_TRACE 2>/dev/null || true; np_trace_adopt >/dev/null 2>&1; np__spool_count'
  assert_out '0'
}

@test "propagation is silent when the SDK is disabled" {
  np_sh_state "
    run=\$(np_trace_run --trace-id $TRACE --run-id $TRACE)
    NP_TRACE_ENABLED=0
    printf '[%s]' \"\$(np_trace_inject \"\$run\")\"
  "
  assert_out '[]'

  np_sh_state "
    NP_TRACE='1|$TRACE|$TRACE'
    export NP_TRACE
    NP_TRACE_ENABLED=0
    np_trace_adopt
  "
  assert_nok
}

# ── foreign enrichment: facts on an adopted node must reach the wire NOW ──
# An adopted node's owner closes it in another process, so nothing staged here
# would ever ride a local lifecycle emit. Setters on a foreign node therefore
# re-emit `started` with the full current bag — the same shape the JS SDK's
# late-enrichment flush produces.

@test "an error recorded on an adopted node reaches the spool immediately" {
  np_sh_state '
    h=$(np_trace_adopt "1|trace-9|scope-42~iam@0.0")
    np_trace_error "$h" --message "role creation denied" --code EACCESS
    wire
  '
  assert_ok
  echo "$output" | jq -e '
    select(.type == "node.run")
    | select(.data.run_id == "scope-42~iam@0.0")
    | select(.data.status == "started")
    | .data.facets["tracing.error"]
    | (.message == "role creation denied" and .code == "EACCESS")
  ' >/dev/null
}

@test "labels on an adopted node re-emit with the full current bag" {
  np_sh_state '
    h=$(np_trace_adopt "1|t|r~wait@0.0")
    np_trace_labels "$h" "wait.elapsed_s=90" "wait.timeout_s=300"
    wire
  '
  assert_ok
  echo "$output" | jq -e '
    select(.type == "node.run") | select(.data.run_id == "r~wait@0.0")
    | .data.labels
    | (.["wait.elapsed_s"] == "90" and .["wait.timeout_s"] == "300")
  ' >/dev/null
}

@test "each foreign setter is its own event — successive errors are all observable" {
  np_sh_state '
    h=$(np_trace_adopt "1|t|r~apply@0.0")
    np_trace_error "$h" --message "first failure"
    np_trace_error "$h" --message "second failure"
    wire | grep -c "node.run"
  '
  assert_out '2'
}

@test "owned nodes still stage: a setter alone emits nothing extra" {
  # The owner terminal carries staged context, exactly as before — the re-emit
  # is FOREIGN-only, so owned flows gain no event-volume.
  np_sh_state '
    run=$(np_trace_run --trace-id t --run-id my-own-run)
    np_trace_error "$run" --message "will ride the terminal"
    count_before=$(wire | grep -c "node.run" || true)
    np_trace_fail "$run"
    count_after=$(wire | grep -c "node.run")
    printf "%s %s" "$count_before" "$count_after"
  '
  # nothing before the terminal; started+failed after
  assert_out '0 2'
}
