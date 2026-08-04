# Assertion helpers. Sourced by every suite. POSIX sh.
NP_TEST_RUN=0
NP_TEST_FAIL=0

assert_eq() {
  NP_TEST_RUN=$((NP_TEST_RUN + 1))
  if [ "$1" = "$2" ]; then
    return 0
  fi
  NP_TEST_FAIL=$((NP_TEST_FAIL + 1))
  printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$2" "$1" >&2
}

assert_match() {
  NP_TEST_RUN=$((NP_TEST_RUN + 1))
  # shellcheck disable=SC2254
  case "$1" in
    $2) return 0 ;;
  esac
  NP_TEST_FAIL=$((NP_TEST_FAIL + 1))
  printf 'FAIL: %s\n  pattern: [%s]\n  actual:  [%s]\n' "$3" "$2" "$1" >&2
}

assert_ok() {
  _a_msg=$1
  shift
  NP_TEST_RUN=$((NP_TEST_RUN + 1))
  if "$@" >/dev/null 2>&1; then
    return 0
  fi
  NP_TEST_FAIL=$((NP_TEST_FAIL + 1))
  printf 'FAIL: %s\n  expected exit 0 from: %s\n' "$_a_msg" "$*" >&2
}

assert_fail() {
  _a_msg=$1
  shift
  NP_TEST_RUN=$((NP_TEST_RUN + 1))
  if "$@" >/dev/null 2>&1; then
    NP_TEST_FAIL=$((NP_TEST_FAIL + 1))
    printf 'FAIL: %s\n  expected non-zero exit from: %s\n' "$_a_msg" "$*" >&2
    return 0
  fi
  return 0
}
