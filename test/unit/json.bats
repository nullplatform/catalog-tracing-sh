#!/usr/bin/env bats
#
# JSON escaping is the most shell-sensitive code in the SDK: the slow path runs
# under awk, and BSD awk, gawk and busybox awk disagree about byte handling.
# Every case here therefore runs in $NP_TEST_SHELL, not in bats' bash.

load '../helper'

@test "plain text passes through" {
  np_sh 'np__json_escape "$1"' 'plain'
  assert_out 'plain'
}

@test "double quotes are escaped" {
  np_sh 'np__json_escape "$1"' 'say "hi"'
  assert_out 'say \"hi\"'
}

@test "backslash is escaped" {
  np_sh 'np__json_escape "$1"' 'a\b'
  assert_out 'a\\b'
}

@test "tab is escaped" {
  np_sh 'np__json_escape "$1"' "$(printf 'a\tb')"
  assert_out 'a\tb'
}

@test "newline is escaped" {
  np_sh 'np__json_escape "$1"' "$(printf 'a\nb')"
  assert_out 'a\nb'
}

@test "UTF-8 passes through unescaped" {
  np_sh 'np__json_escape "$1"' 'héllo'
  assert_out 'héllo'
}

@test "json_str adds quotes" {
  np_sh 'np__json_str "$1"' 'x'
  assert_out '"x"'
}

@test "json_str of the empty string" {
  np_sh 'np__json_str "$1"' ''
  assert_out '""'
}

# --- differential against jq, the reference implementation -----------------

@test "matches jq across awkward inputs" {
  require jq
  while IFS= read -r sample; do
    np_sh 'np__json_str "$1"' "$sample"
    local theirs
    theirs=$(printf '%s' "$sample" | jq -Rs .)
    [ "$output" = "$theirs" ] || {
      printf 'sample:   [%s]\nexpected: [%s]\nactual:   [%s]\n' \
        "$sample" "$theirs" "$output" >&2
      return 1
    }
  done <<'SAMPLES'
plain
quote"inside
back\slash
sl/ash
héllo wörld
{"a":1}
trailing
 leading
日本語
emoji 🚀 here
mixed "q" and \b and é
SAMPLES
}

@test "matches jq for control characters and newlines" {
  require jq
  local sample
  for sample in "$(printf 'a\tb\nc')" "$(printf 'x\001y')" \
                "$(printf 'line1\nline2\nline3')" "$(printf 'a\n\nb')"; do
    np_sh 'np__json_str "$1"' "$sample"
    local theirs
    theirs=$(printf '%s' "$sample" | jq -Rs .)
    [ "$output" = "$theirs" ] || {
      printf 'expected: [%s]\nactual:   [%s]\n' "$theirs" "$output" >&2
      return 1
    }
  done
}

@test "output round-trips back through jq to the input" {
  require jq
  local sample
  for sample in 'plain' 'quote"inside' 'back\slash' 'héllo' '{"a":1}'; do
    np_sh 'np__json_str "$1" | jq -r .' "$sample"
    assert_out "$sample"
  done
}

# --- object builders -------------------------------------------------------

@test "object with two pairs" {
  np_sh 'np__json_obj a 1 b two'
  assert_out '{"a":"1","b":"two"}'
}

@test "empty value is omitted" {
  np_sh 'np__json_obj a 1 b ""'
  assert_out '{"a":"1"}'
}

@test "empty object" {
  np_sh 'np__json_obj'
  assert_out '{}'
}

@test "object escapes its values" {
  np_sh 'np__json_obj a "$1"' 'q"q'
  assert_out '{"a":"q\"q"}'
}

@test "empty key is omitted" {
  np_sh 'np__json_obj "" v'
  assert_out '{}'
}

@test "raw values are inserted verbatim" {
  np_sh 'np__json_obj_raw a "$1" b "$2"' '{"n":1}' '[]'
  assert_out '{"a":{"n":1},"b":[]}'
}

@test "raw empty value is omitted" {
  np_sh 'np__json_obj_raw a "" b 2'
  assert_out '{"b":2}'
}

@test "empty raw object" {
  np_sh 'np__json_obj_raw'
  assert_out '{}'
}

@test "builder output is valid JSON" {
  require jq
  np_sh 'np__json_obj a 1 b two | jq -e . >/dev/null && echo ok'
  assert_out 'ok'
}

@test "nested objects compose and stay valid" {
  require jq
  np_sh 'np__json_obj_raw outer "$(np__json_obj inner value)" n 42'
  assert_out '{"outer":{"inner":"value"},"n":42}'

  np_sh 'np__json_obj_raw outer "$(np__json_obj inner value)" n 42 | jq -e . >/dev/null && echo ok'
  assert_out 'ok'
}
