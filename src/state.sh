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
