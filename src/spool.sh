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
