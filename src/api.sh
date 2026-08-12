# api.sh — the public producer surface. Every function here returns 0, always:
# tracing must never fail the caller.
#
# Every node-scoped function takes an OPTIONAL leading handle. This is one
# function with a defaulted argument, not two ways to say the same thing: when
# the first argument is not a handle it falls back to the innermost open node.

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

# ---------------------------------------------------------------------------
# Emission
# ---------------------------------------------------------------------------

# Emit the node event for a handle at the given status, carrying whatever
# context is currently staged.
np__emit_node() {
  _emit_node_h=$1
  _emit_node_status=$2
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0

  _emit_node_labels=$(np__node_get "$_emit_node_h" labels)
  _emit_node_facets=$(np__node_get "$_emit_node_h" facets)
  _emit_node_key=$(np__node_get "$_emit_node_h" key)
  _emit_node_schema=$(np__node_get "$_emit_node_h" schema_url)

  if [ -n "$_emit_node_key" ]; then
    _emit_node_data=$(np__json_obj_raw \
      trace_id "$(np__json_str "$(np__node_get "$_emit_node_h" trace_id)")" \
      run_id "$(np__json_str "$(np__node_get "$_emit_node_h" run_id)")" \
      key "$(np__json_str "$_emit_node_key")" \
      attempt "$(np__node_get "$_emit_node_h" attempt)" \
      iteration "$(np__node_get "$_emit_node_h" iteration)" \
      status "$(np__json_str "$_emit_node_status")" \
      labels "$_emit_node_labels" \
      facets "$_emit_node_facets" \
      schema_url "$(if [ -n "$_emit_node_schema" ]; then np__json_str "$_emit_node_schema"; fi)")
  else
    _emit_node_data=$(np__json_obj_raw \
      trace_id "$(np__json_str "$(np__node_get "$_emit_node_h" trace_id)")" \
      run_id "$(np__json_str "$(np__node_get "$_emit_node_h" run_id)")" \
      status "$(np__json_str "$_emit_node_status")" \
      labels "$_emit_node_labels" \
      facets "$_emit_node_facets" \
      schema_url "$(if [ -n "$_emit_node_schema" ]; then np__json_str "$_emit_node_schema"; fi)")
  fi

  np__spool "$NP_TYPE_NODE_RUN" "$(np__node_get "$_emit_node_h" nrn)" "$_emit_node_data" >/dev/null
  return 0
}

# A run ref for a handle — the self-describing address used on edge endpoints.
np__ref_of() {
  np__json_obj \
    type run \
    trace_id "$(np__node_get "$1" trace_id)" \
    run_id "$(np__node_get "$1" run_id)"
}

np__emit_parent_edge() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _emit_parent_edge_data=$(np__json_obj_raw from "$(np__ref_of "$1")" to "$(np__ref_of "$2")")
  np__spool "$NP_TYPE_EDGE_PARENT" "$(np__node_get "$1" nrn)" "$_emit_parent_edge_data" >/dev/null
  return 0
}

# Force the lazy `started`. Idempotent.
#
# Shell has no microtask, so `started` is emitted at the first event that must
# follow it — a terminal, a child open, an explicit call, or flush. Context
# staged before that lands on `started`; context staged after lands on the
# terminal. Same observable semantics as the JS and Go SDKs, without a timer.
np_trace_start() {
  _start_h=$(np__resolve_handle "${1:-}")
  np__is_handle "$_start_h" || return 0
  if [ "$(np__node_get "$_start_h" started)" = '1' ]; then
    return 0
  fi
  np__node_set "$_start_h" started 1
  np__emit_node "$_start_h" "$NP_STATUS_STARTED"
  return 0
}

# ---------------------------------------------------------------------------
# Nodes
# ---------------------------------------------------------------------------

np_trace_run() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _run_trace=''
  _run_run=''
  _run_nrn="${NP_TRACE_NRN:-}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --trace-id) _run_trace=${2:-}; shift 2 ;;
      --run-id) _run_run=${2:-}; shift 2 ;;
      --nrn) _run_nrn=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  # A lone root run's trace_id defaults to its run_id, and vice versa.
  [ -n "$_run_trace" ] || _run_trace=$_run_run
  [ -n "$_run_run" ] || _run_run=$_run_trace

  if ! _run_why=$(np__trace_id_violation "$_run_trace"); then
    np__drop 'run' "trace_id $_run_why"
    return 0
  fi
  if ! _run_why=$(np__named_id_violation "$_run_run"); then
    np__drop 'run' "run_id $_run_why"
    return 0
  fi

  _run_h=$(np__handle_new)
  np__node_set "$_run_h" kind run
  np__node_set "$_run_h" trace_id "$_run_trace"
  np__node_set "$_run_h" run_id "$_run_run"
  np__node_set "$_run_h" nrn "$_run_nrn"
  np__node_set "$_run_h" auto_started_at "$(np__iso8601)"
  np__node_set "$_run_h" started 0
  np__node_set "$_run_h" closed 0
  np__ambient_set "$_run_h"
  printf '%s' "$_run_h"
  return 0
}

# np_trace_step [handle] <key> [--attempt N] [--iteration N]
np_trace_step() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _step_parent=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  _step_key=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  _step_attempt=0
  _step_iteration=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --attempt) _step_attempt=${2:-0}; shift 2 ;;
      --iteration) _step_iteration=${2:-0}; shift 2 ;;
      *) shift ;;
    esac
  done

  if ! np__is_handle "$_step_parent"; then
    np__drop 'step' 'no parent node in scope'
    return 0
  fi
  if ! _step_why=$(np__key_violation "$_step_key"); then
    np__drop 'step' "key $_step_why"
    return 0
  fi
  case "$_step_attempt$_step_iteration" in
    '' | *[!0-9]*) np__drop 'step' 'attempt and iteration must be integers'; return 0 ;;
  esac

  # Opening a child forces the parent's started: a parent edge must not point
  # at a node the read model has never seen.
  np_trace_start "$_step_parent"

  _step_id=$(np__derive_child_id "$(np__node_get "$_step_parent" run_id)" \
                               "$_step_key" "$_step_attempt" "$_step_iteration")

  _step_h=$(np__handle_new)
  np__node_set "$_step_h" kind step
  np__node_set "$_step_h" trace_id "$(np__node_get "$_step_parent" trace_id)"
  np__node_set "$_step_h" run_id "$_step_id"
  np__node_set "$_step_h" nrn "$(np__node_get "$_step_parent" nrn)"
  np__node_set "$_step_h" key "$_step_key"
  np__node_set "$_step_h" attempt "$_step_attempt"
  np__node_set "$_step_h" iteration "$_step_iteration"
  np__node_set "$_step_h" parent "$_step_parent"
  np__node_set "$_step_h" auto_started_at "$(np__iso8601)"
  np__node_set "$_step_h" started 0
  np__node_set "$_step_h" closed 0

  np_trace_start "$_step_h"
  np__emit_parent_edge "$_step_parent" "$_step_h"
  np__ambient_set "$_step_h"
  printf '%s' "$_step_h"
  return 0
}

# A named child run — a new scope under the same trace.
np_trace_child() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _child_parent=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  _child_run=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-id) _child_run=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if ! np__is_handle "$_child_parent"; then
    np__drop 'child' 'no parent node in scope'
    return 0
  fi
  if ! _child_why=$(np__named_id_violation "$_child_run"); then
    np__drop 'child' "run_id $_child_why"
    return 0
  fi
  np_trace_start "$_child_parent"
  _child_h=$(np_trace_run --trace-id "$(np__node_get "$_child_parent" trace_id)" \
                       --run-id "$_child_run" \
                       --nrn "$(np__node_get "$_child_parent" nrn)")
  np__is_handle "$_child_h" || return 0
  np__node_set "$_child_h" parent "$_child_parent"
  np_trace_start "$_child_h"
  np__emit_parent_edge "$_child_parent" "$_child_h"
  np__ambient_set "$_child_h"
  printf '%s' "$_child_h"
  return 0
}

# ---------------------------------------------------------------------------
# Staging context
# ---------------------------------------------------------------------------

# Merge a pre-formed `"key":value` fragment into the node's staged labels.
np__stage_label() {
  _stage_label_cur=$(np__node_get "$1" labels)
  if [ -z "$_stage_label_cur" ] || [ "$_stage_label_cur" = '{}' ]; then
    np__node_set "$1" labels "{$2}"
  else
    np__node_set "$1" labels "${_stage_label_cur%\}},$2}"
  fi
  return 0
}

np__stage_facet() {
  _stage_facet_cur=$(np__node_get "$1" facets)
  _stage_facet_entry="$(np__json_str "$2"):$3"
  if [ -z "$_stage_facet_cur" ] || [ "$_stage_facet_cur" = '{}' ]; then
    np__node_set "$1" facets "{$_stage_facet_entry}"
  else
    # Last write wins per namespace: drop any prior entry for this facet.
    np__node_set "$1" facets "${_stage_facet_cur%\}},$_stage_facet_entry}"
  fi
  return 0
}

# Staged context normally rides the node's NEXT lifecycle emit. A FOREIGN
# (adopted) node never has one here — its owner closes it in another process —
# so anything staged on it would die in local state. Re-emit `started` with the
# full current bag instead (additive, the same shape the JS SDK's
# late-enrichment flush produces): the fold keeps the node's real outcome (the
# owner's terminal is later by time) and gains the facts this process observed.
np__flush_foreign() {
  [ "$(np__node_get "$1" foreign)" = '1' ] || return 0
  np__emit_node "$1" "$NP_STATUS_STARTED"
  return 0
}

# np_trace_labels [handle] key=value ...
np_trace_labels() {
  _labels_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_labels_h" || return 0
  for _labels_pair in "$@"; do
    case "$_labels_pair" in
      *=*) ;;
      *) continue ;;
    esac
    _labels_k=${_labels_pair%%=*}
    _labels_v=${_labels_pair#*=}
    # An absent optional is omitted, never recorded as the string "null".
    if [ -n "$_labels_k" ] && [ -n "$_labels_v" ]; then
      np__stage_label "$_labels_h" "$(np__json_str "$_labels_k"):$(np__json_str "$_labels_v")"
    fi
  done
  np__flush_foreign "$_labels_h"
  return 0
}

# np_trace_facet [handle] <namespace> <json-body>  — your own namespace.
np_trace_facet() {
  _facet_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_facet_h" || return 0
  if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    return 0
  fi
  np__stage_facet "$_facet_h" "$1" "$2"
  np__flush_foreign "$_facet_h"
  return 0
}

np_trace_schema() {
  _schema_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_schema_h" || return 0
  np__node_set "$_schema_h" schema_url "${1:-}"
  return 0
}

np_trace_explain() {
  _explain_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_explain_h" || return 0
  _explain_title=''
  _explain_what=''
  _explain_why=''
  _explain_impact=''
  _explain_next=''
  _explain_sev=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) _explain_title=${2:-}; shift 2 ;;
      --what) _explain_what=${2:-}; shift 2 ;;
      --why) _explain_why=${2:-}; shift 2 ;;
      --impact) _explain_impact=${2:-}; shift 2 ;;
      --next) _explain_next=${2:-}; shift 2 ;;
      --severity) _explain_sev=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_explain_title" ]; then
    np__drop 'explain' 'title is required'
    return 0
  fi
  np__stage_facet "$_explain_h" "$NP_FACET_EXPLAIN" \
    "$(np__json_obj title "$_explain_title" severity "$_explain_sev" what "$_explain_what" \
        why "$_explain_why" impact "$_explain_impact" next "$_explain_next")"
  np__flush_foreign "$_explain_h"
  return 0
}

np_trace_error() {
  _error_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_error_h" || return 0
  _error_msg=''
  _error_code=''
  _error_stack=''
  _error_details=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --message) _error_msg=${2:-}; shift 2 ;;
      --code) _error_code=${2:-}; shift 2 ;;
      --stack-trace) _error_stack=${2:-}; shift 2 ;;
      # A JSON object with the diagnosis's structured evidence (counts, the
      # failing probe, ...) — the sibling SDKs' error `details`.
      --details) _error_details=${2:-}; shift 2 ;;
      *)
        if [ -z "$_error_msg" ]; then
          _error_msg=$1
        fi
        shift
        ;;
    esac
  done
  [ -n "$_error_msg" ] || return 0
  case "$_error_details" in
    '' | \{*) ;;
    *) _error_details='' ;;
  esac
  np__stage_facet "$_error_h" "$NP_FACET_ERROR" \
    "$(np__json_obj_raw \
        message "$(np__json_str "$_error_msg")" \
        code "$(if [ -n "$_error_code" ]; then np__json_str "$_error_code"; fi)" \
        stack_trace "$(if [ -n "$_error_stack" ]; then np__json_str "$_error_stack"; fi)" \
        details "$_error_details")"
  np__flush_foreign "$_error_h"
  return 0
}

np_trace_timing() {
  _timing_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_timing_h" || return 0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --started-at) np__node_set "$_timing_h" started_at "${2:-}"; shift 2 ;;
      --ended-at) np__node_set "$_timing_h" ended_at "${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  return 0
}

# Stamp the auto timing facet, letting any manual override win per field.
np__stage_timing() {
  _stage_timing_started=$(np__node_get "$1" started_at)
  _stage_timing_ended=$(np__node_get "$1" ended_at)
  [ -n "$_stage_timing_started" ] || _stage_timing_started=$(np__node_get "$1" auto_started_at)
  [ -n "$_stage_timing_ended" ] || _stage_timing_ended=$2
  np__stage_facet "$1" "$NP_FACET_TIMING" \
    "$(np__json_obj started_at "$_stage_timing_started" ended_at "$_stage_timing_ended")"
  return 0
}

# ---------------------------------------------------------------------------
# Lineage — produces/consumes edges with io pointers
# ---------------------------------------------------------------------------

# A dataset ref for an edge endpoint. The id is the CANONICAL dataset id — the
# exact string a producer and a consumer must both name for lineage to join
# them by value (an ARN, an FQDN, `<type>:<url>` for an asset) — never a
# synthesised id.
np__dataset_ref() {
  np__json_obj type dataset id "$1"
}

# Append one io descriptor to a direction's list; the facet is re-staged
# whole each time (last write wins per namespace), so the array only ever
# grows. $1 handle, $2 facet namespace, $3 descriptor store key, $4 the
# already-formed descriptor JSON.
np__append_io_descriptor() {
  _append_io_descriptor_descriptors=$(np__node_get "$1" "$3")
  if [ -n "$_append_io_descriptor_descriptors" ]; then
    _append_io_descriptor_descriptors="$_append_io_descriptor_descriptors,$4"
  else
    _append_io_descriptor_descriptors=$4
  fi
  np__node_set "$1" "$3" "$_append_io_descriptor_descriptors"
  np__stage_facet "$1" "$2" "[$_append_io_descriptor_descriptors]"
  return 0
}

# Build one io descriptor from its parsed parts, choosing the kind by which
# parts are present: a uri is a POINTER (large data referenced, not inlined),
# a source+external-id is a REF (an entity in an external catalog), a JSON
# value is INLINE (carried in the event itself). Prints the descriptor, or
# nothing (with a drop) when the parts don't form one.
# $1 verb (for drop records), $2 name, $3 inline JSON, $4 uri, $5 ref source,
# $6 ref external id, $7 ref version.
np__build_io_descriptor() {
  _build_io_descriptor_verb=$1
  _build_io_descriptor_name=$2
  _build_io_descriptor_inline=$3
  _build_io_descriptor_uri=$4
  _build_io_descriptor_ref_source=$5
  _build_io_descriptor_ref_id=$6
  _build_io_descriptor_ref_version=$7
  if [ -z "$_build_io_descriptor_name" ]; then
    np__drop "$_build_io_descriptor_verb" 'a descriptor name is required'
    return 1
  fi
  if [ -n "$_build_io_descriptor_uri" ]; then
    np__json_obj kind pointer name "$_build_io_descriptor_name" uri "$_build_io_descriptor_uri"
    return 0
  fi
  if [ -n "$_build_io_descriptor_ref_source" ] && [ -n "$_build_io_descriptor_ref_id" ]; then
    np__json_obj kind ref name "$_build_io_descriptor_name" source "$_build_io_descriptor_ref_source" \
      external_id "$_build_io_descriptor_ref_id" version "$_build_io_descriptor_ref_version"
    return 0
  fi
  if [ -n "$_build_io_descriptor_inline" ]; then
    case "$_build_io_descriptor_inline" in
      \{* | \[* | \"* | [0-9-]* | true | false | null)
        np__json_obj_raw kind '"inline"' name "$(np__json_str "$_build_io_descriptor_name")" value "$_build_io_descriptor_inline"
        return 0
        ;;
    esac
    np__drop "$_build_io_descriptor_verb" 'value must be JSON'
    return 1
  fi
  np__drop "$_build_io_descriptor_verb" 'a JSON value, --uri, or --source + --external-id is required'
  return 1
}

# The shared body of np_trace_output / np_trace_input.
# $1 direction (out|in), $2 verb, then the caller's argv:
#   [handle] <name> [<json-value>] [--uri U] [--source S --external-id E [--version V]]
np__declare_io() {
  _declare_io_direction=$1
  _declare_io_verb=$2
  shift 2
  _declare_io_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_declare_io_handle" || { np__drop "$_declare_io_verb" 'no node in scope'; return 0; }
  _declare_io_name=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  _declare_io_inline=''
  _declare_io_uri=''
  _declare_io_ref_source=''
  _declare_io_ref_id=''
  _declare_io_ref_version=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --uri) _declare_io_uri=${2:-}; shift 2 ;;
      --source) _declare_io_ref_source=${2:-}; shift 2 ;;
      --external-id) _declare_io_ref_id=${2:-}; shift 2 ;;
      --version) _declare_io_ref_version=${2:-}; shift 2 ;;
      *)
        if [ -z "$_declare_io_inline" ]; then
          _declare_io_inline=$1
        fi
        shift
        ;;
    esac
  done
  _declare_io_descriptor=$(np__build_io_descriptor "$_declare_io_verb" "$_declare_io_name" "$_declare_io_inline" \
    "$_declare_io_uri" "$_declare_io_ref_source" "$_declare_io_ref_id" "$_declare_io_ref_version") || return 0
  if [ "$_declare_io_direction" = 'out' ]; then
    np__append_io_descriptor "$_declare_io_handle" "$NP_FACET_OUTPUT" io_output "$_declare_io_descriptor"
  else
    np__append_io_descriptor "$_declare_io_handle" "$NP_FACET_INPUT" io_input "$_declare_io_descriptor"
  fi
  np__flush_foreign "$_declare_io_handle"
  return 0
}

# np_trace_output [handle] <name> [<json-value>] [--uri U] [--source S --external-id E [--version V]]
#
# Record what this node PRODUCED: an inline value carried in the event
# (`np_trace_output instances '{"healthy":2}'`), a pointer to large data
# (`--uri`), or a ref to an external catalog entity (`--source`/`--external-id`).
# For an artifact that should ALSO join the lineage graph, prefer
# np_trace_produces (descriptor + edge in one call).
np_trace_output() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  np__declare_io out output "$@"
  return 0
}

# np_trace_input [handle] <name> [<json-value>] [--uri U] [--source S --external-id E [--version V]]
#
# Record what this node CONSUMED; see np_trace_output.
np_trace_input() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  np__declare_io in input "$@"
  return 0
}

# np__emit_io_edge <handle> <direction> <dataset-id> [descriptor-json]
#
# Emit one lineage edge. The direction decides everything else: `out` is
# edge.produces + tracing.output, `in` is edge.consumes + tracing.input.
#
# With a descriptor the io is declared ONCE: it accumulates into the node's
# io facet AND becomes the edge's tracing.binding — the same single-source
# rule as the sibling SDKs. Without one, the edge records lineage only.
#
# On a FOREIGN (adopted) node this is an observed fact, exactly like
# np_trace_error: the edge is ours to say, and the staged io facet reaches the
# wire through the foreign re-emit.
np__emit_io_edge() {
  _emit_io_edge_handle=$1
  _emit_io_edge_direction=$2
  _emit_io_edge_dataset_id=$3

  if [ "$_emit_io_edge_direction" = 'out' ]; then
    _emit_io_edge_edge_type=$NP_TYPE_EDGE_PRODUCES
    _emit_io_edge_facet_namespace=$NP_FACET_OUTPUT
    _emit_io_edge_descriptor_store=io_output
  else
    _emit_io_edge_edge_type=$NP_TYPE_EDGE_CONSUMES
    _emit_io_edge_facet_namespace=$NP_FACET_INPUT
    _emit_io_edge_descriptor_store=io_input
  fi

  _emit_io_edge_binding=$4

  if [ -n "$_emit_io_edge_binding" ]; then
    np__append_io_descriptor "$_emit_io_edge_handle" "$_emit_io_edge_facet_namespace" "$_emit_io_edge_descriptor_store" "$_emit_io_edge_binding"
  fi

  # An edge must not point FROM a node the read model has never seen.
  np_trace_start "$_emit_io_edge_handle"

  if [ -n "$_emit_io_edge_binding" ]; then
    _emit_io_edge_edge_data=$(np__json_obj_raw \
      from "$(np__ref_of "$_emit_io_edge_handle")" \
      to "$(np__dataset_ref "$_emit_io_edge_dataset_id")" \
      facets "{$(np__json_str "$NP_FACET_BINDING"):$_emit_io_edge_binding}")
  else
    _emit_io_edge_edge_data=$(np__json_obj_raw \
      from "$(np__ref_of "$_emit_io_edge_handle")" \
      to "$(np__dataset_ref "$_emit_io_edge_dataset_id")")
  fi
  np__spool "$_emit_io_edge_edge_type" "$(np__node_get "$_emit_io_edge_handle" nrn)" "$_emit_io_edge_edge_data" >/dev/null
  np__flush_foreign "$_emit_io_edge_handle"
  return 0
}

# The shared argv handling of np_trace_produces / np_trace_consumes:
# resolve the optional leading handle, take the dataset id, parse the
# pointer flags, and hand off to np__emit_io_edge.
# $1 direction (out|in), $2 verb name for drop records, then the caller's argv.
np__declare_lineage() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _declare_lineage_direction=$1
  _declare_lineage_verb=$2
  shift 2

  _declare_lineage_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_declare_lineage_handle" || { np__drop "$_declare_lineage_verb" 'no node in scope'; return 0; }

  _declare_lineage_dataset_id=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  if [ -z "$_declare_lineage_dataset_id" ]; then
    np__drop "$_declare_lineage_verb" 'dataset id is required'
    return 0
  fi

  _declare_lineage_name=''
  _declare_lineage_inline=''
  _declare_lineage_uri=''
  _declare_lineage_ref_source=''
  _declare_lineage_ref_id=''
  _declare_lineage_ref_version=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) _declare_lineage_name=${2:-}; shift 2 ;;
      --uri) _declare_lineage_uri=${2:-}; shift 2 ;;
      --value) _declare_lineage_inline=${2:-}; shift 2 ;;
      --source) _declare_lineage_ref_source=${2:-}; shift 2 ;;
      --external-id) _declare_lineage_ref_id=${2:-}; shift 2 ;;
      --version) _declare_lineage_ref_version=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done

  _declare_lineage_binding=''
  if [ -n "$_declare_lineage_name" ]; then
    _declare_lineage_binding=$(np__build_io_descriptor "$_declare_lineage_verb" "$_declare_lineage_name" "$_declare_lineage_inline" \
      "$_declare_lineage_uri" "$_declare_lineage_ref_source" "$_declare_lineage_ref_id" "$_declare_lineage_ref_version") || return 0
  fi

  np__emit_io_edge "$_declare_lineage_handle" "$_declare_lineage_direction" "$_declare_lineage_dataset_id" "$_declare_lineage_binding"
  return 0
}

# np_trace_produces [handle] <dataset-id> [--name <n> (--uri U | --value JSON | --source S --external-id E [--version V])]
#
# Declare this node WROTE the dataset. With `--name` the io is declared once
# — a pointer (`--uri`, the artifact's address), an inline value (`--value`),
# or a catalog ref (`--source`/`--external-id`) — on both the node and the
# edge's binding. Bare form records lineage only.
np_trace_produces() {
  np__declare_lineage out produces "$@"
  return 0
}

# np_trace_consumes [handle] <dataset-id> [--name <n> (--uri U | --value JSON | --source S --external-id E [--version V])]
#
# Declare this node READ the dataset; see np_trace_produces.
np_trace_consumes() {
  np__declare_lineage in consumes "$@"
  return 0
}

# ---------------------------------------------------------------------------
# Run-to-run edges — how operations relate across the graph
# ---------------------------------------------------------------------------

# Resolve an edge target: a handle from this process, or a PACKED CARRIER
# ("1|<trace_id>|<run_id>") — the natural address in shell, where the other
# end of an edge usually arrived via an env var. Prints the target's ref.
np__edge_target_ref() {
  if np__is_handle "$1"; then
    np__ref_of "$1"
    return 0
  fi
  _edge_target_ref_context=$(np_trace_extract "$1") || return 1
  _edge_target_ref_trace=${_edge_target_ref_context%% *}
  _edge_target_ref_run=${_edge_target_ref_context#* }
  np__json_obj type run trace_id "$_edge_target_ref_trace" run_id "$_edge_target_ref_run"
  return 0
}

# Emit one relationship edge from a node this process holds.
# $1 handle, $2 edge type, $3 target ref JSON, $4 verb for drop records.
np__emit_ref_edge() {
  _emit_ref_edge_from=$(np__ref_of "$1")
  if [ "$_emit_ref_edge_from" = "$3" ]; then
    np__drop "$4" 'self-edge forbidden'
    return 0
  fi
  # An edge must not point FROM a node the read model has never seen.
  np_trace_start "$1"
  _emit_ref_edge_data=$(np__json_obj_raw from "$_emit_ref_edge_from" to "$3")
  np__spool "$2" "$(np__node_get "$1" nrn)" "$_emit_ref_edge_data" >/dev/null
  np__flush_foreign "$1"
  return 0
}

# The shared argv handling of the run-to-run edge verbs.
# $1 edge type, $2 verb, then the caller's argv: [handle] <target>.
np__declare_relation() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _declare_relation_type=$1
  _declare_relation_verb=$2
  shift 2
  _declare_relation_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_declare_relation_handle" || { np__drop "$_declare_relation_verb" 'no node in scope'; return 0; }
  if [ -z "${1:-}" ]; then
    np__drop "$_declare_relation_verb" 'a target (handle or packed carrier) is required'
    return 0
  fi
  _declare_relation_target=$(np__edge_target_ref "$1") || {
    np__drop "$_declare_relation_verb" 'target is not a handle or a valid carrier'
    return 0
  }
  np__emit_ref_edge "$_declare_relation_handle" "$_declare_relation_type" "$_declare_relation_target" "$_declare_relation_verb"
  return 0
}

# np_trace_triggered_by [handle] <target>
#
# The operation that CAUSED this one — a cross-trace fact (the target is
# usually another trace's run, addressed by its packed carrier).
np_trace_triggered_by() {
  np__declare_relation "$NP_TYPE_EDGE_TRIGGERED_BY" triggered_by "$@"
  return 0
}

# np_trace_retry_of [handle] <target> — this run retries that one.
np_trace_retry_of() {
  np__declare_relation "$NP_TYPE_EDGE_RETRY_OF" retry_of "$@"
  return 0
}

# np_trace_continues [handle] <target> — this run resumes that one's work.
np_trace_continues() {
  np__declare_relation "$NP_TYPE_EDGE_CONTINUES" continues "$@"
  return 0
}

# np_trace_correlates [handle] <target> — related, with no causal claim.
np_trace_correlates() {
  np__declare_relation "$NP_TYPE_EDGE_CORRELATES" correlates "$@"
  return 0
}

# np_trace_compensates [handle] <target> — this run undoes that one's effect.
np_trace_compensates() {
  np__declare_relation "$NP_TYPE_EDGE_COMPENSATES" compensates "$@"
  return 0
}

# np_trace_link [handle] <edge-type> <target>
#
# Escape hatch over the named verbs — emit any known edge type. Prefer the
# named functions when one fits.
np_trace_link() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _link_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_link_handle" || { np__drop 'link' 'no node in scope'; return 0; }
  _link_type=${1:-}
  case "$_link_type" in
    "$NP_TYPE_EDGE_TRIGGERED_BY" | "$NP_TYPE_EDGE_RETRY_OF" | "$NP_TYPE_EDGE_CONTINUES" \
    | "$NP_TYPE_EDGE_CORRELATES" | "$NP_TYPE_EDGE_COMPENSATES" | "$NP_TYPE_EDGE_PARENT") ;;
    *) np__drop 'link' "unknown edge type '${_link_type}'"; return 0 ;;
  esac
  if [ -z "${2:-}" ]; then
    np__drop 'link' 'a target (handle or packed carrier) is required'
    return 0
  fi
  _link_target=$(np__edge_target_ref "$2") || {
    np__drop 'link' 'target is not a handle or a valid carrier'
    return 0
  }
  np__emit_ref_edge "$_link_handle" "$_link_type" "$_link_target" link
  return 0
}

# np_trace_instance_of [handle] <namespace> <name> <version> [--nrn N]
#
# This run instantiates a reusable JOB definition — the read model resolves
# the run's plan from the definition. Emit the definition itself with
# np_trace_job.
np_trace_instance_of() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _instance_of_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_instance_of_handle" || { np__drop 'instance_of' 'no node in scope'; return 0; }
  _instance_of_namespace=${1:-}
  _instance_of_name=${2:-}
  _instance_of_version=${3:-}
  if [ "$#" -ge 3 ]; then
    shift 3
  fi
  _instance_of_nrn=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --nrn) _instance_of_nrn=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_instance_of_namespace" ] || [ -z "$_instance_of_name" ] || [ -z "$_instance_of_version" ]; then
    np__drop 'instance_of' 'namespace, name and version are required'
    return 0
  fi
  _instance_of_target=$(np__json_obj type job namespace "$_instance_of_namespace" \
    name "$_instance_of_name" version "$_instance_of_version" nrn "$_instance_of_nrn")
  np__emit_ref_edge "$_instance_of_handle" "$NP_TYPE_EDGE_INSTANCE_OF" "$_instance_of_target" instance_of
  return 0
}

# ---------------------------------------------------------------------------
# Definition nodes — identities, not executions
# ---------------------------------------------------------------------------

# np_trace_dataset <id> [--nrn N]
#
# Emit a dataset node — an identity a lineage edge can point at. The id is
# the CANONICAL address (see np_trace_produces); edges to an unemitted
# dataset still resolve, so this is only needed to carry the node itself.
np_trace_dataset() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _dataset_id=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  _dataset_nrn=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --nrn) _dataset_nrn=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_dataset_id" ]; then
    np__drop 'dataset' 'an id is required'
    return 0
  fi
  np__spool "$NP_TYPE_NODE_DATASET" "$_dataset_nrn" "$(np__json_obj id "$_dataset_id")" >/dev/null
  return 0
}

# np_trace_job <namespace> <name> <version> [--nrn N] [--plan JSON]
#
# Emit a job definition node — the reusable spec runs link instance_of, with
# its expected step plan (previewable before any run exists).
np_trace_job() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _job_namespace=${1:-}
  _job_name=${2:-}
  _job_version=${3:-}
  if [ "$#" -ge 3 ]; then
    shift 3
  fi
  _job_nrn=''
  _job_plan=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --nrn) _job_nrn=${2:-}; shift 2 ;;
      --plan) _job_plan=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_job_namespace" ] || [ -z "$_job_name" ] || [ -z "$_job_version" ]; then
    np__drop 'job' 'namespace, name and version are required'
    return 0
  fi
  case "$_job_plan" in
    '' | \[*) ;;
    *) np__drop 'job' 'the plan must be a JSON array of steps'; return 0 ;;
  esac
  if [ -n "$_job_plan" ]; then
    _job_data=$(np__json_obj_raw \
      namespace "$(np__json_str "$_job_namespace")" \
      name "$(np__json_str "$_job_name")" \
      version "$(np__json_str "$_job_version")" \
      facets "{$(np__json_str "$NP_FACET_PLAN"):$_job_plan}")
  else
    _job_data=$(np__json_obj namespace "$_job_namespace" name "$_job_name" version "$_job_version")
  fi
  np__spool "$NP_TYPE_NODE_JOB" "$_job_nrn" "$_job_data" >/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# The remaining core-facet setters
# ---------------------------------------------------------------------------

# np_trace_actor [handle] <user|service> <id> [--source S]
#
# WHO acted. The sibling SDKs also accept a bearer JWT and decode it; that
# sugar needs base64, which this SDK's runtime toolset excludes — pass the
# identity explicitly (the np CLI stamps the actor on workflow runs already).
np_trace_actor() {
  _actor_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_actor_handle" || return 0
  _actor_kind=${1:-}
  _actor_id=${2:-}
  if [ "$#" -ge 2 ]; then
    shift 2
  fi
  _actor_source=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) _actor_source=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$_actor_kind" in
    user | service) ;;
    *) np__drop 'actor' "kind must be user or service, got '${_actor_kind}'"; return 0 ;;
  esac
  if [ -z "$_actor_id" ]; then
    np__drop 'actor' 'an id is required'
    return 0
  fi
  np__stage_facet "$_actor_handle" "$NP_FACET_ACTOR" \
    "$(np__json_obj kind "$_actor_kind" id "$_actor_id" source "$_actor_source")"
  np__flush_foreign "$_actor_handle"
  return 0
}

# np_trace_decision [handle] <chosen[,chosen...]> [--available a,b,c] [--expression E]
#
# The branch(es) this node chose, with the option set and the human-readable
# expression when known.
np_trace_decision() {
  _decision_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_decision_handle" || return 0
  _decision_chosen=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  _decision_available=''
  _decision_expression=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --available) _decision_available=${2:-}; shift 2 ;;
      --expression) _decision_expression=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_decision_chosen" ]; then
    np__drop 'decision' 'at least one chosen branch is required'
    return 0
  fi
  np__stage_facet "$_decision_handle" "$NP_FACET_DECISION" \
    "$(np__json_obj_raw \
        chosen "$(np__json_str_array_csv "$_decision_chosen")" \
        available "$(if [ -n "$_decision_available" ]; then np__json_str_array_csv "$_decision_available"; fi)" \
        expression "$(if [ -n "$_decision_expression" ]; then np__json_str "$_decision_expression"; fi)")"
  np__flush_foreign "$_decision_handle"
  return 0
}

# np_trace_retry [handle] <attempt> [--next-attempt N] [--delay-ms MS]
np_trace_retry() {
  _retry_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_retry_handle" || return 0
  _retry_attempt=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  _retry_next=''
  _retry_delay=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --next-attempt) _retry_next=${2:-}; shift 2 ;;
      --delay-ms) _retry_delay=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$_retry_attempt$_retry_next$_retry_delay" in
    '' | *[!0-9]*) np__drop 'retry' 'attempt, next-attempt and delay-ms must be non-negative integers'; return 0 ;;
  esac
  np__stage_facet "$_retry_handle" "$NP_FACET_RETRY" \
    "$(np__json_obj_raw attempt "$_retry_attempt" next_attempt "$_retry_next" delay_ms "$_retry_delay")"
  np__flush_foreign "$_retry_handle"
  return 0
}

# np_trace_signal [handle] <name> <wait|received> [--timeout-ms MS]
np_trace_signal() {
  _signal_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_signal_handle" || return 0
  _signal_name=${1:-}
  _signal_direction=${2:-}
  if [ "$#" -ge 2 ]; then
    shift 2
  fi
  _signal_timeout=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout-ms) _signal_timeout=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_signal_name" ]; then
    np__drop 'signal' 'a name is required'
    return 0
  fi
  case "$_signal_direction" in
    wait | received) ;;
    *) np__drop 'signal' "direction must be wait or received, got '${_signal_direction}'"; return 0 ;;
  esac
  case "$_signal_timeout" in
    '' | *[!0-9]*)
      if [ -n "$_signal_timeout" ]; then
        np__drop 'signal' 'timeout-ms must be a non-negative integer'
        return 0
      fi
      ;;
  esac
  np__stage_facet "$_signal_handle" "$NP_FACET_SIGNAL" \
    "$(np__json_obj_raw \
        name "$(np__json_str "$_signal_name")" \
        direction "$(np__json_str "$_signal_direction")" \
        timeout_ms "$_signal_timeout")"
  np__flush_foreign "$_signal_handle"
  return 0
}

# np_trace_external_links [handle] <rel> <uri> [--label L]
#
# One off-platform link (a CI run, a dashboard). Accumulates: call once per
# link, the facet is the array of everything declared so far.
np_trace_external_links() {
  _external_links_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_external_links_handle" || return 0
  _external_links_rel=${1:-}
  _external_links_uri=${2:-}
  if [ "$#" -ge 2 ]; then
    shift 2
  fi
  _external_links_label=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label) _external_links_label=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_external_links_rel" ] || [ -z "$_external_links_uri" ]; then
    np__drop 'external_links' 'rel and uri are required'
    return 0
  fi
  _external_links_link=$(np__json_obj rel "$_external_links_rel" uri "$_external_links_uri" label "$_external_links_label")
  _external_links_links=$(np__node_get "$_external_links_handle" external_links)
  if [ -n "$_external_links_links" ]; then
    _external_links_links="$_external_links_links,$_external_links_link"
  else
    _external_links_links=$_external_links_link
  fi
  np__node_set "$_external_links_handle" external_links "$_external_links_links"
  np__stage_facet "$_external_links_handle" "$NP_FACET_EXTERNAL_LINKS" "[$_external_links_links]"
  np__flush_foreign "$_external_links_handle"
  return 0
}

# np_trace_engine_status [handle] <engine> <state> [--raw JSON]
#
# The underlying engine's own view of this node (a k8s rollout's status, a
# queue's verdict), verbatim.
np_trace_engine_status() {
  _engine_status_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_engine_status_handle" || return 0
  _engine_status_engine=${1:-}
  _engine_status_state=${2:-}
  if [ "$#" -ge 2 ]; then
    shift 2
  fi
  _engine_status_raw=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --raw) _engine_status_raw=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_engine_status_engine" ] || [ -z "$_engine_status_state" ]; then
    np__drop 'engine_status' 'engine and state are required'
    return 0
  fi
  case "$_engine_status_raw" in
    '' | \{*) ;;
    *) np__drop 'engine_status' 'raw must be a JSON object'; return 0 ;;
  esac
  np__stage_facet "$_engine_status_handle" "$NP_FACET_ENGINE_STATUS" \
    "$(np__json_obj_raw \
        engine "$(np__json_str "$_engine_status_engine")" \
        state "$(np__json_str "$_engine_status_state")" \
        raw "$_engine_status_raw")"
  np__flush_foreign "$_engine_status_handle"
  return 0
}

# np_trace_dropped [handle] <reason>
#
# A record of data intentionally dropped — pair with np_trace_skip.
np_trace_dropped() {
  _dropped_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_dropped_handle" || return 0
  if [ -z "${1:-}" ]; then
    np__drop 'dropped' 'a reason is required'
    return 0
  fi
  np__stage_facet "$_dropped_handle" "$NP_FACET_DROPPED" "$(np__json_obj reason "$1")"
  np__flush_foreign "$_dropped_handle"
  return 0
}

# np_trace_plan [handle] <json-array-of-steps>
#
# Declare the node's EXPECTED step plan ([{"key":...,"title":...}, ...]) so
# the read model reports expected-vs-observed progress. On a reusable
# definition, prefer np_trace_job --plan.
np_trace_plan() {
  _plan_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_plan_handle" || return 0
  case "${1:-}" in
    \[*) ;;
    *) np__drop 'plan' 'the plan must be a JSON array of steps'; return 0 ;;
  esac
  np__stage_facet "$_plan_handle" "$NP_FACET_PLAN" "$1"
  np__flush_foreign "$_plan_handle"
  return 0
}

# np_trace_affordances [handle] <json>
#
# What this node OFFERS a human to do — a declared fact the UI renders as a
# control (view live logs, switch traffic). One affordance object
# ('{"kind":"deploy-log",...}') or a bare array of them; the wire form is
# always the array.
np_trace_affordances() {
  _affordances_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_affordances_handle" || return 0
  _affordances_body=${1:-}
  case "$_affordances_body" in
    \[*) ;;
    \{*) _affordances_body="[$_affordances_body]" ;;
    *) np__drop 'affordances' 'body must be a JSON object or array'; return 0 ;;
  esac
  np__stage_facet "$_affordances_handle" "$NP_FACET_AFFORDANCES" "$_affordances_body"
  np__flush_foreign "$_affordances_handle"
  return 0
}

# np_trace_progress [handle] <current> <target> [unit]
#
# How far a CONVERGING phase has advanced toward its declared target —
# instances 3 of 10, traffic 40 of 100. Non-negative integers; the optional
# unit names what is counted ("percent", "instances").
np_trace_progress() {
  _progress_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_progress_handle" || return 0
  _progress_current=${1:-}
  _progress_target=${2:-}
  _progress_unit=${3:-}
  if [ -z "$_progress_current" ] || [ -z "$_progress_target" ]; then
    np__drop 'progress' 'current and target must be non-negative integers'
    return 0
  fi
  case "$_progress_current$_progress_target" in
    *[!0-9]*) np__drop 'progress' 'current and target must be non-negative integers'; return 0 ;;
  esac
  np__stage_facet "$_progress_handle" "$NP_FACET_PROGRESS" \
    "$(np__json_obj_raw current "$_progress_current" target "$_progress_target" \
        unit "$(if [ -n "$_progress_unit" ]; then np__json_str "$_progress_unit"; fi)")"
  np__flush_foreign "$_progress_handle"
  return 0
}

# ---------------------------------------------------------------------------
# Lifecycle terminals
# ---------------------------------------------------------------------------

# The shared terminal path. $1 = handle, $2 = status.
np__terminalize() {
  np__is_handle "$1" || return 0
  if [ "$(np__node_get "$1" closed)" = '1' ]; then
    return 0
  fi
  # An adopted node belongs to the process that created it. Its owner decides
  # its outcome; emitting a terminal here would assert a state we did not
  # observe, and would race the owner's own terminal event.
  if np__is_foreign "$1"; then
    np__drop 'terminal' 'refusing to close an adopted node'
    return 0
  fi
  np_trace_start "$1"
  np__stage_timing "$1" "$(np__iso8601)"
  np__node_set "$1" closed 1
  np__emit_node "$1" "$2"
  np__ambient_clear "$1"
  # Restore the parent as ambient so a sibling opened next lands correctly.
  _terminalize_parent=$(np__node_get "$1" parent)
  if [ -n "$_terminalize_parent" ] && np__is_handle "$_terminalize_parent"; then
    if [ "$(np__node_get "$_terminalize_parent" closed)" != '1' ]; then
      np__ambient_set "$_terminalize_parent"
    fi
  fi
  return 0
}

np_trace_complete() {
  np__terminalize "$(np__resolve_handle "${1:-}")" "$NP_STATUS_COMPLETED"
  return 0
}

# An idempotent completing close.
np_trace_end() {
  np_trace_complete "$@"
  return 0
}

np_trace_fail() {
  _fail_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  # Refuse a foreign fail WHOLE, before the message stages: half-applying it
  # (error facet emitted via the foreign flush, close refused) would smear an
  # unowned outcome onto the node. Recording an observed fact on a foreign
  # node is np_trace_error, deliberately.
  if np__is_foreign "$_fail_h"; then
    np__drop 'terminal' 'refusing to close an adopted node'
    return 0
  fi
  if [ -n "${1:-}" ]; then
    np_trace_error "$_fail_h" --message "$1"
  fi
  # fail cascades to still-open child steps; complete deliberately does not —
  # auto-completing an open child would assert a success the SDK cannot vouch
  # for, and back-date its duration.
  np__cascade_fail "$_fail_h" "${1:-}"
  np__terminalize "$_fail_h" "$NP_STATUS_FAILED"
  return 0
}

# True when $1 is a descendant of $2, by walking the parent chain upward.
# Deliberately NOT recursive: POSIX sh has no `local`, so a recursive walk
# clobbers its caller's loop variables — which silently skipped intermediate
# nodes in the cascade.
np__is_descendant_of() {
  _is_descendant_of_cur=$(np__node_get "$1" parent)
  _is_descendant_of_guard=0
  while [ -n "$_is_descendant_of_cur" ] && [ "$_is_descendant_of_guard" -lt 64 ]; do
    if [ "$_is_descendant_of_cur" = "$2" ]; then
      return 0
    fi
    _is_descendant_of_cur=$(np__node_get "$_is_descendant_of_cur" parent)
    _is_descendant_of_guard=$((_is_descendant_of_guard + 1))
  done
  return 1
}

# Fail every still-open descendant. One flat pass over the registry, deepest
# first, so a node is closed before anything reads it as a parent.
np__cascade_fail() {
  _cascade_fail_depth=64
  while [ "$_cascade_fail_depth" -ge 0 ]; do
    for _cascade_fail_file in "$NP_TRACE_DIR/nodes"/*; do
      [ -f "$_cascade_fail_file" ] || continue
      _cascade_fail_h=${_cascade_fail_file##*/}
      [ "$_cascade_fail_h" = "$1" ] && continue
      [ "$(np__node_get "$_cascade_fail_h" closed)" = '1' ] && continue
      np__is_descendant_of "$_cascade_fail_h" "$1" || continue
      [ "$(np__depth_of "$_cascade_fail_h")" -eq "$_cascade_fail_depth" ] || continue
      if [ -n "$2" ]; then
        np_trace_error "$_cascade_fail_h" --message "$2"
      fi
      np__terminalize "$_cascade_fail_h" "$NP_STATUS_FAILED"
    done
    _cascade_fail_depth=$((_cascade_fail_depth - 1))
  done
  return 0
}

# How many parent links sit above this node.
np__depth_of() {
  _depth_of_cur=$(np__node_get "$1" parent)
  _depth_of_n=0
  while [ -n "$_depth_of_cur" ] && [ "$_depth_of_n" -lt 64 ]; do
    _depth_of_n=$((_depth_of_n + 1))
    _depth_of_cur=$(np__node_get "$_depth_of_cur" parent)
  done
  printf '%s' "$_depth_of_n"
}

np_trace_skip() {
  _skip_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_skip_h" || return 0
  if [ -n "${1:-}" ]; then
    np__stage_facet "$_skip_h" "$NP_FACET_DROPPED" "$(np__json_obj reason "$1")"
  fi
  np__terminalize "$_skip_h" "$NP_STATUS_SKIPPED"
  return 0
}

np_trace_cancel() {
  _cancel_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__terminalize "$_cancel_h" "$NP_STATUS_CANCELLED"
  return 0
}

np_trace_timeout() {
  np__terminalize "$(np__resolve_handle "${1:-}")" "$NP_STATUS_TIMED_OUT"
  return 0
}

# Non-terminal: the node stays open.
np_trace_waiting() {
  _waiting_h=$(np__resolve_handle "${1:-}")
  np__is_handle "$_waiting_h" || return 0
  np_trace_start "$_waiting_h"
  np__emit_node "$_waiting_h" "$NP_STATUS_WAITING"
  return 0
}
