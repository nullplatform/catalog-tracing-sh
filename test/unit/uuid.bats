#!/usr/bin/env bats
#
# UUIDv7 is hand-rolled on the stdlib of /bin/sh, and the API validates the
# version and variant nibbles by regex — a generator that drifts produces
# events the API rejects with a 400, so these are pinned tightly.

load '../helper'

@test "uuid is 36 chars with a version 7 and an RFC 4122 variant nibble" {
  np_sh 'u=$(np__uuidv7); printf "%s %s" "${#u}" "$u"'
  assert_out_match '36 [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-7[0-9a-f][0-9a-f][0-9a-f]-[89ab][0-9a-f][0-9a-f][0-9a-f]-*'
}

@test "the embedded timestamp is within a minute of now" {
  # The first 12 hex chars are the big-endian millisecond timestamp.
  np_sh '
    u=$(np__uuidv7)
    hex=$(printf "%s" "$u" | cut -c1-8)$(printf "%s" "$u" | cut -c10-13)
    embedded=$(printf "%d" "0x$hex")
    delta=$(( $(np__epoch_ms) - embedded ))
    [ "$delta" -lt 0 ] && delta=$(( -delta ))
    if [ "$delta" -lt 60000 ]; then echo fresh; else echo "stale by ${delta}ms"; fi
  '
  assert_out 'fresh'
}

@test "consecutive uuids differ" {
  np_sh '[ "$(np__uuidv7)" != "$(np__uuidv7)" ] && echo different'
  assert_out 'different'
}

@test "the variant nibble is always 8, 9, a or b across many draws" {
  np_sh '
    i=0; bad=0
    while [ "$i" -lt 40 ]; do
      v=$(printf "%s" "$(np__uuidv7)" | cut -c20)
      case "$v" in 8|9|a|b) ;; *) bad=$((bad + 1)) ;; esac
      i=$((i + 1))
    done
    printf "%s" "$bad"
  '
  assert_out '0'
}

@test "np_trace_occurrence exposes a uuid on the public surface" {
  np_sh 'u=$(np_trace_occurrence); printf "%s" "${#u}"'
  assert_out '36'
}
