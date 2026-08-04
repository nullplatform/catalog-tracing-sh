#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

NP_TRACE_DIR="$ROOT/.nptrace-test/state-$$"
rm -rf "$NP_TRACE_DIR"
np__state_init

assert_ok 'nodes dir created'  test -d "$NP_TRACE_DIR/nodes"
assert_ok 'spool dir created'  test -d "$NP_TRACE_DIR/spool"
assert_ok 'failed dir created' test -d "$NP_TRACE_DIR/failed"

h1=$(np__handle_new)
h2=$(np__handle_new)
assert_eq "$h1" 'n1' 'first handle is n1'
assert_eq "$h2" 'n2' 'second handle is n2'

assert_ok   'allocated handle is a handle'     np__is_handle "$h1"
assert_fail 'arbitrary string is not a handle' np__is_handle 'boom'
assert_fail 'empty string is not a handle'     np__is_handle ''
assert_fail 'a message is not a handle'        np__is_handle 'registry unreachable'
assert_fail 'a path traversal is not a handle' np__is_handle '../seq'

np__node_set "$h1" run_id 'root'
np__node_set "$h1" status 'started'
assert_eq "$(np__node_get "$h1" run_id)" 'root' 'node field round-trips'
assert_eq "$(np__node_get "$h1" status)" 'started' 'second field round-trips'
assert_eq "$(np__node_get "$h1" absent)" '' 'absent field is empty'

np__node_set "$h1" status 'completed'
assert_eq "$(np__node_get "$h1" status)" 'completed' 'field overwrite wins'
assert_eq "$(np__node_get "$h1" run_id)" 'root' 'overwrite leaves siblings intact'

# Values containing '=' and spaces must survive verbatim.
np__node_set "$h1" nrn 'organization=1:application=42'
assert_eq "$(np__node_get "$h1" nrn)" 'organization=1:application=42' 'value with = round-trips'
np__node_set "$h1" note 'a value with spaces'
assert_eq "$(np__node_get "$h1" note)" 'a value with spaces' 'value with spaces round-trips'

# A key that is a prefix of another must not collide.
np__node_set "$h1" start 'A'
np__node_set "$h1" started 'B'
assert_eq "$(np__node_get "$h1" start)" 'A' 'prefix key is not shadowed'
assert_eq "$(np__node_get "$h1" started)" 'B' 'longer key is not shadowed'

# Nodes are independent.
np__node_set "$h2" run_id 'other'
assert_eq "$(np__node_get "$h1" run_id)" 'root' 'nodes do not share fields'
assert_eq "$(np__node_get "$h2" run_id)" 'other' 'second node keeps its own'

np__ambient_set "$h1"
assert_eq "$(np__ambient)" "$h1" 'ambient is the set handle'

# THE property the ambient rule rests on: POSIX $$ does not change in a
# subshell, so a handle created inside $(...) is visible to the caller.
inner=$(np__handle_new)
np__ambient_set "$inner"
assert_eq "$(np__ambient)" "$inner" 'ambient survives command substitution'

sub=$( np__ambient_set "$h2"; printf 'done' )
assert_eq "$sub" 'done' 'subshell ran'
assert_eq "$(np__ambient)" "$h2" 'ambient set INSIDE a subshell is visible to the caller'

np__ambient_set "$h1"
assert_eq "$(np__resolve_handle "$h2")" "$h2" 'explicit handle wins'
assert_eq "$(np__resolve_handle 'some message')" "$h1" 'non-handle arg falls back to ambient'
assert_eq "$(np__resolve_handle '')" "$h1" 'empty arg falls back to ambient'
assert_eq "$(np__resolve_handle)" "$h1" 'missing arg falls back to ambient'

# NP_TRACE_CURRENT is level 1 and takes precedence over the per-pid pointer.
NP_TRACE_CURRENT="$h2"
assert_eq "$(np__ambient)" "$h2" 'NP_TRACE_CURRENT wins over the pid pointer'
NP_TRACE_CURRENT=''
assert_eq "$(np__ambient)" "$h1" 'clearing NP_TRACE_CURRENT falls back to the pid pointer'

# Clearing only applies when the cleared handle IS current, so terminalizing an
# outer node cannot silently retarget an inner one.
np__ambient_set "$h1"
np__ambient_clear "$h2"
assert_eq "$(np__ambient)" "$h1" 'clearing a non-current handle is a no-op'
np__ambient_clear "$h1"
assert_eq "$(np__ambient)" '' 'clearing the current handle empties it'

rm -rf "$NP_TRACE_DIR"
. "$ROOT/test/lib/report.sh"
