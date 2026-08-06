#!/usr/bin/env bats
#
# The wire vocabulary. These strings are the contract shared with the API, the
# JS SDK and the Go SDK, so they are pinned literally — a typo here is a silent
# interoperability break, not a test failure somewhere else.

load '../helper'

@test "version is semver-shaped" {
  np_sh 'printf "%s" "$NP_TRACE_VERSION"'
  assert_out_match '[0-9]*.[0-9]*.[0-9]*'
}

@test "node types" {
  np_sh 'printf "%s %s %s" "$NP_TYPE_NODE_RUN" "$NP_TYPE_NODE_DATASET" "$NP_TYPE_NODE_JOB"'
  assert_out 'node.run node.dataset node.job'
}

@test "edge types are the nine expected, all namespaced and distinct" {
  np_sh '
    edges="$NP_TYPE_EDGE_PARENT $NP_TYPE_EDGE_TRIGGERED_BY $NP_TYPE_EDGE_RETRY_OF \
$NP_TYPE_EDGE_CONTINUES $NP_TYPE_EDGE_CORRELATES $NP_TYPE_EDGE_COMPENSATES \
$NP_TYPE_EDGE_PRODUCES $NP_TYPE_EDGE_CONSUMES $NP_TYPE_EDGE_INSTANCE_OF"
    n=0
    for e in $edges; do
      case "$e" in edge.*) ;; *) echo "not an edge type: $e"; exit 1 ;; esac
      n=$((n + 1))
    done
    distinct=$(printf "%s" "$edges" | tr -s " " "\n" | sort -u | wc -l | tr -d " ")
    printf "%s %s" "$n" "$distinct"
  '
  assert_out '9 9'
}

@test "specific edge and status names" {
  np_sh 'printf "%s %s" "$NP_TYPE_EDGE_PARENT" "$NP_TYPE_EDGE_INSTANCE_OF"'
  assert_out 'edge.parent edge.instance_of'
  np_sh 'printf "%s" "$NP_STATUS_TIMED_OUT"'
  assert_out 'timed_out'
}

@test "there are 16 core facets and all are namespaced" {
  np_sh '
    n=0
    for f in $NP_CORE_FACETS; do
      case "$f" in tracing.*) ;; *) echo "unnamespaced facet: $f"; exit 1 ;; esac
      n=$((n + 1))
    done
    printf "%s" "$n"
  '
  assert_out '16'
}

@test "camelCase facet names are preserved exactly" {
  np_sh 'printf "%s %s %s" "$NP_FACET_PROGRESS" "$NP_FACET_EXTERNAL_LINKS" "$NP_FACET_ENGINE_STATUS"'
  assert_out 'tracing.progress tracing.externalLinks tracing.engineStatus'
}

@test "carrier constants match the Go and JS SDKs" {
  np_sh 'printf "%s %s %s" "$NP_CARRIER_KEY" "$NP_CARRIER_VERSION" "$NP_CARRIER_DELIMITER"'
  assert_out 'np-trace 1 |'
}

@test "reserved facet prefix" {
  np_sh 'printf "%s" "$NP_RESERVED_FACET_PREFIX"'
  assert_out 'tracing.'
}

@test "terminal statuses are classified correctly" {
  local s
  for s in completed failed cancelled timed_out skipped; do
    np_sh "np__is_terminal_status $s"
    assert_ok || { echo "$s should be terminal" >&2; return 1; }
  done
  for s in started waiting banana; do
    np_sh "np__is_terminal_status $s"
    assert_nok || { echo "$s should not be terminal" >&2; return 1; }
  done
}
