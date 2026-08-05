#!/bin/sh
# 01 — quickstart: one run, two steps, a failure.
#
#   sh examples/01-quickstart.sh
#
# With no credentials configured the tracer still runs end to end and simply
# spools events it cannot deliver — so this is safe to run anywhere.
set -eu

. "$(dirname "$0")/../nptrace.sh"

np_trace_init --producer "example-quickstart@1" \
              --base-url "${TRACING_API_URL:-http://localhost:8080}" \
              --token "${TRACING_TOKEN:-}"

# Identity is the OPERATION, not the entity. A build is repeatable, so the id
# ends with a per-occurrence token — here the CI job id, which every observer of
# that job can derive independently.
RUN_ID=$(np_trace_key checkout-api build "${CI_JOB_ID:-$(np_trace_occurrence)}")

run=$(np_trace_run --trace-id "$RUN_ID" --run-id "$RUN_ID")
np_trace_labels entity=build action=publish "application.id=42"
np_trace_explain --title "Build checkout-api" --what "Compile, test and publish the image"

compile=$(np_trace_step "$run" compile)
echo "compiling..."
np_trace_complete "$compile"

publish=$(np_trace_step "$run" publish)
echo "publishing..."
# Pretend the registry is down. fail() cascades to any still-open child step.
np_trace_fail "$publish" "registry unreachable"

np_trace_fail "$run" "build failed at publish"

# The EXIT trap flushes; calling it explicitly just makes the example obvious.
np_trace_flush
echo "done — spooled events under $NP_TRACE_DIR"
