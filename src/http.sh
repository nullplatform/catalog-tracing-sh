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
