#!/bin/sh
# One-shot red-team audit for packages/mp4 (RT-mp4, base feat/pkg-mp4 @ a0084452).
#   sh packages/mp4/audit/run_audit.sh [all|build|corpus|unit|compare|seek|fuzz|dos|prof]
# Every artifact (binaries, FFmpeg corpus, fuzz shards, Cargo target, patched perf copies) goes to
# $AUDIT_OUT (default /private/tmp/pion-mp4-audit: the real path of /tmp on macOS, because the wasm32
# runner resolves symlinks). Nothing is written inside the repository.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-mp4-audit}
BIN="$AUDIT_OUT/bin"
FFMPEG=${FFMPEG:-/opt/homebrew/bin/ffmpeg}
SECTION=${1:-all}
export FUZZ_N=${FUZZ_N:-12000}
export AUDIT_OUT FFMPEG
mkdir -p "$BIN"

build() {
  echo "==> build: Pion harness native --release + wasm32 --release -> $BIN"
  pionc fmt --check "$AUDIT_DIR" || exit 1
  pionc check --json "$AUDIT_DIR" || exit 1
  pionc build --release -o "$BIN/mp4_audit" "$AUDIT_DIR" || exit 1
  pionc build --release --target wasm32 -o "$BIN/mp4_audit.wasm" "$AUDIT_DIR" || exit 1
  pionc --version; node --version; python3 --version; "$FFMPEG" -hide_banner -version | head -1
}

corpus() {
  echo "==> corpus: FFmpeg MP4 / fMP4 / DASH inputs + BMFF rewrites (co64, stz2, v1 headers, uuid, size0/largesize mdat, ctts v1, sidx v0)"
  python3 "$AUDIT_DIR/corpus.py" "$AUDIT_OUT/media" 2>/dev/null || exit 1
}

unit() {
  echo "==> unit: redteam_test.pion (redteam_* FAIL while the defect exists; control_* must PASS)"
  python3 "$AUDIT_DIR/vectors.py" pion > "$AUDIT_OUT/vectors_block.pion"
  sed -n '/^\/\/ BEGIN GENERATED VECTORS/,$p' "$AUDIT_DIR/redteam_test.pion" | cmp -s - "$AUDIT_OUT/vectors_block.pion" \
    || { echo "  generated vector block is stale: regenerate with python3 vectors.py pion"; return 1; }
  pionc test --json "$AUDIT_DIR" > "$AUDIT_OUT/unit.json" 2> "$AUDIT_OUT/unit.stderr"
  python3 - "$AUDIT_OUT/unit.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
bad = 0
for t in d['tests']:
    if t['pkg'] != 'mp4_audit':
        continue
    kind = 'RED ' if t['name'].startswith('redteam_') else 'CTRL'
    print(f"  {kind} {'PASS' if t['ok'] else 'FAIL'}  {t['name']}")
    bad += kind == 'CTRL' and not t['ok']
up = [t for t in d['tests'] if t['pkg'] != 'mp4_audit']
print(f"  upstream mp4 tests: {sum(t['ok'] for t in up)}/{len(up)} pass")
sys.exit(1 if bad else 0)
PY
}

prof() {
  echo "==> prof: fMP4 video bench segment, Pion init/media split + patched-variant experiments"
  M="$AUDIT_OUT/bench"
  mkdir -p "$M"
  if [ ! -f "$M/yt_seg_0_1.m4s" ]; then
    (cd "$M" && "$FFMPEG" -y -hide_banner -loglevel error \
      -f lavfi -i testsrc2=size=1280x720:rate=30:duration=4 -f lavfi -i sine=frequency=440:sample_rate=48000:duration=4 \
      -c:v libx264 -preset ultrafast -g 30 -bf 2 -pix_fmt yuv420p -c:a aac -b:a 128k -ac 2 -movflags +faststart standard_h264_aac.mp4 \
      && "$FFMPEG" -y -hide_banner -loglevel error -i standard_h264_aac.mp4 -c copy -f dash \
      -init_seg_name 'yt_init_$RepresentationID$.m4s' -media_seg_name 'yt_seg_$RepresentationID$_$Number$.m4s' \
      -seg_duration 2 -use_template 1 -use_timeline 1 yt_manifest.mpd) || return 1
  fi
  python3 "$AUDIT_DIR/perf.py" "${PERF_ITERS:-300000}"
}

rc=0
case "$SECTION" in
  build) build ;;
  corpus) corpus ;;
  unit) unit || rc=1 ;;
  compare|seek|dos) python3 "$AUDIT_DIR/difftest.py" "$SECTION" || rc=1 ;;
  fuzz) python3 "$AUDIT_DIR/difftest.py" fuzz || rc=1 ;;
  prof) prof || rc=1 ;;
  all)
    build
    corpus
    unit || rc=1
    python3 "$AUDIT_DIR/difftest.py" compare || rc=1
    python3 "$AUDIT_DIR/difftest.py" seek || rc=1
    python3 "$AUDIT_DIR/difftest.py" fuzz || rc=1
    python3 "$AUDIT_DIR/difftest.py" dos || rc=1
    prof || rc=1
    ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
cd "$ROOT_DIR" && if [ -n "$(git status --porcelain --ignored)" ]; then
  git status --porcelain --ignored | grep -v '^?? packages/mp4/audit/$' | grep . && { echo "worktree NOT clean"; rc=1; }
fi
exit $rc
