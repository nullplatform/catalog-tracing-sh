<h2 align="center">
    <a href="https://nullplatform.com" target="_blank">
        <img height="100" alt="nullplatform" src="https://nullplatform.com/favicon/android-chrome-192x192.png" />
    </a>
    <br>
    <br>
    nullplatform tracing — POSIX shell
    <br>
</h2>

Producer-side SDK for the nullplatform tracing API, for shell scripts and CI
pipelines. Wraps the wire contract so producers don't hand-build envelopes,
re-implement the id grammar, or get JSON escaping wrong. Pure POSIX `sh` +
`curl`: no binary, no interpreter, no package manager, nothing to install into
your CI image.

Runnable examples: [`examples/`](./examples/) — start with [`01-quickstart.sh`](./examples/01-quickstart.sh).

**Using an AI coding assistant?** [`llms.txt`](./llms.txt) is a dense, agent-optimized usage guide (rules, full surface, and an anti-patterns table covering what is not implemented yet).

> **Phase 1.** Lifecycle, labels, explain, error, timing and custom facets are
> implemented and verified end to end. Edges, io builders, propagation, the
> remaining core-facet setters and the subcommand CLI mode are Phase 2 — see
> [Not yet implemented](#not-yet-implemented).

## Quick start

```sh
. ./nptrace.sh
np_trace_init --producer "github-actions@1" --api-key "$NP_KEY"

# Identity is the OPERATION; the entity is a label.
RUN_ID=$(np_trace_key checkout-api build "$GITHUB_RUN_ID")

run=$(np_trace_run --trace-id "$RUN_ID" --run-id "$RUN_ID")
np_trace_labels entity=build action=publish "application.id=$APP_ID"
np_trace_explain --title "Build checkout-api" --what "CI build from $GITHUB_SHA"

compile=$(np_trace_step "$run" compile)
make build || { np_trace_fail "$compile" "compile failed"; np_trace_fail "$run"; exit 1; }
np_trace_complete "$compile"

np_trace_complete "$run"
# the EXIT trap flushes
```

Label values are plain strings; an empty value is **dropped** rather than
recorded as `"null"`, so a missing optional never becomes a fake label.

## Install

Vendor the single generated file, pinned to a release tag:

```sh
curl -fsSL -o nptrace.sh \
  https://raw.githubusercontent.com/nullplatform/catalog-tracing-sh/vX.Y.Z/nptrace.sh
```

Or commit `nptrace.sh` into your repo. It is self-contained — there is nothing
to build and nothing to install.

## The guarantee: a down API never breaks your build

This is structural, not defensive:

- **The hot path never touches the network.** Every emit is a local file write,
  so API downtime cannot reach your pipeline.
- **`np_trace_init` makes no network call** — the token is fetched lazily at
  first flush, so a down auth endpoint can't delay pipeline startup.
- **Flush is bounded** by `NP_TRACE_FLUSH_TIMEOUT` (10s). A dead API leaves
  events on disk and exits 0 rather than hanging your job.
- **Every function returns 0, always**, and the SDK is safe under `set -eu`.
- **If state can't be persisted at all** (read-only filesystem, full disk), the
  SDK becomes a real no-op rather than half-working — a half-initialised SDK
  whose next write fails would take down a caller running under `set -e`.

So never write `np_trace_run ... || true`, or branch on an SDK call: there is no
failure to handle, and such code implies one exists.

## Trace & run ids

`trace_id` defaults to `run_id` and vice versa — a lone root anchors its own
trace. Set `trace_id` explicitly to thread related work into one trace.

`trace_id`/`run_id` name the **operation**, never the entity. The entity's
chronicle (every run that ever touched it) is a LABEL query —
`?labels.<entity>.id=<id>`. Carrying the entity as a label rather than baking it
into the id is what lets a create be traced *before* its id exists, and a failed
insert still be found by `<parent>.id` + `action`.

Ingest folds events by `run_id`, so a **repeatable** action (an update, a
retried create, a re-triggerable workflow) that reuses a deterministic id
silently overwrites the previous run's history. Pick the form by what the
operation is:

1. **Deliberately one run** — a self-looping flow resumed across re-enqueues →
   deterministic `np_trace_key <parts>`. Entity actions rarely qualify.
2. **Repeatable, and a natural execution id exists** (a CI job id, a queue
   MessageId, a request id) → `np_trace_key <parts> "$GITHUB_RUN_ID"`. This is
   also the cross-system rendezvous: every observer derives the SAME run id, and
   a redelivery resumes the same run.
3. **Repeatable, no execution id** → mint one:
   `np_trace_key <parts> "$(np_trace_occurrence)"`. The token is a UUIDv7 — the
   same generator as every event id, time-ordered so ids sort by creation time.
   Nobody else can derive a minted id; hand it forward rather than making
   another system guess.

Keep the id's action segment the SAME WORD as `labels.action` — labels are the
query axis, the id prefix is the human-readable one.

Producer-authored ids use the identifier charset `[A-Za-z0-9_.-]+` (the `~`
delimiter and locator punctuation like `/ : @ =` are out). A value outside it is
dropped and recorded rather than emitted.

## Handles

Every open returns an opaque handle. Passing it explicitly is the real API:

```sh
run=$(np_trace_run --trace-id "$T" --run-id "$R")
step=$(np_trace_step "$run" build)
np_trace_complete "$step"
```

The handle argument is **optional** — omit it and the call targets the innermost
open node. This is one function with a defaulted argument, not a second way to
say the same thing:

```sh
np_trace_labels entity=build      # -> the innermost open node
```

Two limits worth knowing up front:

- **Ambient is undefined for parallel or backgrounded work.** Concurrent steps
  share a process id, so pass handles explicitly there.
- **Ambient does not survive a fresh CI step process.** State lives on disk, so
  the node registry does — but the pointer to "current" must be carried:

```sh
echo "NP_TRACE_DIR=$NP_TRACE_DIR"  >> "$GITHUB_ENV"
echo "NP_TRACE_CURRENT=$run"       >> "$GITHUB_ENV"
```

See [`examples/02-ci-across-steps.sh`](./examples/02-ci-across-steps.sh).

## Run & step lifecycle

```sh
run=$(np_trace_run --trace-id "$ID" --run-id "$ID")
step=$(np_trace_step "$run" compile)
np_trace_complete "$step"
np_trace_complete "$run"
```

Terminals: `np_trace_complete`, `np_trace_fail <msg>`, `np_trace_skip [reason]`,
`np_trace_cancel [reason]`, `np_trace_timeout`, `np_trace_end`. Non-terminal:
`np_trace_waiting`. A second terminal on a closed node is a no-op.

A step is a **keyed run**: its `run_id` is derived as
`parent~key@attempt.iteration`, so nesting a step under a step yields
`root~outer@0.0~inner@0.0`. You never construct these. Re-running the same slot
uses `--attempt N`, which produces a distinct derived id — there is no retry
edge for that case.

**Fail cascade.** `np_trace_fail` finalizes any still-open child steps with the
same error, so an error path collapses to one call regardless of how many steps
are open. `np_trace_complete` deliberately does **not** cascade: auto-completing
an open child would back-date its duration and assert a success the SDK can't
vouch for.

**Lazy `started`.** Nothing goes on the wire when you open a node. `started` is
emitted at the first event that must follow it — a terminal, a child open, an
explicit `np_trace_start`, or flush. So context set right after opening lands on
`started`, and an in-flight node is visible with its labels and story rather
than as a bare id. (The TypeScript and Go SDKs achieve this with a microtask;
shell has none, so the emit is deferred to the first event that needs it — same
observable semantics, no timer.)

## Attaching context

```sh
np_trace_labels [handle] key=value ...
np_trace_explain [handle] --title T [--what W] [--why W] [--impact I] [--next N] [--severity ok|warn|error]
np_trace_error   [handle] --message M [--code C] [--stack-trace S]
np_trace_timing  [handle] [--started-at T] [--ended-at T]
np_trace_facet   [handle] <namespace> <json>
np_trace_schema  [handle] <url>
```

`explain` is the human narrative the UI leads with — `--title` is required, and
`--what` should stay one clause. Structured detail belongs in io (Phase 2), not
in explain.

**Timing is automatic.** Every run and step carries a `tracing.timing` facet the
SDK fills from the operation it brackets: `started_at` when you open the node,
`ended_at` when you close it. Call `np_trace_timing` only to **override** a
field, e.g. backfilling real historical times.

`np_trace_facet` takes **your own** namespace — `tracing.*` is reserved for the
16 core facets.

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

Also read: `NP_TRACE_DIR` (state directory), `NP_TRACE_FLUSH_TIMEOUT` (10),
`NP_TRACE_MAX_RETRIES` (3), `NP_TRACE_CONNECT_TIMEOUT` (3), `NP_TRACE_MAX_TIME`
(10), `NP_TRACE_CURRENT`, `NP_TRACE_DEBUG`, `NP_TRACE_ON_DROP`.

The SDK reads **only** `NP_TRACE_*` variables — never an ambient
`NULLPLATFORM_API_KEY`, so a stray key in the environment can't collide with an
explicitly supplied credential.

### `--base-url` and `--auth-url`

Both default to the public API, so a public consumer sets neither.
`--base-url` defaults to `https://api.nullplatform.com/tracing` (the SDK posts
to `{base}/events`); the api-key exchange (`POST {auth}/token`) defaults to
`https://api.nullplatform.com`. **Override both** for a private or in-cluster
deployment.

### Tenancy scope (`nrn`)

By default the SDK sends no `nrn` and the API derives it from the caller's
token. Set it to scope a run — and all its steps and edges — to a precise
resource:

```sh
run=$(np_trace_run --trace-id "$T" --run-id "$R" --nrn "organization=1:application=42")
```

## Authentication

Provide `--api-key` (recommended) or `--token`.

With `--api-key` the SDK exchanges the key for a short-lived bearer at
`POST {auth-url}/token` and caches it on disk (mode 600) until shortly before
expiry. The exchange happens **lazily at first flush**, never at init.

The bearer never appears in `curl`'s argv **or** in a shell xtrace: it is passed
via `--config` from a mode-600 file, and every credential path suppresses
xtrace. CI scripts routinely run `set -x`, and shell options are global, so a
sourced function would otherwise print the token straight into the build log.
There is a regression canary for this in the test suite.

The SDK never verifies the JWT — the API does that.

## Delivery, retries and drops

Each emit writes one file into the spool directory, named for its event id.
Nothing touches the network until a flush, which is triggered by the `EXIT`
trap, by `np_trace_flush`, or by `np_trace_shutdown`.

| Response | Behaviour |
| --- | --- |
| `201`, or `200` duplicate | delivered; the spool file is removed |
| `400` | **never retried** — it is a contract violation. Dead-lettered under `failed/` |
| `401` / `403` | cached token discarded, event dead-lettered |
| `5xx`, network error, timeout | retried up to `NP_TRACE_MAX_RETRIES`, then dead-lettered |

Because the spool file's **name is the event id**, re-POSTing after a crash is
idempotent — the API answers `200 duplicate`. That makes `np_trace_recover`
(re-deliver a crashed job's leftovers) free.

Drops are appended to `$NP_TRACE_DIR/drops.log`, and `NP_TRACE_ON_DROP` may name
a function to call per drop. Nothing is written to stderr unless
`NP_TRACE_DEBUG=1`.

## Coverage checklist: is the entity fully observable?

Identity and a few labels make an operation *findable*. This checklist is the
Definition of Done for the **entity being observable**. A skipped row is a
silent gap — the pipeline runs and the tests pass, but the entity is only
half-traced.

| # | A reader must be able to… | Emit | Confirm with |
|---|---|---|---|
| 1 | **Chronicle** — everything that happened to entity X | `entity` + `action` + `<entity>.id` on every run (plus each `<parent>.id` up front) | `?labels.<entity>.id=<id>` returns its whole life |
| 2 | **Every** operation, not just create | one run per operation **including updates**, keyed by `action` | `?labels.<entity>.id=<id>&labels.action=<verb>` for every verb |
| 3 | **Failures**, even before an id exists | open the run at the **top**, before the work, and fail on the error path | `?labels.<parent>.id=<id>&labels.action=create&status=failed` finds it |
| 4 | **Progress** of a multi-step operation | a step per real task | `GET /runs/:id/steps` |
| 5 | **Read it** — human *and* AI | `np_trace_explain --title --what` plus labels | a run shows a title, a one-line story, and its labels |

The gap this most often catches is **untraced updates** (row 2): `create` and
`delete` are traced, but a plain `update` opens no run, so "what changed, and
did the last update fail?" is unanswerable.

Rows for lineage and plan-progress arrive with Phase 2.

## Not yet implemented

Phase 2: the remaining core-facet setters (`actor`, `external_links`,
`affordances`, `progress`, `engine_status`, `dropped`, `plan`, `decision`,
`retry`, `signal`); the nine edge functions (`triggered_by`, `retry_of`,
`continues`, `correlates`, `instance_of`, `compensates`, `produces`, `consumes`,
`link`); the six io builders; the ref constructors; `dataset` and `job` nodes;
propagation (`inject`/`extract`); and the subcommand CLI mode.

## Wire contract version

This SDK targets v1 of the nullplatform tracing wire contract. The contract is
owned by the tracing API and hand-ported here into `src/identity.sh` and
`src/wire.sh`; their tests are the drift safety net.

## Development

```sh
make lint && make test-all
```

`nptrace.sh` is a **generated file** — edit `src/*.sh` and run `./build.sh`. CI
fails if the committed artifact is stale.

Portability is the real risk in pure POSIX sh, so the suites run across shells:

```sh
NP_TEST_SHELL=/bin/dash make test-all
NP_TEST_SHELL=/bin/bash sh test/run.sh all
docker run --rm -v "$PWD:/w" -w /w busybox:latest sh test/run.sh all
```

The end-to-end suite runs against a live API when `NP_LIVE_URL` is set:

```sh
NP_LIVE_URL=http://localhost:8080 sh test/run.sh integration
```

See [`CLAUDE.md`](./CLAUDE.md) for the working agreements, including the
wire-contract sync procedure, and [`docs/DESIGN.md`](./docs/DESIGN.md) for why
the SDK is shaped the way it is — the settled decisions, the state and ambient
model, the availability guarantee, and the two deliberate divergences from the
TypeScript and Go SDKs. [`docs/PLAN-phase-1.md`](./docs/PLAN-phase-1.md) is the
delivery record for Phase 1 and scopes what Phase 2 still owes.
