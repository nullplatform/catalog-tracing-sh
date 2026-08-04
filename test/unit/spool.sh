#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

NP_TRACE_DIR="$ROOT/.nptrace-test/spool-$$"
rm -rf "$NP_TRACE_DIR"
np__state_init
NP_TRACE_PRODUCER='test-suite@0.1'

assert_eq "$(np__spool_count)" 0 'spool starts empty'

id=$(np__spool "$NP_TYPE_NODE_RUN" 'organization=1' '{"trace_id":"t","run_id":"r"}')
assert_eq "${#id}" 36 'spool returns a uuid event id'
assert_eq "$(np__spool_count)" 1 'one event spooled'
assert_ok 'spool file is named for the event id' test -f "$NP_TRACE_DIR/spool/$id.json"

body=$(cat "$NP_TRACE_DIR/spool/$id.json")
assert_match "$body" '*"id":"'"$id"'"*'              'envelope carries the id'
assert_match "$body" '*"type":"node.run"*'           'envelope carries the type'
assert_match "$body" '*"producer":"test-suite@0.1"*' 'envelope carries the producer'
assert_match "$body" '*"nrn":"organization=1"*'      'envelope carries the nrn'
assert_match "$body" '*"trace_id":"t"*'              'envelope carries the data verbatim'
assert_match "$body" '*"time":"20*Z"*'               'envelope carries an RFC 3339 time'

# The envelope must be valid JSON with exactly the six wire fields.
if command -v jq >/dev/null 2>&1; then
  assert_ok 'envelope parses as JSON' \
    sh -c "jq -e . '$NP_TRACE_DIR/spool/$id.json' >/dev/null"
  keys=$(jq -r 'keys_unsorted | join(",")' "$NP_TRACE_DIR/spool/$id.json")
  assert_eq "$keys" 'id,time,type,nrn,producer,data' 'envelope has exactly the wire fields, in order'
  assert_eq "$(jq -r '.data.run_id' "$NP_TRACE_DIR/spool/$id.json")" 'r' 'data survives as an object'
fi

# No temp file may survive a successful spool.
leftover=$(find "$NP_TRACE_DIR/spool" -name '*.tmp' | wc -l | tr -d ' ')
assert_eq "$leftover" 0 'no temp files left behind'

# An omitted nrn is omitted from the envelope, not emitted as "".
id2=$(np__spool "$NP_TYPE_NODE_RUN" '' '{"trace_id":"t","run_id":"r2"}')
body2=$(cat "$NP_TRACE_DIR/spool/$id2.json")
case "$body2" in
  *'"nrn"'*) assert_eq 'present' 'absent' 'empty nrn is omitted' ;;
  *) assert_eq 'absent' 'absent' 'empty nrn is omitted' ;;
esac
assert_eq "$(np__spool_count)" 2 'two events spooled'

# Distinct events never collide on their file name.
id3=$(np__spool "$NP_TYPE_NODE_RUN" '' '{"trace_id":"t","run_id":"r3"}')
assert_eq "$(np__spool_count)" 3 'a third event spooled'
if [ "$id2" = "$id3" ]; then
  assert_eq 'collided' 'distinct' 'consecutive event ids are distinct'
else
  assert_eq 'distinct' 'distinct' 'consecutive event ids are distinct'
fi

# A value needing escaping must survive into a still-valid envelope.
id4=$(np__spool "$NP_TYPE_NODE_RUN" '' "$(np__json_obj_raw explain "$(np__json_obj title 'He said "go"')")")
if command -v jq >/dev/null 2>&1; then
  assert_ok 'envelope with escaped content parses' \
    sh -c "jq -e . '$NP_TRACE_DIR/spool/$id4.json' >/dev/null"
  assert_eq "$(jq -r '.data.explain.title' "$NP_TRACE_DIR/spool/$id4.json")" 'He said "go"' \
    'escaped content round-trips through the envelope'
fi

rm -rf "$NP_TRACE_DIR"
. "$ROOT/test/lib/report.sh"
