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

# A JSON array of strings from a comma-separated list ("a, b" → ["a","b"]).
# Surrounding whitespace per item is trimmed; empty items are omitted.
np__json_str_array_csv() {
  _ja_out=''
  _ja_rest=$1
  while [ -n "$_ja_rest" ]; do
    case "$_ja_rest" in
      *,*) _ja_item=${_ja_rest%%,*}; _ja_rest=${_ja_rest#*,} ;;
      *) _ja_item=$_ja_rest; _ja_rest='' ;;
    esac
    _ja_item=$(printf '%s' "$_ja_item" | sed 's/^ *//; s/ *$//')
    if [ -n "$_ja_item" ]; then
      if [ -n "$_ja_out" ]; then
        _ja_out="$_ja_out,"
      fi
      _ja_out="$_ja_out$(np__json_str "$_ja_item")"
    fi
  done
  printf '[%s]' "$_ja_out"
}
