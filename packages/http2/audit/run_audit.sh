#!/bin/sh
# Red-team audit of packages/http2 (Wave 10 RT-http2): one command reproduces every piece of evidence.
#
#   sh packages/http2/audit/run_audit.sh [all|build|tests|hpack|frames|conn|wasm|probe|bench]
#
# References: Go 1.27 golang.org/x/net v0.62.0 (http2 Framer/Server + http2/hpack) and
# Rust h2 0.4.20 (its own src/hpack engine, vendored at build time, and h2::Codec via `unstable`).
# Needs: pionc ($HOME/.pion/bin), go, cargo (crates in the local registry or network), node, python3.
# Every artefact (binaries, corpora, Cargo/Go build copies, reports) goes to $AUDIT_OUT
# (default /private/tmp/rt-http2); nothing is written inside the git worktree.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/rt-http2}
BIN="$OUT/bin"
WHAT=${1:-all}
ROUNDS=${BENCH_ROUNDS:-7}
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
GO_TABLES=$(go env GOMODCACHE)/golang.org/x/net@v0.62.0/http2/hpack/tables.go
mkdir -p "$BIN" "$OUT/reports"

step() { printf '\n==== %s ====\n' "$*"; }

go_bin() { # src_dir out_bin
  d="$OUT/go-$(basename "$2")"
  rm -rf "$d" && mkdir -p "$d" && cp "$1"/go.mod "$1"/go.sum "$1"/main.go "$d/"
  (cd "$d" && go build -mod=readonly -o "$2" .)
}

cargo_bin() { # src_dir crate_bin out_bin [vendor]
  d="$OUT/rust-$3"
  rm -rf "$d" && mkdir -p "$d" && cp -R "$1/Cargo.toml" "$1/Cargo.lock" "$1/src" "$d/"
  if [ "${4:-}" = vendor ]; then sh "$1/vendor_h2_hpack.sh" "$d"; fi
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --release --locked --quiet --manifest-path "$d/Cargo.toml"
  cp "$OUT/rust-target/release/$2" "$BIN/$3"
}

build() {
  step "build: Pion probe (native debug/release + wasm32 debug/release) and fair bench"
  pionc build -o "$BIN/probe_debug" "$AUDIT_DIR/probe"
  pionc build --release -o "$BIN/probe_release" "$AUDIT_DIR/probe"
  pionc build --target wasm32 -o "$BIN/probe_debug.wasm" "$AUDIT_DIR/probe"
  pionc build --release --target wasm32 -o "$BIN/probe_release.wasm" "$AUDIT_DIR/probe"
  pionc build --release -o "$BIN/pion_fair" "$AUDIT_DIR/bench/pion_fair"
  pionc build --release -o "$BIN/pion_shipped" "$PKG_DIR/bench/pion_bench"
  step "build: Go x/net v0.62.0 runners (hpack/frames diff, Server harness, fair bench) + shipped v0.34 bench"
  go_bin "$AUDIT_DIR/diff/go" "$BIN/diff_go"
  go_bin "$AUDIT_DIR/conn/go" "$BIN/conn_go"
  go_bin "$AUDIT_DIR/bench/go" "$BIN/go_fair"
  go_bin "$PKG_DIR/bench/go" "$BIN/go_shipped"
  step "build: Rust h2 0.4.20 hpack (vendored) + h2::Codec bench + shipped hpack-patched 0.3.0 bench"
  cargo_bin "$AUDIT_DIR/diff/rust" h2-hpack-diff h2_hpack vendor
  cargo_bin "$AUDIT_DIR/bench/rust_h2codec" h2-codec-bench h2_codec
  cargo_bin "$PKG_DIR/bench/rust" http2-bench-rust rs_shipped
}

corpora() {
  python3 "$AUDIT_DIR/diff/gen_hpack_corpus.py" "$OUT/hpack.txt" "$GO_TABLES"
  python3 "$AUDIT_DIR/diff/gen_frame_corpus.py" "$OUT/frames.txt"
  python3 "$AUDIT_DIR/conn/gen_scenarios.py" "$OUT/scenarios.txt"
}

run_tests() {
  step "pionc fmt --check / check / test (FAIL = evidence of a defect; every control_* must PASS)"
  for d in "$AUDIT_DIR" "$AUDIT_DIR/probe" "$AUDIT_DIR/bench/pion_fair"; do
    pionc fmt --check "$d" >/dev/null && pionc check --json "$d" | grep -q '"ok":true' || { echo "FAIL fmt/check $d"; exit 1; }
  done
  pionc test --json "$AUDIT_DIR" > "$OUT/tests.json" 2> "$OUT/tests.stderr" || true
  python3 - "$OUT/tests.json" <<'PY'
import json, sys
t = open(sys.argv[1]).read()
d = json.loads(t[t.find('{"ok"'):])
mine = [x for x in d["tests"] if x["pkg"] == "http2_redteam_audit"]
bad_controls = [x["name"] for x in mine if x["name"].startswith("control_") and not x["ok"]]
for sev in ("p0_", "p1_", "p2_", "control_"):
    xs = [x for x in mine if x["name"].startswith(sev)]
    print(f"{sev:<9} total={len(xs):<3} FAIL={sum(not x['ok'] for x in xs):<3} PASS={sum(x['ok'] for x in xs)}")
for x in mine:
    print(("PASS " if x["ok"] else "FAIL ") + x["name"])
if bad_controls:
    print("CONTROL REGRESSION:", bad_controls); sys.exit(1)
PY
  echo "(assertion messages: $OUT/tests.stderr)"
}

run_hpack() {
  step "HPACK differential: Pion vs Go x/net/http2/hpack vs Rust h2 hpack"
  python3 "$AUDIT_DIR/diff/compare.py" hpack "$OUT/hpack.txt" "$BIN/probe_release" "$BIN/diff_go" "$BIN/h2_hpack" \
    --md "$OUT/reports/hpack_diff.md" --dump "$OUT/pion_hpack.out" | sed -n '1,12p;/## 3-way/,/total/p;/Root-cause/,$p'
}

run_frames() {
  step "Frame differential: Pion decode_frame vs Go Framer.ReadFrame"
  python3 "$AUDIT_DIR/diff/compare.py" frames "$OUT/frames.txt" "$BIN/probe_release" "$BIN/diff_go" \
    --md "$OUT/reports/frames_diff.md" | sed -n '1,10p;/Root-cause/,$p'
}

run_conn() {
  step "Connection differential: Pion Connection::feed vs Go x/net/http2 Server (MaxConcurrentStreams=4)"
  python3 "$AUDIT_DIR/conn/compare_conn.py" "$OUT/scenarios.txt" "$BIN/probe_release" "$BIN/conn_go" \
    --md "$OUT/reports/conn_diff.md" 2>/dev/null
}

run_wasm() {
  step "4-mode consistency: native debug/release + wasm32 debug/release (node), full corpora"
  python3 "$AUDIT_DIR/diff/four_modes.py" "$BIN" "$WASM_RT" "$OUT/hpack.txt" "$OUT/frames.txt" "$OUT/scenarios.txt" \
    | tee "$OUT/reports/four_modes.md"
}

rss() { /usr/bin/time -l "$@" 2>&1 | grep -E "streams=|drip_|real|maximum resident" | tr -s ' ' | tr '\n' ' '; echo; }

run_probe() {
  step "probe: finished streams are never freed (memory) and every SETTINGS_INITIAL_WINDOW_SIZE walks them all (CPU)"
  rss "$BIN/probe_release" streams 0 1000
  rss "$BIN/probe_release" streams 100000 0
  rss "$BIN/probe_release" streams 100000 1000
  rss "$BIN/probe_release" streams 1000000 0
  rss "$BIN/probe_release" streams 1000000 100
  step "probe: 1-byte drip feed vs bulk (60 x 1 KiB DATA; 64 KiB is the most a connection can ever receive)"
  rss "$BIN/probe_release" drip 60
}

run_bench() {
  step "fair benchmarks (scripts/bench_compare.py, interleaved, SHA-256 verified), corpus = packages/http2/bench/gen_corpus.py"
  C="$OUT/corpus"
  python3 "$PKG_DIR/bench/gen_corpus.py" "$C"
  HB=$(($(wc -c < "$C/hpack_stream.bin") * 100))
  PB=$(($(wc -c < "$C/headers_plain.bin") * 100))
  FB=$(($(wc -c < "$C/frame_stream.bin") * 100))
  BC="python3 $ROOT_DIR/scripts/bench_compare.py --warmup 1 --rounds $ROUNDS"
  $BC --title "B1 HPACK decode (100k blocks, Huffman + dynamic table)" \
    --impl "pion_fair=$BIN/pion_fair hpack_decode $C/hpack_stream.bin" \
    --impl "pion_shipped_bench=$BIN/pion_shipped hpack_decode $C/hpack_stream.bin" \
    --impl "go_xnet_v0.62=$BIN/go_fair hpack_decode $C/hpack_stream.bin" \
    --impl "go_xnet_v0.34_shipped=$BIN/go_shipped hpack_decode $C/hpack_stream.bin" \
    --impl "rust_h2_0.4.20=$BIN/h2_hpack hpack_decode $C/hpack_stream.bin" \
    --impl "rust_hpack_patched_0.3.0=$BIN/rs_shipped hpack_decode $C/hpack_stream.bin" \
    --baseline rust_h2_0.4.20 --ops 100000 --bytes "$HB" --md-out "$OUT/reports/b1.md" --json-out "$OUT/reports/b1.json"
  $BC --title "B2 HPACK encode, Huffman ON (100k blocks)" \
    --impl "pion_fair_huff=$BIN/pion_fair hpack_encode_huff $C/headers_plain.bin" \
    --impl "pion_shipped_bench=$BIN/pion_shipped hpack_encode $C/headers_plain.bin" \
    --impl "go_xnet_v0.62=$BIN/go_fair hpack_encode $C/headers_plain.bin" \
    --impl "rust_h2_0.4.20=$BIN/h2_hpack hpack_encode $C/headers_plain.bin" \
    --baseline rust_h2_0.4.20 --ops 100000 --bytes "$PB" --md-out "$OUT/reports/b2.md" --json-out "$OUT/reports/b2.json"
  $BC --title "B3 HPACK encode, Huffman OFF (100k blocks)" \
    --impl "pion_fair_raw=$BIN/pion_fair hpack_encode_raw $C/headers_plain.bin" \
    --impl "rust_hpack_patched_0.3.0=$BIN/rs_shipped hpack_encode $C/headers_plain.bin" \
    --baseline rust_hpack_patched_0.3.0 --ops 100000 --bytes "$PB" --md-out "$OUT/reports/b3.md" --json-out "$OUT/reports/b3.json"
  $BC --title "B4 Frame engine: deframe + CONTINUATION + HPACK (200k frames)" \
    --impl "pion_fair_codec=$BIN/pion_fair frames_codec $C/frame_stream.bin" \
    --impl "pion_fair_conn=$BIN/pion_fair frames_conn $C/frame_stream.bin" \
    --impl "go_xnet_v0.62_framer=$BIN/go_fair frames $C/frame_stream.bin" \
    --impl "rust_h2_0.4.20_codec=$BIN/h2_codec frames $C/frame_stream.bin" \
    --baseline rust_h2_0.4.20_codec --ops 200000 --bytes "$FB" --md-out "$OUT/reports/b4.md" --json-out "$OUT/reports/b4.json"
}

case "$WHAT" in
  build) build ;;
  tests) run_tests ;;
  hpack) corpora; run_hpack ;;
  frames) corpora; run_frames ;;
  conn) corpora; run_conn ;;
  wasm) corpora; run_wasm ;;
  probe) run_probe ;;
  bench) run_bench ;;
  all)
    build
    corpora
    run_tests
    run_hpack
    run_frames
    run_conn
    run_wasm
    run_probe
    run_bench
    ;;
  *) echo "usage: $0 [all|build|tests|hpack|frames|conn|wasm|probe|bench]" >&2; exit 2 ;;
esac
step "done; reports in $OUT/reports"
