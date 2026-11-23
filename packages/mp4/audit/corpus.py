"""Generate the RT-mp4 differential corpus with FFmpeg + BMFF rewrites.

    python3 corpus.py <out_dir>

Writes `<out_dir>/manifest.tsv`: `name<TAB>kind<TAB>init<TAB>media` where kind is `mp4`
(traditional, media unused) or `fmp4` (init + media segment; ffprobe reads `cat init media`
unless init == media).
"""
import os
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bmff  # noqa: E402

FFMPEG = os.environ.get("FFMPEG", "/opt/homebrew/bin/ffmpeg")
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

V = ["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25:duration=3"]
A = ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=3"]
X264 = ["-c:v", "libx264", "-preset", "veryfast", "-g", "25", "-bf", "3", "-pix_fmt", "yuv420p"]
AAC = ["-c:a", "aac", "-b:a", "96k", "-ac", "2"]

MP4 = [
    ("h264_aac_faststart", V + A + X264 + AAC + ["-movflags", "+faststart"]),
    ("h264_aac_moov_end", V + A + X264 + AAC),
    ("h264_negcts_ctts_v1", V + A + X264 + AAC + ["-movflags", "+negative_cts_offsets"]),
    ("h264_no_editlist", V + X264 + ["-use_editlist", "0"]),
    ("h264_allintra", V + ["-c:v", "libx264", "-preset", "veryfast", "-g", "1", "-bf", "0"]),
    ("h264_avc3", V + X264 + ["-tag:v", "avc3"]),
    ("hevc_hvc1", V + ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=none:bframes=3:keyint=25", "-tag:v", "hvc1"]),
    ("hevc_hev1", V + ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=none:keyint=25"]),
    ("vp9", V + ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "300k", "-g", "25"]),
    ("av1", V + ["-c:v", "libsvtav1", "-preset", "12", "-g", "25"]),
    ("aac_only", A + AAC),
    ("opus", A + ["-c:a", "libopus", "-b:a", "64k"]),
    ("flac", A + ["-c:a", "flac", "-strict", "-2"]),
    ("mp3", A + ["-c:a", "libmp3lame", "-b:a", "128k"]),
    ("h264_opus_interleave_small_chunks", V + A + X264 + ["-c:a", "libopus", "-frag_duration", "0", "-max_interleave_delta", "1", "-movflags", "+faststart"]),
]

FMP4 = [
    # one file, all moof/mdat pairs; split init|media at the first moof for MSE parsing
    ("fmp4_av_default_base_moof", V + A + X264 + AAC + ["-movflags", "+frag_keyframe+empty_moov+default_base_moof"], "split"),
    ("fmp4_av_explicit_bdo", V + A + X264 + AAC + ["-movflags", "+frag_keyframe+empty_moov"], "whole"),
    ("fmp4_av_cmaf_sidx", V + A + X264 + AAC + ["-movflags", "+cmaf+dash+global_sidx", "-frag_duration", "1000000"], "split"),
    ("fmp4_v_negcts_trun_v1", V + X264 + ["-movflags", "+frag_keyframe+empty_moov+default_base_moof+negative_cts_offsets"], "split"),
    ("fmp4_a_only", A + AAC + ["-movflags", "+frag_keyframe+empty_moov+default_base_moof", "-frag_duration", "500000"], "split"),
    ("fmp4_v_allkey_separate_moof", V + ["-c:v", "libx264", "-preset", "veryfast", "-g", "1", "-bf", "0"] + ["-movflags", "+frag_keyframe+empty_moov+default_base_moof+separate_moof", "-frag_duration", "400000"], "split"),
    ("fmp4_hevc", V + ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=none:keyint=25", "-tag:v", "hvc1", "-movflags", "+frag_keyframe+empty_moov+default_base_moof"], "split"),
    ("fmp4_vp9_opus", V + A + ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "300k", "-g", "25", "-c:a", "libopus", "-movflags", "+frag_keyframe+empty_moov+default_base_moof"], "split"),
]

REWRITES = [
    ("rw_co64", "h264_aac_faststart", bmff.stco_to_co64),
    ("rw_co64_moov_end", "h264_aac_moov_end", bmff.stco_to_co64),
    ("rw_stz2_16", "aac_only", lambda t: bmff.stsz_to_stz2(t, 16)),
    ("rw_stz2_8", "opus", lambda t: bmff.stsz_to_stz2(t, 8)),
    ("rw_v1_headers", "h264_aac_faststart", bmff.to_v1_headers),
    ("rw_uuid", "h264_aac_faststart", bmff.add_uuid_boxes),
    ("rw_mdat_size0", "h264_aac_faststart", bmff.trailing_mdat_size0),
    ("rw_mdat_largesize", "h264_aac_faststart", bmff.mdat_largesize),
    ("rw_ctts_v1", "h264_no_editlist", bmff.ctts_to_v1_signed),
]


def ff(args, out):
    subprocess.run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error"] + args + [out], check=True)


def split_at_first_moof(path):
    data = open(path, "rb").read()
    pos = 0
    while pos + 8 <= len(data):
        size = int.from_bytes(data[pos:pos + 4], "big")
        if size == 1:
            size = int.from_bytes(data[pos + 8:pos + 16], "big")
        typ = data[pos + 4:pos + 8]
        if typ in (b"moof", b"sidx", b"styp"):
            break
        pos += size
    return data[:pos], data[pos:]


def main():
    rows = []
    for name, args in MP4:
        out = os.path.join(OUT, name + ".mp4")
        if not os.path.exists(out):
            ff(args, out)
        rows.append((name, "mp4", out, "-"))
    for name, src, fn in REWRITES:
        out = os.path.join(OUT, name + ".mp4")
        data = open(os.path.join(OUT, src + ".mp4"), "rb").read()
        open(out, "wb").write(bmff.rewrite(data, fn))
        rows.append((name, "mp4", out, "-"))
    for name, args, how in FMP4:
        out = os.path.join(OUT, name + ".mp4")
        if not os.path.exists(out):
            ff(args, out)
        if how == "whole":
            rows.append((name, "fmp4", out, out))
        else:
            ini, med = split_at_first_moof(out)
            ip, mp = os.path.join(OUT, name + ".init.mp4"), os.path.join(OUT, name + ".m4s")
            open(ip, "wb").write(ini)
            open(mp, "wb").write(med)
            rows.append((name, "fmp4", ip, mp))
    # sidx v0 rewrite of the CMAF/sidx media segment
    med = open(os.path.join(OUT, "fmp4_av_cmaf_sidx.m4s"), "rb").read()
    tree = bmff.parse(med)
    bmff.sidx_to_v0(tree)
    p = os.path.join(OUT, "fmp4_sidx_v0.m4s")
    open(p, "wb").write(bmff.serialize(tree))
    rows.append(("fmp4_sidx_v0", "fmp4", os.path.join(OUT, "fmp4_av_cmaf_sidx.init.mp4"), p))
    # DASH (separate init + media per representation, like YouTube/Twitter MSE)
    dash = os.path.join(OUT, "dash")
    os.makedirs(dash, exist_ok=True)
    if not os.path.exists(os.path.join(dash, "init_0.m4s")):
        subprocess.run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", os.path.join(OUT, "h264_aac_faststart.mp4"),
                        "-c", "copy", "-f", "dash", "-init_seg_name", "init_$RepresentationID$.m4s",
                        "-media_seg_name", "seg_$RepresentationID$_$Number$.m4s", "-seg_duration", "1",
                        os.path.join(dash, "manifest.mpd")], check=True)
    for rep in ("0", "1"):
        for num in ("1", "2"):
            seg = os.path.join(dash, "seg_%s_%s.m4s" % (rep, num))
            if os.path.exists(seg):
                rows.append(("dash_rep%s_seg%s" % (rep, num), "fmp4", os.path.join(dash, "init_%s.m4s" % rep), seg))
    with open(os.path.join(OUT, "manifest.tsv"), "w") as f:
        for r in rows:
            f.write("\t".join(r) + "\n")
    print("corpus: %d inputs -> %s" % (len(rows), OUT))


main()
