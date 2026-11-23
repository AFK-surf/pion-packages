#!/bin/sh
# One-shot red-team audit of packages/webm v0.1.0 (Pion Native --release + Wasm32 --release vs
# matroska-demuxer 0.6.1, symphonia-format-mkv 0.5.5, ffprobe 9.0.2; libwebm rules quoted in REPORT.md).
#
#   sh packages/webm/audit/run_audit.sh [all|build|unit|diff|vectors|bombs|fuzz|perf]
#
# Needs: pionc (~/.pion/bin), node (Wasm32 runtime ~/.pion/share/pion/pion_wasm_rt.mjs), cargo,
# /opt/homebrew/bin/ffmpeg + ffprobe (libvpx, libsvtav1, libx264, libopus), python3.
# Everything built or generated goes to $AUDIT_OUT (default /private/tmp/pion-webm-audit, the real path of /tmp
# on macOS so the Wasm32 runtime sees the same paths). Nothing is written inside the repository.
# No sample/lldb: timings are wall-clock loops (Developer Mode is off on the audit host).
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG_DIR=$(CDPATH= cd -- "$AUDIT_DIR/.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/pion-webm-audit}
BIN="$OUT/bin"
SECTION=${1:-all}
FUZZ_N=${FUZZ_N:-12000}
RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
mkdir -p "$BIN"

hdr() { printf '\n==== %s ====\n' "$*"; }

build() {
  hdr "build: Pion harness (native --release, wasm32 --release), Rust oracles, ffmpeg corpus + vectors -> $OUT"
  pionc fmt --check "$AUDIT_DIR" || exit 1
  pionc check --json "$AUDIT_DIR" > /dev/null || exit 1
  rm -f "$BIN/pion_audit" "$BIN/pion_audit.wasm" "$BIN/rust_audit"
  pionc build --release -o "$BIN/pion_audit" "$AUDIT_DIR" || exit 1
  pionc build --release --target wasm32 -o "$BIN/pion_audit.wasm" "$AUDIT_DIR" || exit 1
  rm -rf "$OUT/rust-proj" && mkdir -p "$OUT/rust-proj"
  cp -R "$AUDIT_DIR/diff/rust/Cargo.toml" "$AUDIT_DIR/diff/rust/src" "$OUT/rust-proj/"
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build -q --release --manifest-path "$OUT/rust-proj/Cargo.toml" || exit 1
  cp "$OUT/rust-target/release/webm-audit-rust" "$BIN/rust_audit"  # rm + cp: macOS kills re-signed-in-place binaries
  if [ ! -f "$OUT/corpus/mse_media_yt.webm" ]; then
    python3 "$AUDIT_DIR/diff/gen_corpus.py" "$OUT/corpus" 2>/dev/null | tail -1 || exit 1
  fi
  python3 "$AUDIT_DIR/diff/vectors.py" "$OUT/vectors" || exit 1
  # the committed redteam_test.pion must be exactly what the generator + pionc fmt produce
  python3 "$AUDIT_DIR/diff/gen_redteam_test.py" > "$OUT/redteam_test.gen.pion" || exit 1
  mkdir -p "$OUT/fmtcheck" && cp "$OUT/redteam_test.gen.pion" "$OUT/fmtcheck/redteam_test.pion"
  pionc fmt "$OUT/fmtcheck/redteam_test.pion" > /dev/null 2>&1
  if cmp -s "$OUT/fmtcheck/redteam_test.pion" "$AUDIT_DIR/redteam_test.pion"; then
    echo "redteam_test.pion == gen_redteam_test.py | pionc fmt"
  else
    echo "redteam_test.pion is stale: regenerate with diff/gen_redteam_test.py + pionc fmt"; exit 1
  fi
}

unit() {
  hdr "unit: red-team tests, one process per test (redteam_* FAIL while the defect exists; control_* must PASS)"
  bad=0
  for t in $(grep -o '^test "[a-z0-9_]*"' "$AUDIT_DIR/redteam_test.pion" | cut -d'"' -f2); do
    out=$(pionc test --json --filter "$t" "$AUDIT_DIR" 2>&1)
    if echo "$out" | grep -q '"ok":true' && ! echo "$out" | grep -q '"ok":false'; then r=PASS; else r=FAIL; fi
    msg=$(echo "$out" | grep -o 'redteam_test\.pion:[0-9]*: [^"]*' | head -1 | sed 's/redteam_test\.pion:[0-9]*: //' | cut -c1-110)
    case "$t" in redteam_*) k=RED ;; *) k=CTRL ;; esac
    printf "  %-4s %-4s %-58s %s\n" "$k" "$r" "$t" "$msg"
    [ "$k" = CTRL ] && [ "$r" != PASS ] && bad=1
  done
  return $bad
}

vectors() {
  hdr "vectors: hand-built adversarial inputs, Pion native / Pion wasm32 / matroska-demuxer / ffprobe"
  for f in "$OUT"/vectors/*.webm; do
    n=$(basename "$f" .webm)
    case "$n" in bomb_*|kf_*) continue ;; esac
    p=$("$BIN/pion_audit" dump "$f" | head -1 | cut -c1-84)
    pf=$("$BIN/pion_audit" dump "$f" | grep '^F' | head -2 | cut -d' ' -f2,3,5 | tr '\n' ';')
    w=$(node "$RT" "$BIN/pion_audit.wasm" dump "$f" 2>&1 | head -1 | cut -c1-84)
    [ "$w" = "$p" ] && w="(same as native)"
    r=$("$BIN/rust_audit" dump "$f" 2>&1 | grep -v '^T' | head -3 | cut -d' ' -f1-4 | tr '\n' ';' | cut -c1-90)
    ffp=$(ffprobe -v error -show_entries packet=stream_index,pts,size,flags -of csv=p=0 "$f" 2>/dev/null | head -3 | tr '\n' ';' | cut -c1-60)
    printf "  %-36s pion: %s | %s\n  %-36s wasm: %s\n  %-36s rust: %s\n  %-36s ffprobe: %s\n" "$n" "$p" "$pf" "" "$w" "" "$r" "" "${ffp:-(no packets)}"
  done
}

bombs() {
  hdr "bombs: tiny inputs vs. peak RSS / wall time (parse_webm, default DecodeLimits, native --release)"
  base_rss=""
  for f in "$OUT/corpus/opus_audio_60s.webm" "$OUT"/vectors/bomb_*.webm; do
    /usr/bin/time -l "$BIN/pion_audit" bench "$f" 1 parse > "$OUT/bomb.out" 2> "$OUT/bomb.err"
    rss=$(awk '/maximum resident set size/ {printf "%.1f", $1/1048576}' "$OUT/bomb.err")
    sz=$(wc -c < "$f" | tr -d ' ')
    printf "  %-34s %9s B  peakRSS %7s MiB  %s\n" "$(basename "$f")" "$sz" "$rss" "$(cat "$OUT/bomb.out")"
  done
  rm -f "$OUT/bomb.out" "$OUT/bomb.err"
  hdr "bombs on wasm32 --release (node): same inputs, verdict line only"
  for f in "$OUT"/vectors/bomb_*.webm; do
    printf "  %-34s %s\n" "$(basename "$f")" "$(node "$RT" "$BIN/pion_audit.wasm" bench "$f" 1 parse 2>&1 | head -1)"
  done
}

perf() {
  hdr "perf 1: parse_webm only, Pion native --release vs matroska-demuxer --release (2000 iters, 5 alternating rounds)"
  for f in opus_audio_60s.webm vp9_opus_cues.webm av1_opus.webm; do
    for r in 1 2 3 4 5; do
      "$BIN/pion_audit" bench "$OUT/corpus/$f" 2000 parse | sed "s|^|  $f pion  |"
      "$BIN/rust_audit" bench "$OUT/corpus/$f" 2000 | sed "s|^|  $f rust  |"
    done
  done
  hdr "perf 2: per-call cost of the public VINT readers (10M calls each)"
  "$BIN/pion_audit" micro "$OUT/corpus/flac_audio.mkv" 10000000 | sed 's/^/  /'
  hdr "perf 3: stage attribution on Pure Opus 60 s (patched package copies in $OUT/prof, 2000 iters x 7 rounds)"
  python3 "$AUDIT_DIR/diff/prof_variants.py" "$PKG_DIR" "$AUDIT_DIR/src" "$OUT/prof" "$OUT/corpus/opus_audio_60s.webm" 2000 7
  hdr "perf 4: find_keyframe_at cost (2000 queries), 200k-frame single-track file with one keyframe vs real file"
  python3 - "$OUT/vectors/kf_sparse_200k.webm" <<PYEOF
import sys
sys.path.insert(0, "$AUDIT_DIR/diff")
from vectors import *
n = 200000
blocks = [sblock(rel=i % 1000, flags=0x80 if i == 0 else 0x00, payload=b"\x00") for i in range(n)]
open(sys.argv[1], "wb").write(base(*[cluster(i, *blocks[i:i + 1000]) for i in range(0, n, 1000)]))
PYEOF
  "$BIN/pion_audit" kfbench "$OUT/vectors/kf_sparse_200k.webm" 2000 | sed 's/^/  /'
  "$BIN/pion_audit" kfbench "$OUT/corpus/vp9_opus_cues.webm" 2000 | sed 's/^/  /'
}

rc=0
case "$SECTION" in
  build) build ;;
  unit) unit || rc=1 ;;
  diff) python3 "$AUDIT_DIR/diff/compare.py" "$BIN" "$OUT/corpus" ;;
  vectors) vectors ;;
  bombs) bombs ;;
  fuzz) hdr "fuzz: $FUZZ_N structure-aware cases, native --release vs wasm32 --release (+ matroska-demuxer verdicts)"
        rm -rf "$OUT/fuzz"; python3 "$AUDIT_DIR/diff/fuzz.py" "$BIN" "$OUT/corpus" "$OUT/fuzz" "$FUZZ_N" 20261123 2>/dev/null ;;
  perf) perf ;;
  all)
    build
    unit || rc=1
    hdr "diff: real ffmpeg corpus vs matroska-demuxer / ffprobe / symphonia + find_keyframe_at oracle"
    python3 "$AUDIT_DIR/diff/compare.py" "$BIN" "$OUT/corpus"
    vectors
    bombs
    hdr "fuzz: $FUZZ_N structure-aware cases, native --release vs wasm32 --release (+ matroska-demuxer verdicts)"
    rm -rf "$OUT/fuzz"; python3 "$AUDIT_DIR/diff/fuzz.py" "$BIN" "$OUT/corpus" "$OUT/fuzz" "$FUZZ_N" 20261123 2>/dev/null
    perf
    ;;
  *) echo "usage: run_audit.sh [all|build|unit|diff|vectors|bombs|fuzz|perf]"; exit 2 ;;
esac
exit $rc
