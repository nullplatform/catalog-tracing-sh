#!/usr/bin/env bats
#
# The portability shims. Every one of these papers over a real difference
# between GNU, BSD and busybox tooling, so running them in the target shell is
# the whole point of the suite.

load '../helper'

@test "epoch_ms is 13 digits and nothing but digits" {
  np_sh 'ms=$(np__epoch_ms); printf "%s %s" "${#ms}" "$(printf "%s" "$ms" | tr -d "0-9" | wc -c | tr -d " ")"'
  # 13 digits covers 2001-09-09 through 2286; any sane clock lands there.
  assert_out '13 0'
}

@test "epoch_ms is really milliseconds, not seconds wearing a disguise" {
  # busybox 1.37 silently DROPS an unsupported %3N rather than leaking it, so
  # the result is clean digits that are actually seconds. Left unchecked that
  # puts a seconds value in UUIDv7's millisecond field, and every id decodes to
  # 1970 and sorts before everyone else's. Compare against a known-seconds
  # clock rather than trusting the shape.
  np_sh '
    ms=$(np__epoch_ms)
    expected=$(( $(date -u +%s) * 1000 ))
    delta=$(( ms - expected ))
    [ "$delta" -lt 0 ] && delta=$(( -delta ))
    if [ "$delta" -lt 5000 ]; then echo ok; else echo "off by ${delta}ms"; fi
  '
  assert_out 'ok'
}

@test "rand_hex returns the requested length in hex only" {
  np_sh 'h=$(np__rand_hex 19); printf "%s %s" "${#h}" "$(printf "%s" "$h" | tr -d "0-9a-f" | wc -c | tr -d " ")"'
  assert_out '19 0'
}

@test "rand_hex honours a different length" {
  np_sh 'h=$(np__rand_hex 32); printf "%s" "${#h}"'
  assert_out '32'
}

@test "two rand_hex calls differ" {
  np_sh '[ "$(np__rand_hex 32)" != "$(np__rand_hex 32)" ] && echo different'
  assert_out 'different'
}

@test "iso8601 is RFC 3339 UTC" {
  np_sh 'np__iso8601'
  assert_out_match '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*Z'
}
