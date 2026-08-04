#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

u=$(np__uuidv7)
assert_eq "${#u}" 36 'uuid is 36 chars'
assert_match "$u" \
  '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-7[0-9a-f][0-9a-f][0-9a-f]-[89ab][0-9a-f][0-9a-f][0-9a-f]-*' \
  'uuid has version 7 and an RFC 4122 variant nibble'

# The first 12 hex chars are the big-endian millisecond timestamp. Decode it
# and check it is within a minute of now.
hex=$(printf '%s' "$u" | cut -c1-8)$(printf '%s' "$u" | cut -c10-13)
embedded=$(printf '%d' "0x$hex")
now=$(np__epoch_ms)
delta=$((now - embedded))
[ "$delta" -lt 0 ] && delta=$((-delta))
if [ "$delta" -lt 60000 ]; then
  assert_eq 'fresh' 'fresh' 'embedded timestamp is within 60s of now'
else
  assert_eq "stale by ${delta}ms" 'fresh' 'embedded timestamp is within 60s of now'
fi

# Uniqueness across rapid calls.
first=$(np__uuidv7)
second=$(np__uuidv7)
if [ "$first" = "$second" ]; then
  assert_eq 'identical' 'different' 'consecutive uuids differ'
else
  assert_eq 'different' 'different' 'consecutive uuids differ'
fi

# The variant nibble must always land in [89ab] across many draws.
i=0
bad=0
while [ "$i" -lt 40 ]; do
  v=$(printf '%s' "$(np__uuidv7)" | cut -c20)
  case "$v" in
    8 | 9 | a | b) ;;
    *) bad=$((bad + 1)) ;;
  esac
  i=$((i + 1))
done
assert_eq "$bad" 0 'variant nibble is always 8, 9, a or b'

pub=$(np_trace_occurrence)
assert_eq "${#pub}" 36 'np_trace_occurrence returns a uuid'

. "$ROOT/test/lib/report.sh"
