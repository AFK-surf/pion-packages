#!/bin/sh
# RT-git adversarial audit runner for packages/git.
# Builds the Pion oracle + gix oracle out of tree, then runs:
#   1. redteam_test.pion            (p0/p1/p2 expected FAIL, control_* expected PASS)
#   2. difftest.py                  (>= 2,000 vectors, three-way Pion vs git 2.54 vs gix)
#   3. dos.py                       (peak RSS / wall time of Pion vs git index-pack vs gix)
#   4. fourmode.py                  (native_dbg / native_rel / wasm_dbg / wasm_rel replay)
#   5. bench fairness probe         (W1 on real packs; W2 comparator allocation)
# All artifacts go to /tmp/rt-git-*; nothing is written inside the repository.
# Usage: sh packages/git/audit/run_audit.sh [--quick]
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
BIN=/tmp/rt-git-bin
WORK=/tmp/rt-git-work
DOS=/tmp/rt-git-dos
OUT=/tmp/rt-git-out
QUICK=""
[ "${1:-}" = "--quick" ] && QUICK="--quick"
mkdir -p "$BIN" "$WORK" "$DOS" "$OUT"

echo "==> toolchain"
pionc --version
git --version
cargo --version

echo "==> build Pion oracle (native --release) -> $BIN/oracle"
pionc build --release -o "$BIN/oracle" "$AUDIT_DIR"
echo "==> build gix oracle (--release --locked --offline) -> /tmp/rt-git-cargo"
rm -rf /tmp/rt-git-gix-src
cp -R "$AUDIT_DIR/gix_oracle" /tmp/rt-git-gix-src
CARGO_TARGET_DIR=/tmp/rt-git-cargo cargo build -q --release --locked --offline \
  --manifest-path /tmp/rt-git-gix-src/Cargo.toml
GIX=/tmp/rt-git-cargo/release/git_audit_gix

echo "==> [1/5] redteam_test.pion"
pionc test --json --only-pkg "$AUDIT_DIR" > "$OUT/redteam.json" 2> "$OUT/redteam.stderr" || true
python3 - "$OUT/redteam.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
bad = 0
for t in d["tests"]:
    want_pass = t["name"].startswith("control_")
    state = "PASS" if t["ok"] else "FAIL"
    flag = "" if t["ok"] == want_pass else "   <-- UNEXPECTED"
    bad += 1 if flag else 0
    print(f"  {state} {t['name']}{flag}")
fails = sum(1 for t in d["tests"] if not t["ok"])
print(f"  total={d['total']} passed={d['passed']} failed={fails} unexpected={bad}")
EOF

echo "==> [2/5] three-way differential (Pion vs git vs gix)"
REAL_GIT_DIR=$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir)
python3 "$AUDIT_DIR/difftest.py" --pion "$BIN/oracle" --gix "$GIX" --work "$WORK" \
  --real-git-dir "$REAL_GIT_DIR" --json-out "$OUT/difftest.json" | tee "$OUT/difftest.txt" \
  | grep -E '^(tree|commit|tag|loose|delta|pack|idx|index|pkt|ref) |^TOTAL'

echo "==> [3/5] DoS / complexity probes"
python3 "$AUDIT_DIR/dos.py" --pion "$BIN/oracle" --gix "$GIX" --work "$DOS" $QUICK \
  --fourmode-batch "$WORK/pion-packx.bin" | tee "$OUT/dos.md"

echo "==> [4/5] 4-mode consistency (native_dbg/native_rel/wasm_dbg/wasm_rel)"
python3 "$AUDIT_DIR/fourmode.py" "$WORK" | tee "$OUT/fourmode.md" || true

echo "==> [5/5] benchmark fairness"
sh "$ROOT_DIR/packages/git/bench/run_bench.sh" > "$OUT/bench_upstream.log" 2>&1
grep -E '^\| `' "$OUT/bench_upstream.log" || true
BB=/tmp/w12-git-bench/bin
PACK=$(ls -S "$REAL_GIT_DIR"/objects/pack/*.pack | head -1)
python3 "$ROOT_DIR/scripts/bench_compare.py" --title "W1 on real pack ($(basename "$PACK"))" \
  --impl "pion=$BB/pion_bench w1 $PACK 1" --impl "rust_gix=$BB/rust_bench w1 $PACK 1" \
  --baseline rust_gix --warmup 1 --rounds 5 --bytes "$(wc -c < "$PACK" | tr -d ' ')" | grep -E '^\| `|verified'
pionc build --release -o "$BIN/bench_fair" "$AUDIT_DIR/bench_fair"
python3 "$ROOT_DIR/scripts/bench_compare.py" --title "W2 tree encode: allocating vs zero-alloc comparator" \
  --impl "pion_enc=$BIN/bench_fair enc /tmp/w12-git-bench/w2_objects.bundle 3" \
  --impl "pion_enc_noalloc=$BIN/bench_fair enc_noalloc /tmp/w12-git-bench/w2_objects.bundle 3" \
  --baseline pion_enc --warmup 1 --rounds 5 | grep -E '^\| `|verified'

echo "==> clean worktree check"
git -C "$ROOT_DIR" status --porcelain --ignored
echo "DONE: outputs in $OUT"
