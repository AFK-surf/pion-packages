#!/bin/sh
# One-shot red-team audit runner for packages/uuid.
#   sh packages/uuid/audit/run_audit.sh            # everything (tests, differential, wasm32, benches)
#   sh packages/uuid/audit/run_audit.sh --no-bench # skip the timed benchmarks
# All build artifacts / generated data go to $AUDIT_OUT (default /tmp/pion-uuid-audit); the worktree stays clean.
# Exit status: 0 only if no DEFECT / UNEXPECTED was found (i.e. it is non-zero while the audited defects exist).
set -u

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
O="${AUDIT_OUT:-/tmp/pion-uuid-audit}"
BIN="$O/bin"
RUN_BENCH=1
[ "${1:-}" = "--no-bench" ] && RUN_BENCH=0
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$BIN"
STATUS=0

step() { printf '\n==> %s\n' "$*"; }

step "pionc version / cargo version"
pionc --version
cargo --version

step "fmt + check (audit packages)"
for p in "$AUDIT_DIR" "$AUDIT_DIR/driver" "$AUDIT_DIR"/bench/*/; do
  pionc fmt --check "$p" || STATUS=1
  pionc check --json "$p" >/dev/null || { echo "check failed: $p"; STATUS=1; }
done

step "1/5 Pion red-team tests (p1_/p2_/div_ expected to FAIL while defects exist; ctl_ must PASS)"
pionc test --json "$AUDIT_DIR" 2>"$O/test.stderr" >"$O/test.json"
python3 - "$O/test.json" <<'EOF'
import json, sys
j = json.load(open(sys.argv[1]))
for k, v in j.items():
    if isinstance(v, list):
        for t in v:
            if isinstance(t, dict) and t.get("pkg") == "uuid_audit":
                print(("PASS " if t["ok"] else "FAIL ") + t["name"])
ctl_fail = [t["name"] for v in j.values() if isinstance(v, list) for t in v
            if isinstance(t, dict) and t.get("pkg") == "uuid_audit" and t["name"].startswith("ctl_") and not t["ok"]]
if ctl_fail:
    print("UNEXPECTED control failures:", ctl_fail)
sys.exit(0 if j.get("ok") else 1)
EOF
[ $? -eq 0 ] || STATUS=1

step "2/5 Build Rust oracle (uuid =1.29.3, ulid =1.2.1) and Pion driver"
CARGO_TARGET_DIR="$O/rust-target" cargo build --release --quiet --manifest-path "$AUDIT_DIR/oracle/Cargo.toml" || exit 2
pionc build --release -o "$BIN/driver" "$AUDIT_DIR/driver" || exit 2

step "3/5 Differential (native)"
python3 "$AUDIT_DIR/gen_corpus.py" "$O/corpus.tsv"
"$O/rust-target/release/oracle" "$O/corpus.tsv" >"$O/rust.out"
"$BIN/driver" "$O/corpus.tsv" >"$O/pion.out"
python3 "$AUDIT_DIR/diff.py" "$O/corpus.tsv" "$O/rust.out" "$O/pion.out" | tee "$O/diff_native.txt"
grep -q 'RESULT: PASS' "$O/diff_native.txt" || STATUS=1
echo "Rust ContextV7 same-ms burst (compare div_v7context_counter_capacity_no_drift):"
"$O/rust-target/release/v7ctx" 100000

step "4/5 Differential (wasm32: same driver, same corpus, must be byte-identical to native)"
cp "$O/corpus.tsv" "$O/corpus_wasm.tsv"
T0=$(python3 -c 'import time;print(time.time())')
pionc run --release --target wasm32 "$AUDIT_DIR/driver" -- "$O/corpus_wasm.tsv" >"$O/pion_wasm.out" 2>"$O/pion_wasm.err"
T1=$(python3 -c 'import time;print(time.time())')
if cmp -s "$O/pion.out" "$O/pion_wasm.out"; then
  echo "wasm32 output identical to native ($(wc -l <"$O/pion_wasm.out" | tr -d ' ') lines, $(python3 -c "print(round($T1-$T0,2))") s incl. compile)"
else
  echo "wasm32 output DIFFERS from native:"; diff "$O/pion.out" "$O/pion_wasm.out" | head -20; tail -5 "$O/pion_wasm.err"; STATUS=1
fi

if [ "$RUN_BENCH" -eq 1 ]; then
  step "5/5 Benchmarks: idiomatic typed API vs raw API vs Rust (bench_compare.py, warmup 1, rounds 5)"
  python3 "$PKG_DIR/bench/gen_data.py" "$O" 500000
  UB=$(wc -c <"$O/uuids_500000.txt" | tr -d ' ')
  LB=$(wc -c <"$O/ulids_500000.txt" | tr -d ' ')
  CARGO_TARGET_DIR="$O/rust-bench-target" cargo build --release --quiet --manifest-path "$PKG_DIR/bench/rust/Cargo.toml" || exit 2
  RB="$O/rust-bench-target/release"
  for p in pion_uuid_batch pion_uuid_gen pion_ulid_batch; do pionc build --release -o "$BIN/$p" "$PKG_DIR/bench/$p" || exit 2; done
  for p in idiom_uuid_batch idiom_uuid_gen idiom_ulid_batch sort_adv; do pionc build --release -o "$BIN/$p" "$AUDIT_DIR/bench/$p" || exit 2; done
  BC="python3 $ROOT_DIR/scripts/bench_compare.py --warmup 1 --rounds 5"

  $BC --title "UUID batch parse+sort+format 500k: raw vs typed vs Rust" \
    --impl "pion_raw=$BIN/pion_uuid_batch $O/uuids_500000.txt" \
    --impl "pion_typed_buf=$BIN/idiom_uuid_batch $O/uuids_500000.txt buf" \
    --impl "pion_typed_str=$BIN/idiom_uuid_batch $O/uuids_500000.txt str" \
    --impl "rust_uuid=$RB/bench_uuid_batch $O/uuids_500000.txt" \
    --baseline rust_uuid --ops 500000 --bytes "$UB" --md-out "$O/b1.md" >/dev/null && cat "$O/b1.md"

  $BC --title "UUID v5+v7 generate+format 200k: raw vs typed vs Rust" \
    --impl "pion_raw=$BIN/pion_uuid_gen 200000" \
    --impl "pion_typed_buf=$BIN/idiom_uuid_gen 200000 buf" \
    --impl "pion_typed_str=$BIN/idiom_uuid_gen 200000 str" \
    --impl "rust_uuid=$RB/bench_uuid_gen 200000" \
    --baseline rust_uuid --ops 200000 --md-out "$O/b2.md" >/dev/null && cat "$O/b2.md"

  $BC --title "ULID batch parse+sort+format 500k: raw vs typed vs Rust" \
    --impl "pion_raw=$BIN/pion_ulid_batch $O/ulids_500000.txt" \
    --impl "pion_typed_buf=$BIN/idiom_ulid_batch $O/ulids_500000.txt buf" \
    --impl "pion_typed_str=$BIN/idiom_ulid_batch $O/ulids_500000.txt str" \
    --impl "rust_ulid=$RB/bench_ulid_batch $O/ulids_500000.txt" \
    --baseline rust_ulid --ops 500000 --bytes "$LB" --md-out "$O/b3.md" >/dev/null && cat "$O/b3.md"

  for kind in random dup33 deep33 lastbyte signed equal; do
    $BC --title "Sort 1M ($kind): Uuid::sort / sort_u128_pairs_raw vs Rust sort_unstable" \
      --impl "pion_Uuid_sort=$BIN/sort_adv $kind 1000000 sort_uuid" \
      --impl "pion_raw=$BIN/sort_adv $kind 1000000 sort_raw" \
      --impl "pion_Ulid_sort=$BIN/sort_adv $kind 1000000 sort_ulid" \
      --impl "rust_sort_unstable=$O/rust-target/release/sort_adv $kind 1000000 uuid" \
      --baseline rust_sort_unstable --ops 1000000 --md-out "$O/sort_$kind.md" >/dev/null && cat "$O/sort_$kind.md"
  done

  step "wasm32 timings (Node $(node --version) + pion_wasm_rt.mjs; no Rust wasm toolchain on this host -> baseline is Rust native)"
  RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
  for p in pion_uuid_batch pion_uuid_gen pion_ulid_batch; do pionc build --release --target wasm32 -o "$BIN/$p.wasm" "$PKG_DIR/bench/$p" || exit 2; done
  for p in idiom_uuid_batch idiom_uuid_gen idiom_ulid_batch; do pionc build --release --target wasm32 -o "$BIN/$p.wasm" "$AUDIT_DIR/bench/$p" || exit 2; done
  $BC --title "wasm32 UUID batch 500k" \
    --impl "wasm_pion_raw=node $RT $BIN/pion_uuid_batch.wasm $O/uuids_500000.txt" \
    --impl "wasm_pion_typed=node $RT $BIN/idiom_uuid_batch.wasm $O/uuids_500000.txt buf" \
    --impl "native_pion_raw=$BIN/pion_uuid_batch $O/uuids_500000.txt" \
    --impl "native_rust_uuid=$RB/bench_uuid_batch $O/uuids_500000.txt" \
    --baseline native_rust_uuid --ops 500000 --bytes "$UB" --md-out "$O/w1.md" >/dev/null && cat "$O/w1.md"
  $BC --title "wasm32 UUID v5+v7 200k" \
    --impl "wasm_pion_raw=node $RT $BIN/pion_uuid_gen.wasm 200000" \
    --impl "wasm_pion_typed=node $RT $BIN/idiom_uuid_gen.wasm 200000 buf" \
    --impl "native_pion_raw=$BIN/pion_uuid_gen 200000" \
    --impl "native_rust_uuid=$RB/bench_uuid_gen 200000" \
    --baseline native_rust_uuid --ops 200000 --md-out "$O/w2.md" >/dev/null && cat "$O/w2.md"
  $BC --title "wasm32 ULID batch 500k" \
    --impl "wasm_pion_raw=node $RT $BIN/pion_ulid_batch.wasm $O/ulids_500000.txt" \
    --impl "wasm_pion_typed=node $RT $BIN/idiom_ulid_batch.wasm $O/ulids_500000.txt buf" \
    --impl "native_pion_raw=$BIN/pion_ulid_batch $O/ulids_500000.txt" \
    --impl "native_rust_ulid=$RB/bench_ulid_batch $O/ulids_500000.txt" \
    --baseline native_rust_ulid --ops 500000 --bytes "$LB" --md-out "$O/w3.md" >/dev/null && cat "$O/w3.md"
fi

step "worktree must stay clean"
git -C "$ROOT_DIR" status --porcelain --ignored -- "$PKG_DIR"

if [ "$STATUS" -eq 0 ]; then echo "AUDIT: no open defects"; else echo "AUDIT: open defects / divergences present (see above)"; fi
exit "$STATUS"
