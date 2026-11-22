#!/bin/sh
# Red-team audit of packages/cbor (Pion) vs Go fxamacker/cbor/v2 v2.9.0 vs Rust ciborium 0.2.2.
#
#   sh packages/cbor/audit/run_audit.sh            # full run (~4-6 min on an M-series Mac)
#   QUICK=1 sh packages/cbor/audit/run_audit.sh    # skip the 131072-pair quadratic one-shots
#
# Needs: pionc ($HOME/.pion/bin), go >= 1.24, cargo, python3. Network for the first go/cargo fetch.
# All builds, inputs and reports go to $AUDIT_OUT (default /tmp/pion-cbor-audit-$USER); the
# git worktree is never written to.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CBOR_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$CBOR_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/tmp/pion-cbor-audit-$(id -un)}
BIN="$OUT/bin"
ADV="$OUT/adv"
QUICK=${QUICK:-0}
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$BIN" "$ADV"

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

section "0. Build (Pion --release, Go, Rust --release) -> $BIN"
pionc build --release -o "$BIN/pion_probe" "$AUDIT_DIR/probe"
pionc build --release -o "$BIN/pion_encode" "$CBOR_DIR/bench/pion_encode"
pionc build --release -o "$BIN/pion_decode" "$CBOR_DIR/bench/pion_decode"
rm -rf "$OUT/go-build" && mkdir -p "$OUT/go-build"
cp -R "$AUDIT_DIR/go/." "$OUT/go-build/"
cp -R "$CBOR_DIR/bench/go/cmd/bench_encode" "$CBOR_DIR/bench/go/cmd/bench_decode" "$OUT/go-build/cmd/"
(cd "$OUT/go-build" && go mod tidy >/dev/null 2>&1 && for c in probe bench bench_encode bench_decode bench_encode_struct bench_decode_struct deepenc; do
  go build -o "$BIN/go_$c" "./cmd/$c"; done)
rm -rf "$OUT/rust-build" && cp -R "$AUDIT_DIR/rust" "$OUT/rust-build"
CARGO_TARGET_DIR="$OUT/rust-target" cargo build -q --release --manifest-path "$OUT/rust-build/Cargo.toml"
cp "$OUT/rust-target/release/rust_probe" "$OUT/rust-target/release/rust_bench" "$BIN/"
python3 "$AUDIT_DIR/gen_adversarial.py" "$ADV"
python3 "$CBOR_DIR/bench/gen_corpus.py" "$OUT/corpus_2000.cbor" 2000

section "1. Red-team unit tests: pionc test packages/cbor/audit (every redteam_* failure is a finding)"
(cd "$CBOR_DIR" && pionc test --json audit > "$OUT/redteam_test.json" 2> "$OUT/redteam_test.stderr") || true
python3 - "$OUT/redteam_test.json" <<'PY' || true
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
mine = [t for t in d["tests"] if t["pkg"] == "cbor_audit"]
print("cbor_audit: %d tests, %d FAILED (findings), %d passed (controls)" % (
    len(mine), sum(not t["ok"] for t in mine), sum(t["ok"] for t in mine)))
for t in mine:
    print("  %-6s %s" % ("FAIL" if not t["ok"] else "pass", t["name"]))
PY
echo "assertion messages:"; sed 's|^.*/audit/|  |' "$OUT/redteam_test.stderr"

section "2. Targeted-vector differential (RFC 8949 / CTAP2 corner cases)"
python3 "$AUDIT_DIR/diff_vectors.py" "$BIN/pion_probe" "$BIN/go_probe" "$BIN/rust_probe" "$OUT/vec"

section "3. Mutation fuzz differential (10,000 inputs, seed 8949)"
python3 "$AUDIT_DIR/fuzz_diff.py" "$BIN/pion_probe" "$BIN/go_probe" "$BIN/rust_probe" "$OUT/fuzz" 10000 8949 \
  | grep -v '^ *\(in=\|pion=\|go  =\)' || true

section "4. Crash probes: recursion depth (fxamacker accepts MaxNestedLevels up to 65535)"
for n in 20000 30000 40000 65000; do
  python3 -c "print('81'*$n+'00')" > "$OUT/deep_arr_$n.hex"
  python3 -c "print('a100'*$n+'00')" > "$OUT/deep_map_$n.hex"
  python3 "$AUDIT_DIR/oneshot.py" "pion decode [..] depth $n (max_depth=65535)" 60 "$BIN/pion_probe" depth=65535 "$OUT/deep_arr_$n.hex"
  python3 "$AUDIT_DIR/oneshot.py" "go   decode [..] depth $n (MaxNestedLevels=65535)" 60 "$BIN/go_probe" depth=65535 "$OUT/deep_arr_$n.hex"
  python3 "$AUDIT_DIR/oneshot.py" "pion decode {0:..} depth $n (max_depth=65535)" 60 "$BIN/pion_probe" depth=65535 "$OUT/deep_map_$n.hex"
done
for n in 10000 50000 100000 1000000; do
  python3 "$AUDIT_DIR/oneshot.py" "pion encode n-deep array (no depth option) n=$n" 60 "$BIN/pion_probe" "deepenc=$n"
  python3 "$AUDIT_DIR/oneshot.py" "go   encode n-deep array n=$n" 60 "$BIN/go_deepenc" "$n"
done

section "5. DoS one-shots: 131072-pair maps (fxamacker default MaxMapPairs; ~650 KB inputs)"
if [ "$QUICK" = 1 ]; then
  echo "(QUICK=1: skipped)"
else
  for f in map_131072_uint_random map_131072_uint_indef; do
    python3 "$AUDIT_DIR/oneshot.py" "pion dupdec $f" 300 "$BIN/pion_probe" bench dupdec "$ADV/$f.cbor" 1
    python3 "$AUDIT_DIR/oneshot.py" "go   dupdec $f (DupMapKeyEnforcedAPF)" 300 "$BIN/go_bench" dupdec "$ADV/$f.cbor" 1
  done
  for f in map_131072_uint_shellkiller map_131072_bstr_shellkiller map_131072_uint_random map_131072_text_random; do
    for m in enc_det enc_ctap2; do
      python3 "$AUDIT_DIR/oneshot.py" "pion $m $f" 300 "$BIN/pion_probe" bench $m "$ADV/$f.cbor" 1
      python3 "$AUDIT_DIR/oneshot.py" "go   $m $f" 300 "$BIN/go_bench" $m "$ADV/$f.cbor" 1
      python3 "$AUDIT_DIR/oneshot.py" "rust $m $f" 300 "$BIN/rust_bench" $m "$ADV/$f.cbor" 1
    done
  done
fi

section "6. Adversarial head-to-head benchmarks (scripts/bench_compare.py, SHA-256 verified)"
bc() { python3 "$ROOT_DIR/scripts/bench_compare.py" --warmup 1 --rounds 5 --baseline go "$@" | sed -n '/^| Impl/,/^_SHA/p'; }
P="$BIN/pion_probe bench"; G="$BIN/go_bench"; R="$BIN/rust_bench"
for spec in \
  "dupdec map_16384_uint_random 1" "dupdec map_16384_uint_indef 1" \
  "enc_det map_16384_uint_shellkiller 1" "enc_ctap2 map_16384_uint_shellkiller 1" \
  "enc_det map_16384_bstr_shellkiller 1" "enc_ctap2 map_16384_bstr_shellkiller 1" \
  "enc_det map_131072_uint_random 1" "enc_det map_131072_text_random 1" \
  "dec bstr_64MiB 3" "dec tstr_64MiB 3" "dec array_131072_f64 20" "dec map_131072_text_random 20" \
  "dec indef_bstr_1M_chunks 5"; do
  set -- $spec
  echo; echo "### $1 $2 (x$3)"
  if [ "$1" = dupdec ]; then
    bc --title "$1 $2" --impl "pion=$P $1 $ADV/$2.cbor $3" --impl "go=$G $1 $ADV/$2.cbor $3"
  else
    bc --title "$1 $2" --impl "pion=$P $1 $ADV/$2.cbor $3" --impl "go=$G $1 $ADV/$2.cbor $3" --impl "rust=$R $1 $ADV/$2.cbor $3"
  fi
done

section "7. Fairness of packages/cbor/bench: idiomatic Go (typed structs) on the official workloads"
echo "### Workload 1: deterministic encode, 50k records (byte-identical output)"
bc --title "enc" --ops 50000 --impl "pion=$BIN/pion_encode" --impl "go=$BIN/go_bench_encode_struct" \
  --impl "go_map_any=$BIN/go_bench_encode"
B=$(( $(wc -c < "$OUT/corpus_2000.cbor") * 40 ))
echo; echo "### Workload 2: decode + walk, 80k records (identical nodes/checksum)"
bc --title "dec" --ops 80000 --bytes "$B" --impl "pion=$BIN/pion_decode $OUT/corpus_2000.cbor" \
  --impl "go=$BIN/go_bench_decode_struct $OUT/corpus_2000.cbor" --impl "go_map_any=$BIN/go_bench_decode $OUT/corpus_2000.cbor"

section "Done. Artifacts in $OUT"
