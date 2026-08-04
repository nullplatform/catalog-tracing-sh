#!/bin/sh
# End-to-end against a running tracing API — the only test that can prove the
# hand-ported wire contract is actually accepted by real ingest.
# Skipped unless NP_LIVE_URL is set.
set -u
. "$ROOT/test/lib/assert.sh"

if [ -z "${NP_LIVE_URL:-}" ]; then
  printf 'SKIP: set NP_LIVE_URL to run the live suite\n'
  . "$ROOT/test/lib/report.sh"
  return 0 2>/dev/null || exit 0
fi

. "$ROOT/nptrace.sh"

# Build a JWT-shaped bearer for the local dev stack. The API decodes but never
# verifies it (the auth service does that), so the signature is a placeholder.
# Identity: the local demo user, whose org the dev authz mock grants.
b64url() { base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='; }
make_dev_token() {
  _mt_now=$(date +%s)
  _mt_hdr=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
  _mt_pl=$(printf '{"sub":"1234567890","cognito:groups":["@nullplatform/user=%s","@nullplatform/organization=%s"],"organization":%s,"user":%s,"iat":%s,"exp":%s}' \
    "${NP_LIVE_USER:-1}" "${NP_LIVE_ORG:-1255165411}" \
    "${NP_LIVE_ORG:-1255165411}" "${NP_LIVE_USER:-1}" \
    "$_mt_now" "$((_mt_now + 3600))" | b64url)
  printf 'Bearer %s.%s.devsig' "$_mt_hdr" "$_mt_pl"
}

LIVE_TOKEN=${NP_LIVE_TOKEN:-$(make_dev_token)}

NP_TRACE_DIR="$ROOT/.nptrace-test/live-$$"
rm -rf "$NP_TRACE_DIR"
np_trace_init --producer 'catalog-tracing-sh-test@0.1' \
              --token "$LIVE_TOKEN" \
              --base-url "$NP_LIVE_URL" \
              --no-trap

TRACE=$(np_trace_key 'shtest' "$(np_trace_occurrence)")

run=$(np_trace_run --trace-id "$TRACE" --run-id "$TRACE")
np_trace_labels entity=build action=publish 'application.id=42'
np_trace_explain --title 'Shell SDK end-to-end' --what 'Emitted by the POSIX sh SDK test suite'

compile=$(np_trace_step "$run" compile)
np_trace_complete "$compile"

publish=$(np_trace_step "$run" publish)
np_trace_error "$publish" --message 'registry unreachable' --code 'EREG'
np_trace_fail "$publish"

nested_parent=$(np_trace_step "$run" verify)
nested=$(np_trace_step "$nested_parent" checksum)
np_trace_complete "$nested"
np_trace_complete "$nested_parent"

np_trace_complete "$run"

spooled=$(np__spool_count)
assert_match "$spooled" '[1-9]*' 'events were spooled'

np_trace_flush

# Every event must have been accepted: nothing left in spool, nothing failed.
assert_eq "$(np__spool_count)" 0 'all events accepted by ingest'
failed=$(find "$NP_TRACE_DIR/failed" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$failed" 0 'no event was rejected'
if [ -f "$NP_TRACE_DIR/drops.log" ]; then
  drops=$(wc -l < "$NP_TRACE_DIR/drops.log" | tr -d ' ')
else
  drops=0
fi
assert_eq "$drops" 0 'no drops recorded'

# Re-flushing an already-delivered spool file must be an idempotent 200.
printf '%s' "$(np__json_obj_raw \
  id "$(np__json_str "$(np__uuidv7)")" \
  time "$(np__json_str "$(np__iso8601)")" \
  type "$(np__json_str "$NP_TYPE_NODE_RUN")" \
  producer "$(np__json_str 'dup@1')" \
  data "$(np__json_obj trace_id 'dup-probe' run_id 'dup-probe' status started)")" \
  > "$NP_TRACE_DIR/spool/dup.json"
first=$(np__post_event "$NP_TRACE_DIR/spool/dup.json")
second=$(np__post_event "$NP_TRACE_DIR/spool/dup.json")
assert_eq "$first" '201' 'first POST of an event is 201 created'
assert_eq "$second" '200' 're-POST of the same event id is 200 duplicate'
rm -f "$NP_TRACE_DIR/spool/dup.json"

# A deliberately malformed event must be rejected 400 and dead-lettered, never
# retried — and the pipeline still survives.
printf '{"id":"not-a-uuid","time":"nope","type":"node.run","producer":"x@1","data":{}}' \
  > "$NP_TRACE_DIR/spool/bad.json"
np_trace_flush
assert_ok 'a malformed event is dead-lettered' test -f "$NP_TRACE_DIR/failed/bad.json"

rm -rf "$NP_TRACE_DIR"
. "$ROOT/test/lib/report.sh"
