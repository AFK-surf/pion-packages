"""Crafted RT-mp4 vectors (minimal MP4 / fMP4 builders).

`all_vectors()` -> list of (name, kind, a, b): kind 0 = mp4 bytes `a`; kind 1 = init `a` + media `b`;
kind 2 = top-level box list `a`.  `python3 vectors.py pion` prints the Pion `v_*()` hex functions that
`redteam_test.pion` embeds (the generated block between the BEGIN/END markers).
"""
import struct
import sys


def box(t, payload=b""):
    return struct.pack(">I4s", 8 + len(payload), t) + payload


def full(t, ver, flags, payload=b""):
    return box(t, bytes([ver]) + flags.to_bytes(3, "big") + payload)


def u32(*v):
    return struct.pack(">%dI" % len(v), *v)


def ftyp(major=b"isom"):
    return box(b"ftyp", major + u32(512) + b"isomiso2avc1mp41")


def mvhd(ts=1000, dur=0):
    return full(b"mvhd", 0, 0, u32(0, 0, ts, dur) + u32(0x00010000) + b"\x01\x00" + bytes(10)
                + u32(0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000) + bytes(24) + u32(2))


def tkhd(tid, w=320, h=240):
    return full(b"tkhd", 0, 3, u32(0, 0, tid, 0, 0) + bytes(8) + b"\0\0\0\0" + b"\0\0\0\0"
                + u32(0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000) + u32(w << 16, h << 16))


def mdhd(ts):
    return full(b"mdhd", 0, 0, u32(0, 0, ts, 0) + b"\x55\xc4\0\0")


def hdlr(h):
    return full(b"hdlr", 0, 0, u32(0) + h + bytes(12) + b"h\0")


def avc1(w=320, h=240, avcc=b"\x01\x64\x00\x1f\xff\xe0\x00"):
    vis = bytes(6) + b"\0\x01" + bytes(16) + struct.pack(">HH", w, h) + u32(0x480000, 0x480000, 0) + b"\0\x01" + bytes(32) + b"\0\x18\xff\xff"
    return box(b"avc1", vis + box(b"avcC", avcc))


def hvc1(hvcc):
    vis = bytes(6) + b"\0\x01" + bytes(16) + struct.pack(">HH", 320, 240) + u32(0x480000, 0x480000, 0) + b"\0\x01" + bytes(32) + b"\0\x18\xff\xff"
    return box(b"hvc1", vis + box(b"hvcC", hvcc))


def stsd(entry):
    return full(b"stsd", 0, 0, u32(1) + entry)


def table(t, ver, rows, fmt):
    body = u32(len(rows)) + b"".join(struct.pack(fmt, *r) for r in rows)
    return full(t, ver, 0, body)


def trak(tid, ts, stbl_children, handler=b"vide", entry=None, edts=b""):
    stbl = box(b"stbl", stsd(entry if entry is not None else avc1()) + b"".join(stbl_children))
    minf = box(b"minf", full(b"vmhd", 0, 1, bytes(8)) + stbl)
    mdia = box(b"mdia", mdhd(ts) + hdlr(handler) + minf)
    return box(b"trak", tkhd(tid) + edts + mdia)


def mp4(traks, mdat_payload, moov_extra=b""):
    """ftyp + moov + mdat; `traks` is a function(mdat_payload_offset) -> list of trak bytes."""
    head = ftyp()
    probe = box(b"moov", mvhd() + b"".join(traks(0)) + moov_extra)
    off = len(head) + len(probe) + 8
    moov = box(b"moov", mvhd() + b"".join(traks(off)) + moov_extra)
    assert len(moov) == len(probe)
    return head + moov + box(b"mdat", mdat_payload)


def simple_mp4(n, sizes=None, ctts=None, ctts_ver=0, stts=None, stss=None, handler=b"vide", entry=None, ts=1000, edts=b""):
    sizes = sizes or [16] * n
    payload = bytes(sum(sizes))

    def traks(off):
        ch = [table(b"stts", 0, stts or [(n, 40)], ">II")]
        if ctts is not None:
            ch.append(table(b"ctts", ctts_ver, ctts, ">II" if ctts_ver == 0 else ">Ii"))
        ch += [table(b"stsc", 0, [(1, n, 1)], ">III"),
               full(b"stsz", 0, 0, u32(0, n) + u32(*sizes)),
               table(b"stco", 0, [(off,)], ">I")]
        if stss is not None:
            ch.append(table(b"stss", 0, [(x,) for x in stss], ">I"))
        return [trak(1, ts, ch, handler, entry, edts)]
    return mp4(traks, payload)


# ---- fMP4 -------------------------------------------------------------------------------------

def init_segment(tids=(1,), ts=1000, trex_size=0, trex_dur=40):
    traks = b"".join(trak(t, ts, [table(b"stts", 0, [], ">II"), table(b"stsc", 0, [], ">III"),
                                  full(b"stsz", 0, 0, u32(0, 0)), table(b"stco", 0, [], ">I")]) for t in tids)
    mvex = box(b"mvex", b"".join(full(b"trex", 0, 0, u32(t, 1, trex_dur, trex_size, 0)) for t in tids))
    return ftyp(b"iso6") + box(b"moov", mvhd() + traks + mvex)


def moof(seq, trafs):
    """trafs: list of (tfhd_flags, tfhd_fields_bytes, tfdt_bytes_or_None, trun list (ver, flags, count, body))."""
    out = full(b"mfhd", 0, 0, u32(seq))
    for tfhd_flags, tid, fields, tfdt, truns in trafs:
        t = full(b"tfhd", 0, tfhd_flags, u32(tid) + fields)
        if tfdt is not None:
            t += tfdt
        for ver, fl, cnt, body in truns:
            t += full(b"trun", ver, fl, u32(cnt) + body)
        out += box(b"traf", t)
    return box(b"moof", out)


def tfdt(v, ver=1):
    return full(b"tfdt", ver, 0, struct.pack(">Q", v) if ver == 1 else u32(v))


def media(seq, trafs, mdat_len):
    return moof(seq, trafs) + box(b"mdat", bytes(mdat_len))


# ---- vectors ----------------------------------------------------------------------------------

def v_dos_trun_zero_byte_samples():
    """One trun, flags=0 (no per-sample fields), sample_count = default max_samples (4,194,304):
    0 table bytes per sample, every sample size 0 (trex default) at the same offset."""
    return init_segment(), media(1, [(0x020000, 1, b"", tfdt(0), [(0, 0, 4194304, b"")])], 0)


def v_dos_overlapping_chunks():
    """stsz constant size 1 x 4,194,304 samples; 1024 stco chunks that all point at the same 4096-byte
    mdat payload; stsc samples_per_chunk = 4096.  ~8 KiB of input -> 4 Mi samples."""
    n_chunks, spc = 1024, 4096
    def traks(off):
        ch = [table(b"stts", 0, [(n_chunks * spc, 1)], ">II"),
              table(b"stsc", 0, [(1, spc, 1)], ">III"),
              full(b"stsz", 0, 0, u32(1, n_chunks * spc)),
              table(b"stco", 0, [(off,)] * n_chunks, ">I")]
        return [trak(1, 1000, ch)]
    return mp4(traks, bytes(spc))


def v_dos_stsz_prealloc():
    """stsz constant size, sample_count 4,194,304, no stco: sync bitmap is allocated before the
    chunk table is found to be missing."""
    def traks(off):
        return [trak(1, 1000, [table(b"stts", 0, [(4194304, 1)], ">II"), table(b"stsc", 0, [(1, 1, 1)], ">III"),
                               full(b"stsz", 0, 0, u32(1, 4194304))])]
    return mp4(traks, b"")


def v_dos_many_free_boxes():
    """65,000 empty `free` boxes inside moov (max_boxes guard, linear)."""
    return ftyp() + box(b"moov", mvhd() + box(b"free") * 65000)


def v_ctts_v0_negative():
    """ctts v0 entries written as two's-complement negatives (what several muxers emit; ffmpeg,
    Chromium and mp4box read the 32-bit field as signed).  4 samples: I P B B with cto 80,200,-40(!),40."""
    return simple_mp4(4, ctts=[(1, 80), (1, 200), (1, 0xFFFFFFD8), (1, 40)], stss=[1])


def v_trun_v0_negative_cto():
    """trun v0 with sample_composition_time_offset 0xFFFFFC00 (-1024 as int32)."""
    body = u32(40, 16, 0xFFFFFC00) * 1
    return init_segment(), media(1, [(0x020000, 1, b"", tfdt(1000), [(0, 0x001 | 0x100 | 0x200 | 0x800, 1, u32(0) + body)])], 16)


def v_tfdt_huge_ms_overflow():
    """tfdt v1 = 2^62 (legal u64) with timescale 1000: `pts * 1000L` wraps Int64 -> nonsense MSE range."""
    return init_segment(), media(1, [(0x020000, 1, b"", tfdt(1 << 62), [(0, 0x001 | 0x100 | 0x200, 1, u32(0) + u32(40, 16))])], 16)


def v_tfdt_sign_bit():
    """tfdt v1 = 0x8000000000000000 (u64) -> read as negative Int64 base_decode_time."""
    return init_segment(), media(1, [(0x020000, 1, b"", tfdt(1 << 63), [(0, 0x001 | 0x100 | 0x200, 1, u32(0) + u32(40, 16))])], 16)


def v_trun_duration_2p31():
    """trun sample_duration 0x80000000 (legal u32) -> rejected as InvalidSyntax."""
    return init_segment(), media(1, [(0x020000, 1, b"", tfdt(0), [(0, 0x001 | 0x100 | 0x200, 1, u32(0) + u32(0x80000000, 16))])], 16)


def v_stts_delta_2p31():
    """stts sample_delta 0x80000000 (legal u32) -> whole file rejected."""
    return simple_mp4(2, stts=[(2, 0x80000000)])


def v_unknown_track_fragment():
    """traf for track_id 7 that the init segment does not declare: accepted, mvhd timescale used,
    no trex defaults; ffmpeg skips such a traf."""
    return init_segment(), media(1, [(0x020000, 7, b"", tfdt(5000), [(0, 0x001 | 0x100 | 0x200, 1, u32(0) + u32(40, 16))])], 16)


def v_seek_nonmonotonic_pts():
    """Decode-order pts 40(I), 140, 400, 180(I), 220 (dts step 40).  Nearest sync at/before pts 200 is
    sample 3 (pts 180); the binary search over non-monotonic pts stops at index 1 and walks back to 0."""
    return simple_mp4(5, ctts=[(1, 40), (1, 100), (1, 320), (1, 60), (1, 60)], ctts_ver=0, stts=[(5, 40)], stss=[1, 4])


def v_edit_list_media_time():
    """B-frame style track (ctts first offset 80) with edts/elst media_time = 80, as every FFmpeg/x264
    MP4 has: ISO 14496-12 8.6.6 maps media time 80 to presentation 0 (ffprobe first pts = 0)."""
    elst = box(b"edts", full(b"elst", 0, 0, u32(1, 160, 80, 0x00010000)))
    return simple_mp4(4, ctts=[(1, 80), (1, 200), (1, 0), (1, 40)], stss=[1], edts=elst)


def v_hevc_profile_space():
    """hvcC general_profile_space = 1 ('A' prefix per ISO 14496-15 Annex E), profile 1, level 93."""
    hvcc = bytes([1, (1 << 6) | 1]) + u32(0x60000000) + bytes([0x90, 0, 0, 0, 0, 0]) + bytes([93]) + bytes(10)
    return simple_mp4(1, entry=hvc1(hvcc))


def v_negative_pts_ms_trunc():
    """trun v1 cto -1 at dts 0 (timescale 90000): presented at -0.011 ms; floor is -1 ms, truncating division gives 0."""
    body = u32(40, 16) + struct.pack(">i", -1)
    return init_segment(ts=90000), media(1, [(0x020000, 1, b"", tfdt(0), [(1, 0x001 | 0x100 | 0x200 | 0x800, 1, u32(0) + body)])], 16)


def v_ctrl_largesize_sign():
    """Top-level largesize 0xFFFFFFFFFFFFFFFF must be rejected, not wrap."""
    return struct.pack(">I4sQ", 1, b"free", 0xFFFFFFFFFFFFFFFF) + bytes(16)


def v_ctrl_trun_negative_data_offset():
    """trun data_offset = -2^31 with default-base-is-moof: must be rejected, not wrap into the buffer."""
    return init_segment(), media(1, [(0x020000, 1, b"", tfdt(0), [(0, 0x001 | 0x200, 1, struct.pack(">i", -2 ** 31) + u32(16))])], 16)


def v_ctrl_bdo_sign_bit():
    """tfhd base_data_offset 0xFFFFFFFFFFFFFFF0 -> negative Int64; must be rejected."""
    return init_segment(), media(1, [(0x000001, 1, struct.pack(">Q", 0xFFFFFFFFFFFFFFF0), tfdt(0), [(0, 0x200, 1, u32(16))])], 16)


def v_ctrl_timescale_zero():
    """mdhd/mvhd timescale 0 everywhere: no division by zero."""
    ini = init_segment(ts=0).replace(u32(0, 0, 1000, 0) + u32(0x00010000), u32(0, 0, 0, 0) + u32(0x00010000))
    return ini, media(1, [(0x020000, 1, b"", tfdt(0), [(0, 0x001 | 0x100 | 0x200, 1, u32(0) + u32(40, 16))])], 16)


def v_ctrl_stsc_spc_zero():
    """stsc samples_per_chunk 0 for chunk 1 then 2: chunk 1 must be skipped, no infinite loop."""
    def traks(off):
        ch = [table(b"stts", 0, [(2, 40)], ">II"), table(b"stsc", 0, [(1, 0, 1), (2, 2, 1)], ">III"),
              full(b"stsz", 0, 0, u32(0, 2) + u32(8, 8)), table(b"stco", 0, [(off,), (off,)], ">I")]
        return [trak(1, 1000, ch)]
    return mp4(traks, bytes(16))


def v_ctrl_stz2_4bit_odd():
    """stz2 field_size 4 with an odd sample count (3 samples, sizes 1,2,3)."""
    def traks(off):
        ch = [table(b"stts", 0, [(3, 40)], ">II"), table(b"stsc", 0, [(1, 3, 1)], ">III"),
              full(b"stz2", 0, 0, b"\0\0\0\x04" + u32(3) + bytes([0x12, 0x30])), table(b"stco", 0, [(off,)], ">I")]
        return [trak(1, 1000, ch)]
    return mp4(traks, bytes(6))


VECTORS = [
    ("dos_trun_zero_byte_samples", 1, v_dos_trun_zero_byte_samples),
    ("dos_overlapping_chunks", 0, v_dos_overlapping_chunks),
    ("dos_stsz_prealloc", 0, v_dos_stsz_prealloc),
    ("dos_many_free_boxes", 0, v_dos_many_free_boxes),
    ("ctts_v0_negative", 0, v_ctts_v0_negative),
    ("trun_v0_negative_cto", 1, v_trun_v0_negative_cto),
    ("tfdt_huge_ms_overflow", 1, v_tfdt_huge_ms_overflow),
    ("tfdt_sign_bit", 1, v_tfdt_sign_bit),
    ("trun_duration_2p31", 1, v_trun_duration_2p31),
    ("stts_delta_2p31", 0, v_stts_delta_2p31),
    ("unknown_track_fragment", 1, v_unknown_track_fragment),
    ("seek_nonmonotonic_pts", 0, v_seek_nonmonotonic_pts),
    ("edit_list_media_time", 0, v_edit_list_media_time),
    ("hevc_profile_space", 0, v_hevc_profile_space),
    ("negative_pts_ms_trunc", 1, v_negative_pts_ms_trunc),
    ("ctrl_largesize_sign", 2, v_ctrl_largesize_sign),
    ("ctrl_trun_negative_data_offset", 1, v_ctrl_trun_negative_data_offset),
    ("ctrl_bdo_sign_bit", 1, v_ctrl_bdo_sign_bit),
    ("ctrl_timescale_zero", 1, v_ctrl_timescale_zero),
    ("ctrl_stsc_spc_zero", 0, v_ctrl_stsc_spc_zero),
    ("ctrl_stz2_4bit_odd", 0, v_ctrl_stz2_4bit_odd),
]


def all_vectors():
    out = []
    for name, kind, fn in VECTORS:
        r = fn()
        if isinstance(r, tuple):
            out.append((name, kind, r[0], r[1]))
        else:
            out.append((name, kind, r, None))
    return out


def pion_block():
    lines = ["// BEGIN GENERATED VECTORS (python3 vectors.py pion)"]
    for name, kind, a, b in all_vectors():
        if name.startswith("dos_many"):
            continue
        lines.append("")
        lines.append("///| %s" % name)
        lines.append("fn v_%s() -> Bytes {" % name)
        lines.append('  hexb("%s")' % a.hex())
        lines.append("}")
        if b is not None:
            lines.append("")
            lines.append("///| %s (media segment)" % name)
            lines.append("fn v_%s_media() -> Bytes {" % name)
            lines.append('  hexb("%s")' % b.hex())
            lines.append("}")
    lines.append("// END GENERATED VECTORS")
    return "\n".join(lines) + "\n"


if __name__ == "__main__" and len(sys.argv) > 1 and sys.argv[1] == "pion":
    sys.stdout.write(pion_block())
