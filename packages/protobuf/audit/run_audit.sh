#!/bin/sh
# Red-team audit of packages/protobuf (Pion) vs Go google.golang.org/protobuf v1.36.6
# (+ bufbuild/protocompile v0.14.1 as the protoc-equivalent .proto compiler) vs Rust prost 0.13.5.
#
#   sh packages/protobuf/audit/run_audit.sh            # full run (~3 min on an M-series Mac)
#   QUICK=1 sh packages/protobuf/audit/run_audit.sh    # skip the slow quadratic one-shots
#
# Needs: pionc ($HOME/.pion/bin), node (wasm32 runs), go >= 1.24, cargo, python3.
# Network for the first go/cargo fetch. Every build, cache, input and log goes to $AUDIT_OUT
# (default /private/tmp/rt-protobuf); the git worktree is never written to.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt-protobuf}
BIN="$OUT/bin"
ADV="$OUT/adv"
QUICK=${QUICK:-0}
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export GOPATH="$OUT/gopath" GOCACHE="$OUT/gocache" GOMODCACHE="$OUT/gomodcache" GOFLAGS=-modcacherw
export CARGO_TARGET_DIR="$OUT/rust-target" PYTHONDONTWRITEBYTECODE=1
mkdir -p "$BIN" "$ADV"
ONESHOT="python3 $AUDIT_DIR/oneshot.py"

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

section "0. Build (Pion --release native + wasm32, Go oracle, Rust prost oracle, official bench) -> $BIN"
pionc build --release -o "$BIN/pion_probe" "$AUDIT_DIR/probe"
pionc build --release --target wasm32 -o "$BIN/pion_probe.wasm" "$AUDIT_DIR/probe"
printf '#!/bin/sh\nexec node "%s" "%s" "$@"\n' "$HOME/.pion/share/pion/pion_wasm_rt.mjs" "$BIN/pion_probe.wasm" > "$BIN/pion_probe_wasm"
chmod +x "$BIN/pion_probe_wasm"
rm -rf "$OUT/go-build" && cp -R "$AUDIT_DIR/go" "$OUT/go-build"
(cd "$OUT/go-build" && go build -o "$BIN/go_oracle" ./cmd/oracle)
rm -rf "$OUT/rust-build" && cp -R "$AUDIT_DIR/rust" "$OUT/rust-build"
cargo build -q --release --locked --manifest-path "$OUT/rust-build/Cargo.toml"
cp "$CARGO_TARGET_DIR/release/rust_oracle" "$BIN/"
# official packages/protobuf/bench binaries (for the fairness section), built out of tree
pionc build --release -o "$BIN/pion_bench" "$PKG_DIR/bench/pion_bench"
rm -rf "$OUT/obench" && mkdir -p "$OUT/obench" && cp -R "$PKG_DIR/bench/rust" "$PKG_DIR/bench/go" "$OUT/obench/"
cargo build -q --release --manifest-path "$OUT/obench/rust/Cargo.toml"
cp "$CARGO_TARGET_DIR/release/protobuf_bench_rust" "$BIN/official_rust_bench"
(cd "$OUT/obench/go" && go mod tidy >/dev/null 2>&1 && go build -o "$BIN/official_go_bench" .)
python3 "$AUDIT_DIR/gen_adversarial.py" "$ADV"
python3 "$PKG_DIR/bench/gen_corpus.py" "$ADV/spans_2000.bin" 2000

section "1. Red-team unit tests: pionc test packages/protobuf/audit (every redteam_* FAIL is a finding)"
(cd "$PKG_DIR" && pionc test --json audit > "$OUT/redteam_test.json" 2> "$OUT/redteam_test.stderr") || true
python3 - "$OUT/redteam_test.json" <<'PY' || true
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
mine = [t for t in d["tests"] if t["pkg"] == "protobuf_audit"]
print("protobuf_audit: %d tests, %d FAILED (findings), %d passed (controls)" % (
    len(mine), sum(not t["ok"] for t in mine), sum(t["ok"] for t in mine)))
for t in mine:
    print("  %-6s %s" % ("FAIL" if not t["ok"] else "pass", t["name"]))
PY
echo "assertion messages:"; sed 's|^.*/audit/|  |' "$OUT/redteam_test.stderr"

section "2. Targeted-vector differential (wire 3-way, DynamicMessage/JSON vs dynamicpb/protojson, .proto vs protocompile)"
python3 "$AUDIT_DIR/diff_vectors.py" "$BIN/pion_probe" "$BIN/go_oracle" "$BIN/rust_oracle" "$OUT/vec" | tee "$OUT/diff_vectors.md" | grep -E 'DIFF|^\*\*Summary'

section "3. Mutation fuzz differential: 6,000+ wire inputs + 2,000 .proto files, Pion native vs wasm32 vs Go"
python3 "$AUDIT_DIR/fuzz_diff.py" "$BIN/pion_probe" "$BIN/pion_probe_wasm" "$BIN/go_oracle" "$OUT/fuzz" 6000 2000 20261123 \
  | tee "$OUT/fuzz_diff.md" | sed -n '/^## Wire/,/^### /p;/^## .proto/,/^### /p;/robustness verdict/p'

section "4. Crash probes: recursion (native 8 MiB stack, wasm32 via node)"
echo "| probe | wall | status | peak RSS | first line |"
for n in 100 1000 4000 5000 50000; do
  $ONESHOT "pion native deepdec n=$n (max_depth=n+10)" 60 "$BIN/pion_probe" deepdec $n
done
$ONESHOT "go deepdec n=50000 (RecursionLimit=n+10)" 60 "$BIN/go_oracle" deepdec 50000
for n in 1000 20000 25000 50000; do
  $ONESHOT "pion native deepenc n=$n (no options; build + drop)" 60 "$BIN/pion_probe" deepenc $n
done
$ONESHOT "pion native deepgroup n=50000 (max_depth=n+10)" 60 "$BIN/pion_probe" deepgroup 50000
for n in 100 300 500; do
  $ONESHOT "pion wasm32 deepdec n=$n" 60 "$BIN/pion_probe_wasm" deepdec $n
done
for n in 700 1000; do
  $ONESHOT "pion wasm32 deepenc n=$n (no options)" 60 "$BIN/pion_probe_wasm" deepenc $n
done
$ONESHOT "pion wasm32 deepgroup n=2000" 60 "$BIN/pion_probe_wasm" deepgroup 2000

section "5. DoS one-shots (single record, DEFAULT DecodeOptions where noted)"
echo "| probe | wall | status | peak RSS | first line |"
python3 -c "
import sys; sys.path.insert(0, '$AUDIT_DIR')
from pbvec import ld, vi
open('$ADV/merge_unknown_49999.hex', 'w').write((ld(1, vi(99, 1)) * 49999).hex() + '\n')
"
if [ "$QUICK" = 1 ]; then
  echo "(QUICK=1: skipped the 49,999-occurrence default-options merge)"
else
  $ONESHOT "pion decode_dynamic_default merge_unknown x49999 (250 KB)" 300 "$BIN/pion_probe" dyn "$ADV/merge.proto" Outer "$ADV/merge_unknown_49999.hex"
fi
$ONESHOT "go   proto.Unmarshal merge_unknown x49999 (250 KB)" 300 "$BIN/go_oracle" dyn "$ADV/merge.proto" Outer "$ADV/merge_unknown_49999.hex"
for n in 5000 10000 20000 40000; do
  for k in unknown known; do
    $ONESHOT "pion merge_${k}_$n" 300 "$BIN/pion_probe" bench dec "$ADV/merge.proto" Outer "$ADV/merge_${k}_$n.bin" 1
    $ONESHOT "go   merge_${k}_$n" 300 "$BIN/go_oracle" bench dec "$ADV/merge.proto" Outer "$ADV/merge_${k}_$n.bin" 1
  done
done
for t in 500 2000 4000; do
  $ONESHOT "pion bigschema_$t (20k Leaf, 80 KB)" 300 "$BIN/pion_probe" bench dec "$ADV/bigschema_$t.proto" big.v1.Root "$ADV/bigschema_$t.bin" 1
  $ONESHOT "go   bigschema_$t (20k Leaf, 80 KB)" 300 "$BIN/go_oracle" bench dec "$ADV/bigschema_$t.proto" big.v1.Root "$ADV/bigschema_$t.bin" 1
done
for f in 2000 8000 16000; do
  $ONESHOT "pion wide_$f (control)" 300 "$BIN/pion_probe" bench dec "$ADV/wide_$f.proto" W "$ADV/wide_$f.bin" 1
  $ONESHOT "go   wide_$f (control)" 300 "$BIN/go_oracle" bench dec "$ADV/wide_$f.proto" W "$ADV/wide_$f.bin" 1
done
$ONESHOT "pion parse schema, 1 message x 18000 fields" 60 "$BIN/pion_probe" schema "$ADV/schema_fields_18000.proto"
$ONESHOT "go   parse schema, 1 message x 18000 fields" 60 "$BIN/go_oracle" schema "$ADV/schema_fields_18000.proto"

section "6. Adversarial + DynamicMessage head-to-head benchmarks (scripts/bench_compare.py, SHA-256 verified)"
bc() { python3 "$ROOT_DIR/scripts/bench_compare.py" --warmup 1 --rounds 5 --baseline go "$@" | sed -n '/^| Impl/,/^_SHA/p'; }
P="$BIN/pion_probe bench"; G="$BIN/go_oracle bench"
SB=$(( $(wc -c < "$ADV/spans_2000.bin") * 20 ))
for m in dec decjson roundtrip; do
  echo; echo "### OTel spans, DynamicMessage $m vs dynamicpb (2,000 spans x 20)"
  bc --title "spans $m" --ops 40000 --bytes "$SB" --impl "pion=$P $m $ADV/spans.proto Span $ADV/spans_2000.bin 20" \
    --impl "go=$G $m $ADV/spans.proto Span $ADV/spans_2000.bin 20"
done
for m in decjson roundtrip; do
  echo; echo "### map<string,int64> with 50,000 distinct entries: $m (x5)"
  bc --title "map $m" --ops 250000 --impl "pion=$P $m $ADV/map.proto M $ADV/map_50000_distinct.bin 5" \
    --impl "go=$G $m $ADV/map.proto M $ADV/map_50000_distinct.bin 5"
done
echo; echo "### merge_unknown_10000 (40 KB, quadratic merge)"
bc --title "merge" --impl "pion=$P dec $ADV/merge.proto Outer $ADV/merge_unknown_10000.bin 1" \
  --impl "go=$G dec $ADV/merge.proto Outer $ADV/merge_unknown_10000.bin 1"
echo; echo "### bigschema_2000 (80 KB, per-occurrence schema-wide type search)"
bc --title "bigschema" --impl "pion=$P dec $ADV/bigschema_2000.proto big.v1.Root $ADV/bigschema_2000.bin 1" \
  --impl "go=$G dec $ADV/bigschema_2000.proto big.v1.Root $ADV/bigschema_2000.bin 1"

section "7. Fairness: re-run the official packages/protobuf/bench workloads (baseline rust)"
python3 "$PKG_DIR/bench/gen_corpus.py" "$ADV/spans_2000.pb" 2000
for w in decode_spans encode_spans packed_numeric; do
  arg=""; [ "$w" = decode_spans ] && arg="$ADV/spans_2000.pb"
  echo; echo "### official $w"
  python3 "$ROOT_DIR/scripts/bench_compare.py" --warmup 1 --rounds 5 --baseline rust --title "$w" \
    --impl "pion=$BIN/pion_bench $w $arg" --impl "rust=$BIN/official_rust_bench $w $arg" \
    --impl "go=$BIN/official_go_bench $w $arg" | sed -n '/^| Impl/,/^_SHA/p'
done
echo; echo "official bench lockfiles in git: Cargo.lock=$(test -f "$PKG_DIR/bench/rust/Cargo.lock" && echo yes || echo NO) go.sum=$(test -f "$PKG_DIR/bench/go/go.sum" && echo yes || echo NO)"
echo "resolved by this run: $(grep -A1 'name = "bytes"' "$OUT/obench/rust/Cargo.lock" | tr '\n' ' ')"

section "Done. Artifacts in $OUT"
