#!/usr/bin/env python3
"""Hand-built adversarial WebM vectors for the packages/webm red-team audit (shared by gen_redteam_test.py,
run_vectors and the fuzz seeds).  Each builder returns bytes; `VECTORS` maps name -> (bytes, note)."""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ebml import *  # noqa: E402,F401,F403

DURATION, SCALE = 0x4489, 0x2AD7B1
TRACK_ENTRY, TRACK_NUMBER, TRACK_UID, TRACK_TYPE, CODEC_ID, DEFAULT_DURATION, CODEC_PRIVATE = 0xAE, 0xD7, 0x73C5, 0x83, 0x86, 0x23E383, 0x63A2
VIDEO, PIXEL_W, PIXEL_H = 0xE0, 0xB0, 0xBA
CUE_POINT, CUE_TIME, CUE_TP, CUE_TRACK, CUE_CPOS = 0xBB, 0xB3, 0xB7, 0xF7, 0xF1
DOC_TYPE, DOC_TYPE_RV, EBML_RV, MUXING_APP = 0x4282, 0x4285, 0x42F7, 0x4D80


EBML_VERSION, EBML_MAXID, EBML_MAXSIZE, DOC_TYPE_VERSION = 0x4286, 0x42F2, 0x42F3, 0x4287


def header(doc=b"webm", extra=b"", drv=2):
    return elem(EBML, uint(EBML_VERSION, 1) + uint(EBML_RV, 1) + uint(EBML_MAXID, 4) + uint(EBML_MAXSIZE, 8) +
                elem(DOC_TYPE, doc) + uint(DOC_TYPE_VERSION, 4) + (uint(DOC_TYPE_RV, drv) if drv else b"") + extra)


def info(scale=1000000, duration=None, raw_duration=None):
    p = uint(SCALE, scale) + elem(MUXING_APP, b"audit") + elem(0x5741, b"audit")
    if duration is not None:
        p += elem(DURATION, struct.pack(">d", duration))
    if raw_duration is not None:
        p += elem(DURATION, raw_duration)
    return elem(INFO, p)


def track(num=1, ttype=2, codec=b"A_PCM/INT/LIT", dd=20000000, extra=b""):
    p = uint(TRACK_NUMBER, num) + uint(TRACK_UID, num or 1) + uint(TRACK_TYPE, ttype) + elem(CODEC_ID, codec)
    p += elem(0xE1, elem(0xB5, struct.pack(">d", 48000.0)) + uint(0x9F, 1) + uint(0x6264, 16))
    if dd:
        p += uint(DEFAULT_DURATION, dd)
    return elem(TRACK_ENTRY, p + extra)


def tracks(*entries):
    return elem(TRACKS, b"".join(entries) if entries else track())


def sblock(track=1, rel=0, flags=0x80, payload=b"\x11\x22\x33"):
    return elem(SIMPLEBLOCK, enc_size(track) + struct.pack(">h", rel) + bytes([flags]) + payload)


def cluster(ts=0, *blocks, ts_raw=None, unknown=False):
    p = (elem(TIMESTAMP, ts_raw) if ts_raw is not None else uint(TIMESTAMP, ts)) + b"".join(blocks)
    return enc_id(CLUSTER) + UNKNOWN8 + p if unknown else elem(CLUSTER, p)


def webm(*seg_children, hdr=None, unknown_seg=False):
    body = b"".join(seg_children)
    seg = enc_id(SEGMENT) + (UNKNOWN8 if unknown_seg else enc_size(len(body))) + body
    return (hdr if hdr is not None else header()) + seg


def base(*clusters, inf=None, trk=None):
    return webm(inf if inf is not None else info(), trk if trk is not None else tracks(), *clusters)


def zero_lace_bomb(n_blocks, mode="fixed"):
    """n_blocks SimpleBlocks, each 256 zero-byte laced frames (fixed: 7 bytes/block)."""
    if mode == "fixed":
        blk = sblock(flags=0x84, payload=b"\xff")
    else:  # xiph: 255 zero lace sizes
        blk = sblock(flags=0x82, payload=b"\xff" + b"\x00" * 255)
    per = 4096
    cl = []
    for i in range(0, n_blocks, per):
        cl.append(cluster(i, *([blk] * min(per, n_blocks - i))))
    return base(*cl)


def cue_bomb(n):
    return base(elem(CUES, elem(CUE_POINT, b"") * n))


def cue_positions_bomb(n):
    return base(elem(CUES, elem(CUE_POINT, uint(CUE_TIME, 1) + elem(CUE_TP, b"") * n)))


def cluster_bomb(n):
    return base(*([elem(CLUSTER, b"")] * n))


VECTORS = {
    # --- timestamps / floats -------------------------------------------------------------------------
    "dur_pos_inf": (base(cluster(0, sblock()), inf=info(duration=float("inf"))), "Duration=+Inf"),
    "dur_1e19": (base(cluster(0, sblock()), inf=info(duration=1e19)), "Duration=1e19 ticks (finite, ms > i64)"),
    "dur_neg_inf": (base(cluster(0, sblock()), inf=info(duration=float("-inf"))), "Duration=-Inf"),
    "dur_nan": (base(cluster(0, sblock()), inf=info(raw_duration=b"\x7f\xf8\x00\x00\x00\x00\x00\x00")), "Duration=NaN"),
    "dur_f32_inf": (base(cluster(0, sblock()), inf=info(raw_duration=b"\x7f\x80\x00\x00")), "Duration=+Inf as float32"),
    "dur_len2": (base(cluster(0, sblock()), inf=info(raw_duration=b"\x41\x20")), "Duration with 2-byte payload"),
    "dur_len10": (base(cluster(0, sblock()), inf=info(raw_duration=b"\x00" * 10)), "Duration with 10-byte payload"),
    "cluster_ts_2p55": (base(cluster(1 << 55, sblock())), "Cluster Timestamp 2^55 ticks * 1e6 ns overflows i64"),
    "cluster_ts_u64max": (base(cluster(0, sblock(), ts_raw=b"\xff" * 8)), "Cluster Timestamp 0xFFFF_FFFF_FFFF_FFFF (u64 max)"),
    "scale_2p62": (base(cluster(4, sblock()), inf=info(scale=1 << 62)), "TimestampScale 2^62, cluster ts 4"),
    "scale_zero": (base(cluster(0, sblock()), inf=info(scale=0)), "TimestampScale 0"),
    "rel_ts_min_at_zero": (base(cluster(0, sblock(rel=-32768))), "rel_ts -32768 with Cluster Timestamp 0"),
    # --- lacing --------------------------------------------------------------------------------------
    "ebml_lace_one_frame": (base(cluster(0, sblock(flags=0x86, payload=b"\x00\x82\xaa\xbb\xcc"))),
                            "EBML lacing, lace count 1, 4-byte frame 82 aa bb cc"),
    "xiph_lace_one_frame": (base(cluster(0, sblock(flags=0x82, payload=b"\x00\x82\xaa\xbb\xcc"))),
                            "Xiph lacing, lace count 1, 4-byte frame"),
    "fixed_lace_zero_frames": (base(cluster(0, sblock(flags=0x84, payload=b"\xff"))), "fixed lacing, 256 frames, 0 bytes"),
    "xiph_lace_zero_frames": (base(cluster(0, sblock(flags=0x82, payload=b"\xff" + b"\x00" * 255))), "Xiph lacing, 256 x 0-byte frames"),
    "ebml_lace_zero_frames": (base(cluster(0, sblock(flags=0x86, payload=b"\xff\x80" + b"\xbf" * 254))), "EBML lacing, 256 x 0-byte frames"),
    "ebml_lace_neg_delta": (base(cluster(0, sblock(flags=0x86, payload=b"\x02\x81\x80" + b"\x00" * 4))), "EBML lacing delta -> negative"),
    "ebml_lace_last_neg": (base(cluster(0, sblock(flags=0x86, payload=b"\x01\x83\xbf" + b"\x00" * 4))), "EBML lacing sizes > payload"),
    "xiph_lace_ff_run": (base(cluster(0, sblock(flags=0x82, payload=b"\x01" + b"\xff" * 300))), "Xiph lacing 0xFF run past payload"),
    "fixed_lace_indivisible": (base(cluster(0, sblock(flags=0x84, payload=b"\x02" + b"\x00" * 7))), "fixed lacing 7 bytes / 3 frames"),
    # --- structure -----------------------------------------------------------------------------------
    "undeclared_track": (base(cluster(0, sblock(track=5))), "SimpleBlock for track 5, only track 1 declared"),
    "track_number_zero": (base(cluster(0, sblock(track=1)), trk=tracks(track(num=0))), "TrackNumber 0 (spec: >= 1)"),
    "cues_before_info": (webm(elem(CUES, elem(CUE_POINT, uint(CUE_TIME, 5000) + elem(CUE_TP, uint(CUE_TRACK, 1) + uint(CUE_CPOS, 0)))),
                              info(scale=1000), tracks(), cluster(0, sblock())), "Cues (CueTime 5000) before Info (scale 1000)"),
    "unknown_cluster_then_tags": (webm(info(), tracks(), cluster(0, sblock(), unknown=True), elem(0x1254C367, b""), cluster(10, sblock())),
                                  "unknown-size Cluster ended by Tags, then a sized Cluster"),
    "unknown_seg_unknown_cluster_chained": (webm(info(), tracks(), cluster(0, sblock(), unknown=True), unknown_seg=True) + header() +
                                            enc_id(SEGMENT) + UNKNOWN8, "unknown Segment+Cluster followed by a chained EBML header"),
    "child_exceeds_parent": (base(elem(CLUSTER, uint(TIMESTAMP, 0) + enc_id(SIMPLEBLOCK) + enc_size(40) + b"\x81\x00\x00\x80")),
                             "SimpleBlock size runs past its Cluster"),
    "vint_size_8byte_max": (base(enc_id(CLUSTER) + b"\x01\xff\xff\xff\xff\xff\xff\xfe"), "Cluster size 2^56-2"),
    "doc_type_read_version_99": (base(cluster(0, sblock()), ) if False else webm(info(), tracks(), cluster(0, sblock()), hdr=header(drv=99)),
                                 "DocTypeReadVersion 99 (reader must refuse)"),
    "ebml_read_version_2": (webm(info(), tracks(), cluster(0, sblock()), hdr=elem(EBML, uint(EBML_RV, 2) + elem(DOC_TYPE, b"webm"))), "EBMLReadVersion 2"),
    "block_duration_zero": (base(cluster(0, elem(BLOCKGROUP, elem(BLOCK, b"\x81\x00\x00\x00\x11") + uint(BLOCKDURATION, 0, 1)))),
                            "BlockGroup with explicit BlockDuration 0 (track DefaultDuration 20 ms)"),
}

BOMBS = {
    "bomb_fixed_lace_1m_frames": (zero_lace_bomb(4096), "4096 SimpleBlocks x 256 zero-byte fixed laces = 1,048,576 frames"),
    "bomb_xiph_lace_1m_frames": (zero_lace_bomb(4096, "xiph"), "4096 SimpleBlocks x 256 zero-byte Xiph laces"),
    "bomb_cue_points_1m": (cue_bomb(1048576), "1,048,576 empty CuePoints"),
    "bomb_cue_positions_4m": (cue_positions_bomb(4194000), "one CuePoint with 4,194,000 empty CueTrackPositions"),
    "bomb_empty_clusters_1m": (cluster_bomb(1048575), "1,048,575 empty Clusters"),
}

if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, (data, _note) in list(VECTORS.items()) + list(BOMBS.items()):
        open(os.path.join(out, name + ".webm"), "wb").write(data)
    print(f"{len(VECTORS)} vectors + {len(BOMBS)} bombs -> {out}")
