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
  _cm_ms=$(date -u +%s%3N 2>/dev/null) || _cm_ms=''
  case "$_cm_ms" in
    '' | *[!0-9]*) _cm_ms='' ;;
  esac
  if [ -n "$_cm_ms" ] && [ "${#_cm_ms}" -ge 13 ]; then
    printf '%s' "$_cm_ms"
    return 0
  fi
  # Second precision. Event ids stay unique via their random bits.
  printf '%s000' "$(date -u +%s)"
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
# flush.sh — the spool drain. Bounded by a wall-clock budget so a dead API can
# never hang process exit; every path returns 0.

NP_TRACE_FLUSH_TIMEOUT="${NP_TRACE_FLUSH_TIMEOUT:-10}"
NP_TRACE_MAX_RETRIES="${NP_TRACE_MAX_RETRIES:-3}"

np__attempts_of() {
  _ao_n=$(cat "$1.attempts" 2>/dev/null || printf '0')
  case "$_ao_n" in
    '' | *[!0-9]*) _ao_n=0 ;;
  esac
  printf '%s' "$_ao_n"
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
  _fl_deadline=$(( $(date +%s) + NP_TRACE_FLUSH_TIMEOUT ))

  for _fl_file in "$NP_TRACE_DIR/spool"/*.json; do
    [ -f "$_fl_file" ] || continue
    if [ "$(date +%s)" -ge "$_fl_deadline" ]; then
      # Budget spent. Remaining events stay on disk for the next flush or a
      # later np_trace_recover; the process exits on time regardless. This is
      # the guarantee that a dead API cannot hang a build.
      return 0
    fi

    _fl_code=$(np__post_event "$_fl_file")
    case "$_fl_code" in
      201 | 200)
        # 200 is an idempotent re-POST of an already-accepted event.
        rm -f "$_fl_file" "$_fl_file.attempts" 2>/dev/null || :
        ;;
      400)
        # A contract violation. Never retried — retrying cannot change it.
        np__fail_event "$_fl_file" "rejected 400"
        ;;
      401 | 403)
        rm -f "$NP_TRACE_DIR/token" 2>/dev/null || :
        np__fail_event "$_fl_file" "unauthorized $_fl_code"
        ;;
      *)
        _fl_n=$(( $(np__attempts_of "$_fl_file") + 1 ))
        if [ "$_fl_n" -gt "$NP_TRACE_MAX_RETRIES" ]; then
          np__fail_event "$_fl_file" "gave up after $_fl_n attempts (last status $_fl_code)"
        else
          printf '%s' "$_fl_n" > "$_fl_file.attempts" 2>/dev/null || :
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
  _ij_h=$(np__resolve_handle "${1:-}")
  np__is_handle "$_ij_h" || return 0
  printf '%s%s%s%s%s' \
    "$NP_CARRIER_VERSION" "$NP_CARRIER_DELIMITER" \
    "$(np__node_get "$_ij_h" trace_id)" "$NP_CARRIER_DELIMITER" \
    "$(np__node_get "$_ij_h" run_id)"
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
  _ex_raw=${1-${NP_TRACE:-}}
  [ -n "$_ex_raw" ] || return 1

  case "$_ex_raw" in
    "$NP_CARRIER_VERSION$NP_CARRIER_DELIMITER"*) ;;
    *) return 1 ;;
  esac
  _ex_rest=${_ex_raw#*"$NP_CARRIER_DELIMITER"}

  # trace_id is up to the next delimiter; run_id is the whole remainder, which
  # may itself contain '~' and '@' but never a delimiter.
  case "$_ex_rest" in
    *"$NP_CARRIER_DELIMITER"*)
      _ex_trace=${_ex_rest%%"$NP_CARRIER_DELIMITER"*}
      _ex_run=${_ex_rest#*"$NP_CARRIER_DELIMITER"}
      ;;
    *)
      _ex_trace=$_ex_rest
      _ex_run=$_ex_rest
      ;;
  esac
  [ -n "$_ex_trace" ] || return 1
  [ -n "$_ex_run" ] || _ex_run=$_ex_trace

  printf '%s %s' "$_ex_trace" "$_ex_run"
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
  _ad_ctx=$(np_trace_extract "${1-${NP_TRACE:-}}") || return 1
  _ad_trace=${_ad_ctx%% *}
  _ad_run=${_ad_ctx#* }

  if ! _ad_why=$(np__trace_id_violation "$_ad_trace"); then
    np__drop 'adopt' "trace_id $_ad_why"
    return 1
  fi
  # An upstream run_id is commonly a DERIVED path (parent~key@attempt.iteration)
  # rather than a named id — the np CLI hands us the step it is running. Accept
  # either: parse it as a node path first, and only fall back to the named-id
  # rules when it has no delimiter.
  if ! np__parse_node_id "$_ad_run" >/dev/null 2>&1; then
    if ! _ad_why=$(np__named_id_violation "$_ad_run"); then
      np__drop 'adopt' "run_id $_ad_why"
      return 1
    fi
  fi

  _ad_h=$(np__handle_new)
  np__node_set "$_ad_h" kind run
  np__node_set "$_ad_h" trace_id "$_ad_trace"
  np__node_set "$_ad_h" run_id "$_ad_run"
  np__node_set "$_ad_h" nrn "${NP_TRACE_NRN:-}"
  np__node_set "$_ad_h" foreign 1
  # started=1 suppresses the lazy `started` emit; closed=0 keeps it usable as a
  # parent for the whole script.
  np__node_set "$_ad_h" started 1
  np__node_set "$_ad_h" closed 0
  np__ambient_set "$_ad_h"
  printf '%s' "$_ad_h"
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
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --message) _er_msg=${2:-}; shift 2 ;;
      --code) _er_code=${2:-}; shift 2 ;;
      --stack-trace) _er_stack=${2:-}; shift 2 ;;
      *)
        if [ -z "$_er_msg" ]; then
          _er_msg=$1
        fi
        shift
        ;;
    esac
  done
  [ -n "$_er_msg" ] || return 0
  np__stage_facet "$_er_h" "$NP_FACET_ERROR" \
    "$(np__json_obj message "$_er_msg" code "$_er_code" stack_trace "$_er_stack")"
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

# The shared body of produces/consumes.
# $1 handle, $2 edge type, $3 io facet namespace, $4 io side key (io_output /
# io_input), $5 dataset id, $6 pointer name, $7 pointer uri.
#
# With a name+uri the io is declared ONCE as a pointer descriptor: it
# accumulates into the node's tracing.input/tracing.output facet AND becomes
# the edge's tracing.binding — the same single-source rule as the sibling
# SDKs. Bare (no pointer) records lineage only.
#
# On a FOREIGN (adopted) node this is an observed fact, exactly like
# np_trace_error: the edge is ours to say, and the staged io facet reaches the
# wire through the foreign re-emit.
np__io_edge() {
  _ie_h=$1
  _ie_type=$2
  _ie_facet=$3
  _ie_side=$4
  _ie_id=$5
  _ie_name=${6:-}
  _ie_uri=${7:-}

  _ie_binding=''
  if [ -n "$_ie_name" ] && [ -n "$_ie_uri" ]; then
    _ie_binding=$(np__json_obj kind pointer name "$_ie_name" uri "$_ie_uri")
    # Append to the side's descriptor list; the facet is re-staged whole each
    # time (last write wins per namespace), so the array only ever grows.
    _ie_list=$(np__node_get "$_ie_h" "$_ie_side")
    if [ -n "$_ie_list" ]; then
      _ie_list="$_ie_list,$_ie_binding"
    else
      _ie_list="$_ie_binding"
    fi
    np__node_set "$_ie_h" "$_ie_side" "$_ie_list"
    np__stage_facet "$_ie_h" "$_ie_facet" "[$_ie_list]"
  fi

  # An edge must not point FROM a node the read model has never seen.
  np_trace_start "$_ie_h"

  if [ -n "$_ie_binding" ]; then
    _ie_data=$(np__json_obj_raw \
      from "$(np__ref_of "$_ie_h")" \
      to "$(np__dataset_ref "$_ie_id")" \
      facets "{$(np__json_str "$NP_FACET_BINDING"):$_ie_binding}")
  else
    _ie_data=$(np__json_obj_raw \
      from "$(np__ref_of "$_ie_h")" \
      to "$(np__dataset_ref "$_ie_id")")
  fi
  np__spool "$_ie_type" "$(np__node_get "$_ie_h" nrn)" "$_ie_data" >/dev/null
  np__flush_foreign "$_ie_h"
  return 0
}

# np_trace_produces [handle] <dataset-id> [--name <n> --uri <locator>]
#
# Declare this node WROTE the dataset. `--name`/`--uri` record the io as a
# pointer descriptor (the artifact's address) on both the node and the edge.
np_trace_produces() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _pr_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_pr_h" || { np__drop 'produces' 'no node in scope'; return 0; }
  _pr_id=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  if [ -z "$_pr_id" ]; then
    np__drop 'produces' 'dataset id is required'
    return 0
  fi
  _pr_name=''
  _pr_uri=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) _pr_name=${2:-}; shift 2 ;;
      --uri) _pr_uri=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  np__io_edge "$_pr_h" "$NP_TYPE_EDGE_PRODUCES" "$NP_FACET_OUTPUT" io_output \
    "$_pr_id" "$_pr_name" "$_pr_uri"
  return 0
}

# np_trace_consumes [handle] <dataset-id> [--name <n> --uri <locator>]
#
# Declare this node READ the dataset; see np_trace_produces.
np_trace_consumes() {
  [ "${NP_TRACE_ENABLED:-1}" = '1' ] || return 0
  _cn_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_cn_h" || { np__drop 'consumes' 'no node in scope'; return 0; }
  _cn_id=${1:-}
  if [ "$#" -gt 0 ]; then
    shift
  fi
  if [ -z "$_cn_id" ]; then
    np__drop 'consumes' 'dataset id is required'
    return 0
  fi
  _cn_name=''
  _cn_uri=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) _cn_name=${2:-}; shift 2 ;;
      --uri) _cn_uri=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  np__io_edge "$_cn_h" "$NP_TYPE_EDGE_CONSUMES" "$NP_FACET_INPUT" io_input \
    "$_cn_id" "$_cn_name" "$_cn_uri"
  return 0
}

# np_trace_affordances [handle] <json>
#
# What this node OFFERS a human to do — a declared fact the UI renders as a
# control (view live logs, switch traffic). One affordance object
# ('{"kind":"deploy-log",...}') or a bare array of them; the wire form is
# always the array.
np_trace_affordances() {
  _af_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_af_h" || return 0
  _af_body=${1:-}
  case "$_af_body" in
    \[*) ;;
    \{*) _af_body="[$_af_body]" ;;
    *) np__drop 'affordances' 'body must be a JSON object or array'; return 0 ;;
  esac
  np__stage_facet "$_af_h" "$NP_FACET_AFFORDANCES" "$_af_body"
  np__flush_foreign "$_af_h"
  return 0
}

# np_trace_progress [handle] <current> <target> [unit]
#
# How far a CONVERGING phase has advanced toward its declared target —
# instances 3 of 10, traffic 40 of 100. Non-negative integers; the optional
# unit names what is counted ("percent", "instances").
np_trace_progress() {
  _pg_h=$(np__resolve_handle "${1:-}")
  if np__is_handle "${1:-}"; then
    shift
  fi
  np__is_handle "$_pg_h" || return 0
  _pg_current=${1:-}
  _pg_target=${2:-}
  _pg_unit=${3:-}
  case "$_pg_current$_pg_target" in
    '' | *[!0-9]*) np__drop 'progress' 'current and target must be non-negative integers'; return 0 ;;
  esac
  [ -n "$_pg_current" ] && [ -n "$_pg_target" ] || {
    np__drop 'progress' 'current and target must be non-negative integers'
    return 0
  }
  np__stage_facet "$_pg_h" "$NP_FACET_PROGRESS" \
    "$(np__json_obj_raw current "$_pg_current" target "$_pg_target" \
        unit "$(if [ -n "$_pg_unit" ]; then np__json_str "$_pg_unit"; fi)")"
  np__flush_foreign "$_pg_h"
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

# ---- src/cli.sh ----
# cli.sh — argv to function shim (Phase 2).
