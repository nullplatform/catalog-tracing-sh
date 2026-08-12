# ---------------------------------------------------------------------------
# Propagation
#
# Cross-process trace context, wire-identical to the Go and JS SDKs: a single
# carrier value packing "<version>|<trace_id>|<run_id>". The '|' delimiter is
# reserved, so the value splits unambiguously even though a run_id may itself
# contain '~' and '@'.
#
# The carrier travels in the NP_TRACE environment variable. Note that this is
# deliberately OUTSIDE the NP_TRACE_* configuration namespace the SDK reads for
# its own settings: NP_TRACE is context handed to us by a caller, not something
# a user configures.
# ---------------------------------------------------------------------------

# np_trace_inject [handle]
#
# Print the carrier value for a handle (defaults to the ambient node), for
# handing to a child process. Prints nothing when there is no node to inject,
# so `NP_TRACE=$(np_trace_inject)` is always safe.
np_trace_inject() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _inject_h=$(np__resolve_handle "${1:-}")
  np__is_handle "$_inject_h" || return 0
  printf '%s%s%s%s%s' \
    "$NP_CARRIER_VERSION" "$NP_CARRIER_DELIMITER" \
    "$(np__node_get "$_inject_h" trace_id)" "$NP_CARRIER_DELIMITER" \
    "$(np__node_get "$_inject_h" run_id)"
  return 0
}

# np_trace_extract [carrier]
#
# Parse a carrier value (defaults to $NP_TRACE) and print "<trace_id> <run_id>".
# Returns 1 when there is no usable context, so callers can branch:
#
#   if ctx=$(np_trace_extract); then set -- $ctx; fi
#
# When only a trace id is present it is used for both, matching the Go SDK, so
# the result is always a usable pair.
np_trace_extract() {
  _extract_raw=${1-${NP_TRACE:-}}
  [ -n "$_extract_raw" ] || return 1

  case "$_extract_raw" in
    "$NP_CARRIER_VERSION$NP_CARRIER_DELIMITER"*) ;;
    *) return 1 ;;
  esac
  _extract_rest=${_extract_raw#*"$NP_CARRIER_DELIMITER"}

  # trace_id is up to the next delimiter; run_id is the whole remainder, which
  # may itself contain '~' and '@' but never a delimiter.
  case "$_extract_rest" in
    *"$NP_CARRIER_DELIMITER"*)
      _extract_trace=${_extract_rest%%"$NP_CARRIER_DELIMITER"*}
      _extract_run=${_extract_rest#*"$NP_CARRIER_DELIMITER"}
      ;;
    *)
      _extract_trace=$_extract_rest
      _extract_run=$_extract_rest
      ;;
  esac
  [ -n "$_extract_trace" ] || return 1
  [ -n "$_extract_run" ] || _extract_run=$_extract_trace

  printf '%s %s' "$_extract_trace" "$_extract_run"
  return 0
}

# np_trace_adopt [carrier]
#
# Attach to an upstream node and return a handle standing in for it, so work
# started here nests UNDERNEATH it:
#
#   parent=$(np_trace_adopt) || parent=$(np_trace_run --run-id "$(np_trace_occurrence)")
#   step=$(np_trace_step "$parent" build)
#
# The adopted node belongs to whoever created it — typically the np CLI, which
# exports NP_TRACE per workflow step. We hold its ids so children derive
# correctly, but must never speak for it: it is marked foreign, so it emits no
# node event of its own and the terminal verbs refuse to close it. Children
# hanging off it still emit their own containment edges, which IS ours to say.
#
# Returns 1 when there is no upstream context, leaving the caller to open a root
# run instead.
np_trace_adopt() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 1
  _adopt_ctx=$(np_trace_extract "${1-${NP_TRACE:-}}") || return 1
  _adopt_trace=${_adopt_ctx%% *}
  _adopt_run=${_adopt_ctx#* }

  if ! _adopt_why=$(np__trace_id_violation "$_adopt_trace"); then
    np__drop 'adopt' "trace_id $_adopt_why"
    return 1
  fi
  # An upstream run_id is commonly a DERIVED path (parent~key@attempt.iteration)
  # rather than a named id — the np CLI hands us the step it is running. Accept
  # either: parse it as a node path first, and only fall back to the named-id
  # rules when it has no delimiter.
  if ! np__parse_node_id "$_adopt_run" >/dev/null 2>&1; then
    if ! _adopt_why=$(np__named_id_violation "$_adopt_run"); then
      np__drop 'adopt' "run_id $_adopt_why"
      return 1
    fi
  fi

  _adopt_h=$(np__handle_new)
  np__node_set "$_adopt_h" kind run
  np__node_set "$_adopt_h" trace_id "$_adopt_trace"
  np__node_set "$_adopt_h" run_id "$_adopt_run"
  np__node_set "$_adopt_h" nrn "${NP_TRACE_NRN:-}"
  np__node_set "$_adopt_h" foreign 1
  # started=1 suppresses the lazy `started` emit; closed=0 keeps it usable as a
  # parent for the whole script.
  np__node_set "$_adopt_h" started 1
  np__node_set "$_adopt_h" closed 0
  np__ambient_set "$_adopt_h"
  printf '%s' "$_adopt_h"
  return 0
}

# True when a handle stands in for a node owned by another process.
np__is_foreign() {
  [ "$(np__node_get "$1" foreign)" = '1' ]
}
