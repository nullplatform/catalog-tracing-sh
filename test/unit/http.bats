#!/usr/bin/env bats
#
# Transport and credential handling.

load '../helper'

@test "a drop is recorded to drops.log" {
  np_sh_state '
    np__drop evt-1 "test reason"
    [ -f "$NP_TRACE_DIR/drops.log" ] || { echo "no drops.log"; exit 1; }
    cat "$NP_TRACE_DIR/drops.log"
  '
  assert_out_match '*evt-1*test reason*'
}

@test "a configured drop listener is invoked" {
  np_sh_state '
    np_test_on_drop() { printf "listener:%s\n" "$1" >>"$NP_TRACE_DIR/listener.log"; }
    NP_TRACE_ON_DROP=np_test_on_drop
    np__drop evt-2 another
    cat "$NP_TRACE_DIR/listener.log"
  '
  assert_out_match '*listener:evt-2*'
}

@test "a drop is silent by default and visible under NP_TRACE_DEBUG" {
  # Tracing must never add noise to a build log it does not own.
  np_sh_state 'np__drop evt-3 quiet 2>&1'
  assert_out ''

  np_sh_state 'NP_TRACE_DEBUG=1 np__drop evt-4 loud 2>&1'
  assert_out_match '*evt-4*'
}

@test "the auth config is mode 600 and carries the bearer header" {
  np_sh_state '
    NP_TRACE_TOKEN=secret-token-value
    cfg=$(np__auth_config)
    [ -f "$cfg" ] || { echo "no config"; exit 1; }
    case "$(cat "$cfg")" in
      *"Authorization: Bearer secret-token-value"*) ;;
      *) echo "header missing"; exit 1 ;;
    esac
    # ls is the portable way to read the mode string; the path is ours.
    printf "%s" "$(ls -l "$cfg" | cut -c1-10)"
    rm -f "$cfg"
  '
  assert_out '-rw-------'
}

@test "a pre-issued token is returned as-is, with no network call" {
  np_sh_state 'NP_TRACE_TOKEN=secret-token-value; np__token'
  assert_out 'secret-token-value'
}

@test "no credentials yields an empty token without erroring" {
  np_sh_state 'NP_TRACE_TOKEN=""; NP_TRACE_API_KEY=""; printf "[%s]" "$(np__token)"'
  assert_out '[]'
  np_sh_state 'NP_TRACE_TOKEN=""; NP_TRACE_API_KEY=""; np__token >/dev/null'
  assert_ok
}

@test "an unreachable API yields 000, fails fast, and returns 0" {
  np_sh_state '
    NP_TRACE_TOKEN=t
    NP_TRACE_BASE_URL=http://127.0.0.1:1
    printf "{\"id\":\"x\"}" >"$NP_TRACE_DIR/spool/x.json"
    start=$(date +%s)
    code=$(np__post_event "$NP_TRACE_DIR/spool/x.json")
    elapsed=$(( $(date +%s) - start ))
    np__post_event "$NP_TRACE_DIR/spool/x.json" >/dev/null || { echo "returned non-zero"; exit 1; }
    if [ "$elapsed" -le 6 ]; then printf "%s fast" "$code"; else printf "%s %ss" "$code" "$elapsed"; fi
  '
  assert_out '000 fast'
}

@test "the curl config is removed after the POST" {
  np_sh_state '
    NP_TRACE_TOKEN=t
    NP_TRACE_BASE_URL=http://127.0.0.1:1
    printf "{\"id\":\"x\"}" >"$NP_TRACE_DIR/spool/x.json"
    np__post_event "$NP_TRACE_DIR/spool/x.json" >/dev/null
    find "$NP_TRACE_DIR" -name "curlcfg.*" | wc -l | tr -d " "
  '
  assert_out '0'
}

@test "LEAK CANARY: the bearer token never appears in an xtrace" {
  # CI scripts routinely `set -x`, and shell options are global, so a sourced
  # SDK function traces into the build log. The token must appear NOWHERE —
  # not in curl's argv, and not in the plumbing that writes the config file.
  local canary_dir
  canary_dir="$BATS_TEST_TMPDIR/canary"
  run env NP_TRACE_DIR="$canary_dir" NP_TRACE_TOKEN=LEAKCANARY \
    NP_TRACE_BASE_URL=http://127.0.0.1:1 \
    "$NP_TEST_SHELL" -x -c '
      . "$NPTRACE"
      np__state_init
      printf "{}" >"$NP_TRACE_DIR/spool/a.json"
      np__post_event "$NP_TRACE_DIR/spool/a.json"
    ' 2>&1

  local hits
  hits=$(printf '%s' "$output" | grep -c 'LEAKCANARY' || true)
  [ "$hits" -eq 0 ] || {
    printf 'token appeared %s times in the xtrace\n' "$hits" >&2; return 1; }

  # And prove the canary exercised the live auth path, rather than passing
  # because nothing happened.
  assert_out_match '*curlcfg*'
}
