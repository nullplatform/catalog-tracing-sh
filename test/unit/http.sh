#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

NP_TRACE_DIR="$ROOT/.nptrace-test/http-$$"
rm -rf "$NP_TRACE_DIR"
np__state_init

np__drop 'evt-1' 'test reason'
assert_ok 'drops.log created' test -f "$NP_TRACE_DIR/drops.log"
assert_match "$(cat "$NP_TRACE_DIR/drops.log")" '*evt-1*test reason*' 'drop recorded'

# A drop listener is invoked when configured.
np_test_on_drop() { printf 'listener:%s\n' "$1" >> "$NP_TRACE_DIR/listener.log"; }
NP_TRACE_ON_DROP='np_test_on_drop'
np__drop 'evt-2' 'another'
assert_match "$(cat "$NP_TRACE_DIR/listener.log")" '*listener:evt-2*' 'drop listener invoked'
NP_TRACE_ON_DROP=''

# A drop must never write to stderr unless debugging is on.
noise=$(np__drop 'evt-3' 'quiet' 2>&1)
assert_eq "$noise" '' 'drop is silent by default'
noise=$(NP_TRACE_DEBUG=1 np__drop 'evt-4' 'loud' 2>&1)
assert_match "$noise" '*evt-4*' 'drop is visible under NP_TRACE_DEBUG'

# The auth config must be mode 600 and must carry the header.
NP_TRACE_TOKEN='secret-token-value'
cfg=$(np__auth_config)
assert_ok 'auth config written' test -f "$cfg"
assert_match "$(cat "$cfg")" '*Authorization: Bearer secret-token-value*' 'config carries the header'
# The path is ours and fixed; ls is the portable way to read the mode string.
# shellcheck disable=SC2012
perms=$(ls -l "$cfg" | cut -c1-10)
assert_eq "$perms" '-rw-------' 'auth config is mode 600'
rm -f "$cfg"

# A pre-issued token is returned as-is, with no network call.
assert_eq "$(np__token)" 'secret-token-value' 'pre-issued token returned'

# With no credentials at all, the token is empty and nothing errors.
NP_TRACE_TOKEN=''
NP_TRACE_API_KEY=''
assert_eq "$(np__token)" '' 'no credentials yields an empty token'
assert_ok 'token with no credentials still returns 0' np__token

# An unreachable API must yield 000, fail fast, and never error.
NP_TRACE_TOKEN='t'
NP_TRACE_BASE_URL='http://127.0.0.1:1'
printf '{"id":"x"}' > "$NP_TRACE_DIR/spool/x.json"
start=$(date +%s)
code=$(np__post_event "$NP_TRACE_DIR/spool/x.json")
elapsed=$(( $(date +%s) - start ))
assert_eq "$code" '000' 'unreachable API yields status 000'
if [ "$elapsed" -le 6 ]; then
  assert_eq 'fast' 'fast' 'unreachable API fails fast (connect timeout honored)'
else
  assert_eq "${elapsed}s" 'fast' 'unreachable API fails fast (connect timeout honored)'
fi
assert_ok 'post_event returns 0 even on failure' np__post_event "$NP_TRACE_DIR/spool/x.json"

# The curl config file must not be left behind after a POST.
leftover=$(find "$NP_TRACE_DIR" -name 'curlcfg.*' | wc -l | tr -d ' ')
assert_eq "$leftover" 0 'curl config is removed after the POST'

# LEAK CANARY. CI scripts routinely `set -x`, and shell options are global, so
# a sourced SDK function traces into the build log. The token must appear
# NOWHERE in an xtrace — not in curl's argv, and not in the plumbing that
# writes the config file.
canary_dir=$(mktemp -d)
canary_script="
  . $ROOT/nptrace.sh
  np__state_init
  printf '{}' > \"\$NP_TRACE_DIR/spool/a.json\"
  np__post_event \"\$NP_TRACE_DIR/spool/a.json\"
"
canary_out=$(NP_TRACE_DIR="$canary_dir" NP_TRACE_TOKEN='LEAKCANARY' \
  NP_TRACE_BASE_URL='http://127.0.0.1:1' \
  "${NP_TEST_SHELL:-/bin/sh}" -x -c "$canary_script" 2>&1)
assert_eq "$(printf '%s' "$canary_out" | grep -c 'LEAKCANARY')" 0 \
  'the bearer token never appears in an xtrace'
# And the config file really did carry it — proving the canary tested a live path.
assert_match "$canary_out" '*curlcfg*' 'the traced run did exercise the auth-config path'
rm -rf "$canary_dir"

rm -rf "$NP_TRACE_DIR"
. "$ROOT/test/lib/report.sh"
