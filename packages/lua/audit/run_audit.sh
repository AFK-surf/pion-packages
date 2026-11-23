#!/bin/sh
# RT-lua red-team audit of packages/lua: one command reproduces every piece of evidence in AUDIT_REPORT.md.
#
#   sh packages/lua/audit/run_audit.sh [all|build|tests|diff|dos|bench]
#
# Needs: pionc ($HOME/.pion/bin, AFK-surf/pion@66d2b4b), node (wasm32 runtime), go (gopher-lua v1.1.1
# from the module cache / proxy, -mod=readonly), python3, curl + cc (to build the PUC-Rio Lua 5.4.7 oracle).
# Every artefact goes to $AUDIT_OUT (default /private/tmp/rt-lua-audit); the git worktree stays clean.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt-lua-audit}
BIN="$OUT/bin"
WHAT=${1:-all}
ROUNDS=${BENCH_ROUNDS:-5}
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PION_CACHE_DIR=${PION_CACHE_DIR:-$OUT/pion-cache}
LUA_VER=5.4.7
LUA_SHA=9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30
LUA="$OUT/lua-$LUA_VER/src/lua"
mkdir -p "$BIN"

step() { printf '\n==== %s ====\n' "$*"; }

build() {
  step "build: PUC-Rio Lua $LUA_VER oracle"
  if [ ! -x "$LUA" ]; then
    curl -sSfL -o "$OUT/lua-$LUA_VER.tar.gz" "https://www.lua.org/ftp/lua-$LUA_VER.tar.gz"
    echo "$LUA_SHA  $OUT/lua-$LUA_VER.tar.gz" | shasum -a 256 -c -
    tar -C "$OUT" -xzf "$OUT/lua-$LUA_VER.tar.gz"
    (cd "$OUT/lua-$LUA_VER" && make -s "$( [ "$(uname)" = Darwin ] && echo macosx || echo linux )" >/dev/null)
  fi
  "$LUA" -v
  step "build: Pion driver (native debug/release + wasm32 debug/release), serial"
  pionc build -o "$BIN/drv_dbg" "$AUDIT_DIR/driver"
  pionc build --release -o "$BIN/drv_rel" "$AUDIT_DIR/driver"
  pionc build --target wasm32 -o "$BIN/drv_dbg.wasm" "$AUDIT_DIR/driver"
  pionc build --release --target wasm32 -o "$BIN/drv_rel.wasm" "$AUDIT_DIR/driver"
  step "build: benchmark drivers (Pion --release, Go gopher-lua v1.1.1 -mod=readonly)"
  pionc build --release -o "$BIN/bench_pion" "$AUDIT_DIR/bench/pion"
  (cd "$AUDIT_DIR/bench/go" && go build -mod=readonly -o "$BIN/bench_go" .)
}

run_tests() {
  step "pionc test: redteam_test.pion (p0_*/p1_*/p2_* FAIL = evidence; control_* must PASS)"
  pionc fmt --check "$AUDIT_DIR"
  pionc test --json -p lua_redteam_audit "$AUDIT_DIR" > "$OUT/tests.json" 2> "$OUT/tests.stderr" || true
  python3 - "$OUT/tests.json" <<'PY'
import json, sys
t = open(sys.argv[1]).read()
d = json.loads(t[t.find('{"ok"'):])
print("total=%d passed=%d failed=%d" % (d["total"], d["passed"], d["failed"]))
bad = 0
for x in d["tests"]:
    print(("PASS " if x["ok"] else "FAIL ") + x["name"])
    if x["name"].startswith("control_") and not x["ok"]: bad += 1
    if not x["name"].startswith("control_") and x["ok"]: print("  (finding no longer reproduces: fixed?)")
if bad:
    print("REGRESSION: %d control test(s) failed" % bad); sys.exit(1)
PY
  echo "assertion details: $OUT/tests.stderr"
}

run_diff() {
  step "differential: 434 cases, Pion 4 modes vs PUC-Rio Lua $LUA_VER"
  python3 "$AUDIT_DIR/diff/compare.py" "$AUDIT_DIR/diff" "$BIN" "$LUA" "$OUT/diff" --timeout 40 | tee "$OUT/diff.txt" | head -3
  echo "full report: $OUT/diff.txt  (json: $OUT/diff/results.json)"
}

run_dos() {
  step "DoS / crash / limit-bypass probes, 4 modes (rc -11 = SIGSEGV, -6 = SIGABRT, wasm rc 1 = trap/RangeError)"
  python3 "$AUDIT_DIR/dos/probes.py" "$BIN" "$OUT/dos" --timeout ${DOS_TIMEOUT:-30} | tee "$OUT/dos.txt"
}

run_bench() {
  step "benchmark fairness (W3 variants) + adversarial workloads, --warmup 1 --rounds $ROUNDS, SHA-256 checked"
  sh "$AUDIT_DIR/bench/run_bench.sh" "$BIN" "$OUT/bench" "$ROUNDS"
}

case "$WHAT" in
  build) build ;;
  tests) run_tests ;;
  diff) run_diff ;;
  dos) run_dos ;;
  bench) run_bench ;;
  all) build; run_tests; run_diff; run_dos; run_bench ;;
  *) echo "usage: $0 [all|build|tests|diff|dos|bench]" >&2; exit 2 ;;
esac
