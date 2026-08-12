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
  _en_h=$1
  _en_status=$2
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0

  _en_labels=$(np__node_get "$_en_h" labels)
  _en_facets=$(np__node_get "$_en_h" facets)
  _en_key=$(np__node_get "$_en_h" key)
  _en_schema=$(np__node_get "$_en_h" schema_url)

  if [ -n "$_en_key" ]; then
    _en_data=$(np__json_obj_raw \
      trace_id "$(np__json_str "$(np__node_get "$_en_h" trace_id)")" \
      run_id "$(np__json_str "$(np__node_get "$_en_h" run_id)")" \
      key "$(np__json_str "$_en_key")" \
      attempt "$(np__node_get "$_en_h" attempt)" \
      iteration "$(np__node_get "$_en_h" iteration)" \
      status "$(np__json_str "$_en_status")" \
      labels "$_en_labels" \
      facets "$_en_facets" \
      schema_url "$(if [ -n "$_en_schema" ]; then np__json_str "$_en_schema"; fi)")
  else
    _en_data=$(np__json_obj_raw \
      trace_id "$(np__json_str "$(np__node_get "$_en_h" trace_id)")" \
      run_id "$(np__json_str "$(np__node_get "$_en_h" run_id)")" \
      status "$(np__json_str "$_en_status")" \
      labels "$_en_labels" \
      facets "$_en_facets" \
      schema_url "$(if [ -n "$_en_schema" ]; then np__json_str "$_en_schema"; fi)")
  fi

  np__spool "$NP_TYPE_NODE_RUN" "$(np__node_get "$_en_h" nrn)" "$_en_data" >/dev/null
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
  _pe_data=$(np__json_obj_raw from "$(np__ref_of "$1")" to "$(np__ref_of "$2")")
  np__spool "$NP_TYPE_EDGE_PARENT" "$(np__node_get "$1" nrn)" "$_pe_data" >/dev/null
  return 0
}

# Force the lazy `started`. Idempotent.
#
# Shell has no microtask, so `started` is emitted at the first event that must
# follow it — a terminal, a child open, an explicit call, or flush. Context
# staged before that lands on `started`; context staged after lands on the
# terminal. Same observable semantics as the JS and Go SDKs, without a timer.
np_trace_start() {
  _st_h=$(np__resolve_handle "${1:-}")
  np__is_handle "$_st_h" || return 0
  if [ "$(np__node_get "$_st_h" started)" = '1' ]; then
    return 0
  fi
  np__node_set "$_st_h" started 1
  np__emit_node "$_st_h" "$NP_STATUS_STARTED"
  return 0
}

# ---------------------------------------------------------------------------
# Nodes
# ---------------------------------------------------------------------------

np_trace_run() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _rn_trace=''
  _rn_run=''
  _rn_nrn="${NP_TRACE_NRN:-}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --trace-id) _rn_trace=${2:-}; shift 2 ;;
      --run-id) _rn_run=${2:-}; shift 2 ;;
      --nrn) _rn_nrn=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  # A lone root run's trace_id defaults to its run_id, and vice versa.
  [ -n "$_rn_trace" ] || _rn_trace=$_rn_run
  [ -n "$_rn_run" ] || _rn_run=$_rn_trace

  if ! _rn_why=$(np__trace_id_violation "$_rn_trace"); then
    np__drop 'run' "trace_id $_rn_why"
    return 0
  fi
  if ! _rn_why=$(np__named_id_violation "$_rn_run"); then
    np__drop 'run' "run_id $_rn_why"
    return 0
  fi

  _rn_h=$(np__handle_new)
  np__node_set "$_rn_h" kind run
  np__node_set "$_rn_h" trace_id "$_rn_trace"
  np__node_set "$_rn_h" run_id "$_rn_run"
  np__node_set "$_rn_h" nrn "$_rn_nrn"
  np__node_set "$_rn_h" auto_started_at "$(np__iso8601)"
  np__node_set "$_rn_h" started 0
  np__node_set "$_rn_h" closed 0
  np__ambient_set "$_rn_h"
  printf '%s' "$_rn_h"
  return 0
}

# np_trace_step [handle] <key> [--attempt N] [--iteration N]
np_trace_step() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _sp_parent=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  _sp_key=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  _sp_attempt=0
  _sp_iteration=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --attempt) _sp_attempt=${2:-0}; shift 2 ;;
      --iteration) _sp_iteration=${2:-0}; shift 2 ;;
      *) shift ;;
    esac
  done

  if ! np__is_handle "$_sp_parent"; then
    np__drop 'step' 'no parent node in scope'
    return 0
  fi
  if ! _sp_why=$(np__key_violation "$_sp_key"); then
    np__drop 'step' "key $_sp_why"
    return 0
  fi
  case "$_sp_attempt$_sp_iteration" in
    '' | *[!0-9]*) np__drop 'step' 'attempt and iteration must be integers'; return 0 ;;
  esac

  # Opening a child forces the parent's started: a parent edge must not point
  # at a node the read model has never seen.
  np_trace_start "$_sp_parent"

  _sp_id=$(np__derive_child_id "$(np__node_get "$_sp_parent" run_id)" \
                               "$_sp_key" "$_sp_attempt" "$_sp_iteration")

  _sp_h=$(np__handle_new)
  np__node_set "$_sp_h" kind step
  np__node_set "$_sp_h" trace_id "$(np__node_get "$_sp_parent" trace_id)"
  np__node_set "$_sp_h" run_id "$_sp_id"
  np__node_set "$_sp_h" nrn "$(np__node_get "$_sp_parent" nrn)"
  np__node_set "$_sp_h" key "$_sp_key"
  np__node_set "$_sp_h" attempt "$_sp_attempt"
  np__node_set "$_sp_h" iteration "$_sp_iteration"
  np__node_set "$_sp_h" parent "$_sp_parent"
  np__node_set "$_sp_h" auto_started_at "$(np__iso8601)"
  np__node_set "$_sp_h" started 0
  np__node_set "$_sp_h" closed 0

  np_trace_start "$_sp_h"
  np__emit_parent_edge "$_sp_parent" "$_sp_h"
  np__ambient_set "$_sp_h"
  printf '%s' "$_sp_h"
  return 0
}

# A named child run — a new scope under the same trace.
np_trace_child() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _ch_parent=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  _ch_run=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run-id) _ch_run=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if ! np__is_handle "$_ch_parent"; then
    np__drop 'child' 'no parent node in scope'
    return 0
  fi
  if ! _ch_why=$(np__named_id_violation "$_ch_run"); then
    np__drop 'child' "run_id $_ch_why"
    return 0
  fi
  np_trace_start "$_ch_parent"
  _ch_h=$(np_trace_run --trace-id "$(np__node_get "$_ch_parent" trace_id)" \
                       --run-id "$_ch_run" \
                       --nrn "$(np__node_get "$_ch_parent" nrn)")
  np__is_handle "$_ch_h" || return 0
  np__node_set "$_ch_h" parent "$_ch_parent"
  np_trace_start "$_ch_h"
  np__emit_parent_edge "$_ch_parent" "$_ch_h"
  np__ambient_set "$_ch_h"
  printf '%s' "$_ch_h"
  return 0
}

# ---------------------------------------------------------------------------
# Staging context
# ---------------------------------------------------------------------------

# Merge a pre-formed `"key":value` fragment into the node's staged labels.
np__stage_label() {
  _sl_cur=$(np__node_get "$1" labels)
  if [ -z "$_sl_cur" ] || [ "$_sl_cur" = '{}' ]; then
    np__node_set "$1" labels "{$2}"
  else
    np__node_set "$1" labels "${_sl_cur%\}},$2}"
  fi
  return 0
}

np__stage_facet() {
  _sf_cur=$(np__node_get "$1" facets)
  _sf_entry="$(np__json_str "$2"):$3"
  if [ -z "$_sf_cur" ] || [ "$_sf_cur" = '{}' ]; then
    np__node_set "$1" facets "{$_sf_entry}"
  else
    # Last write wins per namespace: drop any prior entry for this facet.
    np__node_set "$1" facets "${_sf_cur%\}},$_sf_entry}"
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
  _lb_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_lb_h" || return 0
  for _lb_pair in "$@"; do
    case "$_lb_pair" in
      *=*) ;;
      *) continue ;;
    esac
    _lb_k=${_lb_pair%%=*}
    _lb_v=${_lb_pair#*=}
    # An absent optional is omitted, never recorded as the string "null".
    if [ -n "$_lb_k" ] && [ -n "$_lb_v" ]; then
      np__stage_label "$_lb_h" "$(np__json_str "$_lb_k"):$(np__json_str "$_lb_v")"
    fi
  done
  np__flush_foreign "$_lb_h"
  return 0
}

# np_trace_facet [handle] <namespace> <json-body>  — your own namespace.
np_trace_facet() {
  _fc_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_fc_h" || return 0
  if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    return 0
  fi
  np__stage_facet "$_fc_h" "$1" "$2"
  np__flush_foreign "$_fc_h"
  return 0
}

np_trace_schema() {
  _sc_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_sc_h" || return 0
  np__node_set "$_sc_h" schema_url "${1:-}"
  return 0
}

np_trace_explain() {
  _ex_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_ex_h" || return 0
  _ex_title=''
  _ex_what=''
  _ex_why=''
  _ex_impact=''
  _ex_next=''
  _ex_sev=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) _ex_title=${2:-}; shift 2 ;;
      --what) _ex_what=${2:-}; shift 2 ;;
      --why) _ex_why=${2:-}; shift 2 ;;
      --impact) _ex_impact=${2:-}; shift 2 ;;
      --next) _ex_next=${2:-}; shift 2 ;;
      --severity) _ex_sev=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_ex_title" ]; then
    np__drop 'explain' 'title is required'
    return 0
  fi
  np__stage_facet "$_ex_h" "$NP_FACET_EXPLAIN" \
    "$(np__json_obj title "$_ex_title" severity "$_ex_sev" what "$_ex_what" \
        why "$_ex_why" impact "$_ex_impact" next "$_ex_next")"
  np__flush_foreign "$_ex_h"
  return 0
}

np_trace_error() {
  _er_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_er_h" || return 0
  _er_msg=''
  _er_code=''
  _er_stack=''
  _er_details=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --message) _er_msg=${2:-}; shift 2 ;;
      --code) _er_code=${2:-}; shift 2 ;;
      --stack-trace) _er_stack=${2:-}; shift 2 ;;
      # A JSON object with the diagnosis's structured evidence (counts, the
      # failing probe, ...) — the sibling SDKs' error `details`.
      --details) _er_details=${2:-}; shift 2 ;;
      *)
        if [ -z "$_er_msg" ]; then
          _er_msg=$1
        fi
        shift
        ;;
    esac
  done
  [ -n "$_er_msg" ] || return 0
  case "$_er_details" in
    '' | \{*) ;;
    *) _er_details='' ;;
  esac
  np__stage_facet "$_er_h" "$NP_FACET_ERROR" \
    "$(np__json_obj_raw \
        message "$(np__json_str "$_er_msg")" \
        code "$(if [ -n "$_er_code" ]; then np__json_str "$_er_code"; fi)" \
        stack_trace "$(if [ -n "$_er_stack" ]; then np__json_str "$_er_stack"; fi)" \
        details "$_er_details")"
  np__flush_foreign "$_er_h"
  return 0
}

np_trace_timing() {
  _tm_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_tm_h" || return 0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --started-at) np__node_set "$_tm_h" started_at "${2:-}"; shift 2 ;;
      --ended-at) np__node_set "$_tm_h" ended_at "${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  return 0
}

# Stamp the auto timing facet, letting any manual override win per field.
np__stage_timing() {
  _sg_started=$(np__node_get "$1" started_at)
  _sg_ended=$(np__node_get "$1" ended_at)
  [ -n "$_sg_started" ] || _sg_started=$(np__node_get "$1" auto_started_at)
  [ -n "$_sg_ended" ] || _sg_ended=$2
  np__stage_facet "$1" "$NP_FACET_TIMING" \
    "$(np__json_obj started_at "$_sg_started" ended_at "$_sg_ended")"
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
  _ai_descriptors=$(np__node_get "$1" "$3")
  if [ -n "$_ai_descriptors" ]; then
    _ai_descriptors="$_ai_descriptors,$4"
  else
    _ai_descriptors=$4
  fi
  np__node_set "$1" "$3" "$_ai_descriptors"
  np__stage_facet "$1" "$2" "[$_ai_descriptors]"
  return 0
}

# Build one io descriptor from its parsed parts, choosing the kind by which
# parts are present: a uri is a POINTER (large data referenced, not inlined),
# a source+external-id is a REF (an entity in an external catalog), a JSON
# value is INLINE (carried in the event itself). Prints the descriptor, or
# nothing (with a drop) when the parts don't form one.
# $1 verb (for drop records), $2 name, $3 inline JSON, $4 uri, $5 ref source,
# $6 ref external id, $7 ref version.
np__io_descriptor() {
  _dv_verb=$1
  _dv_name=$2
  _dv_inline=$3
  _dv_uri=$4
  _dv_ref_source=$5
  _dv_ref_id=$6
  _dv_ref_version=$7
  if [ -z "$_dv_name" ]; then
    np__drop "$_dv_verb" 'a descriptor name is required'
    return 1
  fi
  if [ -n "$_dv_uri" ]; then
    np__json_obj kind pointer name "$_dv_name" uri "$_dv_uri"
    return 0
  fi
  if [ -n "$_dv_ref_source" ] && [ -n "$_dv_ref_id" ]; then
    np__json_obj kind ref name "$_dv_name" source "$_dv_ref_source" \
      external_id "$_dv_ref_id" version "$_dv_ref_version"
    return 0
  fi
  if [ -n "$_dv_inline" ]; then
    case "$_dv_inline" in
      \{* | \[* | \"* | [0-9-]* | true | false | null)
        np__json_obj_raw kind '"inline"' name "$(np__json_str "$_dv_name")" value "$_dv_inline"
        return 0
        ;;
    esac
    np__drop "$_dv_verb" 'value must be JSON'
    return 1
  fi
  np__drop "$_dv_verb" 'a JSON value, --uri, or --source + --external-id is required'
  return 1
}

# The shared body of np_trace_output / np_trace_input.
# $1 direction (out|in), $2 verb, then the caller's argv:
#   [handle] <name> [<json-value>] [--uri U] [--source S --external-id E [--version V]]
np__record_io() {
  _ii_direction=$1
  _ii_verb=$2
  shift 2
  _ii_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_ii_handle" || { np__drop "$_ii_verb" 'no node in scope'; return 0; }
  _ii_name=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  _ii_inline=''
  _ii_uri=''
  _ii_ref_source=''
  _ii_ref_id=''
  _ii_ref_version=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --uri) _ii_uri=${2:-}; shift 2 ;;
      --source) _ii_ref_source=${2:-}; shift 2 ;;
      --external-id) _ii_ref_id=${2:-}; shift 2 ;;
      --version) _ii_ref_version=${2:-}; shift 2 ;;
      *)
        if [ -z "$_ii_inline" ]; then
          _ii_inline=$1
        fi
        shift
        ;;
    esac
  done
  _ii_descriptor=$(np__io_descriptor "$_ii_verb" "$_ii_name" "$_ii_inline" \
    "$_ii_uri" "$_ii_ref_source" "$_ii_ref_id" "$_ii_ref_version") || return 0
  if [ "$_ii_direction" = 'out' ]; then
    np__append_io_descriptor "$_ii_handle" "$NP_FACET_OUTPUT" io_output "$_ii_descriptor"
  else
    np__append_io_descriptor "$_ii_handle" "$NP_FACET_INPUT" io_input "$_ii_descriptor"
  fi
  np__flush_foreign "$_ii_handle"
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
  np__record_io out output "$@"
  return 0
}

# np_trace_input [handle] <name> [<json-value>] [--uri U] [--source S --external-id E [--version V]]
#
# Record what this node CONSUMED; see np_trace_output.
np_trace_input() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  np__record_io in input "$@"
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
  _io_handle=$1
  _io_direction=$2
  _io_dataset_id=$3

  if [ "$_io_direction" = 'out' ]; then
    _io_edge_type=$NP_TYPE_EDGE_PRODUCES
    _io_facet_namespace=$NP_FACET_OUTPUT
    _io_descriptor_store=io_output
  else
    _io_edge_type=$NP_TYPE_EDGE_CONSUMES
    _io_facet_namespace=$NP_FACET_INPUT
    _io_descriptor_store=io_input
  fi

  _io_binding=$4

  if [ -n "$_io_binding" ]; then
    np__append_io_descriptor "$_io_handle" "$_io_facet_namespace" "$_io_descriptor_store" "$_io_binding"
  fi

  # An edge must not point FROM a node the read model has never seen.
  np_trace_start "$_io_handle"

  if [ -n "$_io_binding" ]; then
    _io_edge_data=$(np__json_obj_raw \
      from "$(np__ref_of "$_io_handle")" \
      to "$(np__dataset_ref "$_io_dataset_id")" \
      facets "{$(np__json_str "$NP_FACET_BINDING"):$_io_binding}")
  else
    _io_edge_data=$(np__json_obj_raw \
      from "$(np__ref_of "$_io_handle")" \
      to "$(np__dataset_ref "$_io_dataset_id")")
  fi
  np__spool "$_io_edge_type" "$(np__node_get "$_io_handle" nrn)" "$_io_edge_data" >/dev/null
  np__flush_foreign "$_io_handle"
  return 0
}

# The shared argv handling of np_trace_produces / np_trace_consumes:
# resolve the optional leading handle, take the dataset id, parse the
# pointer flags, and hand off to np__emit_io_edge.
# $1 direction (out|in), $2 verb name for drop records, then the caller's argv.
np__lineage_verb() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _lv_direction=$1
  _lv_verb=$2
  shift 2

  _lv_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_lv_handle" || { np__drop "$_lv_verb" 'no node in scope'; return 0; }

  _lv_dataset_id=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  if [ -z "$_lv_dataset_id" ]; then
    np__drop "$_lv_verb" 'dataset id is required'
    return 0
  fi

  _lv_name=''
  _lv_inline=''
  _lv_uri=''
  _lv_ref_source=''
  _lv_ref_id=''
  _lv_ref_version=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) _lv_name=${2:-}; shift 2 ;;
      --uri) _lv_uri=${2:-}; shift 2 ;;
      --value) _lv_inline=${2:-}; shift 2 ;;
      --source) _lv_ref_source=${2:-}; shift 2 ;;
      --external-id) _lv_ref_id=${2:-}; shift 2 ;;
      --version) _lv_ref_version=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done

  _lv_binding=''
  if [ -n "$_lv_name" ]; then
    _lv_binding=$(np__io_descriptor "$_lv_verb" "$_lv_name" "$_lv_inline" \
      "$_lv_uri" "$_lv_ref_source" "$_lv_ref_id" "$_lv_ref_version") || return 0
  fi

  np__emit_io_edge "$_lv_handle" "$_lv_direction" "$_lv_dataset_id" "$_lv_binding"
  return 0
}

# np_trace_produces [handle] <dataset-id> [--name <n> (--uri U | --value JSON | --source S --external-id E [--version V])]
#
# Declare this node WROTE the dataset. With `--name` the io is declared once
# — a pointer (`--uri`, the artifact's address), an inline value (`--value`),
# or a catalog ref (`--source`/`--external-id`) — on both the node and the
# edge's binding. Bare form records lineage only.
np_trace_produces() {
  np__lineage_verb out produces "$@"
  return 0
}

# np_trace_consumes [handle] <dataset-id> [--name <n> (--uri U | --value JSON | --source S --external-id E [--version V])]
#
# Declare this node READ the dataset; see np_trace_produces.
np_trace_consumes() {
  np__lineage_verb in consumes "$@"
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
  _et_context=$(np_trace_extract "$1") || return 1
  _et_trace=${_et_context%% *}
  _et_run=${_et_context#* }
  np__json_obj type run trace_id "$_et_trace" run_id "$_et_run"
  return 0
}

# Emit one relationship edge from a node this process holds.
# $1 handle, $2 edge type, $3 target ref JSON, $4 verb for drop records.
np__emit_ref_edge() {
  _re_from=$(np__ref_of "$1")
  if [ "$_re_from" = "$3" ]; then
    np__drop "$4" 'self-edge forbidden'
    return 0
  fi
  # An edge must not point FROM a node the read model has never seen.
  np_trace_start "$1"
  _re_data=$(np__json_obj_raw from "$_re_from" to "$3")
  np__spool "$2" "$(np__node_get "$1" nrn)" "$_re_data" >/dev/null
  np__flush_foreign "$1"
  return 0
}

# The shared argv handling of the run-to-run edge verbs.
# $1 edge type, $2 verb, then the caller's argv: [handle] <target>.
np__relation_verb() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _rv_type=$1
  _rv_verb=$2
  shift 2
  _rv_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_rv_handle" || { np__drop "$_rv_verb" 'no node in scope'; return 0; }
  if [ -z "${1:-}" ]; then
    np__drop "$_rv_verb" 'a target (handle or packed carrier) is required'
    return 0
  fi
  _rv_target=$(np__edge_target_ref "$1") || {
    np__drop "$_rv_verb" 'target is not a handle or a valid carrier'
    return 0
  }
  np__emit_ref_edge "$_rv_handle" "$_rv_type" "$_rv_target" "$_rv_verb"
  return 0
}

# np_trace_triggered_by [handle] <target>
#
# The operation that CAUSED this one — a cross-trace fact (the target is
# usually another trace's run, addressed by its packed carrier).
np_trace_triggered_by() {
  np__relation_verb "$NP_TYPE_EDGE_TRIGGERED_BY" triggered_by "$@"
  return 0
}

# np_trace_retry_of [handle] <target> — this run retries that one.
np_trace_retry_of() {
  np__relation_verb "$NP_TYPE_EDGE_RETRY_OF" retry_of "$@"
  return 0
}

# np_trace_continues [handle] <target> — this run resumes that one's work.
np_trace_continues() {
  np__relation_verb "$NP_TYPE_EDGE_CONTINUES" continues "$@"
  return 0
}

# np_trace_correlates [handle] <target> — related, with no causal claim.
np_trace_correlates() {
  np__relation_verb "$NP_TYPE_EDGE_CORRELATES" correlates "$@"
  return 0
}

# np_trace_compensates [handle] <target> — this run undoes that one's effect.
np_trace_compensates() {
  np__relation_verb "$NP_TYPE_EDGE_COMPENSATES" compensates "$@"
  return 0
}

# np_trace_link [handle] <edge-type> <target>
#
# Escape hatch over the named verbs — emit any known edge type. Prefer the
# named functions when one fits.
np_trace_link() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _lk_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_lk_handle" || { np__drop 'link' 'no node in scope'; return 0; }
  _lk_type=${1:-}
  case "$_lk_type" in
    "$NP_TYPE_EDGE_TRIGGERED_BY" | "$NP_TYPE_EDGE_RETRY_OF" | "$NP_TYPE_EDGE_CONTINUES" \
    | "$NP_TYPE_EDGE_CORRELATES" | "$NP_TYPE_EDGE_COMPENSATES" | "$NP_TYPE_EDGE_PARENT") ;;
    *) np__drop 'link' "unknown edge type '${_lk_type}'"; return 0 ;;
  esac
  if [ -z "${2:-}" ]; then
    np__drop 'link' 'a target (handle or packed carrier) is required'
    return 0
  fi
  _lk_target=$(np__edge_target_ref "$2") || {
    np__drop 'link' 'target is not a handle or a valid carrier'
    return 0
  }
  np__emit_ref_edge "$_lk_handle" "$_lk_type" "$_lk_target" link
  return 0
}

# np_trace_instance_of [handle] <namespace> <name> <version> [--nrn N]
#
# This run instantiates a reusable JOB definition — the read model resolves
# the run's plan from the definition. Emit the definition itself with
# np_trace_job.
np_trace_instance_of() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _if_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_if_handle" || { np__drop 'instance_of' 'no node in scope'; return 0; }
  _if_namespace=${1:-}
  _if_name=${2:-}
  _if_version=${3:-}
  if [ "$#" -ge 3 ]; then
    shift 3
  fi
  _if_nrn=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --nrn) _if_nrn=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_if_namespace" ] || [ -z "$_if_name" ] || [ -z "$_if_version" ]; then
    np__drop 'instance_of' 'namespace, name and version are required'
    return 0
  fi
  _if_target=$(np__json_obj type job namespace "$_if_namespace" \
    name "$_if_name" version "$_if_version" nrn "$_if_nrn")
  np__emit_ref_edge "$_if_handle" "$NP_TYPE_EDGE_INSTANCE_OF" "$_if_target" instance_of
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
  _dn_id=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  _dn_nrn=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --nrn) _dn_nrn=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_dn_id" ]; then
    np__drop 'dataset' 'an id is required'
    return 0
  fi
  np__spool "$NP_TYPE_NODE_DATASET" "$_dn_nrn" "$(np__json_obj id "$_dn_id")" >/dev/null
  return 0
}

# np_trace_job <namespace> <name> <version> [--nrn N] [--plan JSON]
#
# Emit a job definition node — the reusable spec runs link instance_of, with
# its expected step plan (previewable before any run exists).
np_trace_job() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _jb_namespace=${1:-}
  _jb_name=${2:-}
  _jb_version=${3:-}
  if [ "$#" -ge 3 ]; then
    shift 3
  fi
  _jb_nrn=''
  _jb_plan=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --nrn) _jb_nrn=${2:-}; shift 2 ;;
      --plan) _jb_plan=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_jb_namespace" ] || [ -z "$_jb_name" ] || [ -z "$_jb_version" ]; then
    np__drop 'job' 'namespace, name and version are required'
    return 0
  fi
  case "$_jb_plan" in
    '' | \[*) ;;
    *) np__drop 'job' 'the plan must be a JSON array of steps'; return 0 ;;
  esac
  if [ -n "$_jb_plan" ]; then
    _jb_data=$(np__json_obj_raw \
      namespace "$(np__json_str "$_jb_namespace")" \
      name "$(np__json_str "$_jb_name")" \
      version "$(np__json_str "$_jb_version")" \
      facets "{$(np__json_str "$NP_FACET_PLAN"):$_jb_plan}")
  else
    _jb_data=$(np__json_obj namespace "$_jb_namespace" name "$_jb_name" version "$_jb_version")
  fi
  np__spool "$NP_TYPE_NODE_JOB" "$_jb_nrn" "$_jb_data" >/dev/null
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
  _ac_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_ac_handle" || return 0
  _ac_kind=${1:-}
  _ac_id=${2:-}
  if [ "$#" -ge 2 ]; then
    shift 2
  fi
  _ac_source=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) _ac_source=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$_ac_kind" in
    user | service) ;;
    *) np__drop 'actor' "kind must be user or service, got '${_ac_kind}'"; return 0 ;;
  esac
  if [ -z "$_ac_id" ]; then
    np__drop 'actor' 'an id is required'
    return 0
  fi
  np__stage_facet "$_ac_handle" "$NP_FACET_ACTOR" \
    "$(np__json_obj kind "$_ac_kind" id "$_ac_id" source "$_ac_source")"
  np__flush_foreign "$_ac_handle"
  return 0
}

# np_trace_decision [handle] <chosen[,chosen...]> [--available a,b,c] [--expression E]
#
# The branch(es) this node chose, with the option set and the human-readable
# expression when known.
np_trace_decision() {
  _dc_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_dc_handle" || return 0
  _dc_chosen=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  _dc_available=''
  _dc_expression=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --available) _dc_available=${2:-}; shift 2 ;;
      --expression) _dc_expression=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_dc_chosen" ]; then
    np__drop 'decision' 'at least one chosen branch is required'
    return 0
  fi
  np__stage_facet "$_dc_handle" "$NP_FACET_DECISION" \
    "$(np__json_obj_raw \
        chosen "$(np__json_str_array_csv "$_dc_chosen")" \
        available "$(if [ -n "$_dc_available" ]; then np__json_str_array_csv "$_dc_available"; fi)" \
        expression "$(if [ -n "$_dc_expression" ]; then np__json_str "$_dc_expression"; fi)")"
  np__flush_foreign "$_dc_handle"
  return 0
}

# np_trace_retry [handle] <attempt> [--next-attempt N] [--delay-ms MS]
np_trace_retry() {
  _rt_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_rt_handle" || return 0
  _rt_attempt=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  _rt_next=''
  _rt_delay=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --next-attempt) _rt_next=${2:-}; shift 2 ;;
      --delay-ms) _rt_delay=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$_rt_attempt$_rt_next$_rt_delay" in
    '' | *[!0-9]*) np__drop 'retry' 'attempt, next-attempt and delay-ms must be non-negative integers'; return 0 ;;
  esac
  np__stage_facet "$_rt_handle" "$NP_FACET_RETRY" \
    "$(np__json_obj_raw attempt "$_rt_attempt" next_attempt "$_rt_next" delay_ms "$_rt_delay")"
  np__flush_foreign "$_rt_handle"
  return 0
}

# np_trace_signal [handle] <name> <wait|received> [--timeout-ms MS]
np_trace_signal() {
  _sg_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_sg_handle" || return 0
  _sg_name=${1:-}
  _sg_direction=${2:-}
  if [ "$#" -ge 2 ]; then
    shift 2
  fi
  _sg_timeout=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout-ms) _sg_timeout=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_sg_name" ]; then
    np__drop 'signal' 'a name is required'
    return 0
  fi
  case "$_sg_direction" in
    wait | received) ;;
    *) np__drop 'signal' "direction must be wait or received, got '${_sg_direction}'"; return 0 ;;
  esac
  case "$_sg_timeout" in
    '' | *[!0-9]*)
      if [ -n "$_sg_timeout" ]; then
        np__drop 'signal' 'timeout-ms must be a non-negative integer'
        return 0
      fi
      ;;
  esac
  np__stage_facet "$_sg_handle" "$NP_FACET_SIGNAL" \
    "$(np__json_obj_raw \
        name "$(np__json_str "$_sg_name")" \
        direction "$(np__json_str "$_sg_direction")" \
        timeout_ms "$_sg_timeout")"
  np__flush_foreign "$_sg_handle"
  return 0
}

# np_trace_external_links [handle] <rel> <uri> [--label L]
#
# One off-platform link (a CI run, a dashboard). Accumulates: call once per
# link, the facet is the array of everything declared so far.
np_trace_external_links() {
  _el_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_el_handle" || return 0
  _el_rel=${1:-}
  _el_uri=${2:-}
  if [ "$#" -ge 2 ]; then
    shift 2
  fi
  _el_label=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label) _el_label=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_el_rel" ] || [ -z "$_el_uri" ]; then
    np__drop 'external_links' 'rel and uri are required'
    return 0
  fi
  _el_link=$(np__json_obj rel "$_el_rel" uri "$_el_uri" label "$_el_label")
  _el_links=$(np__node_get "$_el_handle" external_links)
  if [ -n "$_el_links" ]; then
    _el_links="$_el_links,$_el_link"
  else
    _el_links=$_el_link
  fi
  np__node_set "$_el_handle" external_links "$_el_links"
  np__stage_facet "$_el_handle" "$NP_FACET_EXTERNAL_LINKS" "[$_el_links]"
  np__flush_foreign "$_el_handle"
  return 0
}

# np_trace_engine_status [handle] <engine> <state> [--raw JSON]
#
# The underlying engine's own view of this node (a k8s rollout's status, a
# queue's verdict), verbatim.
np_trace_engine_status() {
  _es_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_es_handle" || return 0
  _es_engine=${1:-}
  _es_state=${2:-}
  if [ "$#" -ge 2 ]; then
    shift 2
  fi
  _es_raw=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --raw) _es_raw=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -z "$_es_engine" ] || [ -z "$_es_state" ]; then
    np__drop 'engine_status' 'engine and state are required'
    return 0
  fi
  case "$_es_raw" in
    '' | \{*) ;;
    *) np__drop 'engine_status' 'raw must be a JSON object'; return 0 ;;
  esac
  np__stage_facet "$_es_handle" "$NP_FACET_ENGINE_STATUS" \
    "$(np__json_obj_raw \
        engine "$(np__json_str "$_es_engine")" \
        state "$(np__json_str "$_es_state")" \
        raw "$_es_raw")"
  np__flush_foreign "$_es_handle"
  return 0
}

# np_trace_dropped [handle] <reason>
#
# A record of data intentionally dropped — pair with np_trace_skip.
np_trace_dropped() {
  _dp_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_dp_handle" || return 0
  if [ -z "${1:-}" ]; then
    np__drop 'dropped' 'a reason is required'
    return 0
  fi
  np__stage_facet "$_dp_handle" "$NP_FACET_DROPPED" "$(np__json_obj reason "$1")"
  np__flush_foreign "$_dp_handle"
  return 0
}

# np_trace_plan [handle] <json-array-of-steps>
#
# Declare the node's EXPECTED step plan ([{"key":...,"title":...}, ...]) so
# the read model reports expected-vs-observed progress. On a reusable
# definition, prefer np_trace_job --plan.
np_trace_plan() {
  _pl_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_pl_handle" || return 0
  case "${1:-}" in
    \[*) ;;
    *) np__drop 'plan' 'the plan must be a JSON array of steps'; return 0 ;;
  esac
  np__stage_facet "$_pl_handle" "$NP_FACET_PLAN" "$1"
  np__flush_foreign "$_pl_handle"
  return 0
}

# np_trace_affordances [handle] <json>
#
# What this node OFFERS a human to do — a declared fact the UI renders as a
# control (view live logs, switch traffic). One affordance object
# ('{"kind":"deploy-log",...}') or a bare array of them; the wire form is
# always the array.
np_trace_affordances() {
  _af_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_af_handle" || return 0
  _af_body=${1:-}
  case "$_af_body" in
    \[*) ;;
    \{*) _af_body="[$_af_body]" ;;
    *) np__drop 'affordances' 'body must be a JSON object or array'; return 0 ;;
  esac
  np__stage_facet "$_af_handle" "$NP_FACET_AFFORDANCES" "$_af_body"
  np__flush_foreign "$_af_handle"
  return 0
}

# np_trace_progress [handle] <current> <target> [unit]
#
# How far a CONVERGING phase has advanced toward its declared target —
# instances 3 of 10, traffic 40 of 100. Non-negative integers; the optional
# unit names what is counted ("percent", "instances").
np_trace_progress() {
  _pg_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_pg_handle" || return 0
  _pg_current=${1:-}
  _pg_target=${2:-}
  _pg_unit=${3:-}
  if [ -z "$_pg_current" ] || [ -z "$_pg_target" ]; then
    np__drop 'progress' 'current and target must be non-negative integers'
    return 0
  fi
  case "$_pg_current$_pg_target" in
    *[!0-9]*) np__drop 'progress' 'current and target must be non-negative integers'; return 0 ;;
  esac
  np__stage_facet "$_pg_handle" "$NP_FACET_PROGRESS" \
    "$(np__json_obj_raw current "$_pg_current" target "$_pg_target" \
        unit "$(if [ -n "$_pg_unit" ]; then np__json_str "$_pg_unit"; fi)")"
  np__flush_foreign "$_pg_handle"
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
  _tz_parent=$(np__node_get "$1" parent)
  if [ -n "$_tz_parent" ] && np__is_handle "$_tz_parent"; then
    if [ "$(np__node_get "$_tz_parent" closed)" != '1' ]; then
      np__ambient_set "$_tz_parent"
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
  _fa_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  # Refuse a foreign fail WHOLE, before the message stages: half-applying it
  # (error facet emitted via the foreign flush, close refused) would smear an
  # unowned outcome onto the node. Recording an observed fact on a foreign
  # node is np_trace_error, deliberately.
  if np__is_foreign "$_fa_h"; then
    np__drop 'terminal' 'refusing to close an adopted node'
    return 0
  fi
  if [ -n "${1:-}" ]; then
    np_trace_error "$_fa_h" --message "$1"
  fi
  # fail cascades to still-open child steps; complete deliberately does not —
  # auto-completing an open child would assert a success the SDK cannot vouch
  # for, and back-date its duration.
  np__cascade_fail "$_fa_h" "${1:-}"
  np__terminalize "$_fa_h" "$NP_STATUS_FAILED"
  return 0
}

# True when $1 is a descendant of $2, by walking the parent chain upward.
# Deliberately NOT recursive: POSIX sh has no `local`, so a recursive walk
# clobbers its caller's loop variables — which silently skipped intermediate
# nodes in the cascade.
np__is_descendant_of() {
  _dz_cur=$(np__node_get "$1" parent)
  _dz_guard=0
  while [ -n "$_dz_cur" ] && [ "$_dz_guard" -lt 64 ]; do
    if [ "$_dz_cur" = "$2" ]; then
      return 0
    fi
    _dz_cur=$(np__node_get "$_dz_cur" parent)
    _dz_guard=$((_dz_guard + 1))
  done
  return 1
}

# Fail every still-open descendant. One flat pass over the registry, deepest
# first, so a node is closed before anything reads it as a parent.
np__cascade_fail() {
  _cf_depth=64
  while [ "$_cf_depth" -ge 0 ]; do
    for _cf_file in "$NP_TRACE_DIR/nodes"/*; do
      [ -f "$_cf_file" ] || continue
      _cf_h=${_cf_file##*/}
      [ "$_cf_h" = "$1" ] && continue
      [ "$(np__node_get "$_cf_h" closed)" = '1' ] && continue
      np__is_descendant_of "$_cf_h" "$1" || continue
      [ "$(np__depth_of "$_cf_h")" -eq "$_cf_depth" ] || continue
      if [ -n "$2" ]; then
        np_trace_error "$_cf_h" --message "$2"
      fi
      np__terminalize "$_cf_h" "$NP_STATUS_FAILED"
    done
    _cf_depth=$((_cf_depth - 1))
  done
  return 0
}

# How many parent links sit above this node.
np__depth_of() {
  _do_cur=$(np__node_get "$1" parent)
  _do_n=0
  while [ -n "$_do_cur" ] && [ "$_do_n" -lt 64 ]; do
    _do_n=$((_do_n + 1))
    _do_cur=$(np__node_get "$_do_cur" parent)
  done
  printf '%s' "$_do_n"
}

np_trace_skip() {
  _sk_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_sk_h" || return 0
  if [ -n "${1:-}" ]; then
    np__stage_facet "$_sk_h" "$NP_FACET_DROPPED" "$(np__json_obj reason "$1")"
  fi
  np__terminalize "$_sk_h" "$NP_STATUS_SKIPPED"
  return 0
}

np_trace_cancel() {
  _cn_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__terminalize "$_cn_h" "$NP_STATUS_CANCELLED"
  return 0
}

np_trace_timeout() {
  np__terminalize "$(np__resolve_handle "${1:-}")" "$NP_STATUS_TIMED_OUT"
  return 0
}

# Non-terminal: the node stays open.
np_trace_waiting() {
  _wt_h=$(np__resolve_handle "${1:-}")
  np__is_handle "$_wt_h" || return 0
  np_trace_start "$_wt_h"
  np__emit_node "$_wt_h" "$NP_STATUS_WAITING"
  return 0
}
