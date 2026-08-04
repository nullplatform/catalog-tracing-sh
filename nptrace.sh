#!/bin/sh

# ---- src/header.sh ----
# nullplatform tracing for POSIX shell — producer SDK for the nullplatform
# tracing API. Zero runtime dependencies beyond curl and the POSIX toolset.
#
# Generated file: edit src/*.sh and run ./build.sh.

if [ -n "${NP_TRACE_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
NP_TRACE_LOADED=1
NP_TRACE_VERSION="0.1.0"

# ---- src/compat.sh ----
# compat.sh — portability shims. The ONLY place OS differences live.

# Unix milliseconds. GNU date supports %N; busybox and BSD may not, in which
# case the format leaks through literally — detected and downgraded to second
# precision (event ids stay unique via their random bits).
np__epoch_ms() {
  _cm_ms=$(date -u +%s%3N 2>/dev/null) || _cm_ms=''
  case "$_cm_ms" in
    '' | *[!0-9]*) _cm_ms="$(date -u +%s)000" ;;
  esac
  printf '%s' "$_cm_ms"
}

# Exactly $1 lowercase hex characters from the kernel CSPRNG.
np__rand_hex() {
  _rh_want=$1
  _rh_bytes=$(( (_rh_want + 1) / 2 ))
  od -An -tx1 -N"$_rh_bytes" /dev/urandom | tr -d ' \n' | cut -c1-"$_rh_want"
}

# RFC 3339 UTC, second precision — the envelope `time` field.
np__iso8601() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# ---- src/json.sh ----
# json.sh — JSON emission. There is no parser here beyond one field extractor
# for the auth response; the SDK only ever WRITES JSON.

# Escape a string for a JSON string body (no surrounding quotes).
#
# Fast path: a string made only of unmistakably safe characters is returned
# unchanged, so the common label/id case never forks an awk. The allowlist is
# deliberately conservative — routing an unusual string to the slow path is
# always correct, only slower.
#
# Slow path: awk under LC_ALL=C, so length/substr are BYTE oriented on every
# awk (gawk, mawk, busybox). UTF-8 sequences pass through byte for byte, which
# is valid JSON; only the seven shorthand escapes and C0 controls are rewritten.
# Records are read line by line and rejoined with \n rather than using a
# multi-character RS, whose behaviour POSIX leaves undefined.
np__json_escape() {
  case "$1" in
    *[!A-Za-z0-9\ ._:/@=+,-]*) ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  printf '%s' "$1" | LC_ALL=C awk '
    function esc(s,   i, c, n, o) {
      o = ""
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\") { o = o "\\\\" }
        else if (c == "\"") { o = o "\\\"" }
        else if (c == "\t") { o = o "\\t" }
        else if (c == "\r") { o = o "\\r" }
        else if (c == "\b") { o = o "\\b" }
        else if (c == "\f") { o = o "\\f" }
        else if (c < " ") { o = o sprintf("\\u%04x", ORD[c]) }
        else { o = o c }
      }
      return o
    }
    BEGIN {
      ORS = ""
      for (i = 0; i < 256; i++) { ORD[sprintf("%c", i)] = i }
      out = ""
    }
    {
      if (NR > 1) { out = out "\\n" }
      out = out esc($0)
    }
    END { printf "%s", out }
  '
}

# A complete quoted JSON string.
np__json_str() {
  printf '"%s"' "$(np__json_escape "$1")"
}

# A JSON object from alternating key/value arguments. Values are emitted as
# JSON strings. A pair whose key or value is empty is OMITTED — an absent
# optional is absent, never the string "".
np__json_obj() {
  _jo_out=''
  while [ "$#" -ge 2 ]; do
    if [ -n "$1" ] && [ -n "$2" ]; then
      if [ -n "$_jo_out" ]; then
        _jo_out="$_jo_out,"
      fi
      _jo_out="$_jo_out$(np__json_str "$1"):$(np__json_str "$2")"
    fi
    shift 2
  done
  printf '{%s}' "$_jo_out"
}

# As np__json_obj, but each value is already-formed JSON inserted verbatim.
# Use for nested objects, arrays, numbers, and booleans.
np__json_obj_raw() {
  _jor_out=''
  while [ "$#" -ge 2 ]; do
    if [ -n "$1" ] && [ -n "$2" ]; then
      if [ -n "$_jor_out" ]; then
        _jor_out="$_jor_out,"
      fi
      _jor_out="$_jor_out$(np__json_str "$1"):$2"
    fi
    shift 2
  done
  printf '{%s}' "$_jor_out"
}

# ---- src/uuid.sh ----
# uuid.sh — UUIDv7. The event id MUST be a v7: the API derives the storage
# partition from its embedded millisecond timestamp and rejects anything else.
#
# Layout: 48-bit big-endian ms timestamp | version nibble 7 | 12 random bits
#         | variant bits 10 | 62 random bits.

np__uuidv7() {
  _u7_ts=$(printf '%012x' "$(np__epoch_ms)")
  _u7_r=$(np__rand_hex 19)

  # The variant nibble must be one of 8, 9, a, b. Fold a random hex digit into
  # that range rather than drawing again.
  case $(printf '%s' "$_u7_r" | cut -c1) in
    0 | 1 | 2 | 3) _u7_var=8 ;;
    4 | 5 | 6 | 7) _u7_var=9 ;;
    8 | 9 | a | b) _u7_var=a ;;
    *) _u7_var=b ;;
  esac

  printf '%s-%s-7%s-%s%s-%s\n' \
    "$(printf '%s' "$_u7_ts" | cut -c1-8)" \
    "$(printf '%s' "$_u7_ts" | cut -c9-12)" \
    "$(printf '%s' "$_u7_r" | cut -c2-4)" \
    "$_u7_var" \
    "$(printf '%s' "$_u7_r" | cut -c5-7)" \
    "$(printf '%s' "$_u7_r" | cut -c8-19)"
}

# Mint a per-occurrence token for a repeatable operation's run_id. Time-ordered,
# so minted ids sort by creation time.
np_trace_occurrence() {
  np__uuidv7
}

# ---- src/identity.sh ----
# identity.sh — the node identity grammar. A hand-port of the tracing API's
# contract module; these functions and their tests are the drift safety net.
#
#   child_run_id = parent_run_id "~" key "@" attempt "." iteration
#
# One charset covers every producer-authored segment: [A-Za-z0-9_.-]+. The
# delimiter '~' and the coordinate marker '@' sit outside it, which is what
# makes the grammar collision-proof — no named id can ever parse as a derived
# one.

NP_ID_DELIMITER='~'
NP_MAX_RUN_ID_LENGTH=1024
NP_MAX_KEY_LENGTH=256
NP_MAX_TRACE_ID_LENGTH=256

np__is_identifier() {
  case "${1:-}" in
    '') return 1 ;;
    *[!A-Za-z0-9_.-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Print a reason and return 1, or return 0 silently.
np__identifier_violation() {
  if [ -z "$1" ]; then
    printf 'must be non-empty'
    return 1
  fi
  if [ "${#1}" -gt "$2" ]; then
    printf 'exceeds %s chars' "$2"
    return 1
  fi
  if ! np__is_identifier "$1"; then
    printf "must be identifier-charset: letters, digits, '_', '.', '-'"
    return 1
  fi
  return 0
}

np__key_violation() {
  np__identifier_violation "${1:-}" "$NP_MAX_KEY_LENGTH"
}

np__named_id_violation() {
  np__identifier_violation "${1:-}" "$NP_MAX_RUN_ID_LENGTH"
}

np__trace_id_violation() {
  np__identifier_violation "${1:-}" "$NP_MAX_TRACE_ID_LENGTH"
}

# The derived id of a keyed child.
np__derive_child_id() {
  printf '%s%s%s@%s.%s' "$1" "$NP_ID_DELIMITER" "$2" "$3" "$4"
}

# Everything before the FIRST delimiter — the nearest named ancestor. Every
# keyed descendant of a named run shares its scope root at any depth.
np__scope_root_of() {
  case "$1" in
    *"$NP_ID_DELIMITER"*) printf '%s' "${1%%"$NP_ID_DELIMITER"*}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Parse the LAST hop of a derived id. Prints "<parent> <key> <attempt> <iteration>".
# Returns 1 for a named id (no delimiter) or a malformed tail.
np__parse_node_id() {
  case "$1" in
    *"$NP_ID_DELIMITER"*) ;;
    *) return 1 ;;
  esac
  _pn_parent=${1%"$NP_ID_DELIMITER"*}
  _pn_tail=${1##*"$NP_ID_DELIMITER"}
  case "$_pn_tail" in
    *@*.*) ;;
    *) return 1 ;;
  esac
  _pn_key=${_pn_tail%%@*}
  _pn_coord=${_pn_tail#*@}
  _pn_attempt=${_pn_coord%%.*}
  _pn_iteration=${_pn_coord#*.}
  if [ -z "$_pn_parent" ] || [ -z "$_pn_key" ]; then
    return 1
  fi
  case "$_pn_attempt" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$_pn_iteration" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s %s %s %s' "$_pn_parent" "$_pn_key" "$_pn_attempt" "$_pn_iteration"
}

# Join parts into a stable id, dropping empty parts. Use instead of
# hand-interpolation so an absent part never leaves a dangling separator.
# The joiner is '-', a charset character, so the result stays a legal named id.
np_trace_key() {
  _k_out=''
  for _k_part in "$@"; do
    if [ -n "$_k_part" ]; then
      if [ -n "$_k_out" ]; then
        _k_out="$_k_out-"
      fi
      _k_out="$_k_out$_k_part"
    fi
  done
  printf '%s' "$_k_out"
}

# ---- src/wire.sh ----
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

# ---- src/state.sh ----
# state.sh — the on-disk node registry. State lives on disk rather than in
# shell memory so handles survive process boundaries: in CI every pipeline step
# is a fresh shell.

np__state_init() {
  if [ -z "${NP_TRACE_DIR:-}" ]; then
    NP_TRACE_DIR="${TMPDIR:-/tmp}/nptrace.$$"
  fi
  export NP_TRACE_DIR
  mkdir -p "$NP_TRACE_DIR/nodes" "$NP_TRACE_DIR/staged" \
           "$NP_TRACE_DIR/spool" "$NP_TRACE_DIR/failed" 2>/dev/null || return 0
  if [ ! -f "$NP_TRACE_DIR/seq" ]; then
    printf '0' > "$NP_TRACE_DIR/seq"
  fi
  return 0
}

# Allocate the next handle. Handles are opaque by contract: consumers never
# parse them.
np__handle_new() {
  _hn_seq=$(cat "$NP_TRACE_DIR/seq" 2>/dev/null || printf '0')
  case "$_hn_seq" in
    '' | *[!0-9]*) _hn_seq=0 ;;
  esac
  _hn_seq=$((_hn_seq + 1))
  printf '%s' "$_hn_seq" > "$NP_TRACE_DIR/seq"
  _hn_handle="n$_hn_seq"
  : > "$NP_TRACE_DIR/nodes/$_hn_handle"
  printf '%s' "$_hn_handle"
}

# THE rule the whole public surface rests on: an argument is a handle iff it
# has the allocator's shape AND names an existing node file. The shape check
# comes first so a caller-supplied string can never traverse out of nodes/.
np__is_handle() {
  case "${1:-}" in
    n) return 1 ;;
    n*) case "${1#n}" in '' | *[!0-9]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  [ -f "$NP_TRACE_DIR/nodes/$1" ]
}

np__node_set() {
  _ns_file="$NP_TRACE_DIR/nodes/$1"
  [ -f "$_ns_file" ] || return 0
  # Drop any prior value for this key, then append the new one. The trailing
  # '=' in the match means a key that is a prefix of another never collides.
  if grep -q "^$2=" "$_ns_file" 2>/dev/null; then
    grep -v "^$2=" "$_ns_file" > "$_ns_file.tmp" 2>/dev/null || : > "$_ns_file.tmp"
    mv "$_ns_file.tmp" "$_ns_file"
  fi
  printf '%s=%s\n' "$2" "$3" >> "$_ns_file"
  return 0
}

np__node_get() {
  _ng_file="$NP_TRACE_DIR/nodes/$1"
  [ -f "$_ng_file" ] || return 0
  # Strip only the leading "key=", so a value containing '=' survives intact.
  sed -n "s/^$2=//p" "$_ng_file" 2>/dev/null | head -n 1
  return 0
}

# Ambient resolution, exactly two levels. There is deliberately no third,
# session-wide level: that is where concurrent writers race.
#
#   1. NP_TRACE_CURRENT — explicit, and what you export to cross a CI step.
#   2. current.$$       — auto-maintained within one process tree. POSIX $$
#                         does not change in a subshell, so a handle created
#                         inside $(...) is visible to the caller.
np__ambient() {
  if [ -n "${NP_TRACE_CURRENT:-}" ]; then
    printf '%s' "$NP_TRACE_CURRENT"
    return 0
  fi
  cat "$NP_TRACE_DIR/current.$$" 2>/dev/null || printf ''
  return 0
}

np__ambient_set() {
  printf '%s' "$1" > "$NP_TRACE_DIR/current.$$" 2>/dev/null || return 0
  return 0
}

np__ambient_clear() {
  # Only clear when the cleared handle IS current, so terminalizing an outer
  # node cannot silently retarget an inner one.
  if [ "$(np__ambient)" = "$1" ]; then
    rm -f "$NP_TRACE_DIR/current.$$" 2>/dev/null || :
    if [ -n "${NP_TRACE_CURRENT:-}" ] && [ "$NP_TRACE_CURRENT" = "$1" ]; then
      NP_TRACE_CURRENT=''
    fi
  fi
  return 0
}

# Every node-scoped public function starts here: use $1 when it is a handle,
# otherwise fall back to the ambient node.
np__resolve_handle() {
  if np__is_handle "${1:-}"; then
    printf '%s' "$1"
  else
    np__ambient
  fi
  return 0
}

# ---- src/spool.sh ----
# spool.sh — the emit hot path. Every emit is a LOCAL FILE WRITE: the network
# is never touched here, which is what makes API downtime invisible to the
# caller. The spool file's NAME is the event id, so re-POSTing after a crash is
# idempotent — that is recover() for free.

# np__spool <type> <nrn> <data-json>  ->  prints the event id
np__spool() {
  _sp_id=$(np__uuidv7)
  _sp_env=$(np__json_obj_raw \
    id "$(np__json_str "$_sp_id")" \
    time "$(np__json_str "$(np__iso8601)")" \
    type "$(np__json_str "$1")" \
    nrn "$(if [ -n "$2" ]; then np__json_str "$2"; fi)" \
    producer "$(np__json_str "${NP_TRACE_PRODUCER:-}")" \
    data "$3")

  _sp_tmp="$NP_TRACE_DIR/spool/$_sp_id.json.tmp"
  _sp_final="$NP_TRACE_DIR/spool/$_sp_id.json"
  printf '%s' "$_sp_env" > "$_sp_tmp" 2>/dev/null || return 0
  # Create-then-rename: a concurrent flush never sees a half-written envelope.
  mv "$_sp_tmp" "$_sp_final" 2>/dev/null || return 0
  printf '%s' "$_sp_id"
  return 0
}

np__spool_count() {
  _sc_n=0
  for _sc_f in "$NP_TRACE_DIR/spool"/*.json; do
    [ -f "$_sc_f" ] || continue
    _sc_n=$((_sc_n + 1))
  done
  printf '%s' "$_sc_n"
  return 0
}

# ---- src/http.sh ----
# http.sh — the only module that touches the network. Every request is bounded
# by a connect AND a total timeout, so an unreachable or hanging API can never
# stall the caller.

NP_TRACE_CONNECT_TIMEOUT="${NP_TRACE_CONNECT_TIMEOUT:-3}"
NP_TRACE_MAX_TIME="${NP_TRACE_MAX_TIME:-10}"
NP_TRACE_DEFAULT_BASE_URL='https://api.nullplatform.com/tracing'
NP_TRACE_DEFAULT_AUTH_URL='https://api.nullplatform.com'

np__drop() {
  printf '%s\t%s\t%s\n' "$(np__iso8601)" "$1" "$2" >> "$NP_TRACE_DIR/drops.log" 2>/dev/null || :
  if [ -n "${NP_TRACE_ON_DROP:-}" ]; then
    "$NP_TRACE_ON_DROP" "$1" "$2" 2>/dev/null || :
  fi
  if [ -n "${NP_TRACE_DEBUG:-}" ]; then
    printf 'np-trace drop: %s (%s)\n' "$1" "$2" >&2
  fi
  return 0
}

# Suppress xtrace for a credential-handling region, remembering whether it was
# on. CI scripts routinely `set -x`, and shell options are global — so without
# this a sourced SDK function would print the bearer token into the build log
# even though it never reaches curl's argv. Every credential path is bracketed
# by np__secret_begin / np__secret_end.
np__secret_begin() {
  case "$-" in
    *x*) NP_TRACE_XTRACE=1; set +x ;;
    *) NP_TRACE_XTRACE='' ;;
  esac
}

np__secret_end() {
  if [ -n "${NP_TRACE_XTRACE:-}" ]; then
    NP_TRACE_XTRACE=''
    set -x
  fi
  return 0
}

# A bearer token. A pre-issued NP_TRACE_TOKEN wins; otherwise exchange the api
# key, caching until shortly before expiry. Called LAZILY, at first flush —
# never at init, so a down auth endpoint cannot delay pipeline startup.
np__token() {
  np__secret_begin
  if [ -n "${NP_TRACE_TOKEN:-}" ]; then
    printf '%s' "$NP_TRACE_TOKEN"
    np__secret_end
    return 0
  fi
  np__token_exchange
  np__secret_end
  return 0
}

# The api-key exchange. Always called from inside a secret region.
np__token_exchange() {
  if [ -z "${NP_TRACE_API_KEY:-}" ]; then
    printf ''
    return 0
  fi

  _tk_cache="$NP_TRACE_DIR/token"
  if [ -f "$_tk_cache" ]; then
    _tk_exp=$(sed -n '1p' "$_tk_cache" 2>/dev/null)
    _tk_val=$(sed -n '2p' "$_tk_cache" 2>/dev/null)
    case "$_tk_exp" in
      '' | *[!0-9]*) _tk_exp=0 ;;
    esac
    if [ -n "$_tk_val" ] && [ "$_tk_exp" -gt "$(date +%s)" ]; then
      printf '%s' "$_tk_val"
      return 0
    fi
  fi

  _tk_body=$(curl -sS -X POST \
    --connect-timeout "$NP_TRACE_CONNECT_TIMEOUT" --max-time "$NP_TRACE_MAX_TIME" \
    -H 'Content-Type: application/json' \
    -d "$(np__json_obj apiKey "$NP_TRACE_API_KEY")" \
    "${NP_TRACE_AUTH_URL:-$NP_TRACE_DEFAULT_AUTH_URL}/token" 2>/dev/null) || _tk_body=''

  _tk_new=$(printf '%s' "$_tk_body" |
    sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [ -z "$_tk_new" ]; then
    np__drop 'auth' 'token exchange failed'
    printf ''
    return 0
  fi
  ( umask 077; printf '%s\n%s\n' "$(( $(date +%s) + 3540 ))" "$_tk_new" > "$_tk_cache" )
  printf '%s' "$_tk_new"
  return 0
}

# The auth header goes to curl via --config from a mode-600 file, NEVER as -H
# in argv: CI runs with `set -x`, and an argv-borne header prints the token
# straight into the build log.
np__auth_config() {
  np__secret_begin
  _ac_file="$NP_TRACE_DIR/curlcfg.$$"
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$(np__token)" > "$_ac_file" )
  np__secret_end
  printf '%s' "$_ac_file"
  return 0
}

# POST one spool file. Prints the HTTP status code, or 000 on a network failure.
np__post_event() {
  _pe_cfg=$(np__auth_config)
  _pe_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    --config "$_pe_cfg" \
    --connect-timeout "$NP_TRACE_CONNECT_TIMEOUT" --max-time "$NP_TRACE_MAX_TIME" \
    -H 'Content-Type: application/json' \
    --data-binary "@$1" \
    "${NP_TRACE_BASE_URL:-$NP_TRACE_DEFAULT_BASE_URL}/events" 2>/dev/null) || _pe_code='000'
  rm -f "$_pe_cfg" 2>/dev/null || :
  case "$_pe_code" in
    '' | *[!0-9]*) _pe_code='000' ;;
  esac
  printf '%s' "$_pe_code"
  return 0
}

# ---- src/flush.sh ----
# flush.sh — the spool drain.

# ---- src/api.sh ----
# api.sh — the public producer surface.

# ---- src/cli.sh ----
# cli.sh — argv to function shim (Phase 2).
