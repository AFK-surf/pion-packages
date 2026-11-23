#!/usr/bin/env python3
"""Generate real ffmpeg WebM corpora for packages/webm head-to-head benchmarks."""

import os
import subprocess
import sys

FFMPEG = "/opt/homebrew/bin/ffmpeg"
CLUSTER_ID = b"\x1f\x43\xb6\x75"
CUES_ID = b"\x1c\x53\xbb\x6b"


def run_ffmpeg(args):
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y"] + args
    subprocess.run(cmd, check=True)


def read_vint_size(data, pos):
    b0 = data[pos]
    length = 1
    mask = 0x80
    while (b0 & mask) == 0:
        mask >>= 1
        length += 1
    val = b0 & ((1 << (8 - length)) - 1)
    for i in range(1, length):
        val = (val << 8) | data[pos + i]
    all_ones = (1 << (7 * length)) - 1
    if val == all_ones:
        return None, pos + length
    return val, pos + length


def read_vint_id(data, pos):
    b0 = data[pos]
    length = 1
    mask = 0x80
    while (b0 & mask) == 0:
        mask >>= 1
        length += 1
    eid = 0
    for i in range(length):
        eid = (eid << 8) | data[pos + i]
    return eid, pos + length


def split_mse_segments(webm_path, init_out, media_out):
    """Split a WebM file into an MSE Init Segment (EBML+Segment+Info+Tracks) and standalone Clusters."""
    data = open(webm_path, "rb").read()
    pos = 0
    n = len(data)
    # 1. Skip EBML header
    eid, pos = read_vint_id(data, pos)
    assert eid == 0x1A45DFA3, f"expected EBML header, got 0x{eid:x}"
    esz, pos = read_vint_size(data, pos)
    pos += esz

    # 2. Enter Segment
    eid, pos = read_vint_id(data, pos)
    assert eid == 0x18538067, f"expected Segment, got 0x{eid:x}"
    seg_sz, seg_data_start = read_vint_size(data, pos)
    seg_end = n if seg_sz is None else seg_data_start + seg_sz

    first_cluster_off = None
    last_cluster_end = None
    init_children = bytearray()
    spos = seg_data_start
    while spos < seg_end:
        elem_start = spos
        cid, cpos = read_vint_id(data, spos)
        csz, pstart = read_vint_size(data, cpos)
        if csz is None:
            raise RuntimeError("unexpected unknown-size child in ffmpeg output")
        pend = pstart + csz
        if cid in (0x1549A966, 0x1654AE6B):  # Info, Tracks
            init_children.extend(data[elem_start:pend])
        elif cid == 0x1F43B675:  # Cluster
            if first_cluster_off is None:
                first_cluster_off = elem_start
            last_cluster_end = pend
        spos = pend

    assert first_cluster_off is not None and last_cluster_end is not None

    # Rewrite Segment size to unknown-size (8-byte 0x01FFFFFFFFFFFFFF) for MSE Init Segment
    ebml_part = data[: data.index(b"\x18\x53\x80\x67")]
    init_header = (
        ebml_part
        + b"\x18\x53\x80\x67"
        + b"\x01\xff\xff\xff\xff\xff\xff\xff"
        + bytes(init_children)
    )
    media_clusters = data[first_cluster_off:last_cluster_end]

    with open(init_out, "wb") as f:
        f.write(init_header)
    with open(media_out, "wb") as f:
        f.write(media_clusters)


def main():
    if len(sys.argv) < 2:
        print("usage: gen_data.py <out_dir>", file=sys.stderr)
        sys.exit(1)
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    vp9_opus = os.path.join(out_dir, "vp9_opus.webm")
    opus_audio = os.path.join(out_dir, "opus_audio.webm")
    av1_opus = os.path.join(out_dir, "av1_opus.webm")
    mse_init = os.path.join(out_dir, "mse_init.webm")
    mse_media = os.path.join(out_dir, "mse_media.webm")

    if not os.path.exists(vp9_opus):
        run_ffmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=12",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=12",
                "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8",
                "-b:v", "250k", "-g", "30",
                "-c:a", "libopus", "-b:a", "64k", "-ac", "2",
                "-f", "webm", vp9_opus,
            ]
        )

    if not os.path.exists(opus_audio):
        run_ffmpeg(
            [
                "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=60",
                "-c:a", "libopus", "-b:a", "96k", "-ac", "2",
                "-f", "webm", opus_audio,
            ]
        )

    if not os.path.exists(av1_opus):
        run_ffmpeg(
            [
                "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=10",
                "-f", "lavfi", "-i", "sine=frequency=523:sample_rate=48000:duration=10",
                "-c:v", "libsvtav1", "-preset", "12", "-g", "24", "-b:v", "200k",
                "-c:a", "libopus", "-b:a", "64k", "-ac", "2",
                "-f", "webm", av1_opus,
            ]
        )

    if not os.path.exists(mse_init) or not os.path.exists(mse_media):
        split_mse_segments(vp9_opus, mse_init, mse_media)

    for p in [vp9_opus, opus_audio, av1_opus, mse_init, mse_media]:
        print(f"  {os.path.basename(p):16s}: {os.path.getsize(p):>10d} B")


if __name__ == "__main__":
    main()
