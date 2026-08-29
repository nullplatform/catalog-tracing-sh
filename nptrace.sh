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

# Unix milliseconds. GNU date supports %N; busybox and BSD may not, and they
# fail in two DIFFERENT ways:
#
#   busybox 1.38 / BSD  -> "1786045823%3N"  the format leaks through literally
#   busybox 1.37        -> "1786045823"     the format is silently DROPPED
#
# The second is the dangerous one: the result is clean digits that merely happen
# to be seconds, so a digits-only check accepts it and every timestamp is then
# 1000x too small — which silently destroys UUIDv7 ordering, since the seconds
# value lands in a 48-bit millisecond field and decodes to 1970.
#
# Length is what separates them: Unix milliseconds have been 13 digits since
# 2001-09-09 and stay 13 until 2286, while seconds are 10. Anything shorter than
# 13 is not milliseconds, whatever it looks like.
np__epoch_ms() {
  _epoch_ms_ms=$(date -u +%s%3N 2>/dev/null) || _epoch_ms_ms=''
  case "$_epoch_ms_ms" in
    '' | *[!0-9]*) _epoch_ms_ms='' ;;
  esac
  if [ -n "$_epoch_ms_ms" ] && [ "${#_epoch_ms_ms}" -ge 13 ]; then
    printf '%s' "$_epoch_ms_ms"
    return 0
  fi
  # Second precision. Event ids stay unique via their random bits.
  printf '%s000' "$(date -u +%s)"
}

# Exactly $1 lowercase hex characters from the kernel CSPRNG.
np__rand_hex() {
  _rand_hex_want=$1
  _rand_hex_bytes=$(( (_rand_hex_want + 1) / 2 ))
  od -An -tx1 -N"$_rand_hex_bytes" /dev/urandom | tr -d ' \n' | cut -c1-"$_rand_hex_want"
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
  _json_obj_out=''
  while [ "$#" -ge 2 ]; do
    if [ -n "$1" ] && [ -n "$2" ]; then
      if [ -n "$_json_obj_out" ]; then
        _json_obj_out="$_json_obj_out,"
      fi
      _json_obj_out="$_json_obj_out$(np__json_str "$1"):$(np__json_str "$2")"
    fi
    shift 2
  done
  printf '{%s}' "$_json_obj_out"
}

# As np__json_obj, but each value is already-formed JSON inserted verbatim.
# Use for nested objects, arrays, numbers, and booleans.
np__json_obj_raw() {
  _json_obj_raw_out=''
  while [ "$#" -ge 2 ]; do
    if [ -n "$1" ] && [ -n "$2" ]; then
      if [ -n "$_json_obj_raw_out" ]; then
        _json_obj_raw_out="$_json_obj_raw_out,"
      fi
      _json_obj_raw_out="$_json_obj_raw_out$(np__json_str "$1"):$2"
    fi
    shift 2
  done
  printf '{%s}' "$_json_obj_raw_out"
}

# A JSON array of strings from a comma-separated list ("a, b" → ["a","b"]).
# Surrounding whitespace per item is trimmed; empty items are omitted.
np__json_str_array_csv() {
  _json_str_array_csv_out=''
  _json_str_array_csv_rest=$1
  while [ -n "$_json_str_array_csv_rest" ]; do
    case "$_json_str_array_csv_rest" in
      *,*) _json_str_array_csv_item=${_json_str_array_csv_rest%%,*}; _json_str_array_csv_rest=${_json_str_array_csv_rest#*,} ;;
      *) _json_str_array_csv_item=$_json_str_array_csv_rest; _json_str_array_csv_rest='' ;;
    esac
    _json_str_array_csv_item=$(printf '%s' "$_json_str_array_csv_item" | sed 's/^ *//; s/ *$//')
    if [ -n "$_json_str_array_csv_item" ]; then
      if [ -n "$_json_str_array_csv_out" ]; then
        _json_str_array_csv_out="$_json_str_array_csv_out,"
      fi
      _json_str_array_csv_out="$_json_str_array_csv_out$(np__json_str "$_json_str_array_csv_item")"
    fi
  done
  printf '[%s]' "$_json_str_array_csv_out"
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
  _parse_node_id_parent=${1%"$NP_ID_DELIMITER"*}
  _parse_node_id_tail=${1##*"$NP_ID_DELIMITER"}
  case "$_parse_node_id_tail" in
    *@*.*) ;;
    *) return 1 ;;
  esac
  _parse_node_id_key=${_parse_node_id_tail%%@*}
  _parse_node_id_coord=${_parse_node_id_tail#*@}
  _parse_node_id_attempt=${_parse_node_id_coord%%.*}
  _parse_node_id_iteration=${_parse_node_id_coord#*.}
  if [ -z "$_parse_node_id_parent" ] || [ -z "$_parse_node_id_key" ]; then
    return 1
  fi
  case "$_parse_node_id_attempt" in
    '' | *[!0-9]*) return 1 ;;
  esac
  case "$_parse_node_id_iteration" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s %s %s %s' "$_parse_node_id_parent" "$_parse_node_id_key" "$_parse_node_id_attempt" "$_parse_node_id_iteration"
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

# Create the state tree. If it cannot be created or written — a read-only
# filesystem, a full disk, a bad NP_TRACE_DIR — the SDK degrades to a REAL
# no-op rather than half-working: a half-initialised SDK whose next write fails
# would take down a caller running under `set -e`, which is exactly the failure
# mode tracing must never cause.
np__state_init() {
  if [ -z "${NP_TRACE_DIR:-}" ]; then
    NP_TRACE_DIR="${TMPDIR:-/tmp}/nptrace.$$"
  fi
  export NP_TRACE_DIR
  if ! mkdir -p "$NP_TRACE_DIR/nodes" "$NP_TRACE_DIR/staged" \
                "$NP_TRACE_DIR/spool" "$NP_TRACE_DIR/failed" 2>/dev/null; then
    NP_TRACE_ENABLED=0
    return 0
  fi
  # Prove the tree is actually writable before trusting it.
  if ! printf '0' > "$NP_TRACE_DIR/seq.probe" 2>/dev/null; then
    NP_TRACE_ENABLED=0
    return 0
  fi
  rm -f "$NP_TRACE_DIR/seq.probe" 2>/dev/null || :
  if [ ! -f "$NP_TRACE_DIR/seq" ]; then
    printf '0' > "$NP_TRACE_DIR/seq" 2>/dev/null || :
  fi
  return 0
}

# Allocate the next handle. Handles are opaque by contract: consumers never
# parse them.
np__handle_new() {
  _handle_new_seq=$(cat "$NP_TRACE_DIR/seq" 2>/dev/null || printf '0')
  case "$_handle_new_seq" in
    '' | *[!0-9]*) _handle_new_seq=0 ;;
  esac
  _handle_new_seq=$((_handle_new_seq + 1))
  printf '%s' "$_handle_new_seq" > "$NP_TRACE_DIR/seq"
  _handle_new_handle="n$_handle_new_seq"
  : > "$NP_TRACE_DIR/nodes/$_handle_new_handle"
  printf '%s' "$_handle_new_handle"
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
  _node_set_file="$NP_TRACE_DIR/nodes/$1"
  [ -f "$_node_set_file" ] || return 0
  # Drop any prior value for this key, then append the new one. The trailing
  # '=' in the match means a key that is a prefix of another never collides.
  if grep -q "^$2=" "$_node_set_file" 2>/dev/null; then
    grep -v "^$2=" "$_node_set_file" > "$_node_set_file.tmp" 2>/dev/null || : > "$_node_set_file.tmp"
    mv "$_node_set_file.tmp" "$_node_set_file"
  fi
  printf '%s=%s\n' "$2" "$3" >> "$_node_set_file"
  return 0
}

np__node_get() {
  _node_get_file="$NP_TRACE_DIR/nodes/$1"
  [ -f "$_node_get_file" ] || return 0
  # Strip only the leading "key=", so a value containing '=' survives intact.
  sed -n "s/^$2=//p" "$_node_get_file" 2>/dev/null | head -n 1
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
  _spool_id=$(np__uuidv7)
  _spool_env=$(np__json_obj_raw \
    id "$(np__json_str "$_spool_id")" \
    time "$(np__json_str "$(np__iso8601)")" \
    type "$(np__json_str "$1")" \
    nrn "$(if [ -n "$2" ]; then np__json_str "$2"; fi)" \
    producer "$(np__json_str "${NP_TRACE_PRODUCER:-}")" \
    data "$3")

  _spool_tmp="$NP_TRACE_DIR/spool/$_spool_id.json.tmp"
  _spool_final="$NP_TRACE_DIR/spool/$_spool_id.json"
  printf '%s' "$_spool_env" > "$_spool_tmp" 2>/dev/null || return 0
  # Create-then-rename: a concurrent flush never sees a half-written envelope.
  mv "$_spool_tmp" "$_spool_final" 2>/dev/null || return 0
  printf '%s' "$_spool_id"
  return 0
}

np__spool_count() {
  _spool_count_n=0
  for _spool_count_f in "$NP_TRACE_DIR/spool"/*.json; do
    [ -f "$_spool_count_f" ] || continue
    _spool_count_n=$((_spool_count_n + 1))
  done
  printf '%s' "$_spool_count_n"
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

  _token_exchange_cache="$NP_TRACE_DIR/token"
  if [ -f "$_token_exchange_cache" ]; then
    _token_exchange_exp=$(sed -n '1p' "$_token_exchange_cache" 2>/dev/null)
    _token_exchange_val=$(sed -n '2p' "$_token_exchange_cache" 2>/dev/null)
    case "$_token_exchange_exp" in
      '' | *[!0-9]*) _token_exchange_exp=0 ;;
    esac
    if [ -n "$_token_exchange_val" ] && [ "$_token_exchange_exp" -gt "$(date +%s)" ]; then
      printf '%s' "$_token_exchange_val"
      return 0
    fi
  fi

  _token_exchange_body=$(curl -sS -X POST \
    --connect-timeout "$NP_TRACE_CONNECT_TIMEOUT" --max-time "$NP_TRACE_MAX_TIME" \
    -H 'Content-Type: application/json' \
    -d "$(np__json_obj apiKey "$NP_TRACE_API_KEY")" \
    "${NP_TRACE_AUTH_URL:-$NP_TRACE_DEFAULT_AUTH_URL}/token" 2>/dev/null) || _token_exchange_body=''

  _token_exchange_new=$(printf '%s' "$_token_exchange_body" |
    sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [ -z "$_token_exchange_new" ]; then
    np__drop 'auth' 'token exchange failed'
    printf ''
    return 0
  fi
  ( umask 077; printf '%s\n%s\n' "$(( $(date +%s) + 3540 ))" "$_token_exchange_new" > "$_token_exchange_cache" )
  printf '%s' "$_token_exchange_new"
  return 0
}

# The auth header goes to curl via --config from a mode-600 file, NEVER as -H
# in argv: CI runs with `set -x`, and an argv-borne header prints the token
# straight into the build log.
np__auth_config() {
  np__secret_begin
  _auth_config_file="$NP_TRACE_DIR/curlcfg.$$"
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$(np__token)" > "$_auth_config_file" )
  np__secret_end
  printf '%s' "$_auth_config_file"
  return 0
}

# POST one spool file. Prints the HTTP status code, or 000 on a network failure.
np__post_event() {
  _post_event_cfg=$(np__auth_config)
  _post_event_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    --config "$_post_event_cfg" \
    --connect-timeout "$NP_TRACE_CONNECT_TIMEOUT" --max-time "$NP_TRACE_MAX_TIME" \
    -H 'Content-Type: application/json' \
    --data-binary "@$1" \
    "${NP_TRACE_BASE_URL:-$NP_TRACE_DEFAULT_BASE_URL}/events" 2>/dev/null) || _post_event_code='000'
  rm -f "$_post_event_cfg" 2>/dev/null || :
  case "$_post_event_code" in
    '' | *[!0-9]*) _post_event_code='000' ;;
  esac
  printf '%s' "$_post_event_code"
  return 0
}

# ---- src/flush.sh ----
# flush.sh — the spool drain. Bounded by a wall-clock budget so a dead API can
# never hang process exit; every path returns 0.

NP_TRACE_FLUSH_TIMEOUT="${NP_TRACE_FLUSH_TIMEOUT:-10}"
NP_TRACE_MAX_RETRIES="${NP_TRACE_MAX_RETRIES:-3}"

np__attempts_of() {
  _attempts_of_n=$(cat "$1.attempts" 2>/dev/null || printf '0')
  case "$_attempts_of_n" in
    '' | *[!0-9]*) _attempts_of_n=0 ;;
  esac
  printf '%s' "$_attempts_of_n"
}

np__fail_event() {
  mv "$1" "$NP_TRACE_DIR/failed/" 2>/dev/null || rm -f "$1" 2>/dev/null || :
  rm -f "$1.attempts" 2>/dev/null || :
  np__drop "${1##*/}" "$2"
  return 0
}

np_trace_flush() {
  [ -n "${NP_TRACE_DIR:-}" ] || return 0
  [ -d "$NP_TRACE_DIR/spool" ] || return 0
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _flush_deadline=$(( $(date +%s) + NP_TRACE_FLUSH_TIMEOUT ))

  for _flush_file in "$NP_TRACE_DIR/spool"/*.json; do
    [ -f "$_flush_file" ] || continue
    if [ "$(date +%s)" -ge "$_flush_deadline" ]; then
      # Budget spent. Remaining events stay on disk for the next flush or a
      # later np_trace_recover; the process exits on time regardless. This is
      # the guarantee that a dead API cannot hang a build.
      return 0
    fi

    _flush_code=$(np__post_event "$_flush_file")
    case "$_flush_code" in
      201 | 200)
        # 200 is an idempotent re-POST of an already-accepted event.
        rm -f "$_flush_file" "$_flush_file.attempts" 2>/dev/null || :
        ;;
      400)
        # A contract violation. Never retried — retrying cannot change it.
        np__fail_event "$_flush_file" "rejected 400"
        ;;
      401 | 403)
        rm -f "$NP_TRACE_DIR/token" 2>/dev/null || :
        np__fail_event "$_flush_file" "unauthorized $_flush_code"
        ;;
      *)
        _flush_n=$(( $(np__attempts_of "$_flush_file") + 1 ))
        if [ "$_flush_n" -gt "$NP_TRACE_MAX_RETRIES" ]; then
          np__fail_event "$_flush_file" "gave up after $_flush_n attempts (last status $_flush_code)"
        else
          printf '%s' "$_flush_n" > "$_flush_file.attempts" 2>/dev/null || :
        fi
        ;;
    esac
  done
  return 0
}

np_trace_shutdown() {
  np_trace_flush
  if [ -n "${NP_TRACE_DIR:-}" ] && [ "${NP_TRACE_KEEP_STATE:-0}" != '1' ]; then
    rm -rf "$NP_TRACE_DIR" 2>/dev/null || :
  fi
  return 0
}

# Re-deliver a previous process's leftover spool. Idempotent by construction:
# the spool file name IS the event id, so the API answers a re-POST with
# 200 duplicate.
np_trace_recover() {
  np_trace_flush
  return 0
}

np__install_trap() {
  if [ -z "${NP_TRACE_NO_TRAP:-}" ]; then
    trap 'np_trace_flush' EXIT
    trap 'np_trace_flush' INT
    trap 'np_trace_flush' TERM
  fi
  return 0
}

# ---- src/propagation.sh ----
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
  if ! _adopt_coords=$(np__parse_node_id "$_adopt_run" 2>/dev/null); then
    _adopt_coords=''
    if ! _adopt_why=$(np__named_id_violation "$_adopt_run"); then
      np__drop 'adopt' "run_id $_adopt_why"
      return 1
    fi
  fi

  _adopt_h=$(np__handle_new)
  np__node_set "$_adopt_h" kind run
  np__node_set "$_adopt_h" trace_id "$_adopt_trace"
  np__node_set "$_adopt_h" run_id "$_adopt_run"
  # A keyed (derived-path) node event must carry its coordinate triple — the
  # API rejects a derived run_id whose key/attempt/iteration are absent. The
  # foreign re-emit (np__flush_foreign) therefore needs the coordinates on the
  # handle, even though the node itself stays the upstream owner's to close.
  if [ -n "$_adopt_coords" ]; then
    np__node_set "$_adopt_h" key "$(printf '%s' "$_adopt_coords" | cut -d' ' -f2)"
    np__node_set "$_adopt_h" attempt "$(printf '%s' "$_adopt_coords" | cut -d' ' -f3)"
    np__node_set "$_adopt_h" iteration "$(printf '%s' "$_adopt_coords" | cut -d' ' -f4)"
  fi
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

# ---- src/api.sh ----
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

# Upsert one pre-formed `"key":value` entry into a node's staged OBJECT store
# (labels / facets) under its key: re-staging a key REPLACES its entry, so an
# event never ships duplicate keys the parser has to break ties on — and a
# step that re-stages its narrative per heartbeat never grows its payload.
# $1 handle, $2 store key, $3 the `"key":value` entry, $4 the entry's key.
np__stage_entry() {
  _stage_entry_handle=$1
  _stage_entry_store=$2
  _stage_entry_slot=$(np__descriptor_slot "$4")
  _stage_entry_slots=$(np__node_get "$_stage_entry_handle" "${_stage_entry_store}_slots")
  case " $_stage_entry_slots " in
    *" $_stage_entry_slot "*) ;;
    *)
      _stage_entry_slots="${_stage_entry_slots:+$_stage_entry_slots }$_stage_entry_slot"
      np__node_set "$_stage_entry_handle" "${_stage_entry_store}_slots" "$_stage_entry_slots"
      ;;
  esac
  np__node_set "$_stage_entry_handle" "${_stage_entry_store}.$_stage_entry_slot" "$3"
  _stage_entry_joined=''
  for _stage_entry_each in $_stage_entry_slots; do
    _stage_entry_value=$(np__node_get "$_stage_entry_handle" "${_stage_entry_store}.$_stage_entry_each")
    [ -n "$_stage_entry_value" ] || continue
    _stage_entry_joined="${_stage_entry_joined:+$_stage_entry_joined,}$_stage_entry_value"
  done
  np__node_set "$_stage_entry_handle" "$_stage_entry_store" "{$_stage_entry_joined}"
  return 0
}

# Merge a pre-formed `"key":value` fragment into the node's staged labels.
np__stage_label() {
  _stage_label_key=$(printf '%s' "$2" | sed -n 's/^"\([^"]*\)".*/\1/p')
  np__stage_entry "$1" labels "$2" "${_stage_label_key:-$2}"
  return 0
}

# Last write wins per namespace: re-staging a facet replaces its entry.
np__stage_facet() {
  np__stage_entry "$1" facets "$(np__json_str "$2"):$3" "$2"
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

# A store-safe slot id for a descriptor's identity string (an io NAME, an
# affordance KIND): cksum is POSIX everywhere and collision-resistant enough
# for a node's handful of descriptors.
np__descriptor_slot() {
  printf '%s' "$1" | cksum | tr ' \t' '__'
}

# Upsert one descriptor into a node's list by IDENTITY; the facet is re-staged
# whole each time (last write wins per namespace). A re-declared identity
# REPLACES its previous descriptor in place — a step that reports the same
# name as its state evolves ("instances" per heartbeat) owns ONE entry
# carrying the latest telling, at its first telling's position — while a new
# identity appends. $1 handle, $2 facet namespace, $3 descriptor store key,
# $4 the already-formed descriptor JSON, $5 the identity string.
np__upsert_descriptor() {
  _upsert_descriptor_handle=$1
  _upsert_descriptor_facet=$2
  _upsert_descriptor_store=$3
  _upsert_descriptor_slot=$(np__descriptor_slot "$5")
  _upsert_descriptor_slots=$(np__node_get "$_upsert_descriptor_handle" "${_upsert_descriptor_store}_slots")
  case " $_upsert_descriptor_slots " in
    *" $_upsert_descriptor_slot "*) ;;
    *)
      _upsert_descriptor_slots="${_upsert_descriptor_slots:+$_upsert_descriptor_slots }$_upsert_descriptor_slot"
      np__node_set "$_upsert_descriptor_handle" "${_upsert_descriptor_store}_slots" "$_upsert_descriptor_slots"
      ;;
  esac
  np__node_set "$_upsert_descriptor_handle" "${_upsert_descriptor_store}.$_upsert_descriptor_slot" "$4"
  _upsert_descriptor_list=''
  for _upsert_descriptor_each in $_upsert_descriptor_slots; do
    _upsert_descriptor_value=$(np__node_get "$_upsert_descriptor_handle" "${_upsert_descriptor_store}.$_upsert_descriptor_each")
    [ -n "$_upsert_descriptor_value" ] || continue
    _upsert_descriptor_list="${_upsert_descriptor_list:+$_upsert_descriptor_list,}$_upsert_descriptor_value"
  done
  np__node_set "$_upsert_descriptor_handle" "$_upsert_descriptor_store" "$_upsert_descriptor_list"
  np__stage_facet "$_upsert_descriptor_handle" "$_upsert_descriptor_facet" "[$_upsert_descriptor_list]"
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
    np__upsert_descriptor "$_declare_io_handle" "$NP_FACET_OUTPUT" io_output "$_declare_io_descriptor" "$_declare_io_name"
  else
    np__upsert_descriptor "$_declare_io_handle" "$NP_FACET_INPUT" io_input "$_declare_io_descriptor" "$_declare_io_name"
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

# np__emit_io_edge <handle> <direction> <dataset-id> [descriptor-json] [descriptor-name]
#
# Emit one lineage edge. The direction decides everything else: `out` is
# edge.produces + tracing.output, `in` is edge.consumes + tracing.input.
#
# With a descriptor the io is declared ONCE: it upserts into the node's io
# facet BY NAME (a re-declared name replaces its entry) AND becomes the
# edge's tracing.binding — the same single-source rule as the sibling SDKs.
# Without one, the edge records lineage only.
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
  _emit_io_edge_binding_name=${5:-$_emit_io_edge_binding}

  if [ -n "$_emit_io_edge_binding" ]; then
    np__upsert_descriptor "$_emit_io_edge_handle" "$_emit_io_edge_facet_namespace" "$_emit_io_edge_descriptor_store" \
      "$_emit_io_edge_binding" "$_emit_io_edge_binding_name"
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

  np__emit_io_edge "$_declare_lineage_handle" "$_declare_lineage_direction" "$_declare_lineage_dataset_id" \
    "$_declare_lineage_binding" "$_declare_lineage_name"
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
#
# A single object UPSERTS by its `kind`: re-declaring a kind replaces that
# entry (a live meter re-emitted per heartbeat), while a NEW kind joins the
# list — a later "deploy-log" never erases the "instances-health" meter.
# An array is a FULL declaration and replaces the whole list.
np_trace_affordances() {
  _affordances_handle=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_affordances_handle" || return 0
  _affordances_body=${1:-}
  case "$_affordances_body" in
    \[*)
      np__node_set "$_affordances_handle" affordances_slots ''
      np__node_set "$_affordances_handle" affordances ''
      np__stage_facet "$_affordances_handle" "$NP_FACET_AFFORDANCES" "$_affordances_body"
      ;;
    \{*)
      _affordances_kind=$(printf '%s' "$_affordances_body" \
        | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      # No kind: the object itself is its identity (append-once semantics).
      [ -n "$_affordances_kind" ] || _affordances_kind=$_affordances_body
      np__upsert_descriptor "$_affordances_handle" "$NP_FACET_AFFORDANCES" affordances \
        "$_affordances_body" "$_affordances_kind"
      ;;
    *) np__drop 'affordances' 'body must be a JSON object or array'; return 0 ;;
  esac
  np__flush_foreign "$_affordances_handle"
  return 0
}

# np_trace_progress [handle] <current> <target> [unit]
#
# How far a CONVERGING phase has advanced toward its declared target —
# instances 3 of 10, traffic 40 of 100. Non-negative integers. The unit is a
# number-FORMAT hint from the wire's CLOSED vocabulary (percent, count, bytes,
# milliseconds) — the API rejects the whole EVENT over an unknown unit, and an
# enriched node re-emits its full facet bag, so one bad unit would poison every
# later emission. A word outside the vocabulary is therefore dropped here (the
# noun belongs in the step's title, not the unit).
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
  case "$_progress_unit" in
    '' | percent | count | bytes | milliseconds) ;;
    *)
      np__drop 'progress' "unit '$_progress_unit' is not in the wire vocabulary (percent, count, bytes, milliseconds); omitted"
      _progress_unit=''
      ;;
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

# ---- src/cli.sh ----
# cli.sh — argv to function shim (Phase 2).
