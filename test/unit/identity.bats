#!/usr/bin/env bats
#
# Identity is the wire contract: these rules must produce byte-identical ids to
# the TypeScript and Go SDKs, so they are pinned exactly rather than loosely.

load '../helper'

@test "identifier charset accepts legal values" {
  np_sh 'np__is_identifier "abc-123_x.y"'; assert_ok
  np_sh 'np__is_identifier "019fce87-2070-7114-a70a-af968f088c27"'; assert_ok
  np_sh 'np__is_identifier "5f2e9c1a4b"'; assert_ok
  np_sh 'np__is_identifier "1.4.7"'; assert_ok
}

@test "identifier charset rejects reserved and illegal characters" {
  np_sh 'np__is_identifier ""'; assert_nok
  np_sh 'np__is_identifier "a~b"'; assert_nok
  np_sh 'np__is_identifier "a@b"'; assert_nok
  np_sh 'np__is_identifier "a/b"'; assert_nok
  np_sh 'np__is_identifier "a b"'; assert_nok
  np_sh 'np__is_identifier "organization=1:app=2"'; assert_nok
}

@test "derives a child id" {
  np_sh 'np__derive_child_id "root" "build" 0 0'
  assert_out 'root~build@0.0'
}

@test "derives an N-level id" {
  np_sh 'np__derive_child_id "root~build@0.0" "sub" 1 2'
  assert_out 'root~build@0.0~sub@1.2'
}

@test "scope root is the named prefix at any depth" {
  np_sh 'np__scope_root_of "root~build@0.0~sub@1.2"'
  assert_out 'root'
  np_sh 'np__scope_root_of "root"'
  assert_out 'root'
}

@test "parses the last hop of a derived id" {
  np_sh 'np__parse_node_id "root~build@0.0"'
  assert_out 'root build 0 0'
}

@test "parses the innermost hop of a nested id" {
  np_sh 'np__parse_node_id "root~build@0.0~sub@1.2"'
  assert_out 'root~build@0.0 sub 1 2'
}

@test "malformed ids do not parse as derived" {
  np_sh 'np__parse_node_id "root"'; assert_nok
  np_sh 'np__parse_node_id "root~build"'; assert_nok
  np_sh 'np__parse_node_id "root~build@a.b"'; assert_nok
}

@test "derive and parse round-trip at depth" {
  np_sh 'np__derive_child_id "$(np__derive_child_id r a 0 0)" b 3 4'
  assert_out 'r~a@0.0~b@3.4'
  np_sh 'np__parse_node_id "r~a@0.0~b@3.4"'
  assert_out 'r~a@0.0 b 3 4'
  np_sh 'np__scope_root_of "r~a@0.0~b@3.4"'
  assert_out 'r'
}

@test "np_trace_key joins parts and drops empties" {
  np_sh 'np_trace_key a b c';      assert_out 'a-b-c'
  np_sh 'np_trace_key a "" c';     assert_out 'a-c'
  np_sh 'np_trace_key';            assert_out ''
  np_sh 'np_trace_key "" ""';      assert_out ''
  np_sh 'np_trace_key single';     assert_out 'single'
}

@test "key and id violations enforce the caps" {
  np_sh 'np__key_violation build'; assert_ok
  np_sh 'np__key_violation ""'; assert_nok
  np_sh 'np__key_violation "a~b"'; assert_nok
  np_sh 'np__key_violation "$(awk "BEGIN{for(i=0;i<257;i++)printf \"a\"}")"'; assert_nok
  np_sh 'np__trace_id_violation "a~b"'; assert_nok
  np_sh 'np__trace_id_violation checkout-api-build-42'; assert_ok
  np_sh 'np__named_id_violation checkout-api-build-42'; assert_ok
}

@test "violations explain themselves" {
  np_sh 'np__key_violation "a~b" || :'
  assert_out_match '*identifier-charset*'
  np_sh 'np__key_violation "" || :'
  assert_out_match '*non-empty*'
  np_sh 'np__key_violation "$(awk "BEGIN{for(i=0;i<257;i++)printf \"a\"}")" || :'
  assert_out_match '*exceeds 256*'
}
