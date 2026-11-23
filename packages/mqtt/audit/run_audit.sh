#!/bin/sh
# RT-mqtt adversarial audit runner for packages/mqtt.
#
#   sh packages/mqtt/audit/run_audit.sh            # everything
#   RT_SKIP_BENCH=1 sh packages/mqtt/audit/run_audit.sh
#
# 1. 12k-vector three-way differential: Pion vs Go paho.golang/packets v0.23.0 vs Rust
#    rumqttc 0.25.1, joined with OASIS oracle labels (diff/gen_vectors.py, diff/compare.py)
# 2. 4-mode parity (native dbg/rel, wasm32 dbg/rel) of the differential verdict stream
# 3. DoS probes (peak RSS / time): 1-byte drip + sticky, 256 MiB declared length, huge property
#    counts, 5k/32k-level topics, TopicTrie insert/remove churn, phantom PUBREC
# 4. pionc test of the audit package (p0_/p1_/p2_ expected FAIL, control_ expected PASS)
# 5. Benchmark fairness re-run (W1/W2/W2b/W3 + W3 with seeded fast Rust hashers)
# 6. sh scripts/verify.sh packages/mqtt
#
# Every artifact and cache lives under /tmp/rt-mqtt-*; the worktree is never written.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
BIN=/tmp/rt-mqtt-bin
DIFF=/tmp/rt-mqtt-diff
BENCH=/tmp/rt-mqtt-bench
export PION_CACHE_DIR=/tmp/rt-mqtt-pion-cache
export GOCACHE=/tmp/rt-mqtt-gocache GOPROXY=off GOFLAGS=-mod=mod
mkdir -p "$BIN" "$DIFF" "$BENCH/bin"

if [ "$(uname)" = Darwin ]; then TIMEV="-l"; else TIMEV="-v"; fi
rss() { # rss <label> <cmd...>: run, print stdout and peak RSS in KiB
  label=$1; shift
  out=$( { /usr/bin/time $TIMEV "$@" > "$DIFF/rss.out"; } 2>&1 )
  kb=$(printf '%s\n' "$out" | awk '/maximum resident set size/ { v=$1; if ($0 ~ /kbytes/) print $NF; else print int(v/1024) } /Maximum resident set size/ { print $NF }' | head -1)
  printf '%-34s rss=%7s KiB  %s\n' "$label" "$kb" "$(tr '\n' ' ' < "$DIFF/rss.out")"
}

echo "==> [build] Pion audit driver (native --release), Go paho v0.23.0, Rust rumqttc 0.25.1"
pionc build --release -o "$BIN/audit_rel" "$AUDIT_DIR"
rm -rf /tmp/rt-mqtt-go && cp -R "$AUDIT_DIR/diff/go" /tmp/rt-mqtt-go
(cd /tmp/rt-mqtt-go && go build -o "$BIN/go_diff" .)
rm -rf /tmp/rt-mqtt-rust && cp -R "$AUDIT_DIR/diff/rust" /tmp/rt-mqtt-rust
CARGO_TARGET_DIR=/tmp/rt-mqtt-rust-target cargo build --release --locked --offline --quiet \
  --manifest-path /tmp/rt-mqtt-rust/Cargo.toml
cp /tmp/rt-mqtt-rust-target/release/rt_mqtt_diff "$BIN/rust_diff"

echo "==> [1] differential corpus + three-way run"
python3 "$AUDIT_DIR/diff/gen_vectors.py" "$DIFF"
shasum -a 256 "$DIFF/vectors.bin" | sed 's/^/vectors.bin sha256 /'
"$BIN/audit_rel" diff "$DIFF/vectors.bin" > "$DIFF/pion.txt"
"$BIN/go_diff" "$DIFF/vectors.bin" > "$DIFF/go.txt"
"$BIN/rust_diff" "$DIFF/vectors.bin" > "$DIFF/rust.txt" 2> "$DIFF/rust.stderr"
for f in pion go rust; do
  printf '%-5s panics=%s\n' "$f" "$(grep -c ' panic ' "$DIFF/$f.txt" || true)"
done
python3 "$AUDIT_DIR/diff/compare.py" "$DIFF/labels.tsv" "$DIFF/pion.txt" "$DIFF/go.txt" \
  "$DIFF/rust.txt" "$DIFF/out" | tee "$DIFF/summary.md"

echo "==> [2] 4-mode parity (verdict stream + selftest digest)"
for mode in dbg rel wasm_dbg wasm_rel; do
  case $mode in
    dbg) flags="" ;; rel) flags="--release" ;;
    wasm_dbg) flags="--target wasm32" ;; wasm_rel) flags="--target wasm32 --release" ;;
  esac
  # shellcheck disable=SC2086
  d=$(pionc run $flags "$AUDIT_DIR" -- diff "$DIFF/vectors.bin" | shasum -a 256 | cut -c1-16)
  # shellcheck disable=SC2086
  s=$(pionc run $flags "$AUDIT_DIR" -- selftest)
  # shellcheck disable=SC2086
  t=$(pionc run $flags "$AUDIT_DIR" -- deep 32000 | sed 's/ ms=.*//')
  printf '%-9s diff_sha=%s  %s  %s\n' "$mode" "$d" "$s" "$t"
done | tee "$DIFF/4mode.txt"
n=$(awk '{print $2}' "$DIFF/4mode.txt" | sort -u | wc -l | tr -d ' ')
[ "$n" = 1 ] && echo "4-mode: identical verdict streams" || echo "4-mode: MISMATCH"

echo "==> [3] DoS probes"
rss "drip 1k frames" "$BIN/audit_rel" drip 1000
rss "drip 100k frames" "$BIN/audit_rel" drip 100000
rss "bigdecl (Pion)" "$BIN/audit_rel" bigdecl
python3 -c "import struct,sys; b=bytes.fromhex('30ffffff7f'); open(sys.argv[1],'wb').write(bytes([5])+struct.pack('!I',len(b))+b)" "$DIFF/big.bin"
rss "bigdecl (Go paho)" "$BIN/go_diff" "$DIFF/big.bin"
rss "bigdecl (Rust rumqttc)" "$BIN/rust_diff" "$DIFF/big.bin"
for n in 10000 40000 160000; do rss "props $n" "$BIN/audit_rel" props $n; done
rss "deep 5000" "$BIN/audit_rel" deep 5000
rss "deep 32000" "$BIN/audit_rel" deep 32000
rss "trie churn 100k" "$BIN/audit_rel" churn 100000
rss "trie churn 1M" "$BIN/audit_rel" churn 1000000
rss "phantom PUBREC" "$BIN/audit_rel" phantom

echo "==> [4] audit tests (p*_ expected FAIL, control_ expected PASS)"
pionc test --json --only-pkg "$AUDIT_DIR" > "$DIFF/audit_tests.json" 2> "$DIFF/audit_tests.stderr" || true
python3 - "$DIFF/audit_tests.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
bad = 0
for t in d["tests"]:
    want_fail = not t["name"].startswith("control_")
    st = "FAIL" if not t["ok"] else "PASS"
    ok = (not t["ok"]) == want_fail
    bad += not ok
    print("%s %-64s %s" % (st, t["name"], "" if ok else "<-- UNEXPECTED"))
print("total=%d passed=%d failed=%d unexpected=%d" % (d["total"], d["passed"], d["failed"], bad))
EOF

if [ "${RT_SKIP_BENCH:-0}" != 1 ]; then
  echo "==> [5] benchmark fairness (bench binaries rebuilt into $BENCH)"
  python3 "$PKG_DIR/bench/gen_corpus.py" "$BENCH" > /dev/null
  pionc build --release -o "$BENCH/bin/pion" "$PKG_DIR/bench/pion_bench"
  rm -rf "$BENCH/go" && mkdir -p "$BENCH/go" && cp "$PKG_DIR"/bench/go/* "$BENCH/go/"
  (cd "$BENCH/go" && GOFLAGS=-mod=readonly go build -o "$BENCH/bin/go" .)
  for v in siphash foldhash fnv; do
    rm -rf "$BENCH/rust-$v" && mkdir -p "$BENCH/rust-$v"
    cp -R "$PKG_DIR/bench/rust/Cargo.toml" "$PKG_DIR/bench/rust/Cargo.lock" "$PKG_DIR/bench/rust/src" "$BENCH/rust-$v/"
    python3 "$AUDIT_DIR/diff/rust_hasher_variant.py" "$v" "$BENCH/rust-$v"
    lock=--locked; [ "$v" = foldhash ] && lock=""
    # shellcheck disable=SC2086
    CARGO_TARGET_DIR="/tmp/rt-mqtt-rust-bench-$v" cargo build --release $lock --offline --quiet \
      --manifest-path "$BENCH/rust-$v/Cargo.toml"
    cp "/tmp/rt-mqtt-rust-bench-$v/release/mqtt_bench" "$BENCH/bin/rust_$v"
  done
  B=$BENCH/bin
  BC="python3 $ROOT_DIR/scripts/bench_compare.py --warmup 1 --rounds 5"
  $BC --title "W1" --impl "pion=$B/pion w1" --impl "go_paho=$B/go w1" --impl "rust_rumqttc=$B/rust_siphash w1" \
    --baseline rust_rumqttc --ops 200000 --md-out "$BENCH/w1.md" --json-out "$BENCH/w1.json" | grep '^|'
  $BC --title "W2" --impl "pion=$B/pion w2 $BENCH/v5_14.bin $BENCH/v311_all14.bin" \
    --impl "rust_rumqttc=$B/rust_siphash w2 $BENCH/v5_14.bin $BENCH/v311_all14.bin" \
    --baseline rust_rumqttc --ops 500000 --md-out "$BENCH/w2.md" --json-out "$BENCH/w2.json" | grep '^|'
  $BC --title "W2b" --impl "pion=$B/pion w2_v5 $BENCH/v5_all15.bin" --impl "go_paho=$B/go w2_v5 $BENCH/v5_all15.bin" \
    --baseline go_paho --ops 500000 --md-out "$BENCH/w2b.md" --json-out "$BENCH/w2b.json" | grep '^|'
  $BC --title "W3" --impl "pion=$B/pion w3" --impl "go_trie=$B/go w3" \
    --impl "rust_trie_siphash=$B/rust_siphash w3" --impl "rust_trie_foldhash=$B/rust_foldhash w3" \
    --impl "rust_trie_fnv=$B/rust_fnv w3" --baseline rust_trie_siphash --ops 100000 \
    --md-out "$BENCH/w3.md" --json-out "$BENCH/w3.json" | grep '^|'
fi

echo "==> [6] packages/mqtt verify.sh"
sh "$ROOT_DIR/scripts/verify.sh" --allow-dirty "$PKG_DIR" | tail -1
git -C "$ROOT_DIR" status --porcelain --ignored -- "$PKG_DIR" | sed 's/^/DIRTY: /'
echo "RT-mqtt audit run complete: results in $DIFF and $BENCH"
