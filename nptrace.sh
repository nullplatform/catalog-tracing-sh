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
# wire.sh — contract constants, ported from the wire contract.

# ---- src/state.sh ----
# state.sh — the on-disk node registry.

# ---- src/spool.sh ----
# spool.sh — the emit hot path.

# ---- src/http.sh ----
# http.sh — the only module that touches the network.

# ---- src/flush.sh ----
# flush.sh — the spool drain.

# ---- src/api.sh ----
# api.sh — the public producer surface.

# ---- src/cli.sh ----
# cli.sh — argv to function shim (Phase 2).
