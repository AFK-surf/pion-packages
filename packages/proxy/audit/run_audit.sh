#!/bin/sh
# Red-team audit of packages/proxy (RT-proxy): one command reproduces every piece of evidence in REPORT.md.
#
#   sh packages/proxy/audit/run_audit.sh [all|build|tests|fuzz|diff|dos|bench]
#
# Exit status (for `all`): 1 while any p0_/p1_/p2_ finding test fails, any control_ test fails,
# the fuzzer reports an invariant violation, or the four build modes disagree; 0 once a fix
# branch closes every finding (no byte of audit/ needs to change). diff / dos / bench are
# reported, not scored (bench only fails on a stdout SHA-256 mismatch).
#
# Needs: pionc ($HOME/.pion/bin, AFK-surf/pion@66d2b4b), node (wasm32 runtime + monoid-login
# reference), go 1.27 (golang.org/x/net v0.62.0 from the module cache or network), python3.
# Every artefact goes to $AUDIT_OUT (default /private/tmp/rt-proxy-audit), never into the worktree.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt-proxy-audit}
BIN="$OUT/bin"
DATA="$OUT/out"
WHAT=${1:-all}
SEED=${FUZZ_SEED:-20261124}
ITERS=${FUZZ_ITERS:-60000}
ROUNDS=${BENCH_ROUNDS:-5}
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PION_CACHE_DIR=${PION_CACHE_DIR:-$OUT/pion-cache}
mkdir -p "$BIN" "$DATA"
FAIL=0

step() { printf '\n==== %s ====\n' "$*"; }

build() {
  step "build: probe (native debug/release + wasm32 debug/release), Go NO_PROXY oracle, W1-W3 bench binaries"
  pionc build -o "$BIN/probe_native_dbg" "$AUDIT_DIR/probe"
  pionc build --release -o "$BIN/probe_native_rel" "$AUDIT_DIR/probe"
  pionc build --target wasm32 -o "$BIN/probe_wasm_dbg.wasm" "$AUDIT_DIR/probe"
  pionc build --release --target wasm32 -o "$BIN/probe_wasm_rel.wasm" "$AUDIT_DIR/probe"
  rm -rf "$OUT/go-oracle" && cp -R "$AUDIT_DIR/diff/go" "$OUT/go-oracle"
  (cd "$OUT/go-oracle" && GOFLAGS=-mod=mod go build -o "$BIN/noproxy_go" .)
  pionc build --release -o "$BIN/pion_proxy_bench" "$PKG_DIR/bench/pion_bench"
  rm -rf "$OUT/go-bench" && cp -R "$PKG_DIR/bench/go" "$OUT/go-bench"
  (cd "$OUT/go-bench" && go build -o "$BIN/go_proxy_bench" .)
}

run_tests() {
  step "pionc test: audit/redteam_test.pion (p0_/p1_/p2_ FAIL = open finding; control_* must PASS)"
  pionc test --json "$AUDIT_DIR" > "$OUT/tests.json" 2> "$OUT/tests.stderr" || true
  python3 -I - "$OUT/tests.json" "$OUT/tests.stderr" <<'EOF' || FAIL=1
import json, re, sys
t = open(sys.argv[1]).read()
i = t.find('{"ok"')
if i < 0:
    print(t[:2000] + open(sys.argv[2]).read()[:2000]); sys.exit(1)
d = json.loads(t[i:])
mine = [x for x in d.get("tests", []) if x["name"].startswith(("p0_", "p1_", "p2_", "control_"))]
if not mine:
    print(t[:2000]); sys.exit(1)
open_findings = [x["name"] for x in mine if not x["ok"] and not x["name"].startswith("control_")]
broken = [x["name"] for x in mine if not x["ok"] and x["name"].startswith("control_")]
for sev in ("p0_", "p1_", "p2_"):
    n = [x for x in mine if x["name"].startswith(sev)]
    print(f"{sev[:2].upper()}: {sum(not x['ok'] for x in n)} open / {len(n)}")
print(f"controls: {sum(x['ok'] for x in mine if x['name'].startswith('control_'))} pass / "
      f"{sum(1 for x in mine if x['name'].startswith('control_'))}")
for x in mine:
    print(("PASS " if x["ok"] else "FAIL ") + x["name"])
print("assertion messages of failing tests:")
for m in re.finditer(r"redteam_test\.pion:(\d+): (.*)", open(sys.argv[2]).read()):
    print(f"  line {m.group(1)}: {m.group(2)[:600]}")
if broken:
    print(f"REGRESSION: control test(s) failed: {broken}")
sys.exit(1 if open_findings or broken else 0)
EOF
}

run_fuzz() {
  step "fuzz: seed=$SEED iters=$ITERS, 9 decoders + proxy URL + NO_PROXY; streaming invariants (prefix/1-byte drip, +32 B pipelined tail, sticky errors, framing) in 4 build modes"
  rc=0
  "$BIN/probe_native_dbg" fuzz "$SEED" "$ITERS" > "$DATA/fuzz_native_dbg.out" || rc=$?
  "$BIN/probe_native_rel" fuzz "$SEED" "$ITERS" > "$DATA/fuzz_native_rel.out" || rc=$?
  node "$WASM_RT" "$BIN/probe_wasm_dbg.wasm" fuzz "$SEED" "$ITERS" > "$DATA/fuzz_wasm_dbg.out" || rc=$?
  node "$WASM_RT" "$BIN/probe_wasm_rel.wasm" fuzz "$SEED" "$ITERS" > "$DATA/fuzz_wasm_rel.out" || rc=$?
  for m in native_dbg native_rel wasm_dbg wasm_rel; do
    printf '%-11s lines=%-7s sha256=%s\n' $m "$(wc -l < "$DATA/fuzz_$m.out" | tr -d ' ')" \
      "$(shasum -a 256 "$DATA/fuzz_$m.out" | cut -d' ' -f1)"
  done
  tail -n 2 "$DATA/fuzz_native_rel.out"
  if cmp -s "$DATA/fuzz_native_rel.out" "$DATA/fuzz_native_dbg.out" &&
    cmp -s "$DATA/fuzz_native_rel.out" "$DATA/fuzz_wasm_dbg.out" &&
    cmp -s "$DATA/fuzz_native_rel.out" "$DATA/fuzz_wasm_rel.out"; then
    echo "4-mode outputs: byte-identical (0 panics / 0 traps: every mode ran to SUMMARY)"
  else
    echo "4-mode outputs: DIFFER"
    FAIL=1
  fi
  grep -q '^SUMMARY iters=' "$DATA/fuzz_wasm_dbg.out" || { echo "wasm_dbg did not finish (trap?)"; FAIL=1; }
  echo "violations by kind (first 3 each):"
  grep '^VIOLATION' "$DATA/fuzz_native_rel.out" | awk '{print $2}' | sort | uniq -c || true
  for k in $(grep '^VIOLATION' "$DATA/fuzz_native_rel.out" | awk '{print $2}' | sort -u); do
    grep "^VIOLATION $k " "$DATA/fuzz_native_rel.out" | head -3 | cut -c1-220
  done
  if [ "$rc" -ne 0 ]; then FAIL=1; fi
}

run_diff() {
  step "differential: proxy URLs vs monoid-login@886d08e (node), NO_PROXY vs golang.org/x/net/http/httpproxy v0.62.0"
  python3 -I "$AUDIT_DIR/diff/gen_corpus.py" "$DATA/corpus"
  "$BIN/probe_native_rel" urls "$DATA/corpus/urls.hex" > "$DATA/urls_pion.out"
  node "$WASM_RT" "$BIN/probe_wasm_rel.wasm" urls "$DATA/corpus/urls.hex" > "$DATA/urls_pion_wasm.out"
  cmp -s "$DATA/urls_pion.out" "$DATA/urls_pion_wasm.out" && echo "urls: native == wasm32" || { echo "urls: native != wasm32"; FAIL=1; }
  node "$AUDIT_DIR/diff/ref_monoid_login.mjs" "$DATA/corpus/urls.hex" > "$DATA/urls_ref.out"
  "$BIN/probe_native_rel" noproxy "$DATA/corpus/noproxy.tsv" > "$DATA/np_pion.out"
  "$BIN/noproxy_go" "$DATA/corpus/noproxy.tsv" > "$DATA/np_go.out"
  python3 -I "$AUDIT_DIR/diff/compare.py" "$DATA/corpus" "$DATA/urls_pion.out" "$DATA/urls_ref.out" \
    "$DATA/np_pion.out" "$DATA/np_go.out" --show 4
}

run_dos() {
  step "DoS: forward-proxy head fed 1 byte per call (each call rescans from byte 0) vs decoded once"
  printf '%-7s %-6s %-26s %s\n' bytes mode result cpu_s
  for n in 8192 16384 32768 65536; do
    for m in drip whole; do
      t=$( { /usr/bin/time -p "$BIN/probe_native_rel" $m $n > "$OUT/dos.txt"; } 2>&1 | awk '/^user/{u=$2} /^sys/{s=$2} END{printf "%.2f", u+s}')
      printf '%-7s %-6s %-26s %s\n' $n $m "$(cut -d' ' -f3 < "$OUT/dos.txt")" "$t"
    done
  done
  echo "(whole = n/64 full decodes of the same head; drip = n decodes of growing prefixes)"
}

run_bench() {
  step "W1/W2/W3 re-run (bench_compare.py --warmup 1 --rounds $ROUNDS, stdout SHA-256 must match)"
  for w in url:200000 socks5:500000 http:100000; do
    m=${w%%:*}
    ops=${w##*:}
    python3 "$ROOT_DIR/scripts/bench_compare.py" --title "W $m" \
      --impl "pion=$BIN/pion_proxy_bench $m" --impl "go_stdlib=$BIN/go_proxy_bench $m" \
      --baseline go_stdlib --warmup 1 --rounds "$ROUNDS" --ops "$ops" \
      --md-out "$DATA/bench_$m.md" --json-out "$DATA/bench_$m.json" > "$DATA/bench_$m.log" 2>&1 || FAIL=1
    grep -E '^\| `|SHA-256|mismatch|ERROR' "$DATA/bench_$m.log" || true
  done
}

case "$WHAT" in
  all) build; run_tests; run_fuzz; run_diff; run_dos; run_bench ;;
  build) build ;;
  tests) run_tests ;;
  fuzz) run_fuzz ;;
  diff) run_diff ;;
  dos) run_dos ;;
  bench) run_bench ;;
  *) echo "usage: $0 [all|build|tests|fuzz|diff|dos|bench]" >&2; exit 2 ;;
esac
step "verdict"
if [ "$FAIL" -ne 0 ]; then
  echo "OPEN FINDINGS / FAILURES: exit 1 (see REPORT.md)"
  exit 1
fi
echo "no open findings: exit 0"
