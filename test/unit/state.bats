#!/usr/bin/env bats
#
# Handles and ambient context. POSIX sh has no associative arrays, so node
# state lives in files and "ambient" is a pointer keyed by $$ — see the
# command-substitution test below for the property that makes it work.

load '../helper'

@test "state init creates the three directories" {
  np_sh_state '
    for d in nodes spool failed; do
      [ -d "$NP_TRACE_DIR/$d" ] || { echo "missing $d"; exit 1; }
    done
    echo ok
  '
  assert_out 'ok'
}

@test "handles are allocated in sequence" {
  np_sh_state 'printf "%s %s" "$(np__handle_new)" "$(np__handle_new)"'
  assert_out 'n1 n2'
}

@test "only an allocated handle is a handle" {
  np_sh_state 'np__is_handle "$(np__handle_new)"'; assert_ok
  np_sh_state 'np__is_handle boom'; assert_nok
  np_sh_state 'np__is_handle ""'; assert_nok
  # A dropped-reason string must never be mistaken for a handle.
  np_sh_state 'np__is_handle "registry unreachable"'; assert_nok
  np_sh_state 'np__is_handle "../seq"'; assert_nok
}

@test "node fields round-trip and overwrite cleanly" {
  np_sh_state '
    h=$(np__handle_new)
    np__node_set "$h" run_id root
    np__node_set "$h" status started
    [ "$(np__node_get "$h" run_id)" = root ] || { echo "run_id lost"; exit 1; }
    [ "$(np__node_get "$h" absent)" = "" ] || { echo "absent not empty"; exit 1; }
    np__node_set "$h" status completed
    printf "%s %s" "$(np__node_get "$h" status)" "$(np__node_get "$h" run_id)"
  '
  assert_out 'completed root'
}

@test "values containing = and spaces survive verbatim" {
  np_sh_state '
    h=$(np__handle_new)
    np__node_set "$h" nrn "organization=1:application=42"
    np__node_set "$h" note "a value with spaces"
    printf "%s|%s" "$(np__node_get "$h" nrn)" "$(np__node_get "$h" note)"
  '
  assert_out 'organization=1:application=42|a value with spaces'
}

@test "a key that is a prefix of another does not collide" {
  np_sh_state '
    h=$(np__handle_new)
    np__node_set "$h" start A
    np__node_set "$h" started B
    printf "%s %s" "$(np__node_get "$h" start)" "$(np__node_get "$h" started)"
  '
  assert_out 'A B'
}

@test "nodes do not share fields" {
  np_sh_state '
    a=$(np__handle_new); b=$(np__handle_new)
    np__node_set "$a" run_id root
    np__node_set "$b" run_id other
    printf "%s %s" "$(np__node_get "$a" run_id)" "$(np__node_get "$b" run_id)"
  '
  assert_out 'root other'
}

@test "ambient set inside command substitution is visible to the caller" {
  # THE property the whole ambient rule rests on: POSIX \$\$ does not change in
  # a subshell, so a handle opened inside \$(...) — which is how every
  # np_trace_* verb is called — still registers for the caller.
  np_sh_state '
    inner=$(np__handle_new)
    np__ambient_set "$inner"
    [ "$(np__ambient)" = "$inner" ] || { echo "lost across substitution"; exit 1; }
    h2=$(np__handle_new)
    sub=$( np__ambient_set "$h2"; printf done )
    printf "%s %s" "$sub" "$([ "$(np__ambient)" = "$h2" ] && echo visible || echo lost)"
  '
  assert_out 'done visible'
}

@test "resolve_handle prefers an explicit handle and falls back to ambient" {
  np_sh_state '
    a=$(np__handle_new); b=$(np__handle_new)
    np__ambient_set "$a"
    printf "%s %s %s %s" \
      "$(np__resolve_handle "$b")" \
      "$(np__resolve_handle "some message")" \
      "$(np__resolve_handle "")" \
      "$(np__resolve_handle)"
  '
  assert_out 'n2 n1 n1 n1'
}

@test "NP_TRACE_CURRENT takes precedence over the per-pid pointer" {
  np_sh_state '
    a=$(np__handle_new); b=$(np__handle_new)
    np__ambient_set "$a"
    NP_TRACE_CURRENT="$b"
    first=$(np__ambient)
    NP_TRACE_CURRENT=""
    printf "%s %s" "$first" "$(np__ambient)"
  '
  assert_out 'n2 n1'
}

@test "clearing only applies to the handle that is actually current" {
  # Otherwise terminalizing an outer node would silently retarget an inner one.
  np_sh_state '
    a=$(np__handle_new); b=$(np__handle_new)
    np__ambient_set "$a"
    np__ambient_clear "$b"
    [ "$(np__ambient)" = "$a" ] || { echo "non-current clear was not a no-op"; exit 1; }
    np__ambient_clear "$a"
    printf "[%s]" "$(np__ambient)"
  '
  assert_out '[]'
}
