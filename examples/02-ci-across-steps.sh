#!/bin/sh
# 02 — carrying a run across separate CI step processes.
#
#   sh examples/02-ci-across-steps.sh
#
# In GitHub Actions (and most CI systems) every `run:` block is a FRESH shell,
# so nothing survives in shell memory. State lives on disk instead: export
# NP_TRACE_DIR so the next process finds the registry, and NP_TRACE_CURRENT so
# the ambient handle still resolves.
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

# Share one state dir across the simulated steps.
NP_TRACE_DIR=$(mktemp -d)
export NP_TRACE_DIR

# --- CI step 1: open the run ------------------------------------------------
sh -eu -c '
  . "'"$ROOT_DIR"'/nptrace.sh"
  np_trace_init --producer "example-ci@1" --no-trap

  RUN_ID=$(np_trace_key checkout-api deploy "$(np_trace_occurrence)")
  run=$(np_trace_run --trace-id "$RUN_ID" --run-id "$RUN_ID")
  np_trace_labels entity=deployment action=deploy
  np_trace_explain --title "Deploy checkout-api"

  # In GitHub Actions this is:  echo "NP_TRACE_CURRENT=$run" >> "$GITHUB_ENV"
  printf "%s" "$run" > "$NP_TRACE_DIR/handoff"
  echo "step 1: opened run $run"
'

# --- CI step 2: a fresh process picks the run back up -----------------------
NP_TRACE_CURRENT=$(cat "$NP_TRACE_DIR/handoff")
export NP_TRACE_CURRENT

sh -eu -c '
  . "'"$ROOT_DIR"'/nptrace.sh"
  np_trace_init --producer "example-ci@1" --no-trap

  # No handle in scope — the ambient one came in through the environment.
  build=$(np_trace_step "$NP_TRACE_CURRENT" build)
  echo "step 2: opened $build under the run from step 1"
  np_trace_complete "$build"
'

# --- CI step 3: close it ----------------------------------------------------
# No flush here: this example is about state crossing processes, so it stays
# entirely offline. A real pipeline lets the EXIT trap flush (drop --no-trap),
# or calls np_trace_flush once at the end.
sh -eu -c '
  . "'"$ROOT_DIR"'/nptrace.sh"
  np_trace_init --producer "example-ci@1" --no-trap
  np_trace_complete "$NP_TRACE_CURRENT"
  echo "step 3: completed the run"
'

echo "spooled $(find "$NP_TRACE_DIR/spool" -name '*.json' | wc -l | tr -d ' ') events across three processes"
echo "distinct node ids (note the step derived under the run from step 1):"
cat "$NP_TRACE_DIR"/spool/*.json |
  tr ',' '\n' |
  sed -n 's/.*"run_id":"\([^"]*\)".*/  \1/p' |
  sort -u
rm -rf "$NP_TRACE_DIR"
