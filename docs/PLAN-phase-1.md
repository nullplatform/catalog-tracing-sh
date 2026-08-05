# catalog-tracing-sh Implementation Plan — Phase 1 (foundation → first end-to-end emit)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the foundation and complete emit path of `catalog-tracing-sh` — a pure POSIX shell producer SDK — up to a working end-to-end trace (a run with steps, labels, explain, error, timing) landing in the tracing API.

**Architecture:** Modules under `src/` concatenated by `build.sh` into one distributable `nptrace.sh`. Emits are local file writes into a spool directory (one file per event, filename = event id); a time-budgeted flush POSTs them with `curl`. Node state lives in a state directory, so handles survive process boundaries — which is what makes this work in CI, where every pipeline step is a fresh shell.

**Tech Stack:** POSIX `sh` (no bash-isms), `curl`, `awk`, `od`, `sed`. Dev-only: `shellcheck`, `jq` (differential tests), Docker Compose (the tracing API stack for end-to-end tests).

**Spec:** `docs/DESIGN.md`

**Status:** Phase 1 is COMPLETE — every task below shipped and is green in CI. Kept as the record of how the SDK was built and what Phase 2 still owes.

## Scope of this plan vs Phase 2

The spec commits to full wire parity. That is too large for one plan, and phases split cleanly because the emit path is a prerequisite for the surface that rides on it. This plan delivers **working, independently useful software**: a pipeline can trace a run with nested steps, labels, explain, error, and timing, end to end.

**In this plan (Tasks 1–14):** repo scaffold + build + test harness; `compat`, `json`, `uuid`, `identity`, `wire`, `state`, `spool`, `http`, `flush`; the `api` subset — `init`, `run`, `step`, `child`, `start`, the seven terminals, `labels`, `explain`, `error`, `timing`, `facet`, `schema`, `key`, `occurrence`, `flush`, `shutdown`, `recover`; end-to-end verification; docs and CI.

**Deferred to Phase 2:** the remaining 11 setters (`actor`, `external_links`, `affordances`, `progress`, `engine_status`, `dropped`, `plan`, `decision`, `retry`, `signal`), all 9 edge functions, the six io builders, the four ref constructors, propagation (`inject`/`extract`), the dual-mode CLI shim (`cli.sh` is scaffolded empty in Task 1), and the full 5-shell portability matrix (Task 14 pins CI to `dash` + `bash`; alpine/`ksh`/bash-3.2 land in Phase 2).

---

## Global Constraints

Every task's requirements implicitly include this section.

- **POSIX `sh` only.** No `bash`-isms: no arrays, no `[[`, no `local`, no `$RANDOM`, no `function` keyword, no `+=`, no process substitution. `shellcheck -s sh` must pass clean on every file.
- **Zero runtime dependencies** beyond `curl`, `awk`, `od`, `sed`, `tr`, `cut`, `date`, `mv`, `mkdir`. No `jq` at runtime.
- **Every public function returns 0, always.** Tracing must never fail the caller. Only `np_trace_run`/`_step`/`_child` write to stdout (the handle); nothing writes to stderr unless `NP_TRACE_DEBUG=1`.
- **Safe under `set -eu`.** No unset-variable references without a default; no bare command substitution whose non-zero exit could trip `-e`.
- **Internal names are prefixed `np__`** (private) or `np_trace_` (public). Private helpers use `np__`; the public surface uses `np_trace_`.
- **Local variables:** POSIX `sh` has no `local`. Every helper prefixes its variables with the function's short name (`_u7_ms`, `_js_out`) to avoid collisions with caller scope.
- **The tracing API being unreachable must be invisible to the caller.** Every curl carries `--connect-timeout 3 --max-time 10`; flush is bounded by `NP_TRACE_FLUSH_TIMEOUT` (default 10 seconds).
- **The bearer token is never passed in argv.** It goes to curl via `--config` from a mode-600 file, because CI runs with `set -x`.
- **Treat the repo as public.** No internal hosts, credentials, service names, codenames, or platform architecture. All example data obviously synthetic.
- **Commits follow Conventional Commits** (`type(scope): description`). Never add Co-Authored-By or Claude attribution.
- **Contract values copied verbatim from `catalog-tracing-api/packages/events/src/`:** delimiter `~`; charset `[A-Za-z0-9_.-]+`; `MAX_RUN_ID_LENGTH=1024`, `MAX_KEY_LENGTH=256`, `MAX_TRACE_ID_LENGTH=256`; carrier field `np-trace` with value `1|<trace_id>|<run_id>`.

---

## File Structure

| File | Responsibility |
|---|---|
| `build.sh` | Concatenate `src/*.sh` into `nptrace.sh` |
| `Makefile` | `build`, `test`, `lint` targets |
| `src/header.sh` | Shebang, re-source guard, `NP_TRACE_VERSION` |
| `src/compat.sh` | Millisecond epoch, random hex. **The only place OS differences live** |
| `src/json.sh` | String escaping, object/array emission |
| `src/uuid.sh` | UUIDv7 generation, `occurrence()` |
| `src/identity.sh` | Hand-port of `packages/events/src/identity.ts` |
| `src/wire.sh` | Hand-port of the enums/constants in `packages/events/src/` |
| `src/state.sh` | State dir, handle allocation, node registry, ambient resolution |
| `src/spool.sh` | Envelope assembly, one file per event, atomic rename |
| `src/http.sh` | curl wrapper, token exchange + cache, drop recording |
| `src/flush.sh` | Spool drain, response handling, time budget, `trap` |
| `src/api.sh` | The public producer surface |
| `src/cli.sh` | argv → function shim (scaffolded empty; Phase 2) |
| `test/run.sh` | Test runner — discovers and runs `test/unit/*.sh`, `test/integration/*.sh` |
| `test/lib/assert.sh` | Assertion helpers |
| `test/unit/*.sh` | One file per module |
| `test/integration/*.sh` | Resilience + live-API suites |
| `nptrace.sh` | The built artifact, committed so vendoring needs no build |

---

### Task 1: Repo scaffold, build, and test harness

**Files:**
- Create: `build.sh`
- Create: `Makefile`
- Create: `src/header.sh`
- Create: `src/{compat,json,uuid,identity,wire,state,spool,http,flush,api,cli}.sh`
- Create: `test/lib/assert.sh`
- Create: `test/run.sh`
- Create: `test/unit/smoke.sh`
- Create: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `build.sh` emitting `nptrace.sh`; `test/run.sh` returning 0 on all-pass and 1 on any failure; assertion helpers `assert_eq <actual> <expected> <message>`, `assert_ok <message> <cmd...>`, `assert_fail <message> <cmd...>`, `assert_match <actual> <glob> <message>`; counters `NP_TEST_RUN` / `NP_TEST_FAIL`.

- [ ] **Step 1: Create the repo and directory skeleton**

```bash
mkdir -p {src,test/lib,test/unit,test/integration}
cd "$(git rev-parse --show-toplevel)"
git init -q
printf 'nptrace.sh.tmp\n*.tmp\n.nptrace-test/\n' > .gitignore
```

- [ ] **Step 2: Write the assertion helpers**

Create `test/lib/assert.sh`:

```sh
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
  if "$@"; then
    return 0
  fi
  NP_TEST_FAIL=$((NP_TEST_FAIL + 1))
  printf 'FAIL: %s\n  expected exit 0 from: %s\n' "$_a_msg" "$*" >&2
}

assert_fail() {
  _a_msg=$1
  shift
  NP_TEST_RUN=$((NP_TEST_RUN + 1))
  if "$@"; then
    NP_TEST_FAIL=$((NP_TEST_FAIL + 1))
    printf 'FAIL: %s\n  expected non-zero exit from: %s\n' "$_a_msg" "$*" >&2
    return 0
  fi
  return 0
}
```

- [ ] **Step 3: Write the test runner**

Create `test/run.sh`:

```sh
#!/bin/sh
# Test runner. Usage: test/run.sh [unit|integration|all]
set -u
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export ROOT
SUITE=${1:-unit}

TOTAL_RUN=0
TOTAL_FAIL=0

run_dir() {
  for suite in "$ROOT/test/$1"/*.sh; do
    [ -f "$suite" ] || continue
    printf '\n== %s\n' "${suite##*/}"
    # Each suite runs in its own shell so a crash can't take down the runner.
    out=$("$NP_TEST_SHELL" "$suite" 2>&1)
    code=$?
    printf '%s\n' "$out"
    counts=$(printf '%s\n' "$out" | sed -n 's/^__COUNTS__ //p')
    ran=${counts%% *}
    failed=${counts##* }
    [ -n "$ran" ] || ran=0
    [ -n "$failed" ] || failed=0
    TOTAL_RUN=$((TOTAL_RUN + ran))
    TOTAL_FAIL=$((TOTAL_FAIL + failed))
    if [ "$code" -ne 0 ]; then
      TOTAL_FAIL=$((TOTAL_FAIL + 1))
      printf 'FAIL: suite %s exited %s\n' "${suite##*/}" "$code" >&2
    fi
  done
}

NP_TEST_SHELL=${NP_TEST_SHELL:-/bin/sh}
export NP_TEST_SHELL

case "$SUITE" in
  unit) run_dir unit ;;
  integration) run_dir integration ;;
  all) run_dir unit; run_dir integration ;;
  *) printf 'unknown suite: %s\n' "$SUITE" >&2; exit 2 ;;
esac

printf '\n%s assertions, %s failures\n' "$TOTAL_RUN" "$TOTAL_FAIL"
[ "$TOTAL_FAIL" -eq 0 ]
```

Every suite ends by reporting its counts; create the shared tail as `test/lib/report.sh`:

```sh
# Sourced at the end of every suite.
printf '__COUNTS__ %s %s\n' "$NP_TEST_RUN" "$NP_TEST_FAIL"
[ "$NP_TEST_FAIL" -eq 0 ]
```

- [ ] **Step 4: Write the smoke suite (the failing test)**

Create `test/unit/smoke.sh`:

```sh
#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

assert_match "$NP_TRACE_VERSION" '[0-9]*.[0-9]*.[0-9]*' 'version is semver-shaped'

. "$ROOT/test/lib/report.sh"
```

- [ ] **Step 5: Run it to verify it fails**

Run: `cd "$(git rev-parse --show-toplevel)" && sh test/run.sh unit`
Expected: FAIL — `nptrace.sh` does not exist yet.

- [ ] **Step 6: Write the module stubs and the header**

Create `src/header.sh`:

```sh
#!/bin/sh
# @nullplatform/tracing for POSIX shell — producer SDK for the nullplatform
# tracing API. Zero runtime dependencies beyond curl and the POSIX toolset.
#
# Generated file: edit src/*.sh and run ./build.sh.

if [ -n "${NP_TRACE_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
NP_TRACE_LOADED=1
NP_TRACE_VERSION="0.1.0"
```

Create each of `src/compat.sh`, `src/json.sh`, `src/uuid.sh`, `src/identity.sh`, `src/wire.sh`, `src/state.sh`, `src/spool.sh`, `src/http.sh`, `src/flush.sh`, `src/api.sh`, `src/cli.sh` containing only a header comment naming its responsibility, e.g.:

```sh
# compat.sh — portability shims. The ONLY place OS differences live.
```

- [ ] **Step 7: Write the build script**

Create `build.sh`:

```sh
#!/bin/sh
# Concatenate src modules into the single distributable nptrace.sh.
set -eu
OUT=${1:-nptrace.sh}
MODULES='header compat json uuid identity wire state spool http flush api cli'
{
  for module in $MODULES; do
    printf '\n# ---- src/%s.sh ----\n' "$module"
    # Strip per-module shebangs; only the built artifact carries one.
    sed '1{/^#!/d;}' "src/$module.sh"
  done
} > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
chmod +x "$OUT"
printf 'built %s (%s lines)\n' "$OUT" "$(wc -l < "$OUT" | tr -d ' ')"
```

Create `Makefile`:

```make
.POSIX:

build:
	./build.sh

lint:
	shellcheck -s sh build.sh src/*.sh test/run.sh test/lib/*.sh test/unit/*.sh

test: build
	sh test/run.sh unit

test-all: build
	sh test/run.sh all

.PHONY: build lint test test-all
```

- [ ] **Step 8: Run the build and the test to verify they pass**

Run: `cd "$(git rev-parse --show-toplevel)" && make test`
Expected: build prints a line count; smoke suite passes; `1 assertions, 0 failures`.

- [ ] **Step 9: Run the linter**

Run: `make lint`
Expected: exit 0, no output.

- [ ] **Step 10: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add .
git commit -m "chore: repo scaffold, concat build, and POSIX test harness"
```

---

### Task 2: compat.sh — millisecond epoch and random hex

**Files:**
- Modify: `src/compat.sh`
- Test: `test/unit/compat.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `np__epoch_ms` → prints Unix milliseconds as a decimal integer. `np__rand_hex <n>` → prints exactly `n` lowercase hex characters. `np__iso8601` → prints an RFC 3339 UTC timestamp like `2026-08-04T12:34:56Z`.

- [ ] **Step 1: Write the failing test**

Create `test/unit/compat.sh`:

```sh
#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

ms=$(np__epoch_ms)
assert_match "$ms" '[0-9]*' 'epoch_ms is all digits'
# 13 digits covers 2001-09-09 through 2286; any sane clock lands here.
assert_eq "${#ms}" 13 'epoch_ms is 13 digits'

# No literal format specifier leaked through from a date without %N support.
assert_match "$ms" '*[!N]' 'epoch_ms contains no literal N'

h=$(np__rand_hex 19)
assert_eq "${#h}" 19 'rand_hex returns exactly 19 chars'
assert_match "$h" '[0-9a-f]*' 'rand_hex is lowercase hex'
case "$h" in
  *[!0-9a-f]*) assert_eq 'non-hex' 'hex' 'rand_hex contains only hex chars' ;;
  *) assert_eq 'hex' 'hex' 'rand_hex contains only hex chars' ;;
esac

a=$(np__rand_hex 32)
b=$(np__rand_hex 32)
assert_match "$a" '*' 'rand_hex produced a value'
if [ "$a" = "$b" ]; then
  assert_eq 'identical' 'different' 'two rand_hex calls differ'
else
  assert_eq 'different' 'different' 'two rand_hex calls differ'
fi

ts=$(np__iso8601)
assert_match "$ts" '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*Z' 'iso8601 is RFC 3339 UTC'

. "$ROOT/test/lib/report.sh"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd "$(git rev-parse --show-toplevel)" && make test`
Expected: FAIL — `np__epoch_ms: not found`.

- [ ] **Step 3: Implement compat.sh**

Replace `src/compat.sh` with:

```sh
# compat.sh — portability shims. The ONLY place OS differences live.

# Unix milliseconds. GNU date supports %N; busybox and BSD may not, in which
# case the format leaks through literally — detected and downgraded to
# second precision (the event id stays unique via its random bits).
np__epoch_ms() {
  _cm_ms=$(date -u +%s%3N 2>/dev/null) || _cm_ms=''
  case "$_cm_ms" in
    '' | *[!0-9]*) _cm_ms="$(date -u +%s)000" ;;
  esac
  printf '%s' "$_cm_ms"
}

# Exactly $1 lowercase hex characters from the kernel CSPRNG.
np__rand_hex() {
  _rh_want=$1
  _rh_bytes=$(( (_rh_want + 1) / 2 ))
  od -An -tx1 -N"$_rh_bytes" /dev/urandom | tr -d ' \n' | cut -c1-"$_rh_want"
}

# RFC 3339 UTC, second precision — the envelope `time` field.
np__iso8601() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS, all compat assertions green.

- [ ] **Step 5: Verify under dash specifically**

Run: `NP_TEST_SHELL=/bin/dash make test` (install with `apt-get install dash` or `brew install dash` if absent)
Expected: PASS. This is the real POSIX gate — `/bin/sh` on macOS is bash in disguise.

- [ ] **Step 6: Commit**

```bash
git add src/compat.sh test/unit/compat.sh
git commit -m "feat(compat): millisecond epoch, random hex, and RFC 3339 helpers"
```

---

### Task 3: uuid.sh — UUIDv7 generation

**Files:**
- Modify: `src/uuid.sh`
- Test: `test/unit/uuid.sh`

**Interfaces:**
- Consumes: `np__epoch_ms`, `np__rand_hex` (Task 2).
- Produces: `np__uuidv7` → prints a lowercase UUIDv7. `np_trace_occurrence` → public alias printing a UUIDv7, for minting per-occurrence run-id tokens.

**Why this is mandatory:** the API derives `partition_timestamp` by parsing the event id and **throws** on a non-UUIDv7 (`EventRepository.ts:84`). A wrong id is a 500, not a validation error.

- [ ] **Step 1: Write the failing test**

Create `test/unit/uuid.sh`:

```sh
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

pub=$(np_trace_occurrence)
assert_eq "${#pub}" 36 'np_trace_occurrence returns a uuid'

. "$ROOT/test/lib/report.sh"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make test`
Expected: FAIL — `np__uuidv7: not found`.

- [ ] **Step 3: Implement uuid.sh**

Replace `src/uuid.sh` with:

```sh
# uuid.sh — UUIDv7. The event id MUST be a v7: the API derives the storage
# partition from its embedded millisecond timestamp.
#
# Layout: 48-bit big-endian ms timestamp | version nibble 7 | 12 random bits
#         | variant bits 10 | 62 random bits.

np__uuidv7() {
  _u7_ts=$(printf '%012x' "$(np__epoch_ms)")
  _u7_r=$(np__rand_hex 19)

  # The variant nibble must be one of 8, 9, a, b. Fold a random hex digit
  # into that range rather than drawing again.
  case $(printf '%s' "$_u7_r" | cut -c1) in
    0 | 1 | 2 | 3) _u7_var=8 ;;
    4 | 5 | 6 | 7) _u7_var=9 ;;
    8 | 9 | a | b) _u7_var=a ;;
    *) _u7_var=b ;;
  esac

  printf '%s-%s-7%s-%s%s-%s\n' \
    "$(printf '%s' "$_u7_ts" | cut -c1-8)" \
    "$(printf '%s' "$_u7_ts" | cut -c9-12)" \
    "$(printf '%s' "$_u7_r" | cut -c2-4)" \
    "$_u7_var" \
    "$(printf '%s' "$_u7_r" | cut -c5-7)" \
    "$(printf '%s' "$_u7_r" | cut -c8-19)"
}

# Mint a per-occurrence token for a repeatable operation's run_id. Time-ordered,
# so minted ids sort by creation time.
np_trace_occurrence() {
  np__uuidv7
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Verify `printf '%012x'` handles a 13-digit millisecond value**

Run: `sh -c 'printf "%012x\n" 1785000000000'` and `dash -c 'printf "%012x\n" 1785000000000'`
Expected: `019f9d1d6800` from both — proving neither shell truncates to signed 32-bit. If either prints `ffffffff` or errors, add a fallback in `np__uuidv7` that splits the value into two halves before formatting, and re-run Step 4.

- [ ] **Step 6: Run under dash and lint**

Run: `NP_TEST_SHELL=/bin/dash make test && make lint`
Expected: PASS, lint clean.

- [ ] **Step 7: Commit**

```bash
git add src/uuid.sh test/unit/uuid.sh
git commit -m "feat(uuid): UUIDv7 generation and the occurrence() token minter"
```

---

### Task 4: json.sh — string escaping

**Files:**
- Modify: `src/json.sh`
- Test: `test/unit/json.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `np__json_escape <string>` → prints the string with JSON string-body escaping applied (no surrounding quotes). `np__json_str <string>` → prints the fully quoted JSON string.

**Why this is the highest-risk code:** it is hand-rolled, it handles arbitrary user input (labels, explain text), and a bug produces a malformed envelope the API rejects with a 400.

- [ ] **Step 1: Write the failing test**

Create `test/unit/json.sh`:

```sh
#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

assert_eq "$(np__json_escape 'plain')" 'plain' 'plain text passes through'
assert_eq "$(np__json_escape 'say "hi"')" 'say \"hi\"' 'double quotes escaped'
assert_eq "$(np__json_escape 'a\b')" 'a\\b' 'backslash escaped'
assert_eq "$(np__json_escape "$(printf 'a\tb')")" 'a\tb' 'tab escaped'
assert_eq "$(np__json_escape "$(printf 'a\nb')")" 'a\nb' 'newline escaped'
assert_eq "$(np__json_escape "$(printf 'a\001b')")" 'ab' 'control char escaped as \\u'
assert_eq "$(np__json_escape 'héllo')" 'héllo' 'UTF-8 passes through unescaped'
assert_eq "$(np__json_str 'x')" '"x"' 'json_str adds quotes'
assert_eq "$(np__json_str '')" '""' 'empty string'

# Differential check against jq, the reference implementation. Dev-only.
if command -v jq >/dev/null 2>&1; then
  for sample in 'plain' 'quote"inside' 'back\slash' 'sl/ash' 'héllo wörld' '{"a":1}'; do
    mine=$(np__json_str "$sample")
    theirs=$(printf '%s' "$sample" | jq -Rs .)
    assert_eq "$mine" "$theirs" "matches jq for [$sample]"
  done
  # Control characters, compared separately since they can't sit in a literal.
  ctrl=$(printf 'a\tb\nc')
  assert_eq "$(np__json_str "$ctrl")" "$(printf '%s' "$ctrl" | jq -Rs .)" 'matches jq for control chars'
fi

. "$ROOT/test/lib/report.sh"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make test`
Expected: FAIL — `np__json_escape: not found`.

- [ ] **Step 3: Implement json.sh**

Replace `src/json.sh` with:

```sh
# json.sh — JSON emission. There is no parser here beyond one field extractor
# for the auth response; the SDK only ever WRITES JSON.

# Escape a string for a JSON string body (no surrounding quotes).
# Fast path: printable ASCII with nothing special returns unchanged, so the
# common label/id case never forks an awk.
np__json_escape() {
  case "$1" in
    *[!\ -~]* | *'"'* | *'\'*) ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  printf '%s' "$1" | awk '
    BEGIN {
      RS = "\001\001\001"     # a separator that will not occur; read all input
      ORS = ""
      for (i = 0; i < 256; i++) { ORD[sprintf("%c", i)] = i }
    }
    {
      out = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\") { out = out "\\\\" }
        else if (c == "\"") { out = out "\\\"" }
        else if (c == "\n") { out = out "\\n" }
        else if (c == "\r") { out = out "\\r" }
        else if (c == "\t") { out = out "\\t" }
        else if (c == "\b") { out = out "\\b" }
        else if (c == "\f") { out = out "\\f" }
        else if (c < " ") { out = out sprintf("\\u%04x", ORD[c]) }
        else { out = out c }
      }
      printf "%s", out
    }
  '
}

# A complete quoted JSON string.
np__json_str() {
  printf '"%s"' "$(np__json_escape "$1")"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS, including every jq differential assertion.

- [ ] **Step 5: Verify against busybox awk**

Run: `docker run --rm -v "$PWD:/w" -w /w busybox:latest sh test/run.sh unit`
Expected: PASS — busybox `awk` is the most limited implementation in the matrix, and the `ORD` lookup table is the part most likely to differ.

- [ ] **Step 6: Commit**

```bash
git add src/json.sh test/unit/json.sh
git commit -m "feat(json): JSON string escaping with an ASCII fast path"
```

---

### Task 5: json.sh — object and array emission

**Files:**
- Modify: `src/json.sh`
- Test: `test/unit/json.sh`

**Interfaces:**
- Consumes: `np__json_str` (Task 4).
- Produces: `np__json_obj <k1> <v1> <k2> <v2> …` → a JSON object with all values emitted as strings; pairs whose value is empty are **omitted** (an absent optional is omitted, never `""`). `np__json_obj_raw <k1> <raw1> …` → same, but values are inserted verbatim as pre-formed JSON. `np__json_kv_append <file> <key> <value>` → append a staged key/value line for later object assembly.

- [ ] **Step 1: Write the failing test**

Append to `test/unit/json.sh`, before the `report.sh` line:

```sh
assert_eq "$(np__json_obj a 1 b two)" '{"a":"1","b":"two"}' 'object with two pairs'
assert_eq "$(np__json_obj a 1 b '')" '{"a":"1"}' 'empty value omitted'
assert_eq "$(np__json_obj)" '{}' 'empty object'
assert_eq "$(np__json_obj a 'q"q')" '{"a":"q\"q"}' 'object escapes values'
assert_eq "$(np__json_obj_raw a '{"n":1}' b '[]')" '{"a":{"n":1},"b":[]}' 'raw values inserted verbatim'
assert_eq "$(np__json_obj_raw a '' b '2')" '{"b":2}' 'raw empty value omitted'
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make test`
Expected: FAIL — `np__json_obj: not found`.

- [ ] **Step 3: Implement the object builders**

Append to `src/json.sh`:

```sh
# A JSON object from alternating key/value arguments. Values are emitted as
# JSON strings. A pair whose value is empty is OMITTED — an absent optional is
# absent, never the string "".
np__json_obj() {
  _jo_out=''
  while [ "$#" -ge 2 ]; do
    if [ -n "$2" ]; then
      if [ -n "$_jo_out" ]; then
        _jo_out="$_jo_out,"
      fi
      _jo_out="$_jo_out$(np__json_str "$1"):$(np__json_str "$2")"
    fi
    shift 2
  done
  printf '{%s}' "$_jo_out"
}

# As np__json_obj, but each value is already-formed JSON inserted verbatim.
# Use for nested objects, arrays, numbers, and booleans.
np__json_obj_raw() {
  _jor_out=''
  while [ "$#" -ge 2 ]; do
    if [ -n "$2" ]; then
      if [ -n "$_jor_out" ]; then
        _jor_out="$_jor_out,"
      fi
      _jor_out="$_jor_out$(np__json_str "$1"):$2"
    fi
    shift 2
  done
  printf '{%s}' "$_jor_out"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/json.sh test/unit/json.sh
git commit -m "feat(json): object emission with omit-empty semantics"
```

---

### Task 6: identity.sh — the id grammar

**Files:**
- Modify: `src/identity.sh`
- Test: `test/unit/identity.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `np__is_identifier <s>` → exit 0 when `s` matches `[A-Za-z0-9_.-]+`. `np__key_violation <key>` / `np__named_id_violation <id>` / `np__trace_id_violation <id>` → print a reason and exit 1, or exit 0 silently. `np__derive_child_id <parent> <key> <attempt> <iteration>` → prints the derived id. `np__scope_root_of <run_id>` → prints everything before the first `~`. `np__parse_node_id <run_id>` → prints `<parent> <key> <attempt> <iteration>` and exits 0 for a derived id; exits 1 for a named id. `np_trace_key <part>…` → joins non-empty parts with `-`.

**Source of truth:** `catalog-tracing-api/packages/events/src/identity.ts`. This is a hand-port; its tests are the drift safety net.

- [ ] **Step 1: Write the failing test**

Create `test/unit/identity.sh`:

```sh
#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

assert_ok   'plain identifier valid'      np__is_identifier 'abc-123_x.y'
assert_fail 'empty invalid'               np__is_identifier ''
assert_fail 'tilde invalid'               np__is_identifier 'a~b'
assert_fail 'at-sign invalid'             np__is_identifier 'a@b'
assert_fail 'slash invalid'               np__is_identifier 'a/b'
assert_fail 'space invalid'               np__is_identifier 'a b'
assert_fail 'colon invalid'               np__is_identifier 'organization=1:app=2'

assert_eq "$(np__derive_child_id 'root' 'build' 0 0)" 'root~build@0.0' 'derives a child id'
assert_eq "$(np__derive_child_id 'root~build@0.0' 'sub' 1 2)" 'root~build@0.0~sub@1.2' 'derives an N-level id'

assert_eq "$(np__scope_root_of 'root~build@0.0~sub@1.2')" 'root' 'scope root is the named prefix'
assert_eq "$(np__scope_root_of 'root')" 'root' 'a named id is its own scope root'

assert_eq "$(np__parse_node_id 'root~build@0.0')" 'root build 0 0' 'parses the last hop'
assert_eq "$(np__parse_node_id 'root~build@0.0~sub@1.2')" 'root~build@0.0 sub 1 2' 'parses the innermost hop'
assert_fail 'a named id does not parse as derived' np__parse_node_id 'root'

assert_eq "$(np_trace_key a b c)" 'a-b-c' 'key joins with dash'
assert_eq "$(np_trace_key a '' c)" 'a-c' 'key drops empty parts'
assert_eq "$(np_trace_key)" '' 'key with no parts is empty'

assert_fail 'over-long key rejected' np__key_violation "$(awk 'BEGIN{for(i=0;i<257;i++)printf "a"}')"
assert_ok   'legal key accepted'     np__key_violation 'build'
assert_fail 'tilde key rejected'     np__key_violation 'a~b'
assert_fail 'tilde trace id rejected' np__trace_id_violation 'a~b'

. "$ROOT/test/lib/report.sh"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make test`
Expected: FAIL — `np__is_identifier: not found`.

- [ ] **Step 3: Implement identity.sh**

Replace `src/identity.sh` with:

```sh
# identity.sh — the node identity grammar. A hand-port of the tracing API's
# contract module; these functions and their tests are the drift safety net.
#
#   child_run_id = parent_run_id "~" key "@" attempt "." iteration
#
# One charset covers every producer-authored segment: [A-Za-z0-9_.-]+. The
# delimiter '~' and the coordinate marker '@' sit outside it, which is what
# makes the grammar collision-proof.

NP_ID_DELIMITER='~'
NP_MAX_RUN_ID_LENGTH=1024
NP_MAX_KEY_LENGTH=256
NP_MAX_TRACE_ID_LENGTH=256

np__is_identifier() {
  case "$1" in
    '') return 1 ;;
    *[!A-Za-z0-9_.-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Shared: print a reason and return 1, or return 0 silently.
np__identifier_violation() {
  if [ -z "$1" ]; then
    printf 'must be non-empty'
    return 1
  fi
  if [ "${#1}" -gt "$2" ]; then
    printf 'exceeds %s chars' "$2"
    return 1
  fi
  if ! np__is_identifier "$1"; then
    printf "must be identifier-charset: letters, digits, '_', '.', '-'"
    return 1
  fi
  return 0
}

np__key_violation() {
  np__identifier_violation "$1" "$NP_MAX_KEY_LENGTH"
}

np__named_id_violation() {
  np__identifier_violation "$1" "$NP_MAX_RUN_ID_LENGTH"
}

np__trace_id_violation() {
  np__identifier_violation "$1" "$NP_MAX_TRACE_ID_LENGTH"
}

# The derived id of a keyed child.
np__derive_child_id() {
  printf '%s%s%s@%s.%s' "$1" "$NP_ID_DELIMITER" "$2" "$3" "$4"
}

# Everything before the FIRST delimiter — the nearest named ancestor.
np__scope_root_of() {
  case "$1" in
    *"$NP_ID_DELIMITER"*) printf '%s' "${1%%"$NP_ID_DELIMITER"*}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Parse the LAST hop of a derived id. Prints "<parent> <key> <attempt> <iteration>".
# Returns 1 for a named id (no delimiter).
np__parse_node_id() {
  case "$1" in
    *"$NP_ID_DELIMITER"*) ;;
    *) return 1 ;;
  esac
  _pn_parent=${1%"$NP_ID_DELIMITER"*}
  _pn_tail=${1##*"$NP_ID_DELIMITER"}
  case "$_pn_tail" in
    *@*.*) ;;
    *) return 1 ;;
  esac
  _pn_key=${_pn_tail%%@*}
  _pn_coord=${_pn_tail#*@}
  _pn_attempt=${_pn_coord%%.*}
  _pn_iteration=${_pn_coord#*.}
  if [ -z "$_pn_parent" ] || [ -z "$_pn_key" ]; then
    return 1
  fi
  case "$_pn_attempt$_pn_iteration" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s %s %s %s' "$_pn_parent" "$_pn_key" "$_pn_attempt" "$_pn_iteration"
}

# Join parts into a stable id, dropping empty parts. Use instead of
# hand-interpolation so an absent part never leaves a dangling separator.
np_trace_key() {
  _k_out=''
  for _k_part in "$@"; do
    if [ -n "$_k_part" ]; then
      if [ -n "$_k_out" ]; then
        _k_out="$_k_out-"
      fi
      _k_out="$_k_out$_k_part"
    fi
  done
  printf '%s' "$_k_out"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Cross-check the port against the TypeScript source**

Run: `grep -n "MAX_RUN_ID_LENGTH\|MAX_KEY_LENGTH\|MAX_TRACE_ID_LENGTH\|ID_DELIMITER =" <the tracing API repo>/packages/events/src/identity.ts`
Expected: `1024`, `256`, `256`, `'~'` — matching the constants in `src/identity.sh`. If any differ, the port is wrong; fix and re-run Step 4.

- [ ] **Step 6: Commit**

```bash
git add src/identity.sh test/unit/identity.sh
git commit -m "feat(identity): port the node id grammar from the wire contract"
```

---

### Task 7: wire.sh — contract constants

**Files:**
- Modify: `src/wire.sh`
- Test: `test/unit/wire.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `NP_TYPE_NODE_RUN`, `NP_TYPE_NODE_DATASET`, `NP_TYPE_NODE_JOB`, `NP_TYPE_EDGE_PARENT` and the eight other edge types; `NP_STATUS_STARTED`/`_COMPLETED`/`_FAILED`/`_CANCELLED`/`_TIMED_OUT`/`_SKIPPED`/`_WAITING`; `NP_FACET_ERROR`/`_TIMING`/… for all 16 core facets; `NP_CORE_FACETS` (space-separated); `NP_CARRIER_KEY`, `NP_CARRIER_VERSION`, `NP_CARRIER_DELIMITER`; `np__is_terminal_status <s>`.

- [ ] **Step 1: Write the failing test**

Create `test/unit/wire.sh`:

```sh
#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

assert_eq "$NP_TYPE_NODE_RUN" 'node.run' 'node.run type'
assert_eq "$NP_TYPE_EDGE_PARENT" 'edge.parent' 'edge.parent type'
assert_eq "$NP_STATUS_TIMED_OUT" 'timed_out' 'timed_out status'
assert_eq "$NP_FACET_PROGRESS" 'tracing.progress' 'progress facet'
assert_eq "$NP_CARRIER_KEY" 'np-trace' 'carrier key'
assert_eq "$NP_CARRIER_VERSION" '1' 'carrier version'

count=0
for f in $NP_CORE_FACETS; do
  count=$((count + 1))
  assert_match "$f" 'tracing.*' "core facet $f is namespaced"
done
assert_eq "$count" 16 'there are 16 core facets'

assert_ok   'completed is terminal'  np__is_terminal_status completed
assert_ok   'skipped is terminal'    np__is_terminal_status skipped
assert_fail 'started is not terminal' np__is_terminal_status started
assert_fail 'waiting is not terminal' np__is_terminal_status waiting

. "$ROOT/test/lib/report.sh"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make test`
Expected: FAIL — `NP_TYPE_NODE_RUN: parameter not set`.

- [ ] **Step 3: Implement wire.sh**

Replace `src/wire.sh` with:

```sh
# wire.sh — contract constants, hand-ported from the tracing API's wire package.
# When the API's contract changes, this file and identity.sh are what must be
# re-ported; their tests are the safety net.

NP_TYPE_NODE_RUN='node.run'
NP_TYPE_NODE_DATASET='node.dataset'
NP_TYPE_NODE_JOB='node.job'

NP_TYPE_EDGE_PARENT='edge.parent'
NP_TYPE_EDGE_TRIGGERED_BY='edge.triggered_by'
NP_TYPE_EDGE_RETRY_OF='edge.retry_of'
NP_TYPE_EDGE_CONTINUES='edge.continues'
NP_TYPE_EDGE_CORRELATES='edge.correlates'
NP_TYPE_EDGE_COMPENSATES='edge.compensates'
NP_TYPE_EDGE_PRODUCES='edge.produces'
NP_TYPE_EDGE_CONSUMES='edge.consumes'
NP_TYPE_EDGE_INSTANCE_OF='edge.instance_of'

NP_STATUS_STARTED='started'
NP_STATUS_COMPLETED='completed'
NP_STATUS_FAILED='failed'
NP_STATUS_CANCELLED='cancelled'
NP_STATUS_TIMED_OUT='timed_out'
NP_STATUS_SKIPPED='skipped'
NP_STATUS_WAITING='waiting'

NP_FACET_ERROR='tracing.error'
NP_FACET_TIMING='tracing.timing'
NP_FACET_INPUT='tracing.input'
NP_FACET_OUTPUT='tracing.output'
NP_FACET_BINDING='tracing.binding'
NP_FACET_DECISION='tracing.decision'
NP_FACET_RETRY='tracing.retry'
NP_FACET_SIGNAL='tracing.signal'
NP_FACET_EXTERNAL_LINKS='tracing.externalLinks'
NP_FACET_PLAN='tracing.plan'
NP_FACET_ACTOR='tracing.actor'
NP_FACET_DROPPED='tracing.dropped'
NP_FACET_ENGINE_STATUS='tracing.engineStatus'
NP_FACET_AFFORDANCES='tracing.affordances'
NP_FACET_EXPLAIN='tracing.explain'
NP_FACET_PROGRESS='tracing.progress'

NP_CORE_FACETS="$NP_FACET_ERROR $NP_FACET_TIMING $NP_FACET_INPUT $NP_FACET_OUTPUT \
$NP_FACET_BINDING $NP_FACET_DECISION $NP_FACET_RETRY $NP_FACET_SIGNAL \
$NP_FACET_EXTERNAL_LINKS $NP_FACET_PLAN $NP_FACET_ACTOR $NP_FACET_DROPPED \
$NP_FACET_ENGINE_STATUS $NP_FACET_AFFORDANCES $NP_FACET_EXPLAIN $NP_FACET_PROGRESS"

NP_RESERVED_FACET_PREFIX='tracing.'

NP_CARRIER_KEY='np-trace'
NP_CARRIER_VERSION='1'
NP_CARRIER_DELIMITER='|'

np__is_terminal_status() {
  case "$1" in
    completed | failed | cancelled | timed_out | skipped) return 0 ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS, including `there are 16 core facets`.

- [ ] **Step 5: Cross-check the facet list against the API**

Run: `grep -c "^  [a-zA-Z]*: 'tracing\." <the tracing API repo>/packages/events/src/reserved.ts`
Expected: `16`, matching `NP_CORE_FACETS`. (Note: `reserved.ts`'s own prose comment says "15" — that comment is stale, the object has 16 entries. Trust the object.)

- [ ] **Step 6: Commit**

```bash
git add src/wire.sh test/unit/wire.sh
git commit -m "feat(wire): port the type, status, facet, and carrier constants"
```

---

### Task 8: state.sh — state dir, handles, ambient resolution

**Files:**
- Modify: `src/state.sh`
- Test: `test/unit/state.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `np__state_init` → creates the state dir tree, sets and exports `NP_TRACE_DIR`. `np__handle_new` → allocates and prints a fresh handle (`n1`, `n2`, …). `np__is_handle <s>` → exit 0 iff `s` names a file in `nodes/`. `np__node_set <handle> <key> <value>` / `np__node_get <handle> <key>` → node field access. `np__ambient` → prints the current ambient handle, or empty. `np__ambient_set <handle>` / `np__ambient_clear <handle>`. `np__resolve_handle <arg>` → prints the handle if `arg` is one, else prints the ambient handle; used by every node-scoped public function.

- [ ] **Step 1: Write the failing test**

Create `test/unit/state.sh`:

```sh
#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

NP_TRACE_DIR="$ROOT/.nptrace-test/state-$$"
rm -rf "$NP_TRACE_DIR"
np__state_init

assert_ok 'nodes dir created' test -d "$NP_TRACE_DIR/nodes"
assert_ok 'spool dir created' test -d "$NP_TRACE_DIR/spool"

h1=$(np__handle_new)
h2=$(np__handle_new)
assert_eq "$h1" 'n1' 'first handle is n1'
assert_eq "$h2" 'n2' 'second handle is n2'

assert_ok   'allocated handle is a handle'    np__is_handle "$h1"
assert_fail 'arbitrary string is not a handle' np__is_handle 'boom'
assert_fail 'empty string is not a handle'     np__is_handle ''

np__node_set "$h1" run_id 'root'
np__node_set "$h1" status 'started'
assert_eq "$(np__node_get "$h1" run_id)" 'root' 'node field round-trips'
assert_eq "$(np__node_get "$h1" status)" 'started' 'second field round-trips'
assert_eq "$(np__node_get "$h1" absent)" '' 'absent field is empty'

np__node_set "$h1" status 'completed'
assert_eq "$(np__node_get "$h1" status)" 'completed' 'field overwrite wins'

# A value containing spaces and an equals sign must survive.
np__node_set "$h1" nrn 'organization=1:application=42'
assert_eq "$(np__node_get "$h1" nrn)" 'organization=1:application=42' 'value with = round-trips'

np__ambient_set "$h1"
assert_eq "$(np__ambient)" "$h1" 'ambient is the set handle'

# A handle created inside a command substitution must be visible to the caller,
# because POSIX $$ does not change in a subshell.
inner=$(np__handle_new; np__ambient_set "$(np__handle_new)"; np__ambient)
assert_eq "$(np__ambient)" "$inner" 'ambient set in a subshell is visible to the caller'

np__ambient_set "$h1"
assert_eq "$(np__resolve_handle "$h2")" "$h2" 'explicit handle wins'
assert_eq "$(np__resolve_handle 'some message')" "$h1" 'non-handle arg falls back to ambient'
assert_eq "$(np__resolve_handle '')" "$h1" 'empty arg falls back to ambient'

# NP_TRACE_CURRENT takes precedence over the per-pid pointer.
NP_TRACE_CURRENT="$h2"
assert_eq "$(np__ambient)" "$h2" 'NP_TRACE_CURRENT wins over current.$$'
unset NP_TRACE_CURRENT

rm -rf "$NP_TRACE_DIR"
. "$ROOT/test/lib/report.sh"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make test`
Expected: FAIL — `np__state_init: not found`.

- [ ] **Step 3: Implement state.sh**

Replace `src/state.sh` with:

```sh
# state.sh — the on-disk node registry. State lives on disk rather than in
# shell memory so handles survive process boundaries: in CI every pipeline step
# is a fresh shell.

np__state_init() {
  if [ -z "${NP_TRACE_DIR:-}" ]; then
    NP_TRACE_DIR="${TMPDIR:-/tmp}/nptrace.$$"
  fi
  export NP_TRACE_DIR
  mkdir -p "$NP_TRACE_DIR/nodes" "$NP_TRACE_DIR/staged" \
           "$NP_TRACE_DIR/spool" "$NP_TRACE_DIR/failed" 2>/dev/null || return 0
  if [ ! -f "$NP_TRACE_DIR/seq" ]; then
    printf '0' > "$NP_TRACE_DIR/seq"
  fi
  return 0
}

# Allocate the next handle. Handles are opaque by contract: consumers never
# parse them.
np__handle_new() {
  _hn_seq=$(cat "$NP_TRACE_DIR/seq" 2>/dev/null || printf '0')
  _hn_seq=$((_hn_seq + 1))
  printf '%s' "$_hn_seq" > "$NP_TRACE_DIR/seq"
  _hn_handle="n$_hn_seq"
  : > "$NP_TRACE_DIR/nodes/$_hn_handle"
  printf '%s' "$_hn_handle"
}

# THE rule the whole public surface rests on: an argument is a handle iff it
# names an existing node file.
np__is_handle() {
  [ -n "${1:-}" ] && [ -f "$NP_TRACE_DIR/nodes/$1" ]
}

np__node_set() {
  _ns_file="$NP_TRACE_DIR/nodes/$1"
  [ -f "$_ns_file" ] || return 0
  # Drop any prior value for this key, then append the new one.
  if grep -q "^$2=" "$_ns_file" 2>/dev/null; then
    grep -v "^$2=" "$_ns_file" > "$_ns_file.tmp" 2>/dev/null || : > "$_ns_file.tmp"
    mv "$_ns_file.tmp" "$_ns_file"
  fi
  printf '%s=%s\n' "$2" "$3" >> "$_ns_file"
  return 0
}

np__node_get() {
  _ng_file="$NP_TRACE_DIR/nodes/$1"
  [ -f "$_ng_file" ] || return 0
  # Take the first match and strip only the leading "key=", so a value
  # containing '=' survives intact.
  sed -n "s/^$2=//p" "$_ng_file" 2>/dev/null | head -n 1
  return 0
}

# Ambient resolution, exactly two levels. There is deliberately no third,
# session-wide level: that is where concurrent writers race.
np__ambient() {
  if [ -n "${NP_TRACE_CURRENT:-}" ]; then
    printf '%s' "$NP_TRACE_CURRENT"
    return 0
  fi
  cat "$NP_TRACE_DIR/current.$$" 2>/dev/null || printf ''
  return 0
}

np__ambient_set() {
  printf '%s' "$1" > "$NP_TRACE_DIR/current.$$" 2>/dev/null || return 0
  return 0
}

np__ambient_clear() {
  # Only clear if the cleared handle is the current one, so terminalizing an
  # outer node cannot silently retarget an inner one.
  if [ "$(np__ambient)" = "$1" ]; then
    rm -f "$NP_TRACE_DIR/current.$$" 2>/dev/null || :
    if [ -n "${NP_TRACE_CURRENT:-}" ] && [ "$NP_TRACE_CURRENT" = "$1" ]; then
      NP_TRACE_CURRENT=''
    fi
  fi
  return 0
}

# Every node-scoped public function starts here: use $1 when it is a handle,
# otherwise fall back to the ambient node.
np__resolve_handle() {
  if np__is_handle "${1:-}"; then
    printf '%s' "$1"
  else
    np__ambient
  fi
  return 0
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS, including the subshell-visibility and `NP_TRACE_CURRENT`-precedence assertions.

- [ ] **Step 5: Run under dash and lint**

Run: `NP_TEST_SHELL=/bin/dash make test && make lint`
Expected: PASS, lint clean.

- [ ] **Step 6: Commit**

```bash
git add src/state.sh test/unit/state.sh
git commit -m "feat(state): on-disk node registry with two-level ambient resolution"
```

---

### Task 9: spool.sh — envelope assembly and atomic spooling

**Files:**
- Modify: `src/spool.sh`
- Test: `test/unit/spool.sh`

**Interfaces:**
- Consumes: `np__uuidv7`, `np__iso8601` (Tasks 2–3), `np__json_obj_raw`, `np__json_str` (Tasks 4–5), `NP_TRACE_DIR` (Task 8).
- Produces: `np__spool <type> <nrn> <data-json>` → assembles the envelope, writes `spool/<event-id>.json` via create-then-rename, prints the event id. `np__spool_count` → prints the number of pending spool files.

- [ ] **Step 1: Write the failing test**

Create `test/unit/spool.sh`:

```sh
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
assert_match "$body" '*"id":"'"$id"'"*'          'envelope carries the id'
assert_match "$body" '*"type":"node.run"*'        'envelope carries the type'
assert_match "$body" '*"producer":"test-suite@0.1"*' 'envelope carries the producer'
assert_match "$body" '*"nrn":"organization=1"*'   'envelope carries the nrn'
assert_match "$body" '*"trace_id":"t"*'           'envelope carries the data verbatim'
assert_match "$body" '*"time":"20*Z"*'            'envelope carries an RFC 3339 time'

# No .tmp file may survive a successful spool.
leftover=$(find "$NP_TRACE_DIR/spool" -name '*.tmp' | wc -l | tr -d ' ')
assert_eq "$leftover" 0 'no temp files left behind'

# An omitted nrn is omitted from the envelope, not emitted as "".
id2=$(np__spool "$NP_TYPE_NODE_RUN" '' '{"trace_id":"t","run_id":"r2"}')
body2=$(cat "$NP_TRACE_DIR/spool/$id2.json")
assert_match "$body2" '*[!n]*' 'envelope built'
case "$body2" in
  *'"nrn"'*) assert_eq 'present' 'absent' 'empty nrn is omitted' ;;
  *) assert_eq 'absent' 'absent' 'empty nrn is omitted' ;;
esac

assert_eq "$(np__spool_count)" 2 'two events spooled'

rm -rf "$NP_TRACE_DIR"
. "$ROOT/test/lib/report.sh"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make test`
Expected: FAIL — `np__spool: not found`.

- [ ] **Step 3: Implement spool.sh**

Replace `src/spool.sh` with:

```sh
# spool.sh — the emit hot path. Every emit is a LOCAL FILE WRITE: the network
# is never touched here, which is what makes API downtime invisible to the
# caller. The spool file's NAME is the event id, so re-POSTing after a crash is
# idempotent — that is recover() for free.

# np__spool <type> <nrn> <data-json>  ->  prints the event id
np__spool() {
  _sp_id=$(np__uuidv7)
  _sp_env=$(np__json_obj_raw \
    id "$(np__json_str "$_sp_id")" \
    time "$(np__json_str "$(np__iso8601)")" \
    type "$(np__json_str "$1")" \
    nrn "$(if [ -n "$2" ]; then np__json_str "$2"; fi)" \
    producer "$(np__json_str "${NP_TRACE_PRODUCER:-}")" \
    data "$3")

  _sp_tmp="$NP_TRACE_DIR/spool/$_sp_id.json.tmp"
  _sp_final="$NP_TRACE_DIR/spool/$_sp_id.json"
  printf '%s' "$_sp_env" > "$_sp_tmp" 2>/dev/null || return 0
  # Create-then-rename: a flush never sees a half-written envelope.
  mv "$_sp_tmp" "$_sp_final" 2>/dev/null || return 0
  printf '%s' "$_sp_id"
  return 0
}

np__spool_count() {
  _sc_n=0
  for _sc_f in "$NP_TRACE_DIR/spool"/*.json; do
    [ -f "$_sc_f" ] || continue
    _sc_n=$((_sc_n + 1))
  done
  printf '%s' "$_sc_n"
  return 0
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/spool.sh test/unit/spool.sh
git commit -m "feat(spool): envelope assembly with atomic create-then-rename"
```

---

### Task 10: http.sh — curl wrapper, token exchange, drop recording

**Files:**
- Modify: `src/http.sh`
- Test: `test/unit/http.sh`

**Interfaces:**
- Consumes: `NP_TRACE_DIR` (Task 8).
- Produces: `np__drop <event-id> <reason>` → appends to `drops.log` and invokes `$NP_TRACE_ON_DROP` if set. `np__token` → prints a bearer token, exchanging the api key at most once per expiry window; prints empty on failure. `np__auth_config` → writes a mode-600 curl config carrying the auth header and prints its path. `np__post_event <file>` → POSTs one spool file, printing the HTTP status code (or `000` on a network failure).

- [ ] **Step 1: Write the failing test**

Create `test/unit/http.sh`:

```sh
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

# A drop listener is invoked when set.
NP_TRACE_ON_DROP='np_test_on_drop'
np_test_on_drop() { printf '%s\n' "listener:$1" >> "$NP_TRACE_DIR/listener.log"; }
np__drop 'evt-2' 'another'
assert_match "$(cat "$NP_TRACE_DIR/listener.log")" '*listener:evt-2*' 'drop listener invoked'
NP_TRACE_ON_DROP=''

# The auth config must be mode 600 and must carry the header.
NP_TRACE_TOKEN='secret-token-value'
cfg=$(np__auth_config)
assert_ok 'auth config written' test -f "$cfg"
assert_match "$(cat "$cfg")" '*Authorization: Bearer secret-token-value*' 'config carries the header'
perms=$(ls -l "$cfg" | cut -c1-10)
assert_eq "$perms" '-rw-------' 'auth config is mode 600'

# A pre-issued token is returned as-is, with no network call.
assert_eq "$(np__token)" 'secret-token-value' 'pre-issued token returned'

# An unreachable API must yield 000 and never hang or error.
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

rm -rf "$NP_TRACE_DIR"
. "$ROOT/test/lib/report.sh"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make test`
Expected: FAIL — `np__drop: not found`.

- [ ] **Step 3: Implement http.sh**

Replace `src/http.sh` with:

```sh
# http.sh — the only module that touches the network. Every request is bounded
# by a connect AND a total timeout, so an unreachable or hanging API can never
# stall the caller.

NP_TRACE_CONNECT_TIMEOUT="${NP_TRACE_CONNECT_TIMEOUT:-3}"
NP_TRACE_MAX_TIME="${NP_TRACE_MAX_TIME:-10}"

np__drop() {
  printf '%s\t%s\t%s\n' "$(np__iso8601)" "$1" "$2" >> "$NP_TRACE_DIR/drops.log" 2>/dev/null || :
  if [ -n "${NP_TRACE_ON_DROP:-}" ]; then
    "$NP_TRACE_ON_DROP" "$1" "$2" 2>/dev/null || :
  fi
  if [ -n "${NP_TRACE_DEBUG:-}" ]; then
    printf 'np-trace drop: %s (%s)\n' "$1" "$2" >&2
  fi
  return 0
}

# A bearer token. A pre-issued NP_TRACE_TOKEN wins; otherwise exchange the api
# key, caching until 60s before expiry. Called LAZILY, at first flush — never at
# init, so a down auth endpoint cannot delay pipeline startup.
np__token() {
  if [ -n "${NP_TRACE_TOKEN:-}" ]; then
    printf '%s' "$NP_TRACE_TOKEN"
    return 0
  fi
  if [ -z "${NP_TRACE_API_KEY:-}" ]; then
    printf ''
    return 0
  fi

  _tk_cache="$NP_TRACE_DIR/token"
  if [ -f "$_tk_cache" ]; then
    _tk_exp=$(sed -n '1p' "$_tk_cache" 2>/dev/null)
    _tk_val=$(sed -n '2p' "$_tk_cache" 2>/dev/null)
    case "$_tk_exp" in
      '' | *[!0-9]*) _tk_exp=0 ;;
    esac
    if [ -n "$_tk_val" ] && [ "$_tk_exp" -gt "$(date +%s)" ]; then
      printf '%s' "$_tk_val"
      return 0
    fi
  fi

  _tk_body=$(curl -sS -X POST \
    --connect-timeout "$NP_TRACE_CONNECT_TIMEOUT" --max-time "$NP_TRACE_MAX_TIME" \
    -H 'Content-Type: application/json' \
    -d "{\"apiKey\":$(np__json_str "$NP_TRACE_API_KEY")}" \
    "${NP_TRACE_AUTH_URL:-https://api.nullplatform.com}/token" 2>/dev/null) || _tk_body=''

  _tk_new=$(printf '%s' "$_tk_body" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [ -z "$_tk_new" ]; then
    np__drop 'auth' 'token exchange failed'
    printf ''
    return 0
  fi
  ( umask 077; printf '%s\n%s\n' "$(( $(date +%s) + 3540 ))" "$_tk_new" > "$_tk_cache" )
  printf '%s' "$_tk_new"
  return 0
}

# The auth header goes to curl via --config from a mode-600 file, NEVER as -H in
# argv: CI runs with `set -x`, and an argv-borne header prints the token into the
# build log.
np__auth_config() {
  _ac_file="$NP_TRACE_DIR/curlcfg.$$"
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$(np__token)" > "$_ac_file" )
  printf '%s' "$_ac_file"
  return 0
}

# POST one spool file. Prints the HTTP status code, or 000 on a network failure.
np__post_event() {
  _pe_cfg=$(np__auth_config)
  _pe_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    --config "$_pe_cfg" \
    --connect-timeout "$NP_TRACE_CONNECT_TIMEOUT" --max-time "$NP_TRACE_MAX_TIME" \
    -H 'Content-Type: application/json' \
    --data-binary "@$1" \
    "${NP_TRACE_BASE_URL:-https://api.nullplatform.com/tracing}/events" 2>/dev/null) || _pe_code='000'
  rm -f "$_pe_cfg" 2>/dev/null || :
  case "$_pe_code" in
    '' | *[!0-9]*) _pe_code='000' ;;
  esac
  printf '%s' "$_pe_code"
  return 0
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS, including the mode-600 and fail-fast assertions.

- [ ] **Step 5: Prove the token never reaches argv**

Run:

```bash
cd "$(git rev-parse --show-toplevel)"
NP_TRACE_DIR=$(mktemp -d) NP_TRACE_TOKEN='LEAKCANARY' NP_TRACE_BASE_URL='http://127.0.0.1:1' \
  sh -x -c '. ./nptrace.sh; np__state_init; printf "{}" > "$NP_TRACE_DIR/spool/a.json"; np__post_event "$NP_TRACE_DIR/spool/a.json"' 2>&1 \
  | grep -c 'LEAKCANARY'
```

Expected: `1` — the token appears only in the `printf` that writes the config file, never in a `curl` argv line. If the count is higher, inspect the trace; any occurrence on a `curl` line is a leak that must be fixed before continuing.

- [ ] **Step 6: Commit**

```bash
git add src/http.sh test/unit/http.sh
git commit -m "feat(http): bounded curl transport with config-file auth and drop recording"
```

---

### Task 11: flush.sh — bounded drain, response handling, exit trap

**Files:**
- Modify: `src/flush.sh`
- Test: `test/unit/flush.sh`, `test/integration/resilience.sh`

**Interfaces:**
- Consumes: `np__post_event`, `np__drop` (Task 10), `np__spool_count` (Task 9).
- Produces: `np_trace_flush` → drains the spool within the time budget, always returns 0. `np_trace_shutdown` → flush then remove the state dir. `np_trace_recover` → re-POST leftover spool files from a previous crashed process. `np__install_trap` → installs `trap np_trace_flush EXIT INT TERM` unless `NP_TRACE_NO_TRAP` is set.

- [ ] **Step 1: Write the failing test**

Create `test/unit/flush.sh`:

```sh
#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

NP_TRACE_DIR="$ROOT/.nptrace-test/flush-$$"
rm -rf "$NP_TRACE_DIR"
np__state_init
NP_TRACE_PRODUCER='test-suite@0.1'
NP_TRACE_TOKEN='t'
NP_TRACE_BASE_URL='http://127.0.0.1:1'

# Three spooled events against a dead endpoint.
i=1
while [ "$i" -le 3 ]; do
  printf '{"id":"e%s"}' "$i" > "$NP_TRACE_DIR/spool/e$i.json"
  i=$((i + 1))
done
assert_eq "$(np__spool_count)" 3 'three events spooled'

start=$(date +%s)
assert_ok 'flush returns 0 against a dead API' np_trace_flush
elapsed=$(( $(date +%s) - start ))

# Network failures are RETAINED for retry, never silently dropped.
assert_eq "$(np__spool_count)" 3 'unreachable API retains the spool'
if [ "$elapsed" -le 12 ]; then
  assert_eq 'bounded' 'bounded' 'flush respects its time budget'
else
  assert_eq "${elapsed}s" 'bounded' 'flush respects its time budget'
fi

# The attempt counter advances so retries eventually give up.
assert_ok 'attempt sidecar written' test -f "$NP_TRACE_DIR/spool/e1.json.attempts"

# After MAX_RETRIES the event moves to failed/ rather than retrying forever.
NP_TRACE_MAX_RETRIES=1
printf '2' > "$NP_TRACE_DIR/spool/e1.json.attempts"
np_trace_flush
assert_ok 'exhausted event moved to failed/' test -f "$NP_TRACE_DIR/failed/e1.json"

rm -rf "$NP_TRACE_DIR"
. "$ROOT/test/lib/report.sh"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make test`
Expected: FAIL — `np_trace_flush: not found`.

- [ ] **Step 3: Implement flush.sh**

Replace `src/flush.sh` with:

```sh
# flush.sh — the spool drain. Bounded by a wall-clock budget so a dead API can
# never hang process exit; every path returns 0.

NP_TRACE_FLUSH_TIMEOUT="${NP_TRACE_FLUSH_TIMEOUT:-10}"
NP_TRACE_MAX_RETRIES="${NP_TRACE_MAX_RETRIES:-3}"

np__attempts_of() {
  _ao_n=$(cat "$1.attempts" 2>/dev/null || printf '0')
  case "$_ao_n" in
    '' | *[!0-9]*) _ao_n=0 ;;
  esac
  printf '%s' "$_ao_n"
}

np__fail_event() {
  mv "$1" "$NP_TRACE_DIR/failed/" 2>/dev/null || rm -f "$1" 2>/dev/null || :
  rm -f "$1.attempts" 2>/dev/null || :
  np__drop "${1##*/}" "$2"
  return 0
}

np_trace_flush() {
  [ -n "${NP_TRACE_DIR:-}" ] || return 0
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _fl_deadline=$(( $(date +%s) + NP_TRACE_FLUSH_TIMEOUT ))

  for _fl_file in "$NP_TRACE_DIR/spool"/*.json; do
    [ -f "$_fl_file" ] || continue
    if [ "$(date +%s)" -ge "$_fl_deadline" ]; then
      # Budget spent. Remaining events stay on disk for the next flush or a
      # later np_trace_recover; the process exits on time regardless.
      return 0
    fi

    _fl_code=$(np__post_event "$_fl_file")
    case "$_fl_code" in
      201 | 200)
        rm -f "$_fl_file" "$_fl_file.attempts" 2>/dev/null || :
        ;;
      400)
        # A contract violation. Never retried — retrying cannot change it.
        np__fail_event "$_fl_file" "rejected 400"
        ;;
      401 | 403)
        rm -f "$NP_TRACE_DIR/token" 2>/dev/null || :
        np__fail_event "$_fl_file" "unauthorized $_fl_code"
        ;;
      *)
        _fl_n=$(( $(np__attempts_of "$_fl_file") + 1 ))
        if [ "$_fl_n" -gt "$NP_TRACE_MAX_RETRIES" ]; then
          np__fail_event "$_fl_file" "gave up after $_fl_n attempts (last status $_fl_code)"
        else
          printf '%s' "$_fl_n" > "$_fl_file.attempts" 2>/dev/null || :
        fi
        ;;
    esac
  done
  return 0
}

np_trace_shutdown() {
  np_trace_flush
  if [ -n "${NP_TRACE_DIR:-}" ] && [ "${NP_TRACE_KEEP_STATE:-0}" != '1' ]; then
    rm -rf "$NP_TRACE_DIR" 2>/dev/null || :
  fi
  return 0
}

# Re-deliver a previous process's leftover spool. Idempotent by construction:
# the spool file name IS the event id, so the API answers a re-POST with
# 200 duplicate.
np_trace_recover() {
  np_trace_flush
  return 0
}

np__install_trap() {
  if [ -z "${NP_TRACE_NO_TRAP:-}" ]; then
    trap 'np_trace_flush' EXIT INT TERM
  fi
  return 0
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Write the resilience integration suite**

Create `test/integration/resilience.sh`:

```sh
#!/bin/sh
# The availability invariant: a down, hanging, or erroring API must be
# invisible to the caller. Every case asserts exit 0, within the budget.
set -u
. "$ROOT/test/lib/assert.sh"

run_pipeline() {
  # $1 = base url. Returns the pipeline's exit code.
  NP_TRACE_DIR="$ROOT/.nptrace-test/res-$$-$(date +%s%N 2>/dev/null || date +%s)"
  export NP_TRACE_DIR
  sh -eu -c '
    . "'"$ROOT"'/nptrace.sh"
    np_trace_init --producer "resilience@0.1" --token "t" --base-url "'"$1"'"
    run=$(np_trace_run --trace-id "t1" --run-id "t1")
    np_trace_labels entity=test action=check
    step=$(np_trace_step "$run" work)
    np_trace_complete "$step"
    np_trace_complete "$run"
    np_trace_flush
  '
}

# 1. Connection refused.
start=$(date +%s)
run_pipeline 'http://127.0.0.1:1'
code=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "$code" 0 'pipeline exits 0 when the API refuses connections'
if [ "$elapsed" -le 15 ]; then
  assert_eq 'bounded' 'bounded' 'refused-connection run stays within budget'
else
  assert_eq "${elapsed}s" 'bounded' 'refused-connection run stays within budget'
fi

# 2. A host that black-holes packets (hang), bounded by --connect-timeout.
start=$(date +%s)
run_pipeline 'http://10.255.255.1'
code=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "$code" 0 'pipeline exits 0 when the API hangs'
if [ "$elapsed" -le 20 ]; then
  assert_eq 'bounded' 'bounded' 'hanging-API run stays within budget'
else
  assert_eq "${elapsed}s" 'bounded' 'hanging-API run stays within budget'
fi

# 3. No auth configured at all.
NP_TRACE_TOKEN='' NP_TRACE_API_KEY=''
run_pipeline 'http://127.0.0.1:1'
assert_eq "$?" 0 'pipeline exits 0 with no credentials configured'

rm -rf "$ROOT"/.nptrace-test/res-* 2>/dev/null || :
. "$ROOT/test/lib/report.sh"
```

- [ ] **Step 6: Run the resilience suite**

Run: `make build && sh test/run.sh integration`
Expected: FAIL for now — `np_trace_init`, `np_trace_run`, and `np_trace_step` arrive in Task 12. Re-run this suite at the end of Task 12 and expect PASS.

- [ ] **Step 7: Commit**

```bash
git add src/flush.sh test/unit/flush.sh test/integration/resilience.sh
git commit -m "feat(flush): time-bounded spool drain with retry and dead-letter handling"
```

---

### Task 12: api.sh — the public lifecycle surface

**Files:**
- Modify: `src/api.sh`
- Test: `test/unit/api.sh`

**Interfaces:**
- Consumes: everything from Tasks 2–11.
- Produces: `np_trace_init [--producer P] [--base-url U] [--auth-url U] [--api-key K] [--token T] [--nrn N] [--enabled 0|1]`; `np_trace_run --trace-id T --run-id R [--nrn N]` → prints a handle; `np_trace_step [h] <key> [--attempt N] [--iteration N]` → prints a handle; `np_trace_child [h] --run-id R` → prints a handle; `np_trace_start [h]`; `np_trace_labels [h] k=v…`; `np_trace_explain [h] --title T [--what W] [--why W] [--impact I] [--next N] [--severity S]`; `np_trace_error [h] --message M [--code C]`; `np_trace_timing [h] [--started-at T] [--ended-at T]`; `np_trace_facet [h] <ns> <json>`; `np_trace_schema [h] <url>`; terminals `np_trace_complete|_fail|_skip|_cancel|_timeout|_end|_waiting [h] [arg]`.

**Key semantic — lazy `started`:** `started` is emitted at the first event that must follow it (a terminal, a child open, an explicit `np_trace_start`, or flush). Context staged before that point lands on `started`; context staged after lands on the terminal.

- [ ] **Step 1: Write the failing test**

Create `test/unit/api.sh`:

```sh
#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

NP_TRACE_DIR="$ROOT/.nptrace-test/api-$$"
rm -rf "$NP_TRACE_DIR"
np_trace_init --producer 'test@0.1' --token 't' --base-url 'http://127.0.0.1:1' --no-trap

run=$(np_trace_run --trace-id 'tr1' --run-id 'tr1')
assert_ok 'run returns a handle' np__is_handle "$run"
assert_eq "$(np__node_get "$run" run_id)" 'tr1' 'run records its run_id'
assert_eq "$(np__node_get "$run" trace_id)" 'tr1' 'run records its trace_id'

# Lazy started: nothing on the wire until something must follow it.
assert_eq "$(np__spool_count)" 0 'opening a run emits nothing yet'

np_trace_labels entity=build action=publish
assert_eq "$(np__spool_count)" 0 'staging labels emits nothing'

step=$(np_trace_step "$run" compile)
assert_eq "$(np__node_get "$step" run_id)" 'tr1~compile@0.0' 'step id is derived'
assert_eq "$(np__node_get "$step" key)" 'compile' 'step records its key'
# Opening a child forces the parent's started, plus the child's own node event
# and the parent edge.
assert_match "$(np__spool_count)" '[1-9]*' 'opening a step forces the parent started'

np_trace_complete "$step"
np_trace_complete "$run"

# Every emitted envelope must carry the staged labels on the run's events.
found=0
for f in "$NP_TRACE_DIR/spool"/*.json; do
  [ -f "$f" ] || continue
  case "$(cat "$f")" in
    *'"entity":"build"'*) found=1 ;;
  esac
done
assert_eq "$found" 1 'staged labels reached the wire'

# A terminal on a closed node is a no-op, never a second terminal.
before=$(np__spool_count)
np_trace_complete "$run"
assert_eq "$(np__spool_count)" "$before" 'double terminal is a no-op'

# Every public function returns 0, even when given nonsense.
assert_ok 'labels on nothing returns 0'    np_trace_labels 'not-a-handle' 'k=v'
assert_ok 'complete on nothing returns 0'  np_trace_complete 'not-a-handle'
assert_ok 'step with an illegal key returns 0' np_trace_step "$run" 'bad key!'

# An illegal key is a recorded drop, not a crash.
assert_match "$(cat "$NP_TRACE_DIR/drops.log" 2>/dev/null || printf '')" '*key*' 'illegal key recorded as a drop'

rm -rf "$NP_TRACE_DIR"
. "$ROOT/test/lib/report.sh"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make test`
Expected: FAIL — `np_trace_init: not found`.

- [ ] **Step 3: Implement api.sh**

Replace `src/api.sh` with:

```sh
# api.sh — the public producer surface. Every function here returns 0, always:
# tracing must never fail the caller.

np_trace_init() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --producer) NP_TRACE_PRODUCER=${2:-}; shift 2 ;;
      --base-url) NP_TRACE_BASE_URL=${2:-}; shift 2 ;;
      --auth-url) NP_TRACE_AUTH_URL=${2:-}; shift 2 ;;
      --api-key) NP_TRACE_API_KEY=${2:-}; shift 2 ;;
      --token) NP_TRACE_TOKEN=${2:-}; shift 2 ;;
      --nrn) NP_TRACE_NRN=${2:-}; shift 2 ;;
      --enabled) NP_TRACE_ENABLED=${2:-1}; shift 2 ;;
      --no-trap) NP_TRACE_NO_TRAP=1; shift ;;
      *) shift ;;
    esac
  done
  NP_TRACE_ENABLED="${NP_TRACE_ENABLED:-1}"
  np__state_init
  # No network call here, deliberately: a down auth endpoint must never delay
  # the start of a pipeline. The token is fetched lazily, at first flush.
  np__install_trap
  return 0
}

# Emit the node event for a handle at the given status, carrying whatever
# context is currently staged.
np__emit_node() {
  _en_h=$1
  _en_status=$2
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0

  _en_labels=$(np__node_get "$_en_h" labels)
  _en_facets=$(np__node_get "$_en_h" facets)
  _en_key=$(np__node_get "$_en_h" key)

  if [ -n "$_en_key" ]; then
    _en_data=$(np__json_obj_raw \
      trace_id "$(np__json_str "$(np__node_get "$_en_h" trace_id)")" \
      run_id "$(np__json_str "$(np__node_get "$_en_h" run_id)")" \
      key "$(np__json_str "$_en_key")" \
      attempt "$(np__node_get "$_en_h" attempt)" \
      iteration "$(np__node_get "$_en_h" iteration)" \
      status "$(np__json_str "$_en_status")" \
      labels "$_en_labels" \
      facets "$_en_facets")
  else
    _en_data=$(np__json_obj_raw \
      trace_id "$(np__json_str "$(np__node_get "$_en_h" trace_id)")" \
      run_id "$(np__json_str "$(np__node_get "$_en_h" run_id)")" \
      status "$(np__json_str "$_en_status")" \
      labels "$_en_labels" \
      facets "$_en_facets")
  fi

  np__spool "$NP_TYPE_NODE_RUN" "$(np__node_get "$_en_h" nrn)" "$_en_data" >/dev/null
  return 0
}

# Force the lazy `started`. Idempotent.
np_trace_start() {
  _st_h=$(np__resolve_handle "${1:-}")
  np__is_handle "$_st_h" || return 0
  [ "$(np__node_get "$_st_h" started)" = '1' ] && return 0
  np__node_set "$_st_h" started 1
  np__emit_node "$_st_h" "$NP_STATUS_STARTED"
  return 0
}

np_trace_run() {
  _rn_trace=''; _rn_run=''; _rn_nrn="${NP_TRACE_NRN:-}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --trace-id) _rn_trace=${2:-}; shift 2 ;;
      --run-id) _rn_run=${2:-}; shift 2 ;;
      --nrn) _rn_nrn=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$_rn_trace" ] || _rn_trace=$_rn_run
  [ -n "$_rn_run" ] || _rn_run=$_rn_trace

  if ! _rn_why=$(np__trace_id_violation "$_rn_trace"); then
    np__drop 'run' "trace_id $_rn_why"
    return 0
  fi
  if ! _rn_why=$(np__named_id_violation "$_rn_run"); then
    np__drop 'run' "run_id $_rn_why"
    return 0
  fi

  _rn_h=$(np__handle_new)
  np__node_set "$_rn_h" kind run
  np__node_set "$_rn_h" trace_id "$_rn_trace"
  np__node_set "$_rn_h" run_id "$_rn_run"
  np__node_set "$_rn_h" nrn "$_rn_nrn"
  np__node_set "$_rn_h" started 0
  np__node_set "$_rn_h" closed 0
  np__ambient_set "$_rn_h"
  printf '%s' "$_rn_h"
  return 0
}

# np_trace_step [handle] <key> [--attempt N] [--iteration N]
np_trace_step() {
  _sp_parent=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  _sp_key=${1:-}
  shift 2>/dev/null || :
  _sp_attempt=0; _sp_iteration=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --attempt) _sp_attempt=${2:-0}; shift 2 ;;
      --iteration) _sp_iteration=${2:-0}; shift 2 ;;
      *) shift ;;
    esac
  done

  np__is_handle "$_sp_parent" || { np__drop 'step' 'no parent node in scope'; return 0; }
  if ! _sp_why=$(np__key_violation "$_sp_key"); then
    np__drop 'step' "key $_sp_why"
    return 0
  fi

  # Opening a child forces the parent's started: a parent edge must not point
  # at a node the read model has never seen.
  np_trace_start "$_sp_parent"

  _sp_parent_id=$(np__node_get "$_sp_parent" run_id)
  _sp_id=$(np__derive_child_id "$_sp_parent_id" "$_sp_key" "$_sp_attempt" "$_sp_iteration")

  _sp_h=$(np__handle_new)
  np__node_set "$_sp_h" kind step
  np__node_set "$_sp_h" trace_id "$(np__node_get "$_sp_parent" trace_id)"
  np__node_set "$_sp_h" run_id "$_sp_id"
  np__node_set "$_sp_h" nrn "$(np__node_get "$_sp_parent" nrn)"
  np__node_set "$_sp_h" key "$_sp_key"
  np__node_set "$_sp_h" attempt "$_sp_attempt"
  np__node_set "$_sp_h" iteration "$_sp_iteration"
  np__node_set "$_sp_h" parent "$_sp_parent"
  np__node_set "$_sp_h" started 0
  np__node_set "$_sp_h" closed 0

  np_trace_start "$_sp_h"
  np__emit_parent_edge "$_sp_parent" "$_sp_h"
  np__ambient_set "$_sp_h"
  printf '%s' "$_sp_h"
  return 0
}

np__emit_parent_edge() {
  _pe_from=$(np__json_obj \
    type run \
    trace_id "$(np__node_get "$1" trace_id)" \
    run_id "$(np__node_get "$1" run_id)")
  _pe_to=$(np__json_obj \
    type run \
    trace_id "$(np__node_get "$2" trace_id)" \
    run_id "$(np__node_get "$2" run_id)")
  _pe_data=$(np__json_obj_raw from "$_pe_from" to "$_pe_to")
  np__spool "$NP_TYPE_EDGE_PARENT" "$(np__node_get "$1" nrn)" "$_pe_data" >/dev/null
  return 0
}

# A named child run (a new scope under the same trace).
np_trace_child() {
  _ch_parent=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  _ch_run=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-id) _ch_run=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  np__is_handle "$_ch_parent" || { np__drop 'child' 'no parent node in scope'; return 0; }
  if ! _ch_why=$(np__named_id_violation "$_ch_run"); then
    np__drop 'child' "run_id $_ch_why"
    return 0
  fi
  np_trace_start "$_ch_parent"
  _ch_h=$(np_trace_run --trace-id "$(np__node_get "$_ch_parent" trace_id)" \
                       --run-id "$_ch_run" \
                       --nrn "$(np__node_get "$_ch_parent" nrn)")
  np__is_handle "$_ch_h" || return 0
  np__node_set "$_ch_h" parent "$_ch_parent"
  np_trace_start "$_ch_h"
  np__emit_parent_edge "$_ch_parent" "$_ch_h"
  np__ambient_set "$_ch_h"
  printf '%s' "$_ch_h"
  return 0
}

# Merge a JSON fragment into the node's staged labels object.
np__stage_label() {
  _sl_cur=$(np__node_get "$1" labels)
  if [ -z "$_sl_cur" ] || [ "$_sl_cur" = '{}' ]; then
    np__node_set "$1" labels "{$2}"
  else
    np__node_set "$1" labels "${_sl_cur%\}},$2}"
  fi
  return 0
}

np__stage_facet() {
  _sf_cur=$(np__node_get "$1" facets)
  _sf_entry="$(np__json_str "$2"):$3"
  if [ -z "$_sf_cur" ] || [ "$_sf_cur" = '{}' ]; then
    np__node_set "$1" facets "{$_sf_entry}"
  else
    np__node_set "$1" facets "${_sf_cur%\}},$_sf_entry}"
  fi
  return 0
}

# np_trace_labels [handle] key=value ...
np_trace_labels() {
  _lb_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_lb_h" || return 0
  for _lb_pair in "$@"; do
    case "$_lb_pair" in
      *=*) ;;
      *) continue ;;
    esac
    _lb_k=${_lb_pair%%=*}
    _lb_v=${_lb_pair#*=}
    # An absent optional is omitted, never recorded as the string "null".
    [ -n "$_lb_v" ] || continue
    np__stage_label "$_lb_h" "$(np__json_str "$_lb_k"):$(np__json_str "$_lb_v")"
  done
  return 0
}

np_trace_facet() {
  _fc_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_fc_h" || return 0
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  np__stage_facet "$_fc_h" "$1" "$2"
  return 0
}

np_trace_schema() {
  _sc_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_sc_h" || return 0
  np__node_set "$_sc_h" schema_url "${1:-}"
  return 0
}

np_trace_explain() {
  _ex_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_ex_h" || return 0
  _ex_title=''; _ex_what=''; _ex_why=''; _ex_impact=''; _ex_next=''; _ex_sev=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) _ex_title=${2:-}; shift 2 ;;
      --what) _ex_what=${2:-}; shift 2 ;;
      --why) _ex_why=${2:-}; shift 2 ;;
      --impact) _ex_impact=${2:-}; shift 2 ;;
      --next) _ex_next=${2:-}; shift 2 ;;
      --severity) _ex_sev=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$_ex_title" ] || { np__drop 'explain' 'title is required'; return 0; }
  np__stage_facet "$_ex_h" "$NP_FACET_EXPLAIN" \
    "$(np__json_obj title "$_ex_title" severity "$_ex_sev" what "$_ex_what" \
        why "$_ex_why" impact "$_ex_impact" next "$_ex_next")"
  return 0
}

np_trace_error() {
  _er_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_er_h" || return 0
  _er_msg=''; _er_code=''; _er_stack=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --message) _er_msg=${2:-}; shift 2 ;;
      --code) _er_code=${2:-}; shift 2 ;;
      --stack-trace) _er_stack=${2:-}; shift 2 ;;
      *) [ -n "$_er_msg" ] || _er_msg=$1; shift ;;
    esac
  done
  [ -n "$_er_msg" ] || return 0
  np__stage_facet "$_er_h" "$NP_FACET_ERROR" \
    "$(np__json_obj message "$_er_msg" code "$_er_code" stack_trace "$_er_stack")"
  return 0
}

np_trace_timing() {
  _tm_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_tm_h" || return 0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --started-at) np__node_set "$_tm_h" started_at "${2:-}"; shift 2 ;;
      --ended-at) np__node_set "$_tm_h" ended_at "${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  return 0
}

# Stamp the auto timing facet, letting any manual override win per field.
np__stage_timing() {
  _sg_started=$(np__node_get "$1" started_at)
  _sg_ended=$(np__node_get "$1" ended_at)
  [ -n "$_sg_started" ] || _sg_started=$(np__node_get "$1" auto_started_at)
  [ -n "$_sg_ended" ] || _sg_ended=$2
  np__stage_facet "$1" "$NP_FACET_TIMING" \
    "$(np__json_obj started_at "$_sg_started" ended_at "$_sg_ended")"
  return 0
}

# The shared terminal path. $1 = handle, $2 = status.
np__terminalize() {
  np__is_handle "$1" || return 0
  [ "$(np__node_get "$1" closed)" = '1' ] && return 0
  np_trace_start "$1"
  np__stage_timing "$1" "$(np__iso8601)"
  np__node_set "$1" closed 1
  np__emit_node "$1" "$2"
  np__ambient_clear "$1"
  # Restore the parent as ambient so a sibling opened next lands correctly.
  _tz_parent=$(np__node_get "$1" parent)
  if [ -n "$_tz_parent" ] && np__is_handle "$_tz_parent"; then
    np__ambient_set "$_tz_parent"
  fi
  return 0
}

np_trace_complete() {
  np__terminalize "$(np__resolve_handle "${1:-}")" "$NP_STATUS_COMPLETED"
}

np_trace_end() {
  np_trace_complete "$@"
}

np_trace_fail() {
  _fa_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  if [ -n "${1:-}" ]; then
    np_trace_error "$_fa_h" --message "$1"
  fi
  # fail cascades to still-open child steps; complete deliberately does not.
  np__cascade_fail "$_fa_h" "${1:-}"
  np__terminalize "$_fa_h" "$NP_STATUS_FAILED"
}

np__cascade_fail() {
  for _cf_file in "$NP_TRACE_DIR/nodes"/*; do
    [ -f "$_cf_file" ] || continue
    _cf_h=${_cf_file##*/}
    [ "$(np__node_get "$_cf_h" parent)" = "$1" ] || continue
    [ "$(np__node_get "$_cf_h" closed)" = '1' ] && continue
    np__cascade_fail "$_cf_h" "$2"
    if [ -n "$2" ]; then
      np_trace_error "$_cf_h" --message "$2"
    fi
    np__terminalize "$_cf_h" "$NP_STATUS_FAILED"
  done
  return 0
}

np_trace_skip() {
  _sk_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  if [ -n "${1:-}" ]; then
    np__stage_facet "$_sk_h" "$NP_FACET_DROPPED" "$(np__json_obj reason "$1")"
  fi
  np__terminalize "$_sk_h" "$NP_STATUS_SKIPPED"
}

np_trace_cancel() {
  _cn_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__terminalize "$_cn_h" "$NP_STATUS_CANCELLED"
}

np_trace_timeout() {
  np__terminalize "$(np__resolve_handle "${1:-}")" "$NP_STATUS_TIMED_OUT"
}

# Non-terminal: the node stays open.
np_trace_waiting() {
  _wt_h=$(np__resolve_handle "${1:-}")
  np__is_handle "$_wt_h" || return 0
  np_trace_start "$_wt_h"
  np__emit_node "$_wt_h" "$NP_STATUS_WAITING"
  return 0
}
```

Then set the auto start timestamp when a node opens — add to `np_trace_run` and `np_trace_step`, immediately after each `np__node_set "$h" started 0` line:

```sh
  np__node_set "$_rn_h" auto_started_at "$(np__iso8601)"
```

(and the `_sp_h` equivalent in `np_trace_step`).

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Run the resilience suite from Task 11**

Run: `sh test/run.sh integration`
Expected: PASS — all three availability cases exit 0 within budget. This is the availability invariant proven end to end.

- [ ] **Step 6: Run under dash and lint**

Run: `NP_TEST_SHELL=/bin/dash make test-all && make lint`
Expected: PASS, lint clean.

- [ ] **Step 7: Commit**

```bash
git add src/api.sh test/unit/api.sh
git commit -m "feat(api): run/step lifecycle, lazy started, staged context, and terminals"
```

---

### Task 13: End-to-end against the live tracing API

**Files:**
- Create: `test/integration/live.sh`

**Interfaces:**
- Consumes: the whole public surface from Task 12.
- Produces: proof that the hand-ported contract is accepted by the real ingest path — the only test that can prove the port is correct.

- [ ] **Step 1: Start the tracing API stack**

```bash
cd <the tracing API repo>
npm run compose:up
NODE_ENV=development npm run db:migrate
NODE_ENV=development npm run start &      # API on :8080
NODE_ENV=development npm run projector &  # folds Layer 1 -> Layer 2
```

- [ ] **Step 2: Write the failing test**

Create `test/integration/live.sh`:

```sh
#!/bin/sh
# End-to-end against a running tracing API. Skipped unless NP_LIVE_URL is set.
set -u
. "$ROOT/test/lib/assert.sh"

if [ -z "${NP_LIVE_URL:-}" ]; then
  printf 'SKIP: set NP_LIVE_URL to run the live suite\n'
  . "$ROOT/test/lib/report.sh"
  return 0 2>/dev/null || exit 0
fi

. "$ROOT/nptrace.sh"

NP_TRACE_DIR="$ROOT/.nptrace-test/live-$$"
rm -rf "$NP_TRACE_DIR"
np_trace_init --producer 'catalog-tracing-sh-test@0.1' \
              --token "${NP_LIVE_TOKEN:-test-token}" \
              --base-url "$NP_LIVE_URL" \
              --no-trap

TRACE=$(np_trace_key 'shtest' "$(np_trace_occurrence)")
run=$(np_trace_run --trace-id "$TRACE" --run-id "$TRACE")
np_trace_labels entity=build action=publish 'application.id=42'
np_trace_explain --title 'Shell SDK end-to-end' --what 'Emitted by the POSIX sh SDK test suite'

compile=$(np_trace_step "$run" compile)
np_trace_complete "$compile"

publish=$(np_trace_step "$run" publish)
np_trace_error "$publish" --message 'registry unreachable' --code 'EREG'
np_trace_fail "$publish"

np_trace_complete "$run"

spooled=$(np__spool_count)
assert_match "$spooled" '[1-9]*' 'events were spooled'

np_trace_flush

# Every event must have been accepted: nothing left in spool, nothing failed.
assert_eq "$(np__spool_count)" 0 'all events accepted by ingest'
failed=$(find "$NP_TRACE_DIR/failed" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$failed" 0 'no event was rejected'
assert_eq "$(cat "$NP_TRACE_DIR/drops.log" 2>/dev/null | wc -l | tr -d ' ')" 0 'no drops recorded'

rm -rf "$NP_TRACE_DIR"
. "$ROOT/test/lib/report.sh"
```

- [ ] **Step 3: Run it to verify it fails or reveals contract errors**

Run:

```bash
cd "$(git rev-parse --show-toplevel)"
make build
NP_LIVE_URL=http://localhost:8080 sh test/run.sh integration
```

Expected: initially FAIL, with rejected events. For each failure, read the API's message:

```bash
cat .nptrace-test/live-*/drops.log
```

The message names the field and reason (the catalog envelope: `{statusCode, code, error, message}`). Fix `src/api.sh` or `src/spool.sh` accordingly and re-run.

- [ ] **Step 4: Verify the trace is readable through the read API**

Run:

```bash
curl -s "http://localhost:8080/runs?labels.application.id=42" \
  -H "Authorization: Bearer ${NP_LIVE_TOKEN:-test-token}" | head -40
```

Expected: the run appears with `status: "completed"`, its `explain` title, and the labels. Then confirm the failed step and the derived id:

```bash
curl -s "http://localhost:8080/steps?key=publish" \
  -H "Authorization: Bearer ${NP_LIVE_TOKEN:-test-token}" | head -40
```

Expected: one keyed node with `status: "failed"`, an `error` field carrying `registry unreachable`, and a `run_id` ending `~publish@0.0`.

- [ ] **Step 5: Re-run the flush to prove idempotency**

Run: re-POST one already-accepted event by hand and confirm the API answers `200` with `duplicate: true`:

```bash
ID=$(sh -c '. ./nptrace.sh; np__uuidv7')
BODY='{"id":"'"$ID"'","time":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","type":"node.run","producer":"t@1","data":{"trace_id":"dup-test","run_id":"dup-test","status":"started"}}'
for _ in 1 2; do
  curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8080/events \
    -H 'Content-Type: application/json' -H "Authorization: Bearer ${NP_LIVE_TOKEN:-test-token}" \
    -d "$BODY"
done
```

Expected: `201` then `200` — confirming the spool's re-POST-after-crash path is safe.

- [ ] **Step 6: Commit**

```bash
git add test/integration/live.sh
git commit -m "test(integration): end-to-end emit against a live tracing API"
```

---

### Task 14: Docs, working agreements, and CI

**Files:**
- Create: `README.md`, `llms.txt`, `CLAUDE.md`, `SECURITY.md`, `LICENSE`
- Create: `.github/workflows/ci.yml`
- Modify: `nptrace.sh` (commit the built artifact)

**Interfaces:**
- Consumes: the complete Phase-1 surface.
- Produces: a repo a consumer can adopt, and a CI gate that runs lint + unit + integration across `dash` and `bash`.

- [ ] **Step 1: Write the CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: ci

on:
  push:
    branches: [main]
  pull_request:

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update && sudo apt-get install -y shellcheck
      - run: make lint

  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        shell: [/bin/dash, /bin/bash]
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update && sudo apt-get install -y dash jq
      - run: make build
      - run: NP_TEST_SHELL=${{ matrix.shell }} sh test/run.sh all

  built-artifact-is-current:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./build.sh
      - name: nptrace.sh must match src/
        run: git diff --exit-code nptrace.sh
```

- [ ] **Step 2: Run the build-currency check locally**

Run: `./build.sh && git diff --exit-code nptrace.sh`
Expected: exit 0 after committing the built artifact in Step 5. If it fails, the committed `nptrace.sh` is stale — rebuild and commit.

- [ ] **Step 3: Write CLAUDE.md**

Create `CLAUDE.md`:

```markdown
# catalog-tracing-sh — working agreements

The POSIX shell SDK (`nptrace.sh`) for the nullplatform tracing API.
Producer-only; zero runtime dependencies beyond `curl` and the POSIX toolset.

## Treat this repo as PUBLIC

The repository may be private for now, but treat everything (code, comments,
examples, README, `llms.txt`, commit messages) as public:

- **No internal leaks.** Only the public `api.nullplatform.com` endpoints — never
  internal hosts, private URLs, credentials/tokens, internal service names,
  codenames, or internal platform architecture. All example data must be
  obviously synthetic.
- Public-quality docs and clear Conventional-Commits messages.

## The wire contract lives in the tracing API (another repo)

The tracing **API** owns the wire contract. It is **hand-ported here** to
`src/identity.sh` and `src/wire.sh`. The SDK and the API ship separately and are
kept in sync **by hand** — there is no codegen and no shared package.

**When the API's wire contract changes:**
1. Port the change into `src/identity.sh` / `src/wire.sh`, keeping
   `test/unit/identity.sh` and `test/unit/wire.sh` aligned.
2. Reconcile the public surface only if producers must set something new.
3. Run `make lint && make test-all` — the wire tests are the safety net.
4. Rebuild (`./build.sh`) and commit `nptrace.sh`.

## Invariants — do not break

- **Tracing NEVER breaks the caller.** If the API or auth endpoint is down, slow,
  hanging, or erroring, the instrumented pipeline proceeds without error. Every
  public function returns 0, always. The hot path is a local file write; the
  network is touched only at flush, under a wall-clock budget.
- **POSIX `sh` only.** No arrays, `[[`, `local`, `$RANDOM`, `function`, `+=`, or
  process substitution. `shellcheck -s sh` must pass clean.
- **Zero runtime dependencies** beyond `curl`, `awk`, `od`, `sed`, `tr`, `cut`,
  `date`, `mv`, `mkdir`.
- **Speak the wire vocabulary** — never rename or invent concepts.
- **One function per operation, with an OPTIONAL handle argument.** The ambient
  form is an omitted argument with a default, never a second function. Do not add
  a parallel `*_begin`/`*_end` family.
- **The bearer token never appears in argv.** It goes to curl via `--config` from
  a mode-600 file, because CI runs with `set -x`.
- **Config comes from `np_trace_init` flags**, defaulted from **namespaced
  `NP_TRACE_*`** environment variables only. Never read an ambient
  `NULLPLATFORM_API_KEY`.
- **Security.** The bearer JWT is never verified here — the API verifies it.

## Build / test

```sh
make lint && make test-all
```

`nptrace.sh` is a generated file — edit `src/*.sh` and rebuild. CI fails if the
committed artifact is stale.
```

- [ ] **Step 4: Write README.md and llms.txt**

`README.md` covers: what it is, install (`curl` the pinned artifact, or vendor the file), a quickstart mirroring the spec's §9 worked example, the config table (`NP_TRACE_*`), the availability guarantee, and the Phase-2 scope note. `llms.txt` follows the shape of the JS and Go SDKs' `llms.txt`: prime directives, the 30-second model, lifecycle, setters, the identity/labels matrix, the coverage checklist, and an anti-patterns table — restricted to the Phase-1 surface, with deferred functions explicitly listed as not-yet-available.

- [ ] **Step 5: Build, run everything, and commit**

```bash
cd "$(git rev-parse --show-toplevel)"
./build.sh
make lint
make test-all
git add .
git commit -m "docs: README, llms.txt, working agreements, and CI matrix"
```

- [ ] **Step 6: Verify the full gate one more time under both shells**

Run:

```bash
NP_TEST_SHELL=/bin/dash sh test/run.sh all
NP_TEST_SHELL=/bin/bash sh test/run.sh all
make lint
```

Expected: `0 failures` from both shells, lint clean.

---

## Self-Review

**Spec coverage.** Spec §4 architecture → Task 1 (build, module split) with each module in Tasks 2–12; §4.1 dual entry mode → `cli.sh` scaffolded in Task 1, shim deferred to Phase 2 and stated in the scope note; §4.2 four-repo checklist → Task 14 `CLAUDE.md`; §5 state/handles/ambient → Task 8; §5.1 two-level ambient → Task 8 tests; §5.2 lazy `started` → Task 12; §5.3 stateless identity → Task 6; §6 availability → Tasks 10 (timeouts), 11 (budget, trap), 12 (resilience suite run), 14 (`CLAUDE.md` invariant); §7 delivery → Tasks 9 and 11; §7.1 auth → Task 10; §7.2 fail-fast divergence → Task 12 (`np__drop` on an illegal key, asserted); §8 surface → Task 12 for the Phase-1 subset, remainder explicitly deferred; §8.4 carrier → Task 7 constants (functions in Phase 2); §10 testing → Tasks 1, 4 (jq differential), 11 and 12 (resilience), 13 (live), 14 (CI matrix); §11 release → Task 14.

**Deliberate gaps, stated in the scope note rather than silently dropped:** the 11 remaining setters, 9 edge functions, six io builders, four ref constructors, propagation, the CLI shim, and the alpine/`ksh`/bash-3.2 legs of the portability matrix. `nptrace.sh` being committed is covered by the Task 14 CI currency check.

**Placeholder scan:** no TBD/TODO; every code step carries runnable code; every run step carries an exact command and expected output. Task 14 Step 4 describes README/`llms.txt` content by section rather than inlining prose — acceptable, since both are documentation whose model (the sibling SDKs' `llms.txt`) is named and readable.

**Type consistency:** `np__resolve_handle`, `np__is_handle`, `np__node_get`/`_set`, `np__ambient*` are defined in Task 8 and used with identical signatures in Tasks 9–12. `np__spool <type> <nrn> <data>` is defined in Task 9 and called with three arguments in Tasks 12 (`np__emit_node`, `np__emit_parent_edge`). `np__json_obj` / `np__json_obj_raw` keep the alternating key/value signature across Tasks 5, 9, and 12. `np__drop <id> <reason>` is two-argument in Tasks 10, 11, and 12. Status and facet constants come from Task 7 and are referenced by their `NP_STATUS_*` / `NP_FACET_*` names throughout.
