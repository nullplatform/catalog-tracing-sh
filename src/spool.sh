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
