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
