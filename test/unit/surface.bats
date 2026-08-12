#!/usr/bin/env bats
#
# The completed producer surface: the remaining core-facet setters, the
# run-to-run edges, and the definition nodes. The wire is the assertion
# surface throughout.

load '../helper'

# --- facet setters -----------------------------------------------------------

@test "actor records who acted, and rejects an unknown kind" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_actor "$run" user 1403978482 --source token
    np_trace_actor "$run" robot 9; echo "rc=$?"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*rc=0*'
  assert_out_match '*"tracing.actor":{"kind":"user","id":"1403978482","source":"token"}*'
  ! [[ "$output" == *'"robot"'* ]]
}

@test "decision carries the chosen branches and the option set" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_decision "$run" "blue-green" --available "initial,blue-green" --expression "strategy == blue_green"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"tracing.decision":{"chosen":\["blue-green"\],"available":\["initial","blue-green"\],"expression":"strategy == blue_green"}*'
}

@test "retry and signal carry their numbers as numbers" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_retry "$run" 2 --next-attempt 3 --delay-ms 4000
    np_trace_signal "$run" approval wait --timeout-ms 60000
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"tracing.retry":{"attempt":2,"next_attempt":3,"delay_ms":4000}*'
  assert_out_match '*"tracing.signal":{"name":"approval","direction":"wait","timeout_ms":60000}*'
}

@test "external links accumulate into one array" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_external_links "$run" ci "https://ci.example.com/run/9" --label "CI run"
    np_trace_external_links "$run" logs "https://logs.example.com/q"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"tracing.externalLinks":\[{"rel":"ci","uri":"https://ci.example.com/run/9","label":"CI run"},{"rel":"logs","uri":"https://logs.example.com/q"}\]*'
}

@test "engine status carries the engine's raw view verbatim" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_engine_status "$run" kubernetes Progressing --raw "{\"replicas\":3}"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"tracing.engineStatus":{"engine":"kubernetes","state":"Progressing","raw":{"replicas":3}}*'
}

@test "dropped pairs with skip to say what was intentionally not done" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    step=$(np_trace_step "$run" gated)
    np_trace_dropped "$step" "feature-flag off"
    np_trace_skip "$step"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"tracing.dropped":{"reason":"feature-flag off"}*'
  assert_out_match '*"status":"skipped"*'
}

@test "plan declares the expected steps on the run" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_plan "$run" "[{\"key\":\"compile\",\"title\":\"Compile\"},{\"key\":\"publish\"}]"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"tracing.plan":\[{"key":"compile","title":"Compile"},{"key":"publish"}\]*'
}

# --- run-to-run edges --------------------------------------------------------

@test "triggered_by links to another trace's run by its packed carrier" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_triggered_by "$run" "1|other-trace|scope-create-9"
    wire
  '
  assert_out_match '*"edge.triggered_by"*'
  assert_out_match '*"to":{"type":"run","trace_id":"other-trace","run_id":"scope-create-9"}*'
}

@test "the relation verbs share one contract, and a self-edge is a drop" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    other=$(np_trace_run --trace-id tr2 --run-id tr2)
    np_trace_retry_of "$run" "$other"
    np_trace_continues "$run" "1|tr3|prior-run"
    np_trace_correlates "$run" "$other"
    np_trace_compensates "$run" "1|tr1|tr1~apply@0.0"
    np_trace_triggered_by "$run" "$run"; echo "rc=$?"
    wire
  '
  assert_out_match '*rc=0*'
  assert_out_match '*"edge.retry_of"*'
  assert_out_match '*"edge.continues"*'
  assert_out_match '*"edge.correlates"*'
  assert_out_match '*"edge.compensates"*'
  count=$(printf "%s" "$output" | grep -o "edge.triggered_by" | wc -l | tr -d " ")
  [ "$count" -eq 0 ]
}

@test "link is the escape hatch, but only over known edge types" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_link "$run" edge.correlates "1|tr9|other"
    np_trace_link "$run" edge.made_up "1|tr9|other"; echo "rc=$?"
    wire
  '
  assert_out_match '*rc=0*'
  assert_out_match '*"edge.correlates"*'
  ! [[ "$output" == *'edge.made_up'* ]]
}

@test "instance_of points the run at its job definition" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_instance_of "$run" workflows k8s-scope-create 4f3a2b1c
    wire
  '
  assert_out_match '*"edge.instance_of"*'
  assert_out_match '*"to":{"type":"job","namespace":"workflows","name":"k8s-scope-create","version":"4f3a2b1c"}*'
}

# --- definition nodes --------------------------------------------------------

@test "a dataset node is an identity: an id and nothing else" {
  np_sh_state '
    np_trace_dataset "dns-record:api.example.com"
    wire
  '
  assert_out_match '*"node.dataset"*'
  assert_out_match '*"data":{"id":"dns-record:api.example.com"}*'
}

@test "a job node carries its plan, previewable before any run" {
  np_sh_state '
    np_trace_job workflows k8s-scope-create 4f3a2b1c --plan "[{\"key\":\"create-namespace\",\"optional\":true}]"
    wire
  '
  assert_out_match '*"node.job"*'
  assert_out_match '*"namespace":"workflows"*'
  assert_out_match '*"tracing.plan":\[{"key":"create-namespace","optional":true}\]*'
}

# --- the completed io kinds --------------------------------------------------

@test "a ref descriptor names an external catalog entity" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_output "$run" application --source catalog --external-id app-42 --version 3
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"tracing.output":\[{"kind":"ref","name":"application","source":"catalog","external_id":"app-42","version":"3"}\]*'
}

@test "produces accepts every descriptor kind as the edge binding" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_produces "$run" "asset:one" --name artifact --source registry --external-id img-9
    np_trace_consumes "$run" "asset:two" --name params --value "{\"replicas\":3}"
    wire
  '
  assert_out_match '*"tracing.binding":{"kind":"ref","name":"artifact","source":"registry","external_id":"img-9"}*'
  assert_out_match '*"tracing.binding":{"kind":"inline","name":"params","value":{"replicas":3}}*'
}

# --- safety ------------------------------------------------------------------

@test "every new verb returns 0 given nonsense and is silent when disabled" {
  np_sh_state '
    np_trace_actor; np_trace_decision; np_trace_retry; np_trace_signal
    np_trace_external_links; np_trace_engine_status; np_trace_dropped; np_trace_plan
    np_trace_triggered_by; np_trace_retry_of; np_trace_continues
    np_trace_correlates; np_trace_compensates; np_trace_link
    np_trace_instance_of; np_trace_dataset; np_trace_job
    NP_TRACE_ENABLED=0
    np_trace_dataset "d:1"; np_trace_job n j 1
    echo "rc=$?"
    wire
  '
  assert_out_match '*rc=0*'
  ! [[ "$output" == *'node.dataset'* ]]
  ! [[ "$output" == *'node.job'* ]]
}
