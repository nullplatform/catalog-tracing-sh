# catalog-tracing-sh — working agreements

The POSIX shell SDK (`nptrace.sh`) for the nullplatform tracing API.
Producer-only; zero runtime dependencies beyond `curl` and the POSIX toolset.

## This repo is PUBLIC

Everything here (code, comments, examples, README, `llms.txt`, commit
messages) is public:

- **No internal leaks.** Only the public `api.nullplatform.com` endpoints —
  never internal/in-cluster hosts, private URLs, credentials/tokens, internal
  service names, codenames, or internal platform architecture. All example data
  must be obviously synthetic.
- Public-quality docs and clear
  [Conventional-Commits](https://www.conventionalcommits.org/) messages.

## The wire contract lives in the tracing API (another repo)

The tracing **API** owns the wire contract. It is **hand-ported here** into
`src/identity.sh` (the id grammar) and `src/wire.sh` (types, statuses, facets,
carrier). The SDK and the API ship separately and are kept in sync **by hand** —
there is no codegen and no shared package.

**When the API's wire contract changes** (envelope shape, the `tracing.*`
facets, id/identity grammar, validation rules), sync this SDK:

1. Port the change into `src/identity.sh` / `src/wire.sh`, keeping
   `test/unit/identity.sh` and `test/unit/wire.sh` aligned.
2. Reconcile the public surface only if producers must set something new.
3. Run `make lint && make test-all` — the wire tests are the safety net; a
   missed change shows up red here.
4. Rebuild (`./build.sh`) and commit `nptrace.sh`. CI fails if the committed
   artifact is stale.

## Invariants — do not break

- **Tracing NEVER breaks the caller.** If the API or auth endpoint is down,
  slow, hanging, or erroring, the instrumented pipeline proceeds without error.
  Every public function returns 0, always. The hot path is a local file write;
  the network is touched only at flush, under a wall-clock budget. When adding
  any surface, ask first: *what does this do when the API is unreachable?* The
  answer must be "nothing the caller can observe."
- **If state cannot be persisted, degrade to a real no-op.** A half-initialised
  SDK whose next write fails takes down a caller running under `set -e` — the
  exact failure mode tracing must never cause.
- **POSIX `sh` only.** No arrays, `[[`, `local`, `$RANDOM`, `function`, `+=`, or
  process substitution. `shellcheck -s sh` must pass clean. Remember there is no
  `local`: a recursive helper clobbers its caller's variables, so prefer
  iteration and per-function variable prefixes (`_sp_`, `_en_`, …).
- **Readable names despite the prefixes.** The prefix is scoping, not an excuse
  for cryptic code: a function's variable prefix IS ITS OWN STRIPPED NAME
  (`np_trace_actor` → `_actor_kind`, `np__node_set` → `_node_set_file`) and the
  suffix is a real word — never two-letter codes on either side. Helper names
  say what they do (`np__declare_lineage`, `np__build_io_descriptor` — not
  `np__lineage_verb`). Keep helper signatures small — when several positional
  args travel together, derive them from one discriminator (see
  `np__emit_io_edge`: the direction picks the edge type, facet and store)
  instead of threading each through the call.
- **Zero runtime dependencies** beyond `curl`, `awk`, `od`, `sed`, `tr`, `cut`,
  `date`, `mv`, `mkdir`. `jq` is a DEV dependency only — never at runtime.
- **Speak the wire vocabulary** — never rename or invent concepts.
- **One function per operation, with an OPTIONAL handle argument.** The ambient
  form is an omitted argument with a default, never a second function. Do not
  add a parallel `*_begin`/`*_end` family — the sibling SDKs deliberately
  removed every redundant second spelling and so does this one.
- **The bearer token never appears in argv OR in an xtrace.** It goes to curl
  via `--config` from a mode-600 file, and every credential path is bracketed by
  `np__secret_begin`/`np__secret_end`, because CI scripts routinely `set -x` and
  shell options are global. `test/unit/http.sh` has a leak canary; keep it.
- **Config comes from `np_trace_init` flags**, defaulted from **namespaced
  `NP_TRACE_*`** environment variables only. Never read an ambient
  `NULLPLATFORM_API_KEY` — an ambient key colliding with an explicit credential
  is a real bug the sibling SDKs already hit.
- **Security.** The bearer JWT is never verified here — the API verifies it.

## Build / test

```sh
make lint && make test-all
```

`nptrace.sh` is a **generated file** — edit `src/*.sh` and rebuild.

The live end-to-end suite is skipped unless `NP_LIVE_URL` is set:

```sh
# with the tracing API running locally
NP_LIVE_URL=http://localhost:8080 bats test/integration
```

Portability is the real risk in pure POSIX sh, so run the matrix before
shipping anything:

```sh
NP_TEST_SHELL=/bin/dash make test-all
NP_TEST_SHELL=/bin/bash make test-all
make test-busybox
```

## Releases

**nullplatform owns the version.** It cuts a release from a green build and
creates the matching GitHub Release; the tag is the version. Tags are **bare —
no `v` prefix** (`0.1.0`, matching the other nullplatform SDKs and the CLI).

`NP_TRACE_VERSION` in `src/header.sh` is therefore **not** the source of truth.
`mirror-version.yml` stamps it from the release tag back into `main` after each
release. Do not bump it by hand to cut a release — that only desynchronises the
repo from the released version.

**Distribution is the repository itself** — consumers add it as a git
submodule pinned to a release tag (or vendor the one file for archive-safe
setups, e.g. `nullplatform/scopes`, whose agent image is built from a
Docker build context where submodules may be silently absent). The built
`nptrace.sh` is committed and CI-enforced current, so a checkout is always
ready to source.

Known nuance: a release tag's tree carries the PREVIOUS `NP_TRACE_VERSION`
— the platform tags a green commit first, and mirror-version.yml stamps
the new version into main afterwards. Producer attribution therefore lags
one release for consumers pinning tags; pin the mirror commit when that
matters.
