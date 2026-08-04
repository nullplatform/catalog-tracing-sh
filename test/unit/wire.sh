#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

assert_eq "$NP_TYPE_NODE_RUN" 'node.run' 'node.run type'
assert_eq "$NP_TYPE_NODE_DATASET" 'node.dataset' 'node.dataset type'
assert_eq "$NP_TYPE_NODE_JOB" 'node.job' 'node.job type'
assert_eq "$NP_TYPE_EDGE_PARENT" 'edge.parent' 'edge.parent type'
assert_eq "$NP_TYPE_EDGE_INSTANCE_OF" 'edge.instance_of' 'edge.instance_of type'
assert_eq "$NP_STATUS_TIMED_OUT" 'timed_out' 'timed_out status'
assert_eq "$NP_FACET_PROGRESS" 'tracing.progress' 'progress facet'
assert_eq "$NP_FACET_EXTERNAL_LINKS" 'tracing.externalLinks' 'externalLinks facet is camelCase'
assert_eq "$NP_FACET_ENGINE_STATUS" 'tracing.engineStatus' 'engineStatus facet is camelCase'
assert_eq "$NP_CARRIER_KEY" 'np-trace' 'carrier key'
assert_eq "$NP_CARRIER_VERSION" '1' 'carrier version'
assert_eq "$NP_CARRIER_DELIMITER" '|' 'carrier delimiter'
assert_eq "$NP_RESERVED_FACET_PREFIX" 'tracing.' 'reserved facet prefix'

count=0
for f in $NP_CORE_FACETS; do
  count=$((count + 1))
  assert_match "$f" 'tracing.*' "core facet $f is namespaced"
done
assert_eq "$count" 16 'there are 16 core facets'

# The nine edge types, all present and distinct.
edges="$NP_TYPE_EDGE_PARENT $NP_TYPE_EDGE_TRIGGERED_BY $NP_TYPE_EDGE_RETRY_OF \
$NP_TYPE_EDGE_CONTINUES $NP_TYPE_EDGE_CORRELATES $NP_TYPE_EDGE_COMPENSATES \
$NP_TYPE_EDGE_PRODUCES $NP_TYPE_EDGE_CONSUMES $NP_TYPE_EDGE_INSTANCE_OF"
edge_count=0
for e in $edges; do
  edge_count=$((edge_count + 1))
  assert_match "$e" 'edge.*' "$e is an edge type"
done
assert_eq "$edge_count" 9 'there are 9 edge types'
assert_eq "$(printf '%s' "$edges" | tr -s ' ' '\n' | sort -u | wc -l | tr -d ' ')" 9 \
  'edge types are distinct'

assert_ok   'completed is terminal'      np__is_terminal_status completed
assert_ok   'failed is terminal'         np__is_terminal_status failed
assert_ok   'cancelled is terminal'      np__is_terminal_status cancelled
assert_ok   'timed_out is terminal'      np__is_terminal_status timed_out
assert_ok   'skipped is terminal'        np__is_terminal_status skipped
assert_fail 'started is not terminal'    np__is_terminal_status started
assert_fail 'waiting is not terminal'    np__is_terminal_status waiting
assert_fail 'nonsense is not terminal'   np__is_terminal_status banana

. "$ROOT/test/lib/report.sh"
