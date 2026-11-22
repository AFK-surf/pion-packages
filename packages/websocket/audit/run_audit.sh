#!/bin/sh
# Red-team audit of packages/websocket: one command runs every piece of evidence.
#
#   sh packages/websocket/audit/run_audit.sh [all|tests|diff|handshake|probe|fuzz|bench]
#
# Pion `packages/websocket` vs Rust tungstenite 0.26.2 (--release) vs Go coder/websocket v1.8.14.
# Needs: pionc ($HOME/.pion/bin), cargo (crates cached or network), go, python3.
# All build artefacts and generated corpora go to $AUDIT_OUT (default: $TMPDIR/pion-ws-audit),
# never into the git worktree.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT=${AUDIT_OUT:-${TMPDIR:-/tmp}/pion-ws-audit}
BIN="$OUT/bin"
WHAT=${1:-all}
ROUNDS=${BENCH_ROUNDS:-5}
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$BIN"

step() { printf '\n==== %s ====\n' "$*"; }

build() {
  step "build: pion runners"
  pionc build --release -o "$BIN/diff_pion" "$AUDIT_DIR/diff/pion"
  pionc build --release -o "$BIN/adv_pion" "$AUDIT_DIR/bench/pion_adv"
  pionc build --release -o "$BIN/probe_pion" "$AUDIT_DIR/probe"
  step "build: rust tungstenite runners (--release)"
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --release --quiet \
    --manifest-path "$AUDIT_DIR/diff/rust/Cargo.toml"
  for b in diff_rust adv_rust hs_rust; do cp "$OUT/rust-target/release/$b" "$BIN/$b"; done
  step "build: go coder/websocket runners"
  (cd "$AUDIT_DIR/diff/go" && for b in diff_go adv_go hs_go; do go build -o "$BIN/$b" "./cmd/$b"; done)
}

run_tests() {
  step "pionc test: audit/tests/redteam_test.pion (FAIL = evidence; control_* must PASS)"
  # pionc exits non-zero when a test fails; that is the expected outcome here.
  pionc test --json -p websocket_redteam_audit "$AUDIT_DIR" > "$OUT/tests.json" 2> "$OUT/tests.stderr" || true
  python3 - "$OUT/tests.json" <<'EOF'
import json, sys
t = open(sys.argv[1]).read()
d = json.loads(t[t.find('{"ok"'):])
print(f"total={d['total']} passed={d['passed']} failed={d['failed']}")
for x in d["tests"]:
    print(("PASS " if x["ok"] else "FAIL ") + x["name"])
EOF
}

run_diff() {
  step "frame differential: pion vs tungstenite vs coder/websocket"
  python3 "$AUDIT_DIR/diff/gen_corpus.py" "$OUT/corpus.txt"
  "$BIN/diff_pion" "$OUT/corpus.txt" > "$OUT/pion.out"
  "$BIN/diff_rust" "$OUT/corpus.txt" > "$OUT/rust.out"
  "$BIN/diff_go" "$OUT/corpus.txt" > "$OUT/go.out"
  python3 "$AUDIT_DIR/diff/compare.py" "$OUT/pion.out" "$OUT/rust.out" "$OUT/go.out" --md "$OUT/diff.md"
}

run_handshake() {
  step "handshake differential"
  python3 "$AUDIT_DIR/diff/gen_handshake.py" "$OUT/hs_corpus.txt"
  "$BIN/diff_pion" hs "$OUT/hs_corpus.txt" > "$OUT/hs_pion.out"
  "$BIN/hs_rust" "$OUT/hs_corpus.txt" > "$OUT/hs_rust.out"
  "$BIN/hs_go" "$OUT/hs_corpus.txt" > "$OUT/hs_go.out"
  paste -d'|' "$OUT/hs_pion.out" "$OUT/hs_rust.out" "$OUT/hs_go.out" | awk -F'|' '
    { split($1,a," "); split($2,b," "); split($3,c," ");
      flag = (a[2]==b[2] && b[2]==c[2]) ? "" : "  <-- differs";
      printf "%-34s pion=%-9s rust=%-9s go=%-9s%s\n", a[1], a[2], b[2], c[2], flag }'
}

run_probe() {
  step "probe: 32-bit frame_total overflow (expect: Ok(None); Pion panics)"
  "$BIN/probe_pion" overflow_len64 || echo "probe exit=$? (134 = abort on panic)"
  step "probe: chunk-queue retention (20000 x 64 KiB frames; drain vs producer 2 frames ahead)"
  for m in queue_drain queue_retention; do
    /usr/bin/time -l "$BIN/probe_pion" "$m" 20000 2> "$OUT/$m.time" || true
    grep -E "maximum resident" "$OUT/$m.time" || /usr/bin/time -v "$BIN/probe_pion" "$m" 20000 2>&1 | grep -i "maximum resident"
  done
}

run_fuzz() {
  step "mutation fuzz (2000 cases, seed 1)"
  python3 "$AUDIT_DIR/diff/fuzz.py" "$BIN/diff_pion" "$BIN/diff_rust" "$BIN/diff_go" "$OUT/fuzz" "${FUZZ_CASES:-2000}" "${FUZZ_SEED:-1}"
}

bench_one() { # name file chunk msgs rounds bytes_per_round
  name=$1; file=$2; chunk=$3; msgs=$4; rounds=$5; bytes=$6
  python3 "$ROOT_DIR/scripts/bench_compare.py" \
    --title "WebSocket adversarial: $name (chunk=$chunk, x$rounds)" \
    --impl "pion=$BIN/adv_pion $file $chunk $msgs $rounds" \
    --impl "rust_tungstenite=$BIN/adv_rust $file $chunk $msgs $rounds" \
    --impl "go_coder_ws=$BIN/adv_go $file $chunk $msgs $rounds" \
    --baseline rust_tungstenite --warmup 1 --rounds "$ROUNDS" \
    --ops $((msgs * rounds)) --bytes $((bytes * rounds)) \
    --md-out "$OUT/bench_$name.md" --json-out "$OUT/bench_$name.json"
}

run_bench() {
  step "adversarial benchmarks (wire streams in $OUT/wire)"
  python3 "$AUDIT_DIR/bench/gen_bench.py" "$OUT/wire"
  W="$OUT/wire"
  sz() { wc -c < "$1" | tr -d ' '; }
  bench_one big_64k   "$W/big_64k.ws"    65536 2048    8 "$(sz "$W/big_64k.ws")"
  bench_one big_1m    "$W/big_1m.ws"     65536 128     8 "$(sz "$W/big_1m.ws")"
  bench_one big_16m   "$W/big_16m.ws"    65536 8       8 "$(sz "$W/big_16m.ws")"
  bench_one text_1m   "$W/text_1m.ws"    65536 128     8 "$(sz "$W/text_1m.ws")"
  bench_one big_1m_c4k "$W/big_1m.ws"    4096  128     4 "$(sz "$W/big_1m.ws")"
  bench_one frag_storm "$W/frag_storm.ws" 65536 100    10 "$(sz "$W/frag_storm.ws")"
  bench_one tiny_1m   "$W/tiny_1m.ws"    65536 1000000 5 "$(sz "$W/tiny_1m.ws")"
  bench_one drip_20k  "$W/drip_20k.ws"   1     20000   5 "$(sz "$W/drip_20k.ws")"
}

build
case "$WHAT" in
  all) run_tests; run_diff; run_handshake; run_probe; run_fuzz; run_bench ;;
  tests) run_tests ;;
  diff) run_diff ;;
  handshake) run_handshake ;;
  probe) run_probe ;;
  fuzz) run_fuzz ;;
  bench) run_bench ;;
  *) echo "unknown target: $WHAT" >&2; exit 2 ;;
esac
step "done; artefacts in $OUT"
git -C "$ROOT_DIR" status --porcelain
