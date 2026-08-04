# nullplatform tracing — POSIX shell SDK

Emit trace events to the nullplatform tracing API from a shell script. Pure
POSIX `sh` + `curl`: no binary, no interpreter, no package manager, nothing to
install into your CI image.

```sh
. ./nptrace.sh
np_trace_init --producer "github-actions@1" --api-key "$NP_KEY"

RUN_ID=$(np_trace_key checkout-api build "$GITHUB_RUN_ID")
run=$(np_trace_run --trace-id "$RUN_ID" --run-id "$RUN_ID")
np_trace_labels entity=build action=publish "application.id=$APP_ID"
np_trace_explain --title "Build checkout-api" --what "CI build from $GITHUB_SHA"

compile=$(np_trace_step "$run" compile)
make build || { np_trace_fail "$compile" "compile failed"; exit 1; }
np_trace_complete "$compile"

np_trace_complete "$run"
# the EXIT trap flushes
```

## Why a shell SDK

CI is where builds, releases and images actually happen, and a pipeline step is
a shell script. Without this, every pipeline hand-rolls wire envelopes with
`curl` — and re-implements the id grammar, the UUIDv7 event id, and JSON
escaping, usually wrongly.

## Install

Vendor the single file, pinned to a release tag:

```sh
curl -fsSL -o nptrace.sh \
  https://raw.githubusercontent.com/nullplatform/catalog-tracing-sh/vX.Y.Z/nptrace.sh
```

Or commit `nptrace.sh` into your repo. It is a generated, self-contained file —
there is nothing to build.

## The guarantee

**A down tracing API is invisible to your build.** Emitting is a local file
write, so the network is never on your critical path. `np_trace_init` makes no
network call. Flush is bounded by a wall-clock budget, so a dead API cannot hang
your job at exit. Every function returns 0, always. If the state directory
cannot even be created, the SDK becomes a real no-op rather than half-working.

## Configuration

`np_trace_init` flags win; each falls back to a namespaced environment variable.

| Flag | Env | Meaning |
| --- | --- | --- |
| `--producer` | `NP_TRACE_PRODUCER` | The emitting system, e.g. `github-actions@1`. Required when enabled |
| `--api-key` | `NP_TRACE_API_KEY` | Exchanged for a bearer token, lazily, at first flush |
| `--token` | `NP_TRACE_TOKEN` | A pre-issued bearer, used as-is |
| `--base-url` | `NP_TRACE_BASE_URL` | Tracing API base. Defaults to the public API |
| `--auth-url` | `NP_TRACE_AUTH_URL` | Token-exchange base. Defaults to the public API |
| `--nrn` | `NP_TRACE_NRN` | Default tenancy scope; steps and edges inherit the run's |
| `--enabled 0` | `NP_TRACE_ENABLED` | `0` makes every call a no-op |
| `--no-trap` | `NP_TRACE_NO_TRAP` | Do not install the `EXIT` flush trap |

Also read: `NP_TRACE_DIR` (state directory), `NP_TRACE_FLUSH_TIMEOUT` (10s),
`NP_TRACE_MAX_RETRIES` (3), `NP_TRACE_CONNECT_TIMEOUT` (3),
`NP_TRACE_MAX_TIME` (10), `NP_TRACE_DEBUG`, `NP_TRACE_ON_DROP`,
`NP_TRACE_CURRENT` (see below).

The SDK reads **only** `NP_TRACE_*` variables. It never reads an ambient
`NULLPLATFORM_API_KEY`.

## Handles

Every open returns an opaque handle. Pass it explicitly — that is the real API:

```sh
run=$(np_trace_run --trace-id "$T" --run-id "$R")
step=$(np_trace_step "$run" build)
np_trace_complete "$step"
```

The handle argument is **optional**. Omit it and the call targets the innermost
open node:

```sh
np_trace_labels entity=build      # -> the innermost open node
```

Two limits worth knowing:

- **Ambient is undefined for parallel or backgrounded work.** Concurrent steps
  share a process id, so pass handles explicitly there.
- **Ambient does not survive a fresh CI step process.** Export it:

```sh
echo "NP_TRACE_DIR=$NP_TRACE_DIR"  >> "$GITHUB_ENV"
echo "NP_TRACE_CURRENT=$run"       >> "$GITHUB_ENV"
```

## Current surface (Phase 1)

Tracer — `np_trace_init`, `np_trace_flush`, `np_trace_shutdown`,
`np_trace_recover`
Nodes — `np_trace_run`, `np_trace_step`, `np_trace_child`, `np_trace_start`
Terminals — `np_trace_complete`, `np_trace_fail`, `np_trace_skip`,
`np_trace_cancel`, `np_trace_timeout`, `np_trace_end`, `np_trace_waiting`
Context — `np_trace_labels`, `np_trace_explain`, `np_trace_error`,
`np_trace_timing`, `np_trace_facet`, `np_trace_schema`
Identity — `np_trace_key`, `np_trace_occurrence`

`np_trace_fail` cascades to still-open child steps; `np_trace_complete`
deliberately does not — auto-completing an open child would assert a success the
SDK cannot vouch for.

**Not yet implemented (Phase 2):** the remaining setters (`actor`,
`external_links`, `affordances`, `progress`, `engine_status`, `dropped`, `plan`,
`decision`, `retry`, `signal`), the nine edge functions, the six io builders,
the ref constructors, propagation (`inject`/`extract`), and the subcommand CLI
mode.

## Development

```sh
make lint && make test-all
```

`nptrace.sh` is generated from `src/*.sh` by `./build.sh`. See
[`CLAUDE.md`](./CLAUDE.md) for the working agreements, including the
wire-contract sync procedure and the portability matrix.
