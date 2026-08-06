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
