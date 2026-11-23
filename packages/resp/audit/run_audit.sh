#!/bin/sh
# Red-team audit suite for packages/resp (see REPORT.md).
#
#   sh packages/resp/audit/run_audit.sh
#
# Builds the Pion probe in four modes (native debug/release, wasm32 debug/release; strictly serial),
# builds the Rust redis-protocol 6.0.0 oracle (--locked), runs every case table under cases/, and prints
# a PASS/FAIL line per failing check plus a summary. Exit status: 0 only if every check passes.
# All artifacts go to $RESP_AUDIT_OUT (default: a fresh mktemp dir); the git worktree is never written.
#
# Environment:
#   PIONC=<path>              pionc binary (default: PATH, then $HOME/.pion/bin/pionc)
#   RESP_AUDIT_OUT=<dir>      output directory (default: mktemp -d)
#   RESP_AUDIT_SKIP_ORACLE=1  skip building/running the Rust oracle (cargo unavailable)
#   RESP_AUDIT_VERBOSE=1      also print every PASS line
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
export PATH="${HOME}/.pion/bin:${HOME}/.cargo/bin:${PATH}"

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  PIONC_BIN=$(command -v pionc || true)
fi
if [ -z "$PIONC_BIN" ] || [ ! -x "$PIONC_BIN" ]; then
  echo "FAIL: pionc not found (set PIONC=...)" >&2
  exit 2
fi
PION_SHARE=$(CDPATH= cd -- "$(dirname -- "$PIONC_BIN")/../share/pion" 2>/dev/null && pwd || true)
WASM_RT="$PION_SHARE/pion_wasm_rt.mjs"
for tool in python3 node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool not found" >&2; exit 2; }
done
[ -f "$WASM_RT" ] || { echo "FAIL: wasm runtime not found at $WASM_RT" >&2; exit 2; }

OUT="${RESP_AUDIT_OUT:-}"
if [ -z "$OUT" ]; then
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/resp-audit.XXXXXX")
fi
mkdir -p "$OUT/hex" "$OUT/bin"
TOOLS="$SCRIPT_DIR/tools"
CASES="$SCRIPT_DIR/cases"
DIRTY_BEFORE=$(git -C "$REPO_ROOT" status --porcelain --ignored -- packages/resp 2>/dev/null || true)

echo "==> resp red-team audit"
echo "    repo:   $REPO_ROOT ($(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?'))"
echo "    pionc:  $("$PIONC_BIN" --version)"
echo "    node:   $(node --version)"
echo "    out:    $OUT"

echo "==> preparing case tables"
for c in decode inline keys redirect slots; do
  python3 "$TOOLS/prep.py" "$CASES/$c.tsv" "$OUT/hex/$c.hex.tsv"
done
python3 "$TOOLS/prep.py" --random-keys "$OUT/hex/keys_random.hex.tsv"

echo "==> building probe (4 modes, serial)"
"$PIONC_BIN" build -o "$OUT/bin/probe_native_dbg" "$SCRIPT_DIR/probe"
"$PIONC_BIN" build --release -o "$OUT/bin/probe_native_rel" "$SCRIPT_DIR/probe"
"$PIONC_BIN" build --target wasm32 -o "$OUT/bin/probe_wasm_dbg.wasm" "$SCRIPT_DIR/probe"
"$PIONC_BIN" build --target wasm32 --release -o "$OUT/bin/probe_wasm_rel.wasm" "$SCRIPT_DIR/probe"

ORACLE_ARG=""
if [ "${RESP_AUDIT_SKIP_ORACLE:-0}" != "1" ]; then
  echo "==> building Rust oracle (redis-protocol 6.0.0, --release --locked)"
  rm -rf "$OUT/oracle-src"
  cp -R "$SCRIPT_DIR/oracle" "$OUT/oracle-src"
  CARGO_TARGET_DIR="$OUT/oracle-target" cargo build --release --locked --quiet \
    --manifest-path "$OUT/oracle-src/Cargo.toml"
  ORACLE="$OUT/oracle-target/release/resp_audit_oracle"
  mkdir -p "$OUT/oracle"
  "$ORACLE" decode "$OUT/hex/decode.hex.tsv" > "$OUT/oracle/decode.oracle"
  "$ORACLE" keys "$OUT/hex/keys.hex.tsv" > "$OUT/oracle/keys.oracle"
  "$ORACLE" keys "$OUT/hex/keys_random.hex.tsv" > "$OUT/oracle/keys_random.oracle"
  ORACLE_ARG="--oracle $OUT/oracle"
fi

echo "==> running native_rel (full: + complexity, RSS stress, 900k-iteration fuzz)"
python3 "$TOOLS/audit.py" run --out "$OUT/native_rel" --hexdir "$OUT/hex" --cases "$CASES" --full -- "$OUT/bin/probe_native_rel"
echo "==> running native_dbg"
python3 "$TOOLS/audit.py" run --out "$OUT/native_dbg" --hexdir "$OUT/hex" --cases "$CASES" -- "$OUT/bin/probe_native_dbg"
echo "==> running wasm_rel"
python3 "$TOOLS/audit.py" run --out "$OUT/wasm_rel" --hexdir "$OUT/hex" --cases "$CASES" -- node "$WASM_RT" "$OUT/bin/probe_wasm_rel.wasm"
echo "==> running wasm_dbg"
python3 "$TOOLS/audit.py" run --out "$OUT/wasm_dbg" --hexdir "$OUT/hex" --cases "$CASES" -- node "$WASM_RT" "$OUT/bin/probe_wasm_dbg.wasm"

if [ -n "$ORACLE_ARG" ]; then
  echo "==> benchmark fairness probes (informational, not judged)"
  python3 "$PKG_DIR/bench/gen_data.py" "$OUT/w1.bin" 200000
  "$ORACLE" w1fair "$OUT/w1.bin" | sed 's/^/    /'
  "$ORACLE" w3split | sed 's/^/    /'
  "$OUT/bin/probe_native_rel" w3split | sed 's/^/    /'
fi

echo "==> judging"
set +e
# shellcheck disable=SC2086
python3 "$TOOLS/audit.py" judge --cases "$CASES" --out "$OUT" --hexdir "$OUT/hex" \
  --modes native_rel,native_dbg,wasm_rel,wasm_dbg $ORACLE_ARG ${RESP_AUDIT_VERBOSE:+--verbose}
RC=$?
set -e

DIRTY_AFTER=$(git -C "$REPO_ROOT" status --porcelain --ignored -- packages/resp 2>/dev/null || true)
if [ "$DIRTY_BEFORE" != "$DIRTY_AFTER" ]; then
  echo "FAIL  worktree changed by the audit run:" >&2
  printf '%s\n' "$DIRTY_AFTER" >&2
  RC=1
else
  echo "PASS  worktree untouched by the audit run"
fi
echo "==> outputs kept in $OUT"
if [ "$RC" -eq 0 ]; then
  echo "AUDIT RESULT: PASS (all checks green)"
else
  echo "AUDIT RESULT: FAIL (open P0/P1/P2 findings, see summary above and REPORT.md)"
fi
exit "$RC"
