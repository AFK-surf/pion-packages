#!/bin/sh
# Show one formula through real KaTeX and through Pion texmath, side by side.
# Usage: sh packages/texmath/audit/repro.sh '<tex>' [I|D] [mathml|layout]
# KATEX_PATH must point at node_modules/katex (or `katex` must be resolvable from this directory).
set -eu
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export PATH="$HOME/.pion/bin:$PATH"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/texmath-repro.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
printf '%s %s\n' "${2:-I}" "$1" >"$WORK/case.txt"
pionc build --release "$AUDIT_DIR/diff_driver" -o "$WORK/drv" >/dev/null
if [ "${3:-mathml}" = "layout" ]; then
  echo "katex: $(node "$AUDIT_DIR/katex_layout.mjs" "$WORK/case.txt")"
  echo "pion : $("$WORK/drv" "$WORK/case.txt" layout)"
else
  echo "katex: $(node "$AUDIT_DIR/katex_diff.mjs" "$WORK/case.txt" 2>/dev/null)"
  set +e
  out=$("$WORK/drv" "$WORK/case.txt")
  rc=$?
  echo "pion : $out (exit $rc)"
fi
