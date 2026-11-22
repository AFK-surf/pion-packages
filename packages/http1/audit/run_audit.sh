#!/bin/sh
# Red-team audit of packages/http1: one command runs every piece of evidence.
#
#   sh packages/http1/audit/run_audit.sh [all|tests|diff|probe|fuzz|bench]
#
# Pion `packages/http1` vs Rust httparse 1.10.1 (--release) vs Go net/http (go toolchain).
# Needs: pionc ($HOME/.pion/bin), cargo (httparse 1.10.1 cached or network), go, python3.
# All build artefacts, Cargo lockfiles and generated corpora go to $AUDIT_OUT
# (default: $TMPDIR/pion-http1-audit), never into the git worktree.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT=${AUDIT_OUT:-${TMPDIR:-/tmp}/pion-http1-audit}
BIN="$OUT/bin"
WHAT=${1:-all}
ROUNDS=${BENCH_ROUNDS:-5}
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
mkdir -p "$BIN"

step() { printf '\n==== %s ====\n' "$*"; }

cargo_bin() { # src_dir bin_name
  rm -rf "$OUT/rust-$2" && mkdir -p "$OUT/rust-$2"
  cp -R "$1/Cargo.toml" "$1/src" "$OUT/rust-$2/"
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --release --quiet \
    --manifest-path "$OUT/rust-$2/Cargo.toml"
  cp "$OUT/rust-target/release/$2" "$BIN/$2"
}

build() {
  step "build: pion probe + bench runner (--release)"
  pionc build --release -o "$BIN/probe_pion" "$AUDIT_DIR/probe"
  pionc build --release -o "$BIN/adv_pion" "$AUDIT_DIR/bench/pion_adv"
  step "build: rust httparse 1.10.1 runners (--release; project copied to \$AUDIT_OUT)"
  cargo_bin "$AUDIT_DIR/diff/rust" diff_rust
  cargo_bin "$AUDIT_DIR/bench/rust" adv_rust
  step "build: go net/http runners"
  (cd "$AUDIT_DIR/diff/go" && go build -o "$BIN/diff_go" .)
  (cd "$AUDIT_DIR/bench/go" && go build -o "$BIN/adv_go" .)
}

run_tests() {
  step "pionc test: audit/tests/redteam_test.pion (FAIL = evidence; control_* must PASS)"
  # pionc exits non-zero when a test fails; that is the expected outcome here.
  pionc test --json -p http1_redteam_audit "$AUDIT_DIR" > "$OUT/tests.json" 2> "$OUT/tests.stderr" || true
  python3 - "$OUT/tests.json" <<'PY'
import json, sys
t = open(sys.argv[1]).read()
d = json.loads(t[t.find('{"ok"'):])
print(f"total={d['total']} passed={d['passed']} failed={d['failed']}")
for x in d["tests"]:
    print(("PASS " if x["ok"] else "FAIL ") + x["name"])
PY
  echo "(assertion messages: $OUT/tests.stderr)"
}

run_diff() {
  step "differential: pion vs httparse 1.10.1 vs go net/http"
  python3 "$AUDIT_DIR/diff/gen_corpus.py" "$OUT/corpus.txt"
  "$BIN/probe_pion" diff "$OUT/corpus.txt" > "$OUT/pion.out"
  "$BIN/diff_rust" "$OUT/corpus.txt" > "$OUT/rust.out"
  "$BIN/diff_go" "$OUT/corpus.txt" > "$OUT/go.out"
  python3 "$AUDIT_DIR/diff/compare.py" "$OUT/pion.out" "$OUT/rust.out" "$OUT/go.out" --md "$OUT/diff.md"
}

rss() { /usr/bin/time -l "$@" 2> "$OUT/time.txt" || /usr/bin/time -v "$@" 2> "$OUT/time.txt"; grep -iE "maximum resident" "$OUT/time.txt"; }

run_probe() {
  step "probe: ChunkedDecoder queue (n tiny chunks, producer <ahead> feeds in front)"
  rss "$BIN/probe_pion" queue 100000 1
  rss "$BIN/probe_pion" queue 100000 100000
  rss "$BIN/probe_pion" queue 1000000 1000000
  step "probe: 1-byte drip vs bulk (ChunkedDecoder / SseDecoder, 1 MiB)"
  rss "$BIN/probe_pion" chunked_drip 1024
  rss "$BIN/probe_pion" sse_drip 1024
  step "probe: Sans-IO re-parse per received byte (O(n^2) header drip)"
  "$BIN/probe_pion" hdr_drip 64
  "$BIN/probe_pion" hdr_drip 400
  "$BIN/probe_pion" hdr_drip 1000
}

run_fuzz() {
  step "mutation fuzz: no panic, prefix->Partial, whole-vs-random-split equivalence"
  "$BIN/probe_pion" fuzz "${FUZZ_CASES:-200000}" "${FUZZ_SEED:-1}" | tail -20
}

bench_one() { # name ops bytes
  python3 "$ROOT_DIR/scripts/bench_compare.py" \
    --title "http1 adversarial: $1" \
    --impl "pion=$BIN/adv_pion $1 $OUT/wire/$1.bin" \
    --impl "rust_httparse=$BIN/adv_rust $1 $OUT/wire/$1.bin" \
    --impl "go_net_http=$BIN/adv_go $1 $OUT/wire/$1.bin" \
    --baseline rust_httparse --warmup 1 --rounds "$ROUNDS" \
    --ops "$2" --bytes "$3" \
    --md-out "$OUT/bench_$1.md" --json-out "$OUT/bench_$1.json"
}

run_bench() {
  step "adversarial benchmarks (corpora in $OUT/wire)"
  python3 "$AUDIT_DIR/bench/gen_bench.py" "$OUT/wire"
  sz() { wc -c < "$OUT/wire/$1.bin" | tr -d ' '; }
  bench_one req64 80000 $(( $(sz req64) * 4 ))
  bench_one chunk1m 256 $(( $(sz chunk1m) * 16 ))
  bench_one sse_multiline 8000 $(( $(sz sse_multiline) * 2 ))
  bench_one drip 4 $(( $(sz drip) * 4 ))
}

build
case "$WHAT" in
  all) run_tests; run_diff; run_probe; run_fuzz; run_bench ;;
  tests) run_tests ;;
  diff) run_diff ;;
  probe) run_probe ;;
  fuzz) run_fuzz ;;
  bench) run_bench ;;
  *) echo "unknown target: $WHAT" >&2; exit 2 ;;
esac
step "done; artefacts in $OUT"
git -C "$ROOT_DIR" status --porcelain --ignored
