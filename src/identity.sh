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
