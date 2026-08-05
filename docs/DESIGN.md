# Design — a POSIX shell producer SDK

Design spec. A fourth producer SDK for the nullplatform tracing API, targeting CI
pipelines: pure POSIX `sh` + `curl`, no binary, no interpreter, no package
manager.

## 1. Why

CI is where builds, releases, images and deployments actually happen — and it is
the one producer environment that has no runtime we already ship an SDK for. A
pipeline step is a shell script. Today the only way to emit a trace from one is
to hand-build wire envelopes with `curl`, which means every pipeline
re-implements the id grammar, the UUIDv7 event id, and JSON escaping, and gets
them wrong.

The `np` CLI is not that vehicle. It has no tracing commands today (v2.4.1), so
"wrap the CLI" means building tracing into the Go CLI first, then requiring the
binary in every CI image — while coupling tracing releases to CLI releases. The
shell SDK removes the dependency instead of adding one.

## 2. Goals and non-goals

Serves the mandate in `docs/design/GOALS.md`, specifically:

- **#5 minimal-code, low-risk adoption** — a pipeline adopts tracing by sourcing
  one file. No image change, no install step, no new runtime.
- **#2 any distributed flow** — CI is a distributed flow: steps span processes,
  runners, and jobs.
- **#1 observe-only** — the SDK is a producer. It never reads, never orchestrates.

Non-goals: a read/query client (rejected for every SDK — consumers integrate the
HTTP surface directly), and any coupling to a specific CI vendor.

## 3. Settled decisions

| #   | Decision                                                                          | Rationale                                                                                                                                                     |
| --- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Pure POSIX `sh` + `curl`. No `jq`, no `bash`-isms, no binary.**                 | `jq` is absent from alpine/slim/scratch-derived images; requiring it puts an install step in every pipeline. `curl` + `sh` is the one thing every runner has. |
| 2   | **Full wire parity with JS/Go** — all 3 node kinds, 9 edge types, 16 core facets. | Partial parity creates "the bash one can't do X" and pushes producers back to hand-rolled `curl`.                                                             |
| 3   | **Token-first handles, ambient as an optional argument.**                         | Mirrors Go's explicit `*Handle` for correctness under nesting/parallelism, with JS-like brevity for linear pipelines.                                         |
| 4   | **Spool file + flush.**                                                           | The JS/Go buffered + `flush()`/`shutdown()` model. The spool doubles as their `PersistentStore`, so `recover()` is free.                                      |
| 5   | **New repo `catalog-tracing-sh`.**                                                | Fourth sibling to `-js`/`-go`, same working agreements and release story.                                                                                     |

### 3.1 The redundant-second-way rule

Both existing SDKs deliberately removed redundant spellings (the raw `.io()`
setter, positional `tracer.job()`, `runKey()`). The ambient-handle sugar must not
become that trap.

**The binding rule: there is ONE function per operation, whose handle argument is
optional.** The ambient form is an omitted argument with a default, not a second
function and not a second way to name a node. Any proposal that adds a parallel
`*_begin`/`*_end` family, or a second spelling of an existing call, is rejected on
this rule.

## 4. Architecture

Modules under `src/`, concatenated at build time into one distributable
`nptrace.sh`. No Node, no Go, no toolchain — the repo is dependency-free end to
end (dev-only: `shellcheck`, and `jq` for differential tests).

| Module        | Owns                                                                                                                |
| ------------- | ------------------------------------------------------------------------------------------------------------------- |
| `compat.sh`   | Millisecond epoch, urandom hex, portable `printf`. **The only place OS differences live.**                          |
| `json.sh`     | String escaping, object/array emission. One minimal field extractor for the auth response — no general parser.      |
| `uuid.sh`     | UUIDv7 generation, `occurrence()`.                                                                                  |
| `identity.sh` | Hand-port of `packages/events/src/identity.ts`.                                                                     |
| `wire.sh`     | Hand-port of the rest of `packages/events`: 12 types, 7 statuses, 9 edges, 16 `CoreFacet` names, reserved prefixes. |
| `state.sh`    | Handle allocation, node registry, ambient resolution.                                                               |
| `spool.sh`    | One file per event, create-then-rename.                                                                             |
| `http.sh`     | curl invocation, apiKey→bearer exchange + cache, backoff, drop reporting.                                           |
| `flush.sh`    | Drain spool, bounded-parallel POSTs, `trap EXIT`, recover.                                                          |
| `api.sh`      | The public producer surface.                                                                                        |
| `cli.sh`      | argv → function shim. **Zero logic of its own.**                                                                    |

`identity.sh` + `wire.sh` are the exact analog of Go's `internal/wire`: a hand-
ported contract whose own tests are the drift safety net.

### 4.1 Dual entry mode

One artifact, two entries — `. nptrace.sh` exposes the functions;
`nptrace.sh step build --complete` runs the same functions as subcommands.
Because state lives on disk rather than in shell memory, both behave identically.

This matters because in GitHub Actions each `run:` block is a fresh shell;
re-sourcing in every block is friction that an executable on `PATH` removes.

`cli.sh` is a pure argv→function shim. If it ever acquires logic of its own, it
becomes a second implementation to keep in parity — that is the rule 3.1 trap in
another costume.

### 4.2 Consequence: the contract checklist becomes four repos

A wire-contract change is now: API (`packages/events` + ingest schema + projector)
→ JS (copy `src/events/` verbatim) → Go (hand-port `internal/wire`) → **sh
(hand-port `identity.sh`/`wire.sh`)**. There is still no codegen and no shared
package; each SDK's own wire tests are the safety net.

## 5. State, handles, and ambient resolution

```
$NP_TRACE_DIR/
  nodes/<handle>          k=v: kind trace_id run_id nrn key attempt iteration parent status started_at
  staged/<handle>.labels  accumulated, not yet emitted
  staged/<handle>.facets
  current.<pid>           ambient pointer
  seq                     handle counter
  spool/<event-uuid>.json one file per event
  failed/<event-uuid>.json
  token                   cached bearer + expiry (mode 600)
  drops.log
```

A **handle** is an opaque short token (`n1`, `n2`, …) naming a file in `nodes/`.
Opaque by contract — consumers never parse it.

**The handle-detection rule** — the rule the whole surface rests on:

> The first argument to any node-scoped function is a handle **iff it names an
> existing file in `nodes/`**.

This is what makes the optional-handle sugar unambiguous (`np_trace_fail "$run"
"boom"` vs `np_trace_fail "boom"`), and it is why handles are allocator-minted
tokens rather than user-chosen strings.

### 5.1 Ambient resolution — exactly two levels

1. `$NP_TRACE_CURRENT`, if set. Explicit, and what you export to cross a CI step
   boundary: `echo "NP_TRACE_CURRENT=$run" >> "$GITHUB_ENV"`.
2. `current.$$`, auto-maintained within one process tree. POSIX `$$` does not
   change in a subshell, so a handle created inside `run=$(np_trace_run …)` is
   visible to the caller.

There is deliberately no third, session-wide fallback: that is the level at which
concurrent writers race.

Two limits, documented rather than discovered:

- **Ambient is undefined for parallel or backgrounded work.** Concurrent steps
  share `$$`, so they must pass handles explicitly. This is why token-first is the
  real API.
- **Ambient does not survive a fresh CI step process** unless `NP_TRACE_CURRENT`
  is exported.

### 5.2 Lazy `started` — the microtask port

JS and Go emit `started` one microtask after construction so synchronously-set
context lands on it. Shell has no microtask; the faithful analog is **lazy
`started`**, emitted at the first event that must follow it: a terminal, a child
open, an explicit `np_trace_start`, or flush.

Observable semantics are identical — context staged before that point lands on
`started`, context staged after lands on the terminal — with no timer.

The JS/Go 200 ms late-enrichment window becomes: context staged after `started`
that never receives a terminal is emitted by flush-at-exit as a coalesced re-emit
of the node's last status.

### 5.3 Identity needs no state

A step's `run_id` is `parent~key@attempt.iteration`, so identity is recomputable
from coordinates alone. State is an ergonomic cache, never the source of truth.
`attempt`/`iteration` are explicit flags defaulting to `0`/`0` — no implicit retry
magic.

## 6. Availability: the tracing API being down is invisible to the build

**Invariant, binding on every nullplatform tracing SDK:** if the tracing API (or
the auth endpoint) is down, slow, hanging, or erroring, the instrumented program's
normal flow proceeds without error. Tracing degrades; the caller never does.

In this SDK that is structural rather than defensive:

- **The hot path never touches the network.** Every emit is a local file write, so
  API downtime cannot reach the pipeline.
- **`np_trace_init` makes no network call.** Token acquisition is lazy, at first
  flush — otherwise a down auth endpoint would delay the start of every pipeline.
- **Flush has a total time budget** (`NP_TRACE_FLUSH_TIMEOUT`, default 10s). A dead
  API must not hang the job at `trap EXIT`; when the budget expires, remaining
  events stay on disk and the process exits 0.
- **Every curl carries `--connect-timeout` and `--max-time`.**
- **Every public function returns 0, always.** Nothing writes to stderr unless
  `NP_TRACE_DEBUG=1`; only the openers write to stdout. Safe under
  `set -euo pipefail`.
- **Spool size and file count are capped** so a runaway pipeline cannot fill a
  runner's disk; over the cap, oldest events are dropped and the drop is recorded.

This invariant should also be recorded in the `CLAUDE.md` of
`catalog-tracing-api`, `-js`, and `-go`, since it binds them too.

## 7. Delivery

Emit = build envelope → write `spool/<uuid>.json.tmp` → `mv` (atomic rename on the
same filesystem). No locking. **The filename is the event id**, so a re-POST after
a crash is idempotent by construction — that is `recover()` for free.

Flush iterates the spool, up to `NP_TRACE_CONCURRENCY` (default 4) curls via `&`
and `wait`, within the flush budget:

| Response                    | Action                                                                           |
| --------------------------- | -------------------------------------------------------------------------------- |
| `201`, or `200` duplicate   | delete the spool file                                                            |
| `400`                       | move to `failed/`, record a drop. **Never retried** — it is a contract violation |
| `401`/`403`                 | refresh the token once, then `failed/`                                           |
| 5xx, network error, timeout | keep, bump the attempt sidecar; after `NP_TRACE_MAX_RETRIES` (3) → `failed/`     |

Triggers: `trap EXIT INT TERM` installed by `np_trace_init` (opt out with
`NP_TRACE_NO_TRAP=1`), an explicit `np_trace_flush`, and an auto-flush when the
spool passes a threshold so a long pipeline does not accumulate.

### 7.1 Auth

Mirrors JS/Go: `NP_TRACE_API_KEY` → `POST {auth}/token` → cache bearer and expiry
in `token` (mode 600), reused until 60s before expiry. A pre-issued
`NP_TRACE_TOKEN` is accepted directly.

**Shell-specific hardening:** the bearer is passed to curl via `--config` from a
600 file, **never as `-H` in argv**. CI turns on `set -x` constantly, and an
argv-borne header prints the token into the build log.

### 7.2 Fail-fast divergence

JS throws before send on client-detectable contract violations; Go records a
deferred `Err()`. Bash cannot throw without risking the build, so the analog is:
**detect at call time, record a drop, return 0.**

`NP_TRACE_STRICT=1` makes those exit non-zero, so violations stay visible in local
development and in the test suite — where surfacing them is safe.

## 8. Public surface

Prefixed `np_trace_*`. Every node-scoped function takes an optional leading handle
per the rule in §5.

- **Tracer** — `np_trace_init`, `_flush`, `_shutdown`, `_recover`
- **Nodes** — `_run`, `_step [h] <key> [--attempt N] [--iteration N]`,
  `_child [h] --run-id R` (a named child run, Go's `Child`), `_dataset <id>`,
  `_job --namespace --name --version` (datasets and jobs are lazy; they emit once
  on first reference)
- **Explicit start** — `_start [h]`, which forces the lazy `started` of §5.2 to be
  emitted now. Needed only when a node must be visible in the read model before it
  opens a child or terminalizes (a long-running step staging context for minutes).
- **Terminals** — `_complete`, `_fail <err>`, `_skip`, `_cancel`, `_timeout`,
  `_end`, `_waiting`
- **Setters** — `_labels k=v…`, `_facet <ns> <json>`, `_schema`,
  `_actor <jwt | --kind --id>`, `_timing`, `_external_links`, `_affordances`,
  `_explain --title`, `_progress --current --target`, `_engine_status`, `_dropped`,
  `_error`; run+job `_plan`; step-only `_decision`, `_retry`, `_signal`
- **Edges** — `_triggered_by`, `_retry_of`, `_continues`, `_correlates`,
  `_instance_of`, `_compensates`, `_produces`, `_consumes`, `_link`
- **Refs/keys** — `_run_ref`, `_step_ref`, `_dataset_ref`, `_job_ref`,
  `_key part…`, `_occurrence`
- **Propagation** — `_inject`, `_extract`

### 8.1 The six io builders

They remain the only path to `tracing.input`/`tracing.output`. The handle-detection
rule gives us JS's handle-method/standalone duality with one function each:

```sh
np_trace_output_pointer "$build" image "$ref" --size-bytes "$n"   # records on the node
desc=$(np_trace_output_pointer image "$ref" --size-bytes "$n")     # returns a descriptor
np_trace_produces "$build" "image:$digest" "$desc"                 # binds the edge
```

### 8.2 Runtime instead of compile-time enforcement

Two checks JS/Go make at compile time become runtime checks (drop + log; visible
under `NP_TRACE_STRICT=1`):

- step-only setters (`_decision`, `_retry`, `_signal`) called on a run
- `_produces` handed an input descriptor, or `_consumes` an output descriptor

### 8.3 Config divergence

JS and Go both forbid reading environment variables. That invariant exists because
an ambient `NULLPLATFORM_API_KEY` once collided with an explicitly-supplied
`getToken`.

In CI, environment _is_ the configuration channel, so this SDK reads env — while
honoring the spirit with a guardrail: it reads **only namespaced `NP_TRACE_*`
variables**, never ambient `NULLPLATFORM_API_KEY`, and an explicit `np_trace_init`
flag always wins.

### 8.4 Propagation format

One carrier field `np-trace`, value `1|<trace_id>|<run_id>` — matching both
existing SDKs' implementations.

## 9. Worked example

```sh
. ./nptrace.sh
np_trace_init --producer "github-actions@1" --api-key "$NP_KEY"

RUN_ID=$(np_trace_key checkout-api build "$GITHUB_RUN_ID")
run=$(np_trace_run --trace-id "$RUN_ID" --run-id "$RUN_ID")
np_trace_labels entity=build action=publish "application.id=$APP_ID"
np_trace_explain --title "Build checkout-api" --what "CI build from $GITHUB_SHA"

build=$(np_trace_step "$run" compile)
make build || { np_trace_fail "$build" "compile failed"; exit 1; }
np_trace_complete "$build"

push=$(np_trace_step "$run" push)
digest=$(docker push … | awk '…')
np_trace_output_pointer "$push" image "$REGISTRY/checkout-api@$digest"
np_trace_produces "$push" "image:$digest"
np_trace_complete "$push"

np_trace_complete "$run"
# trap EXIT flushes
```

Crossing a step boundary in GitHub Actions:

```sh
echo "NP_TRACE_DIR=$NP_TRACE_DIR"     >> "$GITHUB_ENV"
echo "NP_TRACE_CURRENT=$run"          >> "$GITHUB_ENV"
```

## 10. Testing

Portability is the real risk in pure POSIX sh, so it is first-class.

**Shell matrix:** busybox `ash` (alpine), `dash` (debian `/bin/sh`), `bash` 3.2
(macOS), `bash` 5, `ksh`. `shellcheck -s sh` is the linter and is what actually
stops bash-isms (`$RANDOM`, arrays, `[[`, `local`) from creeping in.

**Harness:** a plain `test/run.sh` with assert helpers. No `bats` — the repo stays
dependency-free, matching JS's zero runtime deps and Go's empty `require` block.

| Suite                    | What it proves                                                                                                                                                                                   |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Contract conformance** | Ports the identity property cases from the API's tests and Go's `keys_test.go`. The drift safety net: an unported wire change goes red here.                                                     |
| **JSON escaping**        | Differential-fuzz the escaper against `jq -Rs` (dev-only) over quotes, backslashes, control chars, newlines, tabs, UTF-8, lone surrogates. The highest-risk hand-rolled code.                    |
| **Live wire parity**     | Emit all 12 event types against the API repo's `docker-compose` stack, assert `201`. The only real proof the hand-port is correct.                                                               |
| **Resilience**           | API refusing connections, hanging past `--max-time`, 500-looping; auth endpoint down; invalid token; spool cap exceeded. Assertion in every case: the pipeline exits 0, within the flush budget. |
| **Portability**          | The four suites above, across the shell matrix.                                                                                                                                                  |

**CI:** a GitHub Actions matrix over the shells, plus a nullplatform build
registration on green push to `main` — the same pattern as `catalog-tracing-js`
and `-go` (`ci.yml`; a library, so the build is the gate). Requires the
`NULLPLATFORM_API_KEY` secret and the repo registered as a nullplatform app.

## 11. Release

Same story as the sibling SDKs: nullplatform owns the version, cuts a release, and
creates the GitHub Release with tag `vX.Y.Z`. Distribution is the built artifact —
`curl https://…/nptrace.sh` pinned to a tag, or vendored into a consumer repo.
`main` carries the built `nptrace.sh` so vendoring needs no build step.

Treat the repo as public from day one (the standing rule for both SDK repos): no
internal hosts, credentials, service names, codenames, or platform architecture;
all example data obviously synthetic.

## 12. Open items

- **Bounded by contract, not by this spec:** batch ingest (`POST /events:batch`) is
  still deferred API-side, so flush loops single POSTs. When batch lands, flush
  gains a batch path with no surface change.
- Millisecond epoch has no POSIX-portable spelling (`date +%s%3N` is GNU-only).
  `compat.sh` owns the fallback ladder; the portability suite is what proves it.
