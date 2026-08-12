#!/usr/bin/env bats
#
# Lineage: produces/consumes edges, io pointer descriptors, affordances and
# progress. The wire is the assertion surface — what matters is the bytes the
# API would receive.

load '../helper'

@test "produces emits an edge to the dataset with the pointer as its binding" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_produces "$run" "dns-record:api.example.com" \
      --name dns_record --uri "api.example.com"
    wire
  '
  assert_out_match '*"edge.produces"*'
  assert_out_match '*"type":"dataset"*'
  assert_out_match '*"id":"dns-record:api.example.com"*'
  assert_out_match '*"tracing.binding"*'
  assert_out_match '*"kind":"pointer"*'
  assert_out_match '*"name":"dns_record"*'
  assert_out_match '*"uri":"api.example.com"*'
}

@test "the pointer also rides the node terminal as its tracing.output facet" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_produces "$run" "dns-record:api.example.com" \
      --name dns_record --uri "api.example.com"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"tracing.output":\[{"kind":"pointer","name":"dns_record","uri":"api.example.com"}\]*'
}

@test "consumes is the mirror: edge.consumes and tracing.input" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_consumes "$run" "docker-image:registry.example.com/app:1.2" \
      --name image --uri "registry.example.com/app:1.2"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"edge.consumes"*'
  assert_out_match '*"id":"docker-image:registry.example.com/app:1.2"*'
  assert_out_match '*"tracing.input":\[{"kind":"pointer","name":"image"*'
}

@test "a bare dataset id records lineage only — no binding, no io facet" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_produces "$run" "report:tr1"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"edge.produces"*'
  assert_out_match '*"id":"report:tr1"*'
  ! [[ "$output" == *'"tracing.binding"'* ]]
  ! [[ "$output" == *'"tracing.output"'* ]]
}

@test "successive produces accumulate descriptors — the io facet is an array" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_produces "$run" "k8s-service:ns/svc" --name service --uri "ns/svc"
    np_trace_produces "$run" "k8s-ingress:ns/ing" --name ingress --uri "ns/ing"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"tracing.output":\[{"kind":"pointer","name":"service","uri":"ns/svc"},{"kind":"pointer","name":"ingress","uri":"ns/ing"}\]*'
}

@test "an io edge forces the from-node's lazy started" {
  # Spool filename order is not asserted (busybox UUIDv7s have second
  # granularity, so same-second files sort arbitrarily); the invariant is that
  # the produces call flushes the lazy `started` at all — the read model must
  # know the node the edge points from.
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_produces "$run" "report:tr1"
    wire
  '
  assert_out_match '*"status":"started"*'
  assert_out_match '*"edge.produces"*'
}

@test "a missing dataset id is a drop, never an edge" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_produces "$run"
    echo "rc=$?"
    wire
  '
  assert_out_match '*rc=0*'
  ! [[ "$output" == *'edge.produces'* ]]
}

@test "produces on an ADOPTED node is an observed fact: edge plus foreign re-emit" {
  np_sh_state '
    export NP_TRACE="1|tr9|upstream-run~apply@0.0"
    node=$(np_trace_adopt)
    np_trace_produces "$node" "k8s-namespace:ns-42" --name namespace --uri "ns-42"
    wire
  '
  assert_out_match '*"edge.produces"*'
  assert_out_match '*"run_id":"upstream-run~apply@0.0"*'
  assert_out_match '*"tracing.output"*'
}

@test "affordances: one object is normalized to the wire array" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_affordances "$run" "{\"kind\":\"deploy-log\",\"scope_id\":\"42\"}"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"tracing.affordances":\[{"kind":"deploy-log","scope_id":"42"}\]*'
}

@test "affordances: a bare array passes through; garbage is a drop" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_affordances "$run" "[{\"kind\":\"a\"},{\"kind\":\"b\"}]"
    np_trace_affordances "$run" "not json"
    echo "rc=$?"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*rc=0*'
  assert_out_match '*"tracing.affordances":\[{"kind":"a"},{"kind":"b"}\]*'
}

@test "progress records current/target as numbers, with the unit" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_progress "$run" 3 10 instances
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"tracing.progress":{"current":3,"target":10,"unit":"instances"}*'
}

@test "progress rejects non-integers as a drop" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_progress "$run" lots 10
    echo "rc=$?"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*rc=0*'
  ! [[ "$output" == *'"tracing.progress"'* ]]
}

@test "every lineage envelope is valid JSON" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_produces "$run" "k8s-service:ns/svc" --name service --uri "ns/svc"
    np_trace_consumes "$run" "docker-image:img"
    np_trace_affordances "$run" "{\"kind\":\"deploy-log\"}"
    np_trace_progress "$run" 1 2 percent
    np_trace_complete "$run"
    for f in "$NP_TRACE_DIR/spool"/*.json; do
      jq -e . "$f" >/dev/null || { echo "INVALID: $(cat "$f")"; exit 1; }
    done
    echo all-valid
  '
  assert_out_match '*all-valid*'
}

@test "the new verbs return 0 given nonsense and are no-ops when disabled" {
  np_sh_state '
    np_trace_produces; np_trace_consumes; np_trace_affordances; np_trace_progress
    NP_TRACE_ENABLED=0
    run=x np_trace_produces x "d:1" --name n --uri u
    echo "rc=$?"
    wire
  '
  assert_out_match '*rc=0*'
  ! [[ "$output" == *'edge.produces'* ]]
}

@test "inline output rides the node terminal with its value carried whole" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_output "$run" instances "{\"healthy\":2,\"desired\":3}"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"tracing.output":\[{"kind":"inline","name":"instances","value":{"healthy":2,"desired":3}}\]*'
}

@test "inline and pointer descriptors accumulate in one io array" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_produces "$run" "k8s-service:ns/svc" --name service --uri "ns/svc"
    np_trace_output "$run" instances "{\"healthy\":3}"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*"tracing.output":\[{"kind":"pointer","name":"service","uri":"ns/svc"},{"kind":"inline","name":"instances","value":{"healthy":3}}\]*'
}

@test "inline input is the mirror, and garbage values are drops" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_input "$run" traffic "{\"from\":0,\"desired\":100}"
    np_trace_input "$run" bad "not json"
    echo "rc=$?"
    np_trace_complete "$run"
    wire
  '
  assert_out_match '*rc=0*'
  assert_out_match '*"tracing.input":\[{"kind":"inline","name":"traffic","value":{"from":0,"desired":100}}\]*'
  ! [[ "$output" == *'not json'* ]]
}

@test "error --details carries the structured evidence" {
  np_sh_state '
    run=$(np_trace_run --trace-id tr1 --run-id tr1)
    np_trace_error "$run" --message "gave up" --details "{\"healthy\":1,\"desired\":3}"
    np_trace_fail "$run"
    wire
  '
  assert_out_match '*"tracing.error":{"message":"gave up","details":{"healthy":1,"desired":3}}*'
}

@test "inline io on an adopted node reaches the wire via the foreign re-emit" {
  np_sh_state '
    export NP_TRACE="1|tr9|upstream-run~wait@0.0"
    node=$(np_trace_adopt)
    np_trace_output "$node" instances "{\"healthy\":1}"
    wire
  '
  assert_out_match '*"run_id":"upstream-run~wait@0.0"*'
  assert_out_match '*"tracing.output":\[{"kind":"inline","name":"instances","value":{"healthy":1}}\]*'
}
