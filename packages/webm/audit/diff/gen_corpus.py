#!/usr/bin/env python3
"""Generate the real-world + rewritten WebM/MKV corpus for the packages/webm red-team audit.

  gen_corpus.py <out_dir>

Real files come from /opt/homebrew/bin/ffmpeg (VP8/VP9/AV1/H.264 B-frames + Opus/Vorbis/FLAC/PCM,
multi-cluster with Cues, live/unknown-size Segment).  Rewritten variants re-pack the same frames as
Xiph / fixed-size / EBML laced SimpleBlocks, BlockGroups (BlockDuration + ReferenceBlock +
DiscardPadding), unknown-size Clusters and an MSE init + media split.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ebml import *  # noqa: E402,F401,F403

FF = "/opt/homebrew/bin/ffmpeg"


def ff(args):
    subprocess.run([FF, "-hide_banner", "-loglevel", "error", "-y"] + args, check=True)


SRC_V = ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30"]
SRC_A = ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000"]


def real(out):
    jobs = {
        "vp8_vorbis.webm": SRC_V + SRC_A + ["-t", "4", "-c:v", "libvpx", "-b:v", "300k", "-c:a", "libvorbis" if False else "vorbis", "-strict", "-2", "-ac", "2"],
        "vp9_opus_cues.webm": SRC_V + SRC_A + ["-t", "8", "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-g", "30", "-c:a", "libopus", "-cluster_time_limit", "1000"],
        "av1_opus.webm": SRC_V + SRC_A + ["-t", "3", "-c:v", "libsvtav1", "-preset", "12", "-g", "24", "-c:a", "libopus"],
        "h264_bframes_aac.mkv": SRC_V + SRC_A + ["-t", "4", "-c:v", "libx264", "-preset", "ultrafast", "-bf", "3", "-tune", "film", "-g", "48", "-c:a", "aac"],
        "opus_audio_60s.webm": SRC_A + ["-t", "60", "-c:a", "libopus", "-b:a", "64k"],
        "flac_audio.mkv": SRC_A + ["-t", "5", "-c:a", "flac"],
        "pcm_audio.mkv": SRC_A + ["-t", "3", "-c:a", "pcm_s16le", "-af", "asetnsamples=n=960"],
        "vp9_tiny_clusters.webm": SRC_V + ["-t", "3", "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-cluster_size_limit", "2000", "-cluster_time_limit", "50"],
    }
    for name, args in jobs.items():
        ff(args + [os.path.join(out, name)])
    # live / piped muxing: unknown-size Segment, no Cues, no SeekHead back-patching
    with open(os.path.join(out, "vp9_opus_live.webm"), "wb") as f:
        subprocess.run([FF, "-hide_banner", "-loglevel", "error"] + SRC_V + SRC_A +
                       ["-t", "3", "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-c:a", "libopus",
                        "-live", "1", "-f", "webm", "pipe:1"], stdout=f, check=True)


def rebuild(hdr, kids, clusters, unknown_seg=False, unknown_cluster=False):
    """kids: non-cluster segment children raw bytes; clusters: list of lists of raw child elements."""
    body = b"".join(kids)
    for cl in clusters:
        payload = b"".join(cl)
        if unknown_cluster:
            body += enc_id(CLUSTER) + UNKNOWN8 + payload
        else:
            body += elem(CLUSTER, payload)
    seg = enc_id(SEGMENT) + (UNKNOWN8 if unknown_seg else enc_size(len(body), 8)) + body
    return hdr + seg


def load(path):
    d = open(path, "rb").read()
    hdr, items = split_file(d)
    kids = [raw for (i, raw, _p) in items if i in (INFO, TRACKS)]
    clusters = []
    for i, raw, payload in items:
        if i == CLUSTER:
            cl = []
            for ci, cs, cps, cpe in children(payload, 0, len(payload)):
                cl.append((ci, payload[cs:cpe], payload[cps:cpe]))
            clusters.append(cl)
    return hdr, kids, clusters


def relace(path, out_path, mode, group, track_filter=None):
    """Re-pack runs of consecutive SimpleBlocks of one track into laced blocks of up to `group` frames."""
    hdr, kids, clusters = load(path)
    new_clusters = []
    for cl in clusters:
        out = []
        run = []

        def flush():
            if not run:
                return
            if len(run) == 1:
                out.append(run[0][0])
            else:
                frames = [r[1] for r in run]
                tr, rel, flags, hp = run[0][2]
                head = enc_size(tr) + rel.to_bytes(2, "big", signed=True)
                lflags = (flags & ~0x06) | {"xiph": 0x02, "fixed": 0x04, "ebml": 0x06}[mode]
                hb = bytes([lflags, len(frames) - 1])
                if mode == "xiph":
                    for fr in frames[:-1]:
                        n = len(fr)
                        hb += b"\xff" * (n // 255) + bytes([n % 255])
                elif mode == "ebml":
                    hb += enc_size(len(frames[0]))
                    for a, b in zip(frames[:-2], frames[1:-1]):
                        hb += enc_svint(len(b) - len(a))
                out.append(elem(SIMPLEBLOCK, head + hb + b"".join(frames)))
            run.clear()

        for ci, raw, payload in cl:
            if ci == SIMPLEBLOCK:
                tr, rel, flags, hp = block_header(payload)
                if (flags & 0x06) == 0 and (track_filter is None or tr == track_filter):
                    fr = payload[hp:]
                    same = run and run[0][2][0] == tr and (mode != "fixed" or len(run[0][1]) == len(fr))
                    if not same:
                        flush()
                    run.append((raw, fr, (tr, rel, flags, hp)))
                    if len(run) >= group:
                        flush()
                    continue
            flush()
            out.append(raw)
        flush()
        new_clusters.append(out)
    open(out_path, "wb").write(rebuild(hdr, kids, new_clusters))


def to_blockgroups(path, out_path):
    """SimpleBlock -> BlockGroup{Block, BlockDuration, ReferenceBlock (non-key), DiscardPadding (every 7th)}."""
    hdr, kids, clusters = load(path)
    new_clusters = []
    k = 0
    for cl in clusters:
        out = []
        for ci, raw, payload in cl:
            if ci == SIMPLEBLOCK:
                tr, rel, flags, hp = block_header(payload)
                blk = payload[:hp - 1] + bytes([flags & 0x0E]) + payload[hp:]
                g = elem(BLOCK, blk) + uint(BLOCKDURATION, 20 + (k % 3))
                if not flags & 0x80:
                    g += elem(REFBLOCK, (-33 & 0xFFFF).to_bytes(2, "big"))
                if k % 7 == 3:
                    g += elem(DISCARDPAD, (6500000).to_bytes(4, "big"))
                out.append(elem(BLOCKGROUP, g))
                k += 1
            else:
                out.append(raw)
        new_clusters.append(out)
    open(out_path, "wb").write(rebuild(hdr, kids, new_clusters))


def unknown_sizes(path, out_path):
    hdr, kids, clusters = load(path)
    open(out_path, "wb").write(rebuild(hdr, kids, [[r for _i, r, _p in cl] for cl in clusters],
                                       unknown_seg=True, unknown_cluster=True))


def mse_split(path, init_path, media_path, unknown_cluster):
    hdr, kids, clusters = load(path)
    open(init_path, "wb").write(hdr + enc_id(SEGMENT) + UNKNOWN8 + b"".join(kids))
    media = b""
    for cl in clusters:
        payload = b"".join(r for _i, r, _p in cl)
        media += (enc_id(CLUSTER) + UNKNOWN8 + payload) if unknown_cluster else elem(CLUSTER, payload)
    open(media_path, "wb").write(media)


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    real(out)
    j = lambda n: os.path.join(out, n)  # noqa: E731
    relace(j("opus_audio_60s.webm"), j("lace_xiph_opus.webm"), "xiph", 8)
    relace(j("opus_audio_60s.webm"), j("lace_ebml_opus.webm"), "ebml", 8)
    relace(j("pcm_audio.mkv"), j("lace_fixed_pcm.mkv"), "fixed", 6)
    relace(j("vp8_vorbis.webm"), j("lace_xiph_vorbis.webm"), "xiph", 5, track_filter=2)
    relace(j("vp9_opus_cues.webm"), j("lace_ebml_vp9_opus.webm"), "ebml", 4, track_filter=2)
    to_blockgroups(j("vp9_opus_cues.webm"), j("blockgroup_vp9_opus.webm"))
    to_blockgroups(j("h264_bframes_aac.mkv"), j("blockgroup_h264_bframes.mkv"))
    unknown_sizes(j("vp9_opus_cues.webm"), j("unknown_seg_cluster.webm"))
    unknown_sizes(j("lace_ebml_opus.webm"), j("unknown_lace_ebml_opus.webm"))
    mse_split(j("vp9_opus_cues.webm"), j("mse_init.webm"), j("mse_media.webm"), False)
    mse_split(j("vp9_opus_cues.webm"), j("mse_init_yt.webm"), j("mse_media_yt.webm"), True)
    print("corpus:", " ".join(sorted(os.listdir(out))))


if __name__ == "__main__":
    main()
