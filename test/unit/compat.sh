#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

ms=$(np__epoch_ms)
assert_match "$ms" '[0-9]*' 'epoch_ms is all digits'
# 13 digits covers 2001-09-09 through 2286; any sane clock lands here.
assert_eq "${#ms}" 13 'epoch_ms is 13 digits'

case "$ms" in
  *[!0-9]*) assert_eq 'non-numeric' 'numeric' 'epoch_ms contains only digits' ;;
  *) assert_eq 'numeric' 'numeric' 'epoch_ms contains only digits' ;;
esac

h=$(np__rand_hex 19)
assert_eq "${#h}" 19 'rand_hex returns exactly 19 chars'
case "$h" in
  *[!0-9a-f]*) assert_eq 'non-hex' 'hex' 'rand_hex contains only hex chars' ;;
  *) assert_eq 'hex' 'hex' 'rand_hex contains only hex chars' ;;
esac

a=$(np__rand_hex 32)
b=$(np__rand_hex 32)
assert_eq "${#a}" 32 'rand_hex 32 returns 32 chars'
if [ "$a" = "$b" ]; then
  assert_eq 'identical' 'different' 'two rand_hex calls differ'
else
  assert_eq 'different' 'different' 'two rand_hex calls differ'
fi

ts=$(np__iso8601)
assert_match "$ts" '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*Z' 'iso8601 is RFC 3339 UTC'

. "$ROOT/test/lib/report.sh"
