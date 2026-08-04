#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

assert_ok   'plain identifier valid'      np__is_identifier 'abc-123_x.y'
assert_fail 'empty invalid'               np__is_identifier ''
assert_fail 'tilde invalid'               np__is_identifier 'a~b'
assert_fail 'at-sign invalid'             np__is_identifier 'a@b'
assert_fail 'slash invalid'               np__is_identifier 'a/b'
assert_fail 'space invalid'               np__is_identifier 'a b'
assert_fail 'nrn shape invalid'           np__is_identifier 'organization=1:app=2'
assert_ok   'uuid is a valid identifier'  np__is_identifier '019fce87-2070-7114-a70a-af968f088c27'
assert_ok   'git sha is valid'            np__is_identifier '5f2e9c1a4b'
assert_ok   'dotted version is valid'     np__is_identifier '1.4.7'

assert_eq "$(np__derive_child_id 'root' 'build' 0 0)" 'root~build@0.0' 'derives a child id'
assert_eq "$(np__derive_child_id 'root~build@0.0' 'sub' 1 2)" 'root~build@0.0~sub@1.2' 'derives an N-level id'

assert_eq "$(np__scope_root_of 'root~build@0.0~sub@1.2')" 'root' 'scope root is the named prefix'
assert_eq "$(np__scope_root_of 'root')" 'root' 'a named id is its own scope root'

assert_eq "$(np__parse_node_id 'root~build@0.0')" 'root build 0 0' 'parses the last hop'
assert_eq "$(np__parse_node_id 'root~build@0.0~sub@1.2')" 'root~build@0.0 sub 1 2' 'parses the innermost hop'
assert_fail 'a named id does not parse as derived' np__parse_node_id 'root'
assert_fail 'a malformed derived id does not parse' np__parse_node_id 'root~build'
assert_fail 'non-numeric coordinates do not parse' np__parse_node_id 'root~build@a.b'

# Derive then parse must round-trip at any depth.
deep=$(np__derive_child_id "$(np__derive_child_id 'r' 'a' 0 0)" 'b' 3 4)
assert_eq "$deep" 'r~a@0.0~b@3.4' 'two-level derivation'
assert_eq "$(np__parse_node_id "$deep")" 'r~a@0.0 b 3 4' 'round-trips through parse'
assert_eq "$(np__scope_root_of "$deep")" 'r' 'deep id keeps its scope root'

assert_eq "$(np_trace_key a b c)" 'a-b-c' 'key joins with dash'
assert_eq "$(np_trace_key a '' c)" 'a-c' 'key drops empty parts'
assert_eq "$(np_trace_key)" '' 'key with no parts is empty'
assert_eq "$(np_trace_key '' '')" '' 'key of only empty parts is empty'
assert_eq "$(np_trace_key single)" 'single' 'key of one part'

long=$(awk 'BEGIN{for(i=0;i<257;i++)printf "a"}')
assert_fail 'over-long key rejected'  np__key_violation "$long"
assert_ok   'legal key accepted'      np__key_violation 'build'
assert_fail 'empty key rejected'      np__key_violation ''
assert_fail 'tilde key rejected'      np__key_violation 'a~b'
assert_fail 'tilde trace id rejected' np__trace_id_violation 'a~b'
assert_ok   'legal trace id accepted' np__trace_id_violation 'checkout-api-build-42'
assert_ok   'legal named id accepted' np__named_id_violation 'checkout-api-build-42'

# The violation helpers print a reason on rejection.
assert_match "$(np__key_violation 'a~b' || :)" '*identifier-charset*' 'charset violation explains itself'
assert_match "$(np__key_violation '' || :)" '*non-empty*' 'empty violation explains itself'
assert_match "$(np__key_violation "$long" || :)" '*exceeds 256*' 'length violation explains itself'

. "$ROOT/test/lib/report.sh"
