# wire.sh — contract constants, hand-ported from the tracing API's wire
# package. When the API's contract changes, this file and identity.sh are what
# must be re-ported; their tests are the safety net.

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
NP_RESERVED_LABEL_PREFIX='tracing.io/'

# The context carrier: ONE field whose value packs version, trace and run.
NP_CARRIER_KEY='np-trace'
NP_CARRIER_VERSION='1'
NP_CARRIER_DELIMITER='|'

np__is_terminal_status() {
  case "${1:-}" in
    completed | failed | cancelled | timed_out | skipped) return 0 ;;
    *) return 1 ;;
  esac
}
