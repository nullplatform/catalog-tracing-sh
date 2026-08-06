#!/usr/bin/env bats
#
# End-to-end against a running tracing API — the only test that can prove the
# hand-ported wire contract is actually accepted by real ingest.
# Skipped unless NP_LIVE_URL is set.

load '../helper'

setup() {
  [ -n "${NP_LIVE_URL:-}" ] || skip "set NP_LIVE_URL to run the live suite"
  if [ ! -f "$NPTRACE" ]; then
    printf 'nptrace.sh not found at %s (run ./build.sh)\n' "$NPTRACE" >&2
    return 1
  fi
  NP_TRACE_DIR="$BATS_TEST_TMPDIR/nptrace"
  export NP_TRACE_DIR
  LIVE_TOKEN=${NP_LIVE_TOKEN:-$(make_dev_token)}
  export LIVE_TOKEN
}

# A JWT-shaped bearer for the local dev stack. The API decodes but never
# verifies it (the auth service does that), so the signature is a placeholder.
make_dev_token() {
  local now hdr pl
  now=$(date +%s)
  b64url() { base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='; }
  hdr=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
  pl=$(printf '{"sub":"1234567890","cognito:groups":["@nullplatform/user=%s","@nullplatform/organization=%s"],"organization":%s,"user":%s,"iat":%s,"exp":%s}' \
    "${NP_LIVE_USER:-1}" "${NP_LIVE_ORG:-1255165411}" \
    "${NP_LIVE_ORG:-1255165411}" "${NP_LIVE_USER:-1}" \
    "$now" "$((now + 3600))" | b64url)
  printf 'Bearer %s.%s.devsig' "$hdr" "$pl"
}

# Run code with the SDK initialised against the live API.
np_live() {
  run "$NP_TEST_SHELL" -c '
    . "$NPTRACE"
    np_trace_init --producer "catalog-tracing-sh-test@0.1" \
                  --token "$LIVE_TOKEN" --base-url "$NP_LIVE_URL" --no-trap
    '"$1"
}

@test "a full trace is accepted by real ingest, with nothing rejected" {
  np_live '
    TRACE=$(np_trace_key shtest "$(np_trace_occurrence)")
    run=$(np_trace_run --trace-id "$TRACE" --run-id "$TRACE")
    np_trace_labels entity=build action=publish "application.id=42"
    np_trace_explain --title "Shell SDK end-to-end" \
                     --what "Emitted by the POSIX sh SDK test suite"

    compile=$(np_trace_step "$run" compile)
    np_trace_complete "$compile"

    publish=$(np_trace_step "$run" publish)
    np_trace_error "$publish" --message "registry unreachable" --code EREG
    np_trace_fail "$publish"

    # Nesting must survive real ingest at depth, not just locally.
    verify=$(np_trace_step "$run" verify)
    checksum=$(np_trace_step "$verify" checksum)
    np_trace_complete "$checksum"
    np_trace_complete "$verify"
    np_trace_complete "$run"

    [ "$(np__spool_count)" -gt 0 ] || { echo "nothing spooled"; exit 1; }
    np_trace_flush

    failed=$(find "$NP_TRACE_DIR/failed" -name "*.json" 2>/dev/null | wc -l | tr -d " ")
    if [ -f "$NP_TRACE_DIR/drops.log" ]; then
      drops=$(wc -l <"$NP_TRACE_DIR/drops.log" | tr -d " ")
    else
      drops=0
    fi
    printf "%s %s %s" "$(np__spool_count)" "$failed" "$drops"
  '
  # spool drained, nothing dead-lettered, nothing dropped
  assert_out '0 0 0'
}

@test "re-POSTing the same event id is an idempotent 200" {
  np_live '
    printf "%s" "$(np__json_obj_raw \
      id "$(np__json_str "$(np__uuidv7)")" \
      time "$(np__json_str "$(np__iso8601)")" \
      type "$(np__json_str "$NP_TYPE_NODE_RUN")" \
      producer "$(np__json_str dup@1)" \
      data "$(np__json_obj trace_id dup-probe run_id dup-probe status started)")" \
      >"$NP_TRACE_DIR/spool/dup.json"
    first=$(np__post_event "$NP_TRACE_DIR/spool/dup.json")
    second=$(np__post_event "$NP_TRACE_DIR/spool/dup.json")
    printf "%s %s" "$first" "$second"
  '
  assert_out '201 200'
}

@test "a malformed event is dead-lettered rather than retried forever" {
  np_live '
    printf "{\"id\":\"not-a-uuid\",\"time\":\"nope\",\"type\":\"node.run\",\"producer\":\"x@1\",\"data\":{}}" \
      >"$NP_TRACE_DIR/spool/bad.json"
    np_trace_flush
    [ -f "$NP_TRACE_DIR/failed/bad.json" ] && echo dead-lettered || echo retried
  '
  assert_out 'dead-lettered'
}
