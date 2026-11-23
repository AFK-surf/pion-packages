#!/bin/sh
# Head-to-head benchmark runner for packages/mp4:
# Pion Native (--release) vs independent pure-Rust `symphonia-format-isomp4` 0.5 (--release),
# with mandatory `ffprobe` ground-truth verification on all corpora (including multi-trun fMP4).
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
FFPROBE_BIN="${FFPROBE:-/opt/homebrew/bin/ffprobe}"
if [ ! -x "$FFMPEG_BIN" ]; then
  FFMPEG_BIN=$(command -v ffmpeg)
fi
if [ ! -x "$FFPROBE_BIN" ]; then
  FFPROBE_BIN=$(command -v ffprobe)
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

# Generate a real multi-trun fMP4 media segment (2 trun boxes inside 1 traf) from yt_seg_0_1.m4s
python3 - "$MEDIA_DIR/yt_seg_0_1.m4s" "$MEDIA_DIR/yt_seg_0_1_multitrun.m4s" <<'PYEOF'
import struct, sys

src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()

def parse_boxes(buf, start, end):
    out = []
    p = start
    while p + 8 <= end:
        sz = struct.unpack_from(">I", buf, p)[0]
        typ = buf[p+4:p+8]
        if sz == 0:
            sz = end - p
        out.append((typ, p, sz))
        p += sz
    return out

top = parse_boxes(data, 0, len(data))
out = bytearray()
for typ, off, sz in top:
    if typ != b"moof":
        out += data[off:off+sz]
        continue
    moof_children = parse_boxes(data, off + 8, off + sz)
    new_moof_body = bytearray()
    # First compute delta in moof size when splitting 1 trun into 2 truns
    # Splitting adds 1 trun header (12 B) + sample_count (4 B) + data_offset (4 B) = 20 B
    # (or 16 B without data_offset on 2nd trun, which chains directly!)
    for mtyp, moff, msz in moof_children:
        if mtyp != b"traf":
            new_moof_body += data[moff:moff+msz]
            continue
        traf_children = parse_boxes(data, moff + 8, moff + msz)
        new_traf_body = bytearray()
        for ttyp, toff, tsz in traf_children:
            if ttyp != b"trun":
                new_traf_body += data[toff:toff+tsz]
                continue
            ver = data[toff + 8]
            flags = int.from_bytes(data[toff+9:toff+12], "big")
            sc = struct.unpack_from(">I", data, toff + 12)[0]
            p = toff + 16
            data_off = None
            if flags & 0x1:
                data_off = struct.unpack_from(">i", data, p)[0]
                p += 4
            first_flags = None
            if flags & 0x4:
                first_flags = struct.unpack_from(">I", data, p)[0]
                p += 4
            per_sz = (4 if flags & 0x100 else 0) + (4 if flags & 0x200 else 0) + (4 if flags & 0x400 else 0) + (4 if flags & 0x800 else 0)
            half = sc // 2
            rem = sc - half
            entries1 = data[p : p + half * per_sz]
            entries2 = data[p + half * per_sz : p + sc * per_sz]
            # Sum byte sizes of trun1 samples so trun2 gets an explicit data_offset
            trun1_bytes = 0
            sz_off = (4 if flags & 0x100 else 0)
            for k in range(half):
                trun1_bytes += struct.unpack_from(">I", entries1, k * per_sz + sz_off)[0]
            # trun2 keeps data_offset (0x1) and omits first_sample_flags (0x4)
            flags2 = (flags & ~0x4) | 0x1
            # Splitting 1 trun into 2 adds 1 trun header (16 B) + trun2 data_offset (4 B) = 20 B
            delta = 20
            trun2_body = bytearray(struct.pack(">BBHI", ver, (flags2 >> 16) & 255, flags2 & 65535, rem))
            trun2_body += struct.pack(">i", (data_off or 0) + delta + trun1_bytes)
            trun2_body += entries2
            trun2 = struct.pack(">I4s", 8 + len(trun2_body), b"trun") + trun2_body
            trun1_body = bytearray(struct.pack(">BBHI", ver, (flags >> 16) & 255, flags & 65535, half))
            if data_off is not None:
                trun1_body += struct.pack(">i", data_off + delta)
            if first_flags is not None:
                trun1_body += struct.pack(">I", first_flags)
            trun1_body += entries1
            trun1 = struct.pack(">I4s", 8 + len(trun1_body), b"trun") + trun1_body
            new_traf_body += trun1 + trun2
        new_moof_body += struct.pack(">I4s", 8 + len(new_traf_body), b"traf") + new_traf_body
    out += struct.pack(">I4s", 8 + len(new_moof_body), b"moof") + new_moof_body

open(dst, "wb").write(out)
PYEOF

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_mp4_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust symphonia-format-isomp4 benchmark (--release, isolated in /tmp/pion-mp4-bench)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/mp4-bench-rust" "$BIN_DIR/rust_mp4_bench"

STD_MP4="$MEDIA_DIR/standard_h264_aac.mp4"
YT_V_INIT="$MEDIA_DIR/yt_init_0.m4s"
YT_V_SEG1="$MEDIA_DIR/yt_seg_0_1.m4s"
YT_V_MTRUN="$MEDIA_DIR/yt_seg_0_1_multitrun.m4s"
YT_A_INIT="$MEDIA_DIR/yt_init_1.m4s"
YT_A_SEG1="$MEDIA_DIR/yt_seg_1_1.m4s"

echo "==> Verifying Pion against independent ffprobe ground-truth on all 4 corpora (incl. multi-trun)"
python3 - "$BIN_DIR/pion_mp4_bench" "$FFPROBE_BIN" "$OUT_DIR" "$STD_MP4" "$YT_V_INIT" "$YT_V_SEG1" "$YT_V_MTRUN" "$YT_A_INIT" "$YT_A_SEG1" <<'PYEOF'
import json, os, subprocess, sys

pion_bin, ffprobe_bin, out_dir, std_mp4, v_init, v_seg, v_mtrun, a_init, a_seg = sys.argv[1:]

def check_one(label, mode, a, b=None):
    if mode == "mp4":
        dump = subprocess.check_output([pion_bin, "dump-mp4", a], text=True)
        probe_path, base = a, 0
    else:
        dump = subprocess.check_output([pion_bin, "dump-fmp4", a, b], text=True)
        probe_path = os.path.join(out_dir, f"probe_{label}.mp4")
        open(probe_path, "wb").write(open(a, "rb").read() + open(b, "rb").read())
        base = os.path.getsize(a)
    pr = json.loads(subprocess.check_output([
        ffprobe_bin, "-v", "error",
        "-show_entries", "stream=index,id:packet=stream_index,pts,dts,duration,size,pos,flags",
        "-of", "json", probe_path
    ], text=True))
    sid2tid = {s["index"]: int(s["id"], 16) for s in pr["streams"]}
    ff_by_t = {}
    for p in pr["packets"]:
        ff_by_t.setdefault(sid2tid[p["stream_index"]], []).append(p)
    pion_by_t = {}
    for line in dump.splitlines():
        parts = line.split()
        if parts[0] == "s":
            tid, off, sz, dts, pts, dur, sync = [int(x) for x in parts[1:]]
            pion_by_t.setdefault(tid, []).append((off, sz, dts, pts, dur, sync))
    assert set(pion_by_t.keys()) == set(ff_by_t.keys()), f"{label}: track mismatch"
    total = 0
    for tid, ps in pion_by_t.items():
        ff = ff_by_t[tid]
        assert len(ps) == len(ff), f"{label} t{tid}: count {len(ps)} != {len(ff)}"
        for i, ((off, sz, dts, pts, dur, sync), p) in enumerate(zip(ps, ff)):
            assert off + base == int(p["pos"]), f"{label} t{tid}[{i}] pos {off+base} != {p['pos']}"
            assert sz == int(p["size"]), f"{label} t{tid}[{i}] size {sz} != {p['size']}"
            assert dur == int(p["duration"]), f"{label} t{tid}[{i}] dur {dur} != {p['duration']}"
            assert bool(sync) == ("K" in p["flags"]), f"{label} t{tid}[{i}] key mismatch"
            assert dts == int(p["dts"]), f"{label} t{tid}[{i}] dts {dts} != {p['dts']}"
            assert pts == int(p["pts"]), f"{label} t{tid}[{i}] pts {pts} != {p['pts']}"
        total += len(ps)
    print(f"  ffprobe oracle PASS: {label} ({len(pion_by_t)} track(s), {total} samples exact on pos/size/dts/pts/dur/key)")

check_one("standard_mp4", "mp4", std_mp4)
check_one("fmp4_video", "fmp4", v_init, v_seg)
check_one("fmp4_video_multitrun", "fmp4", v_init, v_mtrun)
check_one("fmp4_audio", "fmp4", a_init, a_seg)
PYEOF

echo ""
echo "=== BENCH 1: Standard MP4 Demux (H.264 720p B-frames + AAC-LC x 1000) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "MP4 Demux: Standard H.264+AAC (moov+stbl x 1000)" \
  --impl "pion=$BIN_DIR/pion_mp4_bench mp4 $STD_MP4 1000" \
  --impl "rust_symphonia=$BIN_DIR/rust_mp4_bench mp4 $STD_MP4 1000" \
  --baseline rust_symphonia \
  --warmup 1 --rounds 5 --ops 1000 \
  --md-out "$OUT_DIR/bench_mp4.md" --json-out "$OUT_DIR/bench_mp4.json"

echo ""
echo "=== BENCH 2: YouTube MSE fMP4 Video Init + Media Segment (sidx+moof+mdat x 1000) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "fMP4 MSE Video Segment (H.264 720p init+seg x 1000)" \
  --impl "pion=$BIN_DIR/pion_mp4_bench fmp4 $YT_V_INIT $YT_V_SEG1 1000" \
  --impl "rust_symphonia=$BIN_DIR/rust_mp4_bench fmp4 $YT_V_INIT $YT_V_SEG1 1000" \
  --baseline rust_symphonia \
  --warmup 1 --rounds 5 --ops 1000 \
  --md-out "$OUT_DIR/bench_fmp4_video.md" --json-out "$OUT_DIR/bench_fmp4_video.json"

echo ""
echo "=== BENCH 3: Multi-trun fMP4 Video Init + Media Segment (2 truns/traf x 1000) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "fMP4 Multi-trun Video Segment (2 truns/traf init+seg x 1000)" \
  --impl "pion=$BIN_DIR/pion_mp4_bench fmp4 $YT_V_INIT $YT_V_MTRUN 1000" \
  --impl "rust_symphonia=$BIN_DIR/rust_mp4_bench fmp4 $YT_V_INIT $YT_V_MTRUN 1000" \
  --baseline rust_symphonia \
  --warmup 1 --rounds 5 --ops 1000 \
  --md-out "$OUT_DIR/bench_fmp4_multitrun.md" --json-out "$OUT_DIR/bench_fmp4_multitrun.json"

echo ""
echo "=== BENCH 4: YouTube MSE fMP4 Audio Init + Media Segment (AAC-LC x 2000) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "fMP4 MSE Audio Segment (AAC-LC 48kHz init+seg x 2000)" \
  --impl "pion=$BIN_DIR/pion_mp4_bench fmp4 $YT_A_INIT $YT_A_SEG1 2000" \
  --impl "rust_symphonia=$BIN_DIR/rust_mp4_bench fmp4 $YT_A_INIT $YT_A_SEG1 2000" \
  --baseline rust_symphonia \
  --warmup 1 --rounds 5 --ops 2000 \
  --md-out "$OUT_DIR/bench_fmp4_audio.md" --json-out "$OUT_DIR/bench_fmp4_audio.json"
