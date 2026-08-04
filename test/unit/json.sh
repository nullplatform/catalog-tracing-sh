#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

assert_eq "$(np__json_escape 'plain')" 'plain' 'plain text passes through'
assert_eq "$(np__json_escape 'say "hi"')" 'say \"hi\"' 'double quotes escaped'
assert_eq "$(np__json_escape 'a\b')" 'a\\b' 'backslash escaped'
assert_eq "$(np__json_escape "$(printf 'a\tb')")" 'a\tb' 'tab escaped'
assert_eq "$(np__json_escape "$(printf 'a\nb')")" 'a\nb' 'newline escaped'
assert_eq "$(np__json_escape 'héllo')" 'héllo' 'UTF-8 passes through unescaped'
assert_eq "$(np__json_str 'x')" '"x"' 'json_str adds quotes'
assert_eq "$(np__json_str '')" '""' 'empty string'

# Differential check against jq, the reference implementation. Dev-only.
if command -v jq >/dev/null 2>&1; then
  for sample in 'plain' 'quote"inside' 'back\slash' 'sl/ash' 'héllo wörld' \
                '{"a":1}' 'tab	sep' 'trailing ' ' leading' '日本語' \
                'emoji 🚀 here' 'mixed "q" and \b and é'; do
    mine=$(np__json_str "$sample")
    theirs=$(printf '%s' "$sample" | jq -Rs .)
    assert_eq "$mine" "$theirs" "matches jq for [$sample]"
  done

  # Control characters, compared separately since they cannot sit in a literal.
  ctrl=$(printf 'a\tb\nc')
  assert_eq "$(np__json_str "$ctrl")" "$(printf '%s' "$ctrl" | jq -Rs .)" \
    'matches jq for tab and newline'

  bell=$(printf 'x\001y')
  assert_eq "$(np__json_str "$bell")" "$(printf '%s' "$bell" | jq -Rs .)" \
    'matches jq for a control char'

  multi=$(printf 'line1\nline2\nline3')
  assert_eq "$(np__json_str "$multi")" "$(printf '%s' "$multi" | jq -Rs .)" \
    'matches jq for multiple newlines'

  blank=$(printf 'a\n\nb')
  assert_eq "$(np__json_str "$blank")" "$(printf '%s' "$blank" | jq -Rs .)" \
    'matches jq for a blank line'

  # Everything the escaper produces must be parseable back to the input.
  for sample in 'plain' 'quote"inside' 'back\slash' 'héllo' '{"a":1}'; do
    roundtrip=$(np__json_str "$sample" | jq -r .)
    assert_eq "$roundtrip" "$sample" "round-trips through jq for [$sample]"
  done
fi

. "$ROOT/test/lib/report.sh"
