#!/bin/sh
# Head-to-head benchmark runner for packages/mp4:
# Pion Native (--release) vs Rust `mp4` crate 0.14 (--release).
# All build artifacts, Cargo lockfile, and FFmpeg corpora are isolated in /tmp/pion-mp4-bench.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-mp4-bench"
MEDIA_DIR="$OUT_DIR/media"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$MEDIA_DIR" "$BIN_DIR"

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  if command -v pionc >/dev/null 2>&1; then
    PIONC_BIN=$(command -v pionc)
  elif [ -x "${HOME:-}/.pion/bin/pionc" ]; then
    PIONC_BIN="${HOME}/.pion/bin/pionc"
  fi
fi

FFMPEG_BIN="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
if [ ! -x "$FFMPEG_BIN" ]; then
  FFMPEG_BIN=$(command -v ffmpeg)
fi

if [ ! -f "$MEDIA_DIR/standard_h264_aac.mp4" ] || [ ! -f "$MEDIA_DIR/yt_seg_0_1.m4s" ]; then
  echo "==> Generating deterministic FFmpeg MP4 & fMP4 corpora -> $MEDIA_DIR"
  (
    cd "$MEDIA_DIR"
    "$FFMPEG_BIN" -y -hide_banner -loglevel error \
      -f lavfi -i testsrc2=size=1280x720:rate=30:duration=4 \
      -f lavfi -i sine=frequency=440:sample_rate=48000:duration=4 \
      -c:v libx264 -preset ultrafast -g 30 -bf 2 -pix_fmt yuv420p \
      -c:a aac -b:a 128k -ac 2 \
      -movflags +faststart \
      standard_h264_aac.mp4
    "$FFMPEG_BIN" -y -hide_banner -loglevel error \
      -i standard_h264_aac.mp4 -c copy \
      -f dash -init_seg_name 'yt_init_$RepresentationID$.m4s' \
      -media_seg_name 'yt_seg_$RepresentationID$_$Number$.m4s' \
      -seg_duration 2 -use_template 1 -use_timeline 1 \
      yt_manifest.mpd
  )
fi

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_mp4_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust mp4 benchmark (--release, isolated in /tmp/pion-mp4-bench)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/mp4-bench-rust" "$BIN_DIR/rust_mp4_bench"

STD_MP4="$MEDIA_DIR/standard_h264_aac.mp4"
YT_V_INIT="$MEDIA_DIR/yt_init_0.m4s"
YT_V_SEG1="$MEDIA_DIR/yt_seg_0_1.m4s"
YT_A_INIT="$MEDIA_DIR/yt_init_1.m4s"
YT_A_SEG1="$MEDIA_DIR/yt_seg_1_1.m4s"

STD_SIZE=$(wc -c < "$STD_MP4" | tr -d ' ')
YTV_SIZE=$(( $(wc -c < "$YT_V_INIT" | tr -d ' ') + $(wc -c < "$YT_V_SEG1" | tr -d ' ') ))
YTA_SIZE=$(( $(wc -c < "$YT_A_INIT" | tr -d ' ') + $(wc -c < "$YT_A_SEG1" | tr -d ' ') ))

echo ""
echo "=== BENCH 1: Standard MP4 Demux (H.264 720p B-frames + AAC-LC x 5000) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "MP4 Demux: Standard H.264+AAC (moov+stbl x 5000)" \
  --impl "pion=$BIN_DIR/pion_mp4_bench mp4 $STD_MP4 5000" \
  --impl "rust_mp4=$BIN_DIR/rust_mp4_bench mp4 $STD_MP4 5000" \
  --baseline rust_mp4 \
  --warmup 1 --rounds 5 --bytes $((STD_SIZE * 5000)) \
  --md-out "$OUT_DIR/bench_mp4.md" --json-out "$OUT_DIR/bench_mp4.json"

echo ""
echo "=== BENCH 2: YouTube MSE fMP4 Video Init + Media Segment (sidx+moof+mdat x 20000) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "fMP4 MSE Video Segment (H.264 720p init+seg x 20000)" \
  --impl "pion=$BIN_DIR/pion_mp4_bench fmp4 $YT_V_INIT $YT_V_SEG1 20000" \
  --impl "rust_mp4=$BIN_DIR/rust_mp4_bench fmp4 $YT_V_INIT $YT_V_SEG1 20000" \
  --baseline rust_mp4 \
  --warmup 1 --rounds 5 --bytes $((YTV_SIZE * 20000)) \
  --md-out "$OUT_DIR/bench_fmp4_video.md" --json-out "$OUT_DIR/bench_fmp4_video.json"

echo ""
echo "=== BENCH 3: YouTube MSE fMP4 Audio Init + Media Segment (AAC-LC init+seg x 20000) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "fMP4 MSE Audio Segment (AAC-LC 48kHz init+seg x 20000)" \
  --impl "pion=$BIN_DIR/pion_mp4_bench fmp4 $YT_A_INIT $YT_A_SEG1 20000" \
  --impl "rust_mp4=$BIN_DIR/rust_mp4_bench fmp4 $YT_A_INIT $YT_A_SEG1 20000" \
  --baseline rust_mp4 \
  --warmup 1 --rounds 5 --bytes $((YTA_SIZE * 20000)) \
  --md-out "$OUT_DIR/bench_fmp4_audio.md" --json-out "$OUT_DIR/bench_fmp4_audio.json"
