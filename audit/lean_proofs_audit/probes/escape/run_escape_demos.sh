#!/usr/bin/env bash
# Show that two "escape" mutations that pass BOTH unit tests and the proof gate are real bugs.
# Needs the mutated copies produced by mutate.py (default root /private/tmp/rt-lean-audit-mut).
# Usage: run_escape_demos.sh <pion-packages checkout> [mut-root]
set -euo pipefail
REPO="$(cd "${1:?repo}" && pwd)"
MUT="${2:-/private/tmp/rt-lean-audit-mut}"
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.pion/bin:$PATH"
T="$(mktemp -d /private/tmp/rt-lean-audit-escape.XXXXXX)"
trap 'rm -rf "$T"' EXIT
export PION_CACHE_DIR="$T/cas"
demo() { # name pkg mut-id file
  for v in orig mut; do
    if [ "$v" = orig ]; then P="$REPO/packages/$2"; else P="$MUT/$3/$2"; fi
    mkdir -p "$T/$1-$v/src"
    printf '[package]\nname = "d%s"\nversion = "0.1.0"\n\n[dependencies]\n%s = { path = "%s" }\n' "$v" "$2" "$P" > "$T/$1-$v/pion.toml"
    cp "$HERE/$4" "$T/$1-$v/src/main.pion"
    pionc build -o "$T/$1-$v/bin" "$T/$1-$v" >/dev/null
    printf '%-28s %-5s ' "$1" "$v"; "$T/$1-$v/bin" | tr '\n' ' '; echo
  done
}
demo effect-timer-order effect effect-neg-pop effect_timer_order.pion
demo regex-multiline-captures regex regex-neg-pike-eol regex_multiline_captures.pion
demo json5-newline-escape json5 json5-neg-escape json5_newline_escape.pion
