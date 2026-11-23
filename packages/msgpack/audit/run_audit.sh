#!/bin/sh
# Red-team audit of packages/msgpack (Pion) vs Rust rmpv =1.3.1 vs Go vmihailenco/msgpack/v5 v5.4.1.
#
#   sh packages/msgpack/audit/run_audit.sh            # full run (~6-8 min on an M-series Mac)
#   QUICK=1 sh packages/msgpack/audit/run_audit.sh    # skip the slowest quadratic one-shots
#
# Needs: pionc ($HOME/.pion/bin), node (wasm32 runs), go >= 1.24, cargo, python3.
# All builds, inputs and reports go to $AUDIT_OUT (default /private/tmp/pion-msgpack-audit-$USER);
# the git worktree is never written to.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/pion-msgpack-audit-$(id -un)}
BIN="$OUT/bin"
ADV="$OUT/adv"
QUICK=${QUICK:-0}
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$BIN" "$ADV"

section() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

section "0. Build: Pion probe x4 (native debug/release, wasm32 debug/release), Go, Rust --release -> $BIN"
pionc build --release -o "$BIN/pion_probe" "$AUDIT_DIR/probe"
pionc build -o "$BIN/pion_probe_debug" "$AUDIT_DIR/probe"
pionc build --target wasm32 -o "$BIN/pion_probe_debug.wasm" "$AUDIT_DIR/probe"
pionc build --release --target wasm32 -o "$BIN/pion_probe_release.wasm" "$AUDIT_DIR/probe"
pionc build --release -o "$BIN/pion_bench" "$PKG_DIR/bench/pion_bench"
pionc build --target wasm32 -o "$BIN/wasm_smoke_debug.wasm" "$PKG_DIR/wasm_smoke"
pionc build --release --target wasm32 -o "$BIN/wasm_smoke_release.wasm" "$PKG_DIR/wasm_smoke"
rm -rf "$OUT/go-build" && cp -R "$AUDIT_DIR/go" "$OUT/go-build"
cp -R "$PKG_DIR/bench/go" "$OUT/go-build/cmd/official"
rm -f "$OUT/go-build/cmd/official/go.mod" "$OUT/go-build/cmd/official/go.sum"
(cd "$OUT/go-build" && go mod tidy >/dev/null 2>&1 && for c in probe bench bench_struct official; do
  go build -o "$BIN/go_$c" "./cmd/$c"; done)
rm -rf "$OUT/rust-build" && cp -R "$AUDIT_DIR/rust" "$OUT/rust-build"
CARGO_TARGET_DIR="$OUT/rust-target" cargo build -q --release --manifest-path "$OUT/rust-build/Cargo.toml"
cp "$OUT/rust-target/release/rust_probe" "$BIN/"
rm -rf "$OUT/rust-official" && cp -R "$PKG_DIR/bench/rust" "$OUT/rust-official"
CARGO_TARGET_DIR="$OUT/rust-target" cargo build -q --release --manifest-path "$OUT/rust-official/Cargo.toml"
cp "$OUT/rust-target/release/msgpack_bench_rust" "$BIN/rust_official"
python3 "$AUDIT_DIR/gen_adversarial.py" "$ADV"
python3 "$PKG_DIR/bench/gen_corpus.py" rpc "$OUT/rpc_2000.msgpack" 2000 >/dev/null

section "1. Red-team unit tests: pionc test packages/msgpack/audit (every redteam_* failure is a finding)"
(cd "$PKG_DIR" && pionc test --json audit > "$OUT/redteam_test.json" 2> "$OUT/redteam_test.stderr") || true
python3 - "$OUT/redteam_test.json" <<'PY' || true
import json, sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
mine = [t for t in d["tests"] if t["pkg"] == "msgpack_audit"]
base = [t for t in d["tests"] if t["pkg"] == "msgpack"]
print("msgpack (original suite): %d tests, %d passed" % (len(base), sum(t["ok"] for t in base)))
print("msgpack_audit: %d tests, %d FAILED (findings), %d passed (controls)" % (
    len(mine), sum(not t["ok"] for t in mine), sum(t["ok"] for t in mine)))
for t in mine:
    print("  %-6s %s" % ("FAIL" if not t["ok"] else "pass", t["name"]))
PY
echo "assertion messages:"; sed 's|^.*/audit/|  |' "$OUT/redteam_test.stderr"

section "2. Targeted-vector differential + Pion 4-mode consistency (all 256 markers, ints, IEEE-754, ts, canonical, UTF-8, dup, depth)"
python3 "$AUDIT_DIR/gen_vectors.py" "$OUT/vectors.tsv"
python3 "$AUDIT_DIR/diff_vectors.py" "$OUT/vectors.tsv" "$BIN" "$OUT/vec" > "$OUT/vectors_report.txt"
head -2 "$OUT/vectors_report.txt"; grep '^## ' "$OUT/vectors_report.txt"
echo "(full table: $OUT/vectors_report.txt)"

section "3. Structured + mutation fuzz differential (30,000 inputs, seed 1795) incl. Pion 4-mode consistency"
python3 "$AUDIT_DIR/fuzz_diff.py" "$BIN" "$OUT/fuzz" 30000 1795

section "4. Wasm32 smoke (node) and native-vs-wasm deep / large probes"
RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
for m in debug release; do
  rc=0; node "$RT" "$BIN/wasm_smoke_$m.wasm" || rc=$?; echo "  wasm_smoke $m: exit=$rc"
done
one() { "$@" 2>&1 | grep -v '^    at' | head -1 || true; }
for spec in "a 1024 1024 decode" "m 1024 1024 decode" "m 1024 1024 strict" "a 100000 1000000 validate" "a 1025 2000 decode" \
  "a 1680 1024 equals" "m 1060 1024 equals" "a 50000 128 encode" "a 60000 128 encode"; do
  set -- $spec
  n=$(one "$BIN/pion_probe" deep "$@"); nd=$(one "$BIN/pion_probe_debug" deep "$@")
  wd=$(one node "$RT" "$BIN/pion_probe_debug.wasm" deep "$@"); wr=$(one node "$RT" "$BIN/pion_probe_release.wasm" deep "$@")
  [ -n "$n" ] || n="CRASH (no output, likely SIGSEGV)"
  printf '  deep %-26s native-rel=%-34s native-dbg=%-6s wasm-dbg=%-6s wasm-rel=%s\n' "$spec" "$n" "$([ "$nd" = "$n" ] && echo same || echo "${nd:-CRASH}")" \
    "$([ "$wd" = "$n" ] && echo same || echo "$wd")" "$([ "$wr" = "$n" ] && echo same || echo "$wr")"
done
echo "  F-8 wasm32 stack margin at the advertised 1024 cap (node default --stack-size=984 KB):"
for ss in 984 950 900; do
  printf '    node --stack-size=%s  map depth 1024 decode: %s   array depth 1024: %s\n' "$ss" \
    "$(one node --stack-size=$ss "$RT" "$BIN/pion_probe_release.wasm" deep m 1024 1024 decode)" \
    "$(one node --stack-size=$ss "$RT" "$BIN/pion_probe_release.wasm" deep a 1024 1024 decode)"
done
echo "  user-built deep values, rmpv for comparison (Rust main thread 8 MiB):"
for n in 60000 100000; do printf '    rust_probe deepdrop %s: %s\n' "$n" "$(one "$BIN/rust_probe" deepdrop $n)"; done
for f in rpc_mixed_1m deep100_x10k strmap_10k; do
  n=$("$BIN/pion_probe" bench dec dup "$ADV/$f.msgpack" 1 | tr '\n' ' ')
  w=$(node "$RT" "$BIN/pion_probe_release.wasm" bench dec dup "$ADV/$f.msgpack" 1 | tr '\n' ' ')
  wd=$(node "$RT" "$BIN/pion_probe_debug.wasm" bench dec dup "$ADV/$f.msgpack" 1 | tr '\n' ' ')
  printf '  bench dec %-14s native=%s wasm-rel=%s wasm-dbg=%s\n' "$f" "$n" "$([ "$w" = "$n" ] && echo same || echo "$w")" "$([ "$wd" = "$n" ] && echo same || echo "$wd")"
done
echo "  F-3 on wasm32 (bigenc 1 MiB x 2048): $(one node "$RT" "$BIN/pion_probe_release.wasm" bigenc 1 2048)"

section "5. DoS / crash one-shots"
O1() { python3 "$AUDIT_DIR/oneshot.py" "$@"; }
echo "--- F-1 reject_duplicate_keys HashDoS (crafted uint64 keys; same-size random keys as control) ---"
sizes="16384 65535 131072"; [ "$QUICK" = 1 ] || sizes="$sizes 262144"
for n in $sizes; do
  O1 "pion dup  hashdos_$n" 600 "$BIN/pion_probe" bench dec dup "$ADV/hashdos_$n.msgpack" 1
  O1 "pion dup  random_$n" 600 "$BIN/pion_probe" bench dec dup "$ADV/random_$n.msgpack" 1
  O1 "go   dupdec hashdos_$n (Go map)" 600 "$BIN/go_bench" dupdec "$ADV/hashdos_$n.msgpack" 1
  O1 "rust dupdec hashdos_$n (HashSet)" 600 "$BIN/rust_probe" bench dupdec "$ADV/hashdos_$n.msgpack" 1
done
echo "--- F-2 decode_prefix_at streaming over a <= 2 MiB buffer (re-copies the whole buffer per frame) ---"
sizes="65536 262144 1048576"; [ "$QUICK" = 1 ] || sizes="$sizes 2097152"
for s in $sizes 2228224; do
  O1 "pion decode_prefix_at loop frames_$s" 600 "$BIN/pion_probe" bench prefix - "$ADV/frames_$s.msgpack" 1
  O1 "pion decode_all            frames_$s" 600 "$BIN/pion_probe" bench all - "$ADV/frames_$s.msgpack" 1
  O1 "go   Decoder.Decode loop   frames_$s" 600 "$BIN/go_bench" prefix "$ADV/frames_$s.msgpack" 1
  O1 "rust read_value loop       frames_$s" 600 "$BIN/rust_probe" bench prefix "$ADV/frames_$s.msgpack" 1
done
echo "--- F-3 encode() of > 2 GiB output: 32-bit Int size overflow (Array of N refs to one 1 MiB Bin) ---"
for c in 2047 2048 4097; do
  O1 "pion encode_default 1MiB x $c" 120 "$BIN/pion_probe" bigenc 1 "$c"
  O1 "rust write_value_ref 1MiB x $c" 120 "$BIN/rust_probe" bigenc 1 "$c"
done

section "6. Adversarial head-to-head benchmarks (scripts/bench_compare.py, SHA-256 verified)"
bc() { python3 "$ROOT_DIR/scripts/bench_compare.py" --warmup 1 --rounds 5 --baseline go "$@" | sed -n '/^| Impl/,/^_SHA/p'; }
P="$BIN/pion_probe bench"; G="$BIN/go_bench"; R="$BIN/rust_probe bench"
for spec in "rpc_mixed_1m 20" "ints_1m 5" "f32_1m 5" "f64_1m 5" "deep100_x10k 5" "strmap_10k 50"; do
  set -- $spec
  echo; echo "### dec $1 (x$2)"
  bc --title "dec $1" --bytes $(( $(wc -c < "$ADV/$1.msgpack") * $2 )) \
    --impl "pion=$P dec - $ADV/$1.msgpack $2" --impl "pion_canon=$P dec canon $ADV/$1.msgpack $2" \
    --impl "rust=$R dec $ADV/$1.msgpack $2" --impl "rust_ref=$R refdec $ADV/$1.msgpack $2" \
    --impl "go=$G dec $ADV/$1.msgpack $2"
done
echo; echo "### reject_duplicate_keys strmap_10k (x50)"
bc --title "dupdec strmap_10k" --impl "pion=$P dec dup $ADV/strmap_10k.msgpack 50" \
  --impl "rust=$R dupdec $ADV/strmap_10k.msgpack 50" --impl "go=$G dupdec $ADV/strmap_10k.msgpack 50"
echo; echo "### streaming 262,144-byte buffer of 65,536 frames (x1)"
bc --title "prefix frames_262144" --impl "pion=$P prefix - $ADV/frames_262144.msgpack 1" \
  --impl "pion_decode_all=$P all - $ADV/frames_262144.msgpack 1" \
  --impl "rust=$R prefix $ADV/frames_262144.msgpack 1" --impl "go=$G prefix $ADV/frames_262144.msgpack 1"

section "7. Fairness of packages/msgpack/bench: idiomatic Go (typed structs) and Rust (zero-copy read_value_ref)"
B=$(( $(wc -c < "$OUT/rpc_2000.msgpack") * 40 ))
echo "### Workload 1: decode-rpc, 80k records (identical official stdout)"
bc --title "decode-rpc" --ops 80000 --bytes "$B" --impl "pion=$BIN/pion_bench decode-rpc $OUT/rpc_2000.msgpack" \
  --impl "rust=$BIN/rust_official decode-rpc $OUT/rpc_2000.msgpack" \
  --impl "go=$BIN/go_bench_struct decode-rpc $OUT/rpc_2000.msgpack" \
  --impl "go_any_official=$BIN/go_official decode-rpc $OUT/rpc_2000.msgpack"
echo; echo "### Workload 1 shape, generic tree walk: Rust zero-copy ValueRef vs Pion (nodes/payload stdout)"
bc --title "rpc tree" --ops 80000 --bytes "$B" --impl "pion=$P dec - $OUT/rpc_2000.msgpack 40" \
  --impl "rust=$R dec $OUT/rpc_2000.msgpack 40" --impl "rust_ref=$R refdec $OUT/rpc_2000.msgpack 40" \
  --impl "go=$G dec $OUT/rpc_2000.msgpack 40"
echo; echo "### Workload 2: encode-rpc, 50k records (byte-identical output)"
bc --title "encode-rpc" --ops 50000 --impl "pion=$BIN/pion_bench encode-rpc" \
  --impl "rust=$BIN/rust_official encode-rpc" --impl "go=$BIN/go_bench_struct encode-rpc" \
  --impl "go_any_sorted_official=$BIN/go_official encode-rpc"

section "Done. Artifacts in $OUT"
