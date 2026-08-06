#!/usr/bin/env bats
#
# The spool is the durability boundary: an event that reaches a file survives a
# dead API, and the file name IS the event id, which is what makes delivery
# idempotent.

load '../helper'

@test "spool starts empty" {
  np_sh_state 'np__spool_count'
  assert_out '0'
}

@test "spool returns a uuid event id and names the file after it" {
  np_sh_state '
    id=$(np__spool "$NP_TYPE_NODE_RUN" "organization=1" "{\"trace_id\":\"t\",\"run_id\":\"r\"}")
    [ -f "$NP_TRACE_DIR/spool/$id.json" ] || { echo "no file for $id"; exit 1; }
    printf "%s %s" "${#id}" "$(np__spool_count)"
  '
  assert_out '36 1'
}

@test "the envelope carries every wire field" {
  np_sh_state '
    NP_TRACE_PRODUCER="test-suite@0.1"
    id=$(np__spool "$NP_TYPE_NODE_RUN" "organization=1" "{\"trace_id\":\"t\",\"run_id\":\"r\"}")
    cat "$NP_TRACE_DIR/spool/$id.json"
  '
  assert_out_match '*"type":"node.run"*'
  assert_out_match '*"producer":"test-suite@0.1"*'
  assert_out_match '*"nrn":"organization=1"*'
  assert_out_match '*"trace_id":"t"*'
  assert_out_match '*"time":"20*Z"*'
}

@test "the envelope has exactly the six wire fields, in order" {
  require jq
  np_sh_state '
    id=$(np__spool "$NP_TYPE_NODE_RUN" "organization=1" "{\"trace_id\":\"t\",\"run_id\":\"r\"}")
    jq -r "keys_unsorted | join(\",\")" "$NP_TRACE_DIR/spool/$id.json"
  '
  assert_out 'id,time,type,nrn,producer,data'
}

@test "data survives as a nested object, not a string" {
  require jq
  np_sh_state '
    id=$(np__spool "$NP_TYPE_NODE_RUN" "" "{\"trace_id\":\"t\",\"run_id\":\"r\"}")
    jq -r ".data.run_id" "$NP_TRACE_DIR/spool/$id.json"
  '
  assert_out 'r'
}

@test "no temp file survives a successful spool" {
  np_sh_state '
    np__spool "$NP_TYPE_NODE_RUN" "" "{\"trace_id\":\"t\",\"run_id\":\"r\"}" >/dev/null
    find "$NP_TRACE_DIR/spool" -name "*.tmp" | wc -l | tr -d " "
  '
  assert_out '0'
}

@test "an empty nrn is omitted from the envelope, not emitted as an empty string" {
  np_sh_state '
    id=$(np__spool "$NP_TYPE_NODE_RUN" "" "{\"trace_id\":\"t\",\"run_id\":\"r2\"}")
    case "$(cat "$NP_TRACE_DIR/spool/$id.json")" in
      *\"nrn\"*) echo present ;;
      *) echo absent ;;
    esac
  '
  assert_out 'absent'
}

@test "consecutive event ids are distinct and never collide on file name" {
  np_sh_state '
    a=$(np__spool "$NP_TYPE_NODE_RUN" "" "{\"run_id\":\"r2\"}")
    b=$(np__spool "$NP_TYPE_NODE_RUN" "" "{\"run_id\":\"r3\"}")
    [ "$a" != "$b" ] || { echo collided; exit 1; }
    np__spool_count
  '
  assert_out '2'
}

@test "content needing escaping round-trips through a still-valid envelope" {
  require jq
  np_sh_state '
    id=$(np__spool "$NP_TYPE_NODE_RUN" "" \
      "$(np__json_obj_raw explain "$(np__json_obj title "He said \"go\"")")")
    jq -e . "$NP_TRACE_DIR/spool/$id.json" >/dev/null || { echo "invalid JSON"; exit 1; }
    jq -r ".data.explain.title" "$NP_TRACE_DIR/spool/$id.json"
  '
  assert_out 'He said "go"'
}
