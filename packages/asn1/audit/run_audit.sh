#!/bin/sh
# Red-team audit of packages/asn1: one command reproduces every piece of evidence in REDTEAM_REPORT.md.
#
#   sh packages/asn1/audit/run_audit.sh [all|build|tests|diff|wasm|probe|bench]
#
# Pion `packages/asn1` vs Go 1.27 (crypto/x509 + encoding/asn1 + encoding/pem + cryptobyte) vs
# Rust (der 0.7.10 / spki 0.7 / pkcs8 0.10 / x509-parser 0.16.0 / pem 3.0.6 / rustls-webpki 0.103,
# --release). Real keys and certificates come from the local OpenSSL 3.x.
# Needs: pionc ($HOME/.pion/bin), node (wasm32 runtime), cargo (crates cached or network), go,
# python3, openssl. Every build artefact and generated corpus goes to $AUDIT_OUT
# (default /private/tmp/rt-asn1), never into the git worktree.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt-asn1}
BIN="$OUT/bin"
DATA="$OUT/out"
WHAT=${1:-all}
ROUNDS=${BENCH_ROUNDS:-5}
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export GOFLAGS=${GOFLAGS:--mod=mod}
mkdir -p "$BIN" "$DATA"

step() { printf '\n==== %s ====\n' "$*"; }

build() {
  step "build: pion oracle (native debug/release + wasm32 debug/release)"
  pionc build --release -o "$BIN/oracle_pion" "$AUDIT_DIR/oracle"
  pionc build -o "$BIN/oracle_pion_debug" "$AUDIT_DIR/oracle"
  pionc build --release --target wasm32 -o "$BIN/oracle_pion.wasm" "$AUDIT_DIR/oracle"
  pionc build --target wasm32 -o "$BIN/oracle_pion_debug.wasm" "$AUDIT_DIR/oracle"
  step "build: go oracle (go1.27 crypto/x509, x/crypto/cryptobyte)"
  rm -rf "$OUT/go-build" && cp -R "$AUDIT_DIR/diff/go" "$OUT/go-build"
  (cd "$OUT/go-build" && go build -o "$BIN/oracle_go" .)
  step "build: rust oracle (der / x509-parser / rustls-webpki, --release)"
  rm -rf "$OUT/rust-build" && cp -R "$AUDIT_DIR/diff/rust" "$OUT/rust-build"
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --release --quiet --manifest-path "$OUT/rust-build/Cargo.toml"
  cp "$OUT/rust-target/release/oracle_rust" "$BIN/oracle_rust"
}

run_tests() {
  step "pionc test: audit/redteam_test.pion (p0_/p1_/p2_ FAIL = evidence; control_* must PASS)"
  # pionc exits non-zero when a test fails; that is the expected outcome here.
  pionc test --json "$AUDIT_DIR" > "$OUT/tests.json" 2> "$OUT/tests.stderr" || true
  python3 - "$OUT/tests.json" "$OUT/tests.stderr" <<'EOF'
import json, re, sys
t = open(sys.argv[1]).read()
d = json.loads(t[t.find('{"ok"'):])
why = {}
for m in re.finditer(r"redteam_test\.pion:(\d+): (.*)", open(sys.argv[2]).read()):
    why.setdefault(m.group(2), m.group(1))
mine = [x for x in d["tests"] if x["name"].startswith(("p0_", "p1_", "p2_", "control_"))]
print(f"audit tests={len(mine)} passed={sum(x['ok'] for x in mine)} failed={sum(not x['ok'] for x in mine)}")
bad = 0
for x in mine:
    print(("PASS " if x["ok"] else "FAIL ") + x["name"])
    if not x["ok"] and x["name"].startswith("control_"):
        bad += 1
print("assertion messages of failing tests:")
for msg, line in sorted(why.items(), key=lambda kv: int(kv[1])):
    print(f"  line {line}: {msg}")
if bad:
    print(f"REGRESSION: {bad} control test(s) failed")
    sys.exit(1)
EOF
}

run_diff() {
  step "corpus: typed DER mutations + X.509 attacks + hostnames + PEM + SPKI/PKCS#8 (OpenSSL keys)"
  python3 -I "$AUDIT_DIR/diff/gen_corpus.py" "$DATA"
  step "3-way differential: pion vs go vs rust"
  for o in pion go rust; do "$BIN/oracle_$o" vectors "$DATA/corpus.tsv" > "$DATA/$o.out"; done
  python3 -I "$AUDIT_DIR/diff/compare.py" "$DATA/pion.out" "$DATA/go.out" "$DATA/rust.out" --show 8 --md "$DATA/diff.md" | sed -n '1,30p'
  echo "(full listing: $DATA/diff.md)"
}

run_wasm() {
  step "4-mode consistency: native debug/release + wasm32 debug/release (node) over the whole corpus"
  "$BIN/oracle_pion" vectors "$DATA/corpus.tsv" > "$DATA/m_native_release.out"
  "$BIN/oracle_pion_debug" vectors "$DATA/corpus.tsv" > "$DATA/m_native_debug.out"
  node "$WASM_RT" "$BIN/oracle_pion.wasm" vectors "$DATA/corpus.tsv" > "$DATA/m_wasm_release.out"
  node "$WASM_RT" "$BIN/oracle_pion_debug.wasm" vectors "$DATA/corpus.tsv" > "$DATA/m_wasm_debug.out"
  for m in native_release native_debug wasm_release wasm_debug; do
    printf '%-15s lines=%s sha256=%s\n' "$m" "$(wc -l < "$DATA/m_$m.out" | tr -d ' ')" \
      "$(shasum -a 256 "$DATA/m_$m.out" | cut -c1-16)"
  done
  if cmp -s "$DATA/m_native_release.out" "$DATA/m_wasm_release.out" &&
    cmp -s "$DATA/m_native_release.out" "$DATA/m_native_debug.out" &&
    cmp -s "$DATA/m_native_release.out" "$DATA/m_wasm_debug.out"; then
    echo "4-mode outputs: byte-identical"
  else
    echo "4-mode outputs: DIFFER"
    return 1
  fi
}

run_probe() {
  step "deep-nesting probe: parse then drop n nested SEQUENCEs with max_depth lifted (139 = SIGSEGV)"
  for n in 1000 8000 12000 50000 60000 100000; do
    for m in native wasm; do
      if [ $m = native ]; then
        "$BIN/oracle_pion" deep $n $((n + 1)) parse > "$OUT/probe.txt" 2>&1 && rc=0 || rc=$?
      else
        node "$WASM_RT" "$BIN/oracle_pion.wasm" deep $n $((n + 1)) parse > "$OUT/probe.txt" 2>&1 && rc=0 || rc=$?
      fi
      r=$(grep -E 'parsed|dropped|RangeError' "$OUT/probe.txt" | cut -c1-60 | tr '\n' ' ')
      printf '%-7s n=%-7s rc=%-4s %s\n' $m $n $rc "$r"
    done
  done
}

run_bench() {
  step "adversarial-shape benchmarks (bench_compare.py, --rounds $ROUNDS, stdout SHA-256 must match)"
  python3 -I "$AUDIT_DIR/diff/gen_bench.py" "$DATA/bench"
  for shape in real many_san many_rdn many_ext big_rsa_cert; do
    f="$DATA/bench/$shape.derbin"
    it=$(cat "$DATA/bench/$shape.iters")
    python3 "$ROOT_DIR/scripts/bench_compare.py" \
      --title "asn1 adversarial shape: $shape" \
      --impl "pion=$BIN/oracle_pion certs $f $it" \
      --impl "go_x509=$BIN/oracle_go certs $f $it" \
      --impl "rust_x509=$BIN/oracle_rust certs $f $it" \
      --baseline go_x509 --warmup 1 --rounds "$ROUNDS" \
      --md-out "$DATA/bench/$shape.md" --json-out "$DATA/bench/$shape.json" 2>&1 | grep -E '^\| |SHA|mismatch|ERROR' || true
  done
  step "performance cliff: one certificate with N distinct extensions (duplicate-OID check is O(N^2))"
  for n in 1000 4000 16000 64000; do
    f="$DATA/bench/ext_$n.derbin"
    printf 'N=%-6s bytes=%-8s' $n "$(wc -c < "$f" | tr -d ' ')"
    for o in pion go rust; do
      t=$( { /usr/bin/time -p "$BIN/oracle_$o" certs "$f" 1 > /dev/null; } 2>&1 | awk '/^user/{u=$2} /^sys/{s=$2} END{printf "%.2f", u+s}')
      printf ' %s_cpu=%ss' $o "$t"
    done
    echo
  done
  step "performance cliff: encode_der_element on n nested SEQUENCEs (max_depth lifted)"
  for n in 5000 10000 20000 40000; do
    for ph in parse encode; do
      t=$( { /usr/bin/time -p "$BIN/oracle_pion" deep $n $((n + 1)) $ph > /dev/null; } 2>&1 | awk '/^user/{u=$2} /^sys/{s=$2} END{printf "%.2f", u+s}')
      printf 'n=%-6s %-6s cpu=%ss\n' $n $ph "$t"
    done
  done
}

case "$WHAT" in
  all) build; run_tests; run_diff; run_wasm; run_probe; run_bench ;;
  build) build ;;
  tests) run_tests ;;
  diff) run_diff ;;
  wasm) run_wasm ;;
  probe) run_probe ;;
  bench) run_bench ;;
  *) echo "usage: $0 [all|build|tests|diff|wasm|probe|bench]" >&2; exit 2 ;;
esac
