#!/bin/sh
# Concatenate src modules into the single distributable nptrace.sh.
set -eu
OUT=${1:-nptrace.sh}
MODULES='header compat json uuid identity wire state spool http flush propagation api cli'
{
  for module in $MODULES; do
    printf '\n# ---- src/%s.sh ----\n' "$module"
    # Strip per-module shebangs; only the built artifact carries one.
    sed '1{/^#!/d;}' "src/$module.sh"
  done
} > "$OUT.tmp"
# The artifact keeps a shebang of its own so it is directly executable.
{
  printf '#!/bin/sh\n'
  cat "$OUT.tmp"
} > "$OUT.tmp2"
mv "$OUT.tmp2" "$OUT"
rm -f "$OUT.tmp"
chmod +x "$OUT"
printf 'built %s (%s lines)\n' "$OUT" "$(wc -l < "$OUT" | tr -d ' ')"
