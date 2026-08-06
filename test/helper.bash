# Shared helper for every .bats suite.
#
# bats itself runs in bash, but this SDK's entire promise is that it behaves
# identically in whatever shell a consumer's CI happens to ship. So the code
# under test must NEVER run in bats' bash: np_sh evaluates it in $NP_TEST_SHELL
# (dash, busybox ash, ...) as a child process, and bats only inspects the
# result. Sourcing nptrace.sh into the bats shell would silently reduce the
# whole matrix to a bash-only suite.

NPTRACE="$BATS_TEST_DIRNAME/../../nptrace.sh"
NP_TEST_SHELL="${NP_TEST_SHELL:-/bin/sh}"
export NPTRACE NP_TEST_SHELL

# np_sh <code> [args...]
#
# Run <code> in the target shell with the SDK sourced. Positional args are
# passed through as "$1", "$2", ... so awkward values (quotes, newlines,
# backslashes) never have to survive a round of shell quoting.
#
#   np_sh 'np__json_escape "$1"' 'say "hi"'
#
# Sets bats' $output and $status as usual.
np_sh() {
  local code=$1
  shift
  run "$NP_TEST_SHELL" -c ". \"\$NPTRACE\"; $code" np_sh "$@"
}

# np_sh_state <code> [args...]
#
# As np_sh, but with an initialised, isolated state directory — for anything
# that opens nodes or spools events. $NP_TRACE_DIR is per-test, and the code
# runs with the SDK already initialised against an unroutable endpoint so
# nothing tries to reach the network.
np_sh_state() {
  local code=$1
  shift
  run "$NP_TEST_SHELL" -c '
    . "$NPTRACE"
    np_trace_init --producer "test@0.1" --token t \
      --base-url "http://127.0.0.1:1" --no-trap
    # Read every spooled envelope, concatenated. The wire is the assertion
    # surface: it is what the API would actually receive.
    wire() {
      for _w_f in "$NP_TRACE_DIR/spool"/*.json; do
        [ -f "$_w_f" ] || continue
        cat "$_w_f"
        printf "\n"
      done
    }
    '"$code" np_sh "$@"
}

setup() {
  # Without this, a wrong path means every np_sh call fails to source the SDK
  # and produces empty output — which reads as a normal assertion failure, or
  # worse, passes for any test expecting empty. Fail on the real cause instead.
  if [ ! -f "$NPTRACE" ]; then
    printf 'nptrace.sh not found at %s (run ./build.sh)\n' "$NPTRACE" >&2
    return 1
  fi
  NP_TRACE_DIR="$BATS_TEST_TMPDIR/nptrace"
  export NP_TRACE_DIR
}

# assert_out <expected>  — exact match against the captured output.
assert_out() {
  if [ "$output" != "$1" ]; then
    printf 'expected: [%s]\nactual:   [%s]\n' "$1" "$output" >&2
    return 1
  fi
}

# assert_out_match <glob> — pattern match against the captured output.
assert_out_match() {
  # shellcheck disable=SC2254
  case "$output" in
    $1) return 0 ;;
  esac
  printf 'pattern: [%s]\nactual:  [%s]\n' "$1" "$output" >&2
  return 1
}

# assert_ok / assert_nok — exit status of the last np_sh call.
assert_ok() {
  [ "$status" -eq 0 ] && return 0
  printf 'expected exit 0, got %s\noutput: [%s]\n' "$status" "$output" >&2
  return 1
}

assert_nok() {
  [ "$status" -ne 0 ] && return 0
  printf 'expected a non-zero exit, got 0\noutput: [%s]\n' "$output" >&2
  return 1
}

# Skip a suite's differential checks when the reference tool is absent.
require() {
  command -v "$1" >/dev/null 2>&1 || skip "$1 not installed"
}
