#!/usr/bin/env python3
"""Deterministic corpus generator for the packages/icc red-team audit (python3 stdlib only).

    python3 -I gen.py <out_dir> [fuzz_n]

Writes into <out_dir>:
  diff/*.icc        well-formed matrix/TRC and GRAY profiles (differential vs an exact float reference, qcms, moxcms)
  adv/*             adversarial profiles / JPEG / WebP, with expectations in manifest.json
  trunc/*           every byte prefix of 5 seeds
  fuzz/*            fuzz_n LCG mutants of the seeds
  dos/*             resource bombs (dos.json: verdict + per-parse budget)
  grid.rgb          the differential input: 4 x 256 ramps, 33^3 grid, 4096 LCG pixels
  *.lst             one path per line per group; manifest.json, dos.json
No ICC file from the system is copied here: run_audit.sh adds /System/Library/ColorSync/Profiles out of tree.
"""
import json
import math
import os
import struct
import sys

# ----------------------------------------------------------------------------------------------------------------
# ICC writers
# ----------------------------------------------------------------------------------------------------------------


def s15(v):
    return struct.pack(">i", int(round(v * 65536.0)))


def u16(v):
    return struct.pack(">H", v & 0xFFFF)


def u32(v):
    return struct.pack(">I", v & 0xFFFFFFFF)


def xyz_tag(x, y, z):
    return b"XYZ \0\0\0\0" + s15(x) + s15(y) + s15(z)


def xyz_raw(a, b, c):
    return b"XYZ \0\0\0\0" + u32(a) + u32(b) + u32(c)


def curv(entries):
    return b"curv\0\0\0\0" + u32(len(entries)) + b"".join(u16(e) for e in entries)


def curv_gamma(g):
    return b"curv\0\0\0\0" + u32(1) + u16(int(round(g * 256.0)))


def para(t, params):
    return b"para\0\0\0\0" + u16(t) + u16(0) + b"".join(s15(p) for p in params)


def desc_v2(text):
    # textDescriptionType: ASCII count incl. NUL, then empty Unicode and ScriptCode parts (ICC.1:2001 6.5.17)
    return b"desc\0\0\0\0" + u32(len(text) + 1) + text + b"\0" + u32(0) + u32(0) + u16(0) + b"\0" + b"\0" * 67


def mluc(records):
    """records: [(lang2+ctry2 bytes, utf16be bytes)]"""
    n = len(records)
    head = b"mluc\0\0\0\0" + u32(n) + u32(12)
    off = 16 + 12 * n
    table = b""
    blob = b""
    for loc, s in records:
        table += loc + u32(len(s)) + u32(off + len(blob))
        blob += s
    return head + table + blob


def sf32(vals):
    return b"sf32\0\0\0\0" + b"".join(s15(v) for v in vals)


def text_tag(t):
    return b"text\0\0\0\0" + t + b"\0"


def profile(tags, cs=b"RGB ", pcs=b"XYZ ", ver=(4, 0x30), cls=b"mntr", aliases=(), intent=0, hdr_patch=None):
    """tags: [(sig, payload)], aliases: [(sig, target_sig)] share the target's offset/size."""
    n = len(tags) + len(aliases)
    cur = 132 + 12 * n
    offs = {}
    body = b""
    for sig, payload in tags:
        offs[sig] = (cur + len(body), len(payload))
        body += payload + b"\0" * ((-len(payload)) % 4)
    size = cur + len(body)
    h = bytearray(128)
    h[0:4] = u32(size)
    h[4:8] = b"rtic"
    h[8] = ver[0]
    h[9] = ver[1]
    h[12:16] = cls
    h[16:20] = cs
    h[20:24] = pcs
    h[24:36] = struct.pack(">6H", 2026, 11, 24, 12, 0, 0)
    h[36:40] = b"acsp"
    h[40:44] = b"APPL"
    h[64:68] = u32(intent)
    h[68:80] = s15(0.9642) + s15(1.0) + s15(0.8249)
    h[80:84] = b"rtic"
    table = u32(n)
    for sig, _ in tags:
        table += sig + u32(offs[sig][0]) + u32(offs[sig][1])
    for sig, tgt in aliases:
        table += sig + u32(offs[tgt][0]) + u32(offs[tgt][1])
    out = bytearray(bytes(h) + table + body)
    if hdr_patch:
        hdr_patch(out)
    return bytes(out)


def raw_profile(entries, blobs, size_override=None, count_override=None, cs=b"RGB ", pcs=b"XYZ "):
    """Low-level writer: entries = [(sig, blob_index | (offset, size))], blobs placed after the table."""
    n = len(entries)
    cur = 132 + 12 * n
    offs = []
    body = b""
    for b in blobs:
        offs.append(cur + len(body))
        body += b + b"\0" * ((-len(b)) % 4)
    size = cur + len(body)
    h = bytearray(128)
    h[0:4] = u32(size if size_override is None else size_override)
    h[4:8] = b"rtic"
    h[8] = 4
    h[12:16] = b"mntr"
    h[16:20] = cs
    h[20:24] = pcs
    h[36:40] = b"acsp"
    h[68:80] = s15(0.9642) + s15(1.0) + s15(0.8249)
    t = u32(n if count_override is None else count_override)
    for sig, e in entries:
        if isinstance(e, tuple):
            t += sig + u32(e[0]) + u32(e[1])
        else:
            t += sig + u32(offs[e]) + u32(len(blobs[e]))
    return bytes(h) + t + body


# Real-world D50-adapted primaries (s15Fixed16 values as found in the ICC profiles that define them)
D50W = (0.9642, 1.0, 0.8249)
PRIM = {
    "srgb": ((0.436066, 0.222488, 0.013916), (0.385147, 0.716873, 0.097076), (0.143066, 0.060608, 0.714096)),
    "p3": ((0.515121, 0.241196, -0.001053), (0.291977, 0.692245, 0.041885), (0.157104, 0.066574, 0.784073)),
    "adobe": ((0.609741, 0.311111, 0.019470), (0.205276, 0.625671, 0.060867), (0.149185, 0.063217, 0.744568)),
    "prophoto": ((0.797760, 0.288040, 0.0), (0.135185, 0.711868, 0.0), (0.031342, 0.000092, 0.825195)),
    "rec2020": ((0.673459, 0.279033, -0.001931), (0.165661, 0.675338, 0.029979), (0.125100, 0.045629, 0.797162)),
    # ACES AP0 adapted to D50 (has negative components)
    "ap0": ((1.017977, 0.367478, -0.0010), (-0.031066, 0.645838, -0.002075), (-0.022714, -0.013308, 0.826019)),
}
SRGB_PARA = [2.4, 1 / 1.055, 0.055 / 1.055, 1 / 12.92, 0.04045]
CHAD_D65 = [1.047882, 0.022919, -0.050201, 0.029587, 0.990479, -0.017059, -0.009232, 0.015076, 0.751678]


def srgb_eotf(x):
    return x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4


def rgb_profile(prim, trc_r, trc_g=None, trc_b=None, desc=b"red-team", ver=(4, 0x30), extra=(), chad=True):
    r, g, b = PRIM[prim] if isinstance(prim, str) else prim
    tags = [
        (b"desc", desc_v2(desc) if ver[0] == 2 else mluc([(b"enUS", desc.decode().encode("utf-16-be"))])),
        (b"wtpt", xyz_tag(*D50W)),
        (b"rXYZ", xyz_tag(*r)),
        (b"gXYZ", xyz_tag(*g)),
        (b"bXYZ", xyz_tag(*b)),
        (b"rTRC", trc_r),
    ]
    aliases = []
    if trc_g is None:
        aliases.append((b"gTRC", b"rTRC"))
    else:
        tags.append((b"gTRC", trc_g))
    if trc_b is None:
        aliases.append((b"bTRC", b"rTRC"))
    else:
        tags.append((b"bTRC", trc_b))
    if chad:
        tags.append((b"chad", sf32(CHAD_D65)))
    tags.extend(extra)
    return profile(tags, ver=ver, aliases=aliases)


def gray_profile(ktrc, pcs=b"XYZ ", ver=(2, 0x20)):
    return profile(
        [(b"desc", desc_v2(b"gray")), (b"wtpt", xyz_tag(*D50W)), (b"kTRC", ktrc)], cs=b"GRAY", pcs=pcs, ver=ver
    )


def mat_inv(m):
    a, b, c = m[0]
    d, e, f = m[1]
    g, h, i = m[2]
    A = e * i - f * h
    B = -(d * i - f * g)
    C = d * h - e * g
    det = a * A + b * B + c * C
    return [
        [A / det, -(b * i - c * h) / det, (b * f - c * e) / det],
        [B / det, (a * i - c * g) / det, -(a * f - c * d) / det],
        [C / det, -(a * h - b * g) / det, (a * e - b * d) / det],
    ]


# packages/icc's own PCS(D50) -> linear sRGB matrix, used only to place a perturbation exactly (P2 fast-path case)
PION_T = [
    [3.134112153323845, -1.6173924595518705, -0.49063340456472027],
    [-0.9787872961391832, 1.9162795864266209, 0.03345471423138195],
    [0.07198304438569493, -0.22898585024754495, 1.4053851315844992],
]


def srgb_offdiag(delta):
    """sRGB primaries moved so that the PCS->sRGB product gets +delta at (row 1, col 0): red leaks into green."""
    ti = mat_inv(PION_T)
    r, g, b = [list(p) for p in PRIM["srgb"]]
    r = [r[k] + ti[k][1] * delta for k in range(3)]
    return (tuple(r), tuple(g), tuple(b))


def mft2_constant_white():
    """A2B0 lut16Type (mft2) that maps every RGB input to PCS XYZ D50 white (u1Fixed15 encoding)."""
    out = b"mft2\0\0\0\0" + bytes([3, 3, 2, 0])
    for v in (1, 0, 0, 0, 1, 0, 0, 0, 1):
        out += s15(float(v))
    out += u16(2) + u16(2)  # input / output table entries
    out += (u16(0) + u16(65535)) * 3  # identity input tables
    wx, wy, wz = [int(round(v * 32768.0)) for v in D50W]
    out += (u16(wx) + u16(wy) + u16(wz)) * 8  # 2x2x2 CLUT, all corners = white
    out += (u16(0) + u16(65535)) * 3  # identity output tables
    return out


# ----------------------------------------------------------------------------------------------------------------
# Containers
# ----------------------------------------------------------------------------------------------------------------


def seg(marker, payload):
    return bytes([0xFF, marker]) + u16(len(payload) + 2) + payload


def icc_app2(seq, total, chunk):
    return seg(0xE2, b"ICC_PROFILE\0" + bytes([seq, total]) + chunk)


JFIF = seg(0xE0, b"JFIF\0\x01\x01\0\0\x01\0\x01\0\0")
DQT = seg(0xDB, b"\0" + bytes(range(1, 65)))
SOS = seg(0xDA, b"\x01\x01\0\0\x3f\0")
SCAN = b"\x12\x34\xff\x00\x56\xff\xd0\x78"
EOI = b"\xff\xd9"


def jpeg(*segments, tail=True):
    out = b"\xff\xd8" + b"".join(segments)
    if tail:
        out += SOS + SCAN + EOI
    return out


def split_chunks(data, n):
    k = (len(data) + n - 1) // n
    return [data[i * k : (i + 1) * k] for i in range(n)]


def jpeg_icc(icc, nchunks=1, order=None):
    parts = split_chunks(icc, nchunks)
    order = order or list(range(1, nchunks + 1))
    return jpeg(JFIF, *[icc_app2(s, nchunks, parts[s - 1]) for s in order], DQT)


def chunk(fourcc, payload):
    out = fourcc + struct.pack("<I", len(payload)) + payload
    if len(payload) & 1:
        out += b"\0"
    return out


VP8L = chunk(b"VP8L", b"\x2f\0\0\0\0\x07\0\x88\x88\x08")


def vp8x(flags):
    return chunk(b"VP8X", bytes([flags, 0, 0, 0]) + b"\0\0\0" + b"\0\0\0")


def riff(*chunks, size=None):
    body = b"WEBP" + b"".join(chunks)
    return b"RIFF" + struct.pack("<I", len(body) if size is None else size) + body


def webp_icc(icc):
    return riff(vp8x(0x20), chunk(b"ICCP", icc), VP8L)


# ----------------------------------------------------------------------------------------------------------------
# Corpus
# ----------------------------------------------------------------------------------------------------------------


def diff_corpus():
    """Well-formed profiles: name -> bytes. Every one must transform within the tolerance of compare.py."""
    srgb1024 = curv([int(round(srgb_eotf(i / 1023) * 65535)) for i in range(1024)])
    srgb4096 = curv([int(round(srgb_eotf(i / 4095) * 65535)) for i in range(4096)])
    lcg = 12345
    mono = []
    acc = 0
    for i in range(256):
        lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF
        acc += 1 + (lcg >> 16) % 500
        mono.append(acc)
    mono = [int(v * 65535 / mono[-1]) for v in mono]
    d = {
        "srgb_v4_para3": rgb_profile("srgb", para(3, SRGB_PARA)),
        "srgb_v2_curv1024": rgb_profile("srgb", srgb1024, ver=(2, 0x10)),
        "srgb_v2_curv4096": rgb_profile("srgb", srgb4096, ver=(2, 0x10)),
        "srgb_prims_gamma22": rgb_profile("srgb", curv_gamma(2.2)),
        "p3_v4_para3": rgb_profile("p3", para(3, SRGB_PARA)),
        "adobe_v2_gamma": rgb_profile("adobe", curv_gamma(563 / 256), ver=(2, 0x10)),
        "prophoto_gamma18": rgb_profile("prophoto", curv_gamma(1.8)),
        "rec2020_para3_709": rgb_profile("rec2020", para(3, [1 / 0.45, 1 / 1.099, 0.099 / 1.099, 1 / 4.5, 0.081])),
        "rec709_linear_curv0": rgb_profile("srgb", curv([])),
        "ap0_linear_negative_xyz": rgb_profile("ap0", curv([])),
        "p3_para0_g22": rgb_profile("p3", para(0, [2.2])),
        "p3_para0_g045": rgb_profile("p3", para(0, [0.45])),
        "p3_para1_crush": rgb_profile("p3", para(1, [2.2, 1.05, -0.05])),
        "p3_para2_offset": rgb_profile("p3", para(2, [2.2, 1.0, 0.0, 0.02])),
        "p3_para2_negb": rgb_profile("p3", para(2, [2.4, 1.1, -0.1, 0.05])),
        "p3_para3_d0": rgb_profile("p3", para(3, [2.2, 1.0, 0.0, 0.5, 0.0])),
        "p3_para3_d1": rgb_profile("p3", para(3, [2.2, 1.0, 0.0, 0.5, 1.0])),
        "p3_para4_flare": rgb_profile("p3", para(4, SRGB_PARA + [0.01, 0.005])),
        "p3_para4_discontinuous": rgb_profile("p3", para(4, [2.0, 1.0, 0.0, 0.2, 0.3, 0.1, 0.0])),
        "p3_curv2_linear": rgb_profile("p3", curv([0, 65535])),
        "p3_curv2_inverted": rgb_profile("p3", curv([65535, 0])),
        "p3_curv2_half": rgb_profile("p3", curv([0, 32768])),
        "p3_curv256_monotone": rgb_profile("p3", curv(mono)),
        "p3_gamma1": rgb_profile("p3", curv_gamma(1.0)),
        "p3_gamma05": rgb_profile("p3", curv_gamma(0.5)),
        "p3_gamma3": rgb_profile("p3", curv_gamma(3.0)),
        "p3_mixed_trcs": rgb_profile("p3", curv_gamma(1.8), para(3, SRGB_PARA), srgb1024),
        "zero_matrix": rgb_profile(((0, 0, 0), (0, 0, 0), (0, 0, 0)), para(3, SRGB_PARA)),
        "singular_matrix": rgb_profile(((0.3214, 0.3333, 0.2750),) * 3, para(3, SRGB_PARA)),
        "srgb_offdiag_0019": rgb_profile(srgb_offdiag(0.0019), para(3, SRGB_PARA)),
        "srgb_offdiag_0010": rgb_profile(srgb_offdiag(0.0010), para(3, SRGB_PARA)),
        "gray_gamma22": gray_profile(curv_gamma(2.2)),
        "gray_srgb_para3": gray_profile(para(3, SRGB_PARA), ver=(4, 0x30)),
        "gray_curv256": gray_profile(curv(mono)),
        "gray_identity": gray_profile(curv([])),
        "gray_para0_g18": gray_profile(para(0, [1.8]), ver=(4, 0x30)),
        "gray_para4_flare": gray_profile(para(4, SRGB_PARA + [0.01, 0.005]), ver=(4, 0x30)),
    }
    return d


def fnv64(data):
    h = 0xCBF29CE484222325
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h


# dump.pion probe set is 4 x 256 + 9^3 RGB pixels: an engine honouring the all-white A2B0 outputs only 0xFF
ALL_WHITE_FNV = fnv64(b"\xff" * ((4 * 256 + 729) * 3))


def adv_corpus():
    """[(name, bytes, ext, [regex that must match a line of the dump record], finding_or_None)]"""
    good = rgb_profile("p3", para(3, SRGB_PARA))
    cases = []

    def add(name, data, want, ext="icc", finding=None):
        cases.append((name, data, ext, want, finding))

    P_ERR = ["^P ERR "]
    # --- header ---
    for v, w in ((0, P_ERR), (127, P_ERR), (128, ["^P ERR UnexpectedEof"]), (131, ["^P ERR UnexpectedEof"])):
        b = bytearray(good)
        b[0:4] = u32(v)
        add("hdr_size_%d" % v, bytes(b), w)
    b = bytearray(good)
    b[0:4] = u32(len(good) + 1)
    add("hdr_size_past_eof", bytes(b), ["^P ERR UnexpectedEof"])
    b = bytearray(good)
    b[0:4] = u32(0xFFFFFFFF)
    add("hdr_size_ffffffff", bytes(b), ["^P ERR UnexpectedEof"])
    add("hdr_trailing_garbage", good + b"\xee" * 64, ["^P OK size=%d " % len(good), "^T OK "])
    b = bytearray(good)
    b[36:40] = b"ACSP"
    add("hdr_bad_magic", bytes(b), ["^P ERR InvalidHeader"])
    for v in (4, 0x00010000, 0xFFFFFFFF):
        b = bytearray(good)
        b[64:68] = u32(v)
        add("hdr_intent_%x" % v, bytes(b), ["^P ERR InvalidHeader"])
    b = bytearray(good)
    b[128:132] = u32(0)
    b[0:4] = u32(132)
    add("tags_zero", bytes(b[:132]), ["^P OK .* ntags=0 ", "^T ERR UnsupportedProfile"])
    # --- tag table ---
    for cnt in (4097, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x15555556):
        b = bytearray(good)
        b[128:132] = u32(cnt)
        add("tags_count_%x" % cnt, bytes(b), ["^P ERR InvalidTagTable"])
    b = bytearray(good)
    b[128:132] = u32(200)
    add("tags_table_past_size", bytes(b), ["^P ERR InvalidTagTable"])
    # 4096 unknown tags, all valid: accepted
    blob = b"zzzz\0\0\0\0"
    many = raw_profile([(b"x%03d" % (i % 1000) if i < 1000 else struct.pack(">I", 0x41000000 + i), 0) for i in range(4096)], [blob])
    add("tags_4096_unknown", many, ["^P OK .* ntags=4096 ", "^T ERR UnsupportedProfile"])
    xyz = xyz_tag(0.5, 0.25, 0.0)
    base_len = len(raw_profile([(b"rXYZ", 0)], [xyz]))
    for name, off, size in (
        ("off_0", 0, 20),
        ("off_127", 127, 20),
        ("size_0", 144, 0),
        ("off_eq_size", base_len, 1),
        ("off_past_size", base_len + 4, 4),
        ("end_past_size", 144, base_len - 144 + 1),
        ("wrap32_off", 0xFFFFFFF0, 0x20),
        ("wrap32_size", 144, 0xFFFFFFFF),
        ("wrap32_both", 0x80000000, 0x80000000),
    ):
        add("tag_" + name, raw_profile([(b"rXYZ", (off, size))], [xyz]), ["^P ERR InvalidTagTable"])
    add("tag_end_eq_size", raw_profile([(b"rXYZ", (144, base_len - 144))], [xyz]), ["^P OK "])
    add("tag_unknown_oob_rejects_profile", raw_profile([(b"zzzz", (144, 0x1000))], [xyz]), ["^P ERR InvalidTagTable"])
    add("tag_overlaps_table", raw_profile([(b"cprt", (128, 8))], [xyz]), ["^P OK "])
    # --- XYZ / chad ---
    add("xyz_short", raw_profile([(b"rXYZ", (144, 19))], [xyz]), ["^P ERR InvalidTag"])
    add("xyz_bad_type", raw_profile([(b"gXYZ", 0)], [b"xyz " + xyz[4:]]), ["^P ERR InvalidTag"])
    add("chad_short", raw_profile([(b"chad", (144, 43))], [sf32(CHAD_D65)]), ["^P ERR InvalidTag"])
    add("chad_bad_type", raw_profile([(b"chad", 0)], [b"mf32" + sf32(CHAD_D65)[4:]]), ["^P ERR InvalidTag"])
    ext_prims = ((xyz_raw(0x80000000, 0x80000000, 0x80000000)), xyz_raw(0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF), xyz_raw(0, 0, 0))
    ex = profile([(b"rXYZ", ext_prims[0]), (b"gXYZ", ext_prims[1]), (b"bXYZ", ext_prims[2]), (b"rTRC", para(3, SRGB_PARA))], aliases=[(b"gTRC", b"rTRC"), (b"bTRC", b"rTRC")])
    add("xyz_extreme_s15f16", ex, ["^P OK ", "^X c0e0000000000000,c0e0000000000000,c0e0000000000000 40dfffffff", "^T ERR UnsupportedProfile"])
    add("matrix_gain_over_limit", rgb_profile(((3.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)), para(3, SRGB_PARA)), ["^T ERR UnsupportedProfile"])
    # --- curv ---
    for name, data, want in (
        ("curv_count_40000000", b"curv\0\0\0\0" + u32(0x40000000) + b"\0" * 16, ["^P ERR InvalidTag"]),
        ("curv_count_80000000", b"curv\0\0\0\0" + u32(0x80000000) + b"\0" * 16, ["^P ERR InvalidTag"]),
        ("curv_count_ffffffff", b"curv\0\0\0\0" + u32(0xFFFFFFFF) + b"\0" * 16, ["^P ERR InvalidTag"]),
        ("curv_count_65537", b"curv\0\0\0\0" + u32(65537) + b"\0" * (2 * 65537), ["^P ERR InvalidTag"]),
        ("curv_count_65536_ok", curv(list(range(0, 65536))), ["^P OK ", "^K T65536:"]),
        ("curv_table_short_by_1", b"curv\0\0\0\0" + u32(4) + b"\0" * 7, ["^P ERR InvalidTag"]),
        ("curv_gamma_size12", b"curv\0\0\0\0" + u32(1), ["^P ERR InvalidTag"]),
        ("curv_gamma_0", curv_gamma(0.0), ["^P OK ", "^T OK "]),
        ("curv_gamma_max", b"curv\0\0\0\0" + u32(1) + u16(0xFFFF), ["^P OK ", "^T OK "]),
        ("curv_tag_size_11", b"curv\0\0\0\0\0\0\0", ["^P ERR InvalidTag"]),
        ("trc_bad_type", b"sf32\0\0\0\0" + u32(0) + b"\0" * 4, ["^P ERR InvalidTag"]),
        ("para_type5", para(5, [1.0] * 7), ["^P ERR InvalidTag"]),
        ("para_type65535", b"para\0\0\0\0" + u16(65535) + u16(0) + b"\0" * 28, ["^P ERR InvalidTag"]),
        ("para_type4_short", para(4, [1.0] * 7)[:39], ["^P ERR InvalidTag"]),
        ("para_type1_short", para(1, [1.0] * 3)[:23], ["^P ERR InvalidTag"]),
        ("para_type0_short", para(0, [1.0])[:15], ["^P ERR InvalidTag"]),
        ("para_g_min", b"para\0\0\0\0" + u16(0) + u16(0) + u32(0x80000000), ["^P OK ", "^T OK "]),
        ("para_g_zero", para(0, [0.0]), ["^P OK ", "^T OK "]),
        ("para1_a_zero", para(1, [2.2, 0.0, 0.5]), ["^P OK ", "^T OK "]),
        ("para2_a_zero", para(2, [2.2, 0.0, 0.5, 0.1]), ["^P OK ", "^T OK "]),
        ("para3_neg_base", para(3, [2.2, 1.0, -2.0, 0.1, 0.5]), ["^P OK ", "^T OK "]),
        ("para4_extremes", b"para\0\0\0\0" + u16(4) + u16(0) + u32(0x7FFFFFFF) + u32(0x80000000) + u32(0x7FFFFFFF) + u32(0x80000000) + u32(0x80000000) + u32(0x7FFFFFFF) + u32(0x80000000), ["^P OK ", "^T OK "]),
        ("para3_frac_pow_neg", para(3, [2.5, -1.0, 0.5, 1.0, 0.0]), ["^P OK ", "^T OK "]),
    ):
        add(name, profile([(b"rXYZ", xyz_tag(*PRIM["p3"][0])), (b"gXYZ", xyz_tag(*PRIM["p3"][1])), (b"bXYZ", xyz_tag(*PRIM["p3"][2])), (b"rTRC", data)], aliases=[(b"gTRC", b"rTRC"), (b"bTRC", b"rTRC")]), want)
    # --- desc / mluc ---
    def with_desc(payload):
        return profile([(b"desc", payload)])

    add("desc_v2_ok", with_desc(desc_v2(b"Hello")), ["desc=48656c6c6f$"])
    add("desc_count_0", with_desc(b"desc\0\0\0\0" + u32(0)), ["^P OK .* desc=$"])
    add("desc_no_nul", with_desc(b"desc\0\0\0\0" + u32(3) + b"abc"), ["desc=616263$"])
    add("desc_count_past_tag", with_desc(b"desc\0\0\0\0" + u32(4) + b"abc"), ["^P ERR InvalidTag"])
    add("desc_count_ffffffff", with_desc(b"desc\0\0\0\0" + u32(0xFFFFFFFF) + b"abc"), ["^P ERR InvalidTag"])
    add("desc_size_lt_12", raw_profile([(b"desc", (144, 11))], [b"desc\0\0\0\0" + u32(0) + b"\0" * 8]), ["^P ERR InvalidTag"])
    add("desc_size_lt_4_ignored", raw_profile([(b"desc", (144, 3))], [b"desc\0\0\0\0"]), ["^P OK .* desc=-$"])
    add("desc_text_type_ignored", with_desc(text_tag(b"plain")), ["^P OK .* desc=-$"])
    add("desc_inner_nul", with_desc(b"desc\0\0\0\0" + u32(6) + b"ab\0cd\0"), ["desc=6162$"])
    add("desc_high_bytes", with_desc(b"desc\0\0\0\0" + u32(4) + b"\xff\xfe\x80\0"), ["^P OK .* desc=fffe80$"])
    add("mluc_zero_records", with_desc(b"mluc\0\0\0\0" + u32(0) + u32(12)), ["^P OK .* desc=$"])
    add("mluc_4097_records", with_desc(b"mluc\0\0\0\0" + u32(4097) + u32(12)), ["^P ERR InvalidTag"])
    add("mluc_count_ffffffff", with_desc(b"mluc\0\0\0\0" + u32(0xFFFFFFFF) + u32(12)), ["^P ERR InvalidTag"])
    add("mluc_record_size_11", with_desc(b"mluc\0\0\0\0" + u32(1) + u32(11) + b"enUS" + u32(0) + u32(28)), ["^P ERR InvalidTag"])
    add("mluc_record_size_ffffffff", with_desc(b"mluc\0\0\0\0" + u32(1) + u32(0xFFFFFFFF) + b"enUS" + u32(0) + u32(28)), ["^P ERR InvalidTag"])
    add("mluc_table_past_tag", with_desc(b"mluc\0\0\0\0" + u32(2) + u32(12) + b"enUS" + u32(0) + u32(28)), ["^P ERR InvalidTag"])
    add("mluc_str_off_past", with_desc(b"mluc\0\0\0\0" + u32(1) + u32(12) + b"enUS" + u32(2) + u32(0x1000) + b"\0A"), ["^P ERR InvalidTag"])
    add("mluc_str_len_past", with_desc(b"mluc\0\0\0\0" + u32(1) + u32(12) + b"enUS" + u32(0xFFFFFFFF) + u32(28) + b"\0A"), ["^P ERR InvalidTag"])
    add("mluc_str_off_ffffffff", with_desc(b"mluc\0\0\0\0" + u32(1) + u32(12) + b"enUS" + u32(2) + u32(0xFFFFFFFF) + b"\0A"), ["^P ERR InvalidTag"])
    add("mluc_odd_len", with_desc(mluc([(b"enUS", b"\0A\0B\0")])), ["desc=4142$"])
    add("mluc_surrogate_pair", with_desc(mluc([(b"enUS", "\U0001F600x".encode("utf-16-be"))])), ["desc=f09f988078$"])
    add("mluc_unpaired_high", with_desc(mluc([(b"enUS", b"\xd8\x3d\0x")])), ["desc=efbfbd78$"])
    add("mluc_unpaired_high_at_end", with_desc(mluc([(b"enUS", b"\0x\xd8\x3d")])), ["desc=78efbfbd$"])
    add("mluc_unpaired_low", with_desc(mluc([(b"enUS", b"\xde\x00\0x")])), ["desc=efbfbd78$"])
    add("mluc_reversed_pair", with_desc(mluc([(b"enUS", b"\xde\x00\xd8\x3d")])), ["desc=efbfbdefbfbd$"])
    add("mluc_trailing_nuls", with_desc(mluc([(b"enUS", b"\0A\0\0\0\0")])), ["desc=41$"])
    add("mluc_enus_preferred", with_desc(mluc([(b"deDE", "Farbe".encode("utf-16-be")), (b"enGB", "Colour".encode("utf-16-be")), (b"enUS", "Color".encode("utf-16-be"))])), ["desc=436f6c6f72$"])
    add("mluc_en_fallback", with_desc(mluc([(b"deDE", "Farbe".encode("utf-16-be")), (b"enGB", "Colour".encode("utf-16-be"))])), ["desc=436f6c6f7572$"])
    add("mluc_first_fallback", with_desc(mluc([(b"deDE", "Farbe".encode("utf-16-be")), (b"frFR", "Couleur".encode("utf-16-be"))])), ["desc=4661726265$"])
    add("mluc_bmp_nonascii", with_desc(mluc([(b"enUS", "\u00e9\u4e2d".encode("utf-16-be"))])), ["desc=c3a9e4b8ad$"])
    # --- transform preconditions ---
    add("gray_pcs_lab", gray_profile(curv_gamma(2.2), pcs=b"Lab "), ["^T ERR UnsupportedProfile"])
    add("gray_missing_ktrc", profile([(b"wtpt", xyz_tag(*D50W))], cs=b"GRAY"), ["^T ERR UnsupportedProfile"])
    add("rgb_missing_gxyz", profile([(b"rXYZ", xyz_tag(*PRIM["p3"][0])), (b"bXYZ", xyz_tag(*PRIM["p3"][2])), (b"rTRC", para(3, SRGB_PARA))], aliases=[(b"gTRC", b"rTRC"), (b"bTRC", b"rTRC")]), ["^T ERR UnsupportedProfile"])
    add("rgb_missing_btrc", profile([(b"rXYZ", xyz_tag(*PRIM["p3"][0])), (b"gXYZ", xyz_tag(*PRIM["p3"][1])), (b"bXYZ", xyz_tag(*PRIM["p3"][2])), (b"rTRC", para(3, SRGB_PARA))], aliases=[(b"gTRC", b"rTRC")]), ["^T ERR UnsupportedProfile"])
    b = bytearray(good)
    b[20:24] = b"Lab "
    add("rgb_pcs_lab", bytes(b), ["^T ERR UnsupportedProfile"])
    b = bytearray(good)
    b[16:20] = b"CMYK"
    add("cmyk_class", bytes(b), ["^T ERR UnsupportedProfile"])
    # --- findings ---
    dup = profile([(b"rXYZ", xyz_tag(*PRIM["p3"][0])), (b"gXYZ", xyz_tag(*PRIM["p3"][1])), (b"bXYZ", xyz_tag(*PRIM["p3"][2])), (b"rTRC", para(3, SRGB_PARA)), (b"zzzz", curv_gamma(1.0))], aliases=[(b"gTRC", b"rTRC"), (b"bTRC", b"rTRC")])
    # rename the 'zzzz' record into a second rTRC (gamma 1.0): last-wins in packages/icc and moxcms 0.9.2, first-wins in qcms 0.3.0
    i = dup.index(b"zzzz", 132)
    dup = dup[:i] + b"rTRC" + dup[i + 4 :]
    add("dup_rtrc_conflicting", dup, ["^P ERR InvalidTagTable"], finding="P0-1")
    a2b = rgb_profile("p3", para(3, SRGB_PARA), extra=[(b"A2B0", mft2_constant_white())])
    add("a2b0_with_matrix_trc", a2b, ["^T ERR UnsupportedProfile|^T OK id=0 gray=0 fnv=" + ALL_WHITE_FNV], finding="P2-3")
    # --- JPEG ---
    icc = good
    J = "jpg"
    add("jpeg_single", jpeg_icc(icc), ["^C OK %d " % len(icc), "^P OK "], J)
    add("jpeg_3_in_order", jpeg_icc(icc, 3), ["^C OK %d " % len(icc), "^P OK "], J)
    add("jpeg_3_out_of_order", jpeg_icc(icc, 3, [3, 1, 2]), ["^C OK %d " % len(icc), "^P OK "], J)
    add("jpeg_255_chunks", jpeg_icc(icc + b"\0" * (255 - len(icc) % 255), 255), ["^C OK ", "^P OK "], J)
    add("jpeg_255_chunks_reversed", jpeg_icc(icc + b"\0" * (255 - len(icc) % 255), 255, list(range(255, 0, -1))), ["^C OK ", "^P OK "], J)
    parts = split_chunks(icc, 3)
    add("jpeg_seq_0", jpeg(icc_app2(0, 1, icc)), ["^C ERR InvalidContainer"], J)
    add("jpeg_total_0", jpeg(icc_app2(1, 0, icc)), ["^C ERR InvalidContainer"], J)
    add("jpeg_seq_gt_total", jpeg(icc_app2(2, 1, icc)), ["^C ERR InvalidContainer"], J)
    add("jpeg_dup_seq", jpeg(icc_app2(1, 2, parts[0]), icc_app2(1, 2, parts[1])), ["^C ERR InvalidContainer"], J)
    add("jpeg_total_mismatch", jpeg(icc_app2(1, 2, parts[0]), icc_app2(2, 3, parts[1])), ["^C ERR InvalidContainer"], J)
    add("jpeg_missing_chunk", jpeg(icc_app2(1, 3, parts[0]), icc_app2(3, 3, parts[2])), ["^C ERR InvalidContainer"], J)
    add("jpeg_two_full_sets", jpeg(icc_app2(1, 1, icc), icc_app2(1, 1, icc)), ["^C ERR InvalidContainer"], J)
    add("jpeg_empty_chunk", jpeg(icc_app2(1, 1, b"")), ["^C OK 0 ", "^P ERR UnexpectedEof"], J)
    add("jpeg_app2_after_sos_ignored", b"\xff\xd8" + JFIF + SOS + SCAN + icc_app2(1, 1, icc) + EOI, ["^C NONE"], J)
    add("jpeg_app2_after_eoi_ignored", b"\xff\xd8" + JFIF + EOI + icc_app2(1, 1, icc), ["^C NONE"], J)
    add("jpeg_chunk_after_sos_not_merged", jpeg(icc_app2(1, 2, parts[0]), tail=False) + SOS + SCAN + icc_app2(2, 2, parts[1]) + EOI, ["^C ERR InvalidContainer"], J)
    add("jpeg_fill_bytes", b"\xff\xd8" + b"\xff" * 1000 + icc_app2(1, 1, icc)[1:] + SOS + SCAN + EOI, ["^C OK %d " % len(icc)], J)
    add("jpeg_rst_tem_before", b"\xff\xd8\xff\xd0\xff\x01\xff\xd7" + icc_app2(1, 1, icc) + EOI, ["^C OK %d " % len(icc)], J)
    add("jpeg_stray_bytes_resync", b"\xff\xd8" + JFIF + b"\x00\x11garbage" + icc_app2(1, 1, icc) + EOI, ["^C OK %d " % len(icc)], J)
    add("jpeg_no_icc", jpeg(JFIF, DQT), ["^C NONE"], J)
    add("jpeg_mpf_app2", jpeg(seg(0xE2, b"MPF\0" + b"\0" * 20)), ["^C NONE"], J)
    add("jpeg_icc_prefix_no_nul", jpeg(seg(0xE2, b"ICC_PROFILE\x01\x01\x01" + icc)), ["^C NONE"], J)
    add("jpeg_icc_payload_13", jpeg(seg(0xE2, b"ICC_PROFILE\0\x01")), ["^C NONE"], J)
    add("jpeg_seg_len_0", b"\xff\xd8\xff\xe2\x00\x00" + b"\0" * 32, ["^C ERR InvalidContainer"], J)
    add("jpeg_seg_len_1", b"\xff\xd8\xff\xe2\x00\x01" + b"\0" * 32, ["^C ERR InvalidContainer"], J)
    add("jpeg_seg_len_past_eof", b"\xff\xd8\xff\xe2\xff\xff" + b"ICC_PROFILE\0\x01\x01", ["^C ERR InvalidContainer"], J)
    add("jpeg_marker_at_eof", b"\xff\xd8\xff\xff", ["^C ERR InvalidContainer"], J)
    add("jpeg_len_at_eof", b"\xff\xd8\xff\xe2\x00", ["^C ERR InvalidContainer"], J)
    add("jpeg_no_soi", b"\xff\xd9" + icc_app2(1, 1, icc), ["^C ERR InvalidContainer"], J)
    add("jpeg_len_0", b"", ["^C ERR InvalidContainer"], J)
    add("jpeg_len_1", b"\xff", ["^C ERR InvalidContainer"], J)
    add("jpeg_soi_only", b"\xff\xd8", ["^C NONE"], J)
    # --- WebP ---
    W = "webp"
    add("webp_vp8x_iccp", webp_icc(icc), ["^C OK %d " % len(icc), "^P OK "], W)
    add("webp_odd_iccp_padded", webp_icc(icc + b"\0"), ["^C OK %d " % (len(icc) + 1)], W)
    add("webp_odd_last_chunk_unpadded", riff(vp8x(0x20), chunk(b"ICCP", icc + b"\0"))[:-1], ["^C OK %d " % (len(icc) + 1)], W)
    add("webp_dup_iccp_first_wins", riff(vp8x(0x20), chunk(b"ICCP", icc), chunk(b"ICCP", b"x" * 200), VP8L), ["^C OK %d " % len(icc)], W)
    add("webp_no_iccp", riff(vp8x(0), VP8L), ["^C NONE"], W)
    add("webp_iccp_past_riff_size", riff(vp8x(0x20), VP8L, chunk(b"ICCP", icc), size=4 + 18 + 18), ["^C NONE"], W)
    add("webp_riff_size_ffffffff", riff(vp8x(0x20), chunk(b"ICCP", icc), VP8L, size=0xFFFFFFFF), ["^C OK %d " % len(icc)], W)
    add("webp_riff_size_3", riff(vp8x(0x20), size=3), ["^C ERR InvalidContainer"], W)
    add("webp_riff_size_4", riff(vp8x(0x20), chunk(b"ICCP", icc), size=4), ["^C NONE"], W)
    add("webp_chunk_ffffffff", b"RIFF" + struct.pack("<I", 100) + b"WEBP" + b"ICCP" + struct.pack("<I", 0xFFFFFFFF) + b"\0" * 80, ["^C ERR InvalidContainer"], W)
    add("webp_chunk_wrap", b"RIFF" + struct.pack("<I", 100) + b"WEBP" + b"VP8X" + struct.pack("<I", 0xFFFFFFF7) + b"\0" * 80, ["^C ERR InvalidContainer"], W)
    add("webp_iccp_truncated", riff(vp8x(0x20), chunk(b"ICCP", icc))[:-10], ["^C ERR InvalidContainer"], W)
    add("webp_header_only", b"RIFF\x04\0\0\0WEBP", ["^C NONE"], W)
    add("webp_short", b"RIFF\x04\0\0\0WEB", ["^C ERR InvalidContainer"], W)
    add("webp_bad_riff", b"RIFX" + webp_icc(icc)[4:], ["^C ERR InvalidContainer"], W)
    add("webp_bad_form", webp_icc(icc)[:8] + b"WAVE" + webp_icc(icc)[12:], ["^C ERR InvalidContainer"], W)
    add("webp_partial_chunk_header", riff(vp8x(0x20)) + b"ICC", ["^C NONE"], W)
    add("webp_iccp_without_vp8x_flag", riff(vp8x(0x00), chunk(b"ICCP", icc), VP8L), ["^C NONE"], W, finding="P2-4")
    add("webp_iccp_in_simple_format", riff(VP8L, chunk(b"ICCP", icc)), ["^C NONE"], W, finding="P2-4")
    return cases


def trunc_seeds():
    jp = jpeg_icc(rgb_profile("p3", para(3, SRGB_PARA)), 3, [2, 3, 1])
    return {
        "p3_v4.icc": rgb_profile("p3", para(3, SRGB_PARA)),
        "srgb_v2_curv.icc": rgb_profile("srgb", curv([int(round(srgb_eotf(i / 63) * 65535)) for i in range(64)]), ver=(2, 0x10)),
        "gray_mluc.icc": profile([(b"desc", mluc([(b"deDE", "Grau".encode("utf-16-be")), (b"enUS", "Gray \U0001F600".encode("utf-16-be"))])), (b"kTRC", para(4, SRGB_PARA + [0.01, 0.005])), (b"chad", sf32(CHAD_D65))], cs=b"GRAY"),
        "p3_3chunks.jpg": jp,
        "p3_vp8x.webp": webp_icc(rgb_profile("p3", para(3, SRGB_PARA))),
    }


def lcg_stream(seed):
    s = seed
    while True:
        s = (s * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        yield s >> 33


INTERESTING32 = [0, 1, 0x7F, 0x80, 0xFF, 0x7FFF, 0x8000, 0xFFFF, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 128, 4096, 4097, 65536]


def mutate(data, r):
    b = bytearray(data)
    for _ in range(1 + next(r) % 4):
        if not b:
            b = bytearray(b"\0")
        op = next(r) % 7
        p = next(r) % len(b)
        if op == 0:
            b[p] ^= 1 << (next(r) % 8)
        elif op == 1:
            b[p] = next(r) & 0xFF
        elif op == 2 and len(b) >= 4:
            p = min(p, len(b) - 4) & ~3 if next(r) % 2 else min(p, len(b) - 4)
            b[p : p + 4] = struct.pack(">I", INTERESTING32[next(r) % len(INTERESTING32)])
        elif op == 3 and len(b) >= 2:
            p = min(p, len(b) - 2)
            b[p : p + 2] = struct.pack(">H", INTERESTING32[next(r) % len(INTERESTING32)] & 0xFFFF)
        elif op == 4:
            del b[p : p + 1 + next(r) % 16]
        elif op == 5:
            b[p:p] = bytes(next(r) & 0xFF for _ in range(1 + next(r) % 16))
        else:
            q = next(r) % len(b)
            n = 1 + next(r) % 32
            b[p:p] = b[q : q + n]
    return bytes(b)


def dos_corpus(out):
    """Resource bombs: [(name, path, verdict regex, budget_ms, finding)] - budget is per parse, native release."""
    items = []

    def add(name, data, verdict, budget, finding=None, ext="icc"):
        p = os.path.join(out, name + "." + ext)
        with open(p, "wb") as f:
            f.write(data)
        items.append({"name": name, "path": p, "verdict": verdict, "budget_ms": budget, "finding": finding, "bytes": len(data)})

    L = 1 << 20
    big_desc = b"desc\0\0\0\0" + u32(L) + b"A" * (L - 1) + b"\0"
    add("dup_desc_4096x1MiB", raw_profile([(b"desc", 0)] * 4096, [big_desc]), "PERR|TERR", 250, "P0-1")
    curv64k = curv(list(range(65536)))
    add("dup_rtrc_4096x64Ki_curv", raw_profile([(b"rTRC", 0)] * 4096, [curv64k]), "PERR|TERR", 250, "P0-1")
    u = ("\u00e9" * (L // 2)).encode("utf-16-be")
    add("dup_mluc_4096x1MiB", raw_profile([(b"desc", 0)] * 4096, [mluc([(b"enUS", u)])]), "PERR|TERR", 250, "P0-1")
    recs = b"".join(b"frFR" + u32(8) + u32(16 + 12 * 4096) for _ in range(4096))
    add("dup_mluc_4096x4096_records", raw_profile([(b"desc", 0)] * 4096, [b"mluc\0\0\0\0" + u32(4096) + u32(12) + recs + "abcd".encode("utf-16-be")]), "PERR|TERR", 250, "P0-1")
    # distinct signatures: the parser looks at <= 12 known tags, so work stays linear
    add("unique_4096_tags_1MiB_blob", raw_profile([(b"desc", 0)] + [(struct.pack(">I", 0x61000000 + i), 0) for i in range(4095)], [big_desc]), "TERR", 250)
    add("single_desc_16MiB", raw_profile([(b"desc", 0)], [b"desc\0\0\0\0" + u32(16 * L) + b"A" * (16 * L)]), "TERR", 250)
    add("curv_65536_x4_distinct", raw_profile([(b"rTRC", 0), (b"gTRC", 0), (b"bTRC", 0), (b"kTRC", 0)], [curv64k]), "TERR", 250)
    icc = rgb_profile("p3", para(3, SRGB_PARA))
    big = icc + b"\0" * (255 * 65519 - len(icc))
    add("jpeg_255x65519_chunks", jpeg_icc(big, 255), "OK", 250, ext="jpg")
    add("jpeg_4MiB_fill", b"\xff\xd8" + b"\xff" * (4 * L) + icc_app2(1, 1, icc)[1:] + EOI, "OK", 250, ext="jpg")
    add("jpeg_4MiB_stray", b"\xff\xd8" + b"\x00" * (4 * L) + icc_app2(1, 1, icc) + EOI, "OK", 250, ext="jpg")
    add("jpeg_1M_empty_segments", b"\xff\xd8" + b"\xff\xe3\x00\x02" * (L // 4) + icc_app2(1, 1, icc) + EOI, "OK", 250, ext="jpg")
    add("webp_1M_empty_chunks", riff(vp8x(0x20), *([b"JUNK\0\0\0\0"] * (L // 8)), chunk(b"ICCP", icc)), "OK", 250, ext="webp")
    return items


def grid_rgb():
    out = bytearray()
    for ch in range(4):
        for v in range(256):
            out += bytes([v if ch in (0, 3) else 0, v if ch in (1, 3) else 0, v if ch in (2, 3) else 0])
    lv = [min(255, i * 8) for i in range(33)]
    for r in lv:
        for g in lv:
            for b in lv:
                out += bytes([r, g, b])
    r = lcg_stream(0x1CC)
    for _ in range(4096):
        out += bytes([next(r) & 0xFF, next(r) & 0xFF, next(r) & 0xFF])
    return bytes(out)


def main():
    out = sys.argv[1]
    fuzz_n = int(sys.argv[2]) if len(sys.argv) > 2 else 10000
    for d in ("diff", "adv", "trunc", "fuzz", "dos"):
        os.makedirs(os.path.join(out, d), exist_ok=True)

    def w(rel, data):
        p = os.path.join(out, rel)
        with open(p, "wb") as f:
            f.write(data)
        return p

    lst = {"diff": [], "adv": [], "trunc": [], "fuzz": []}
    for name, data in diff_corpus().items():
        lst["diff"].append(w("diff/%s.icc" % name, data))
    manifest = []
    for name, data, ext, want, finding in adv_corpus():
        p = w("adv/%s.%s" % (name, ext), data)
        lst["adv"].append(p)
        manifest.append({"name": name, "path": p, "want": want, "finding": finding})
    seeds = trunc_seeds()
    for name, data in seeds.items():
        stem, ext = name.rsplit(".", 1)
        for k in range(len(data) + 1):
            lst["trunc"].append(w("trunc/%s_%05d.%s" % (stem, k, ext), data[:k]))
    r = lcg_stream(0x5EED1CC)
    names = sorted(seeds)
    for i in range(fuzz_n):
        name = names[i % len(names)]
        stem, ext = name.rsplit(".", 1)
        lst["fuzz"].append(w("fuzz/%s_%05d.%s" % (stem, i, ext), mutate(seeds[name], r)))
    dos = dos_corpus(os.path.join(out, "dos"))
    w("grid.rgb", grid_rgb())
    for g, paths in lst.items():
        with open(os.path.join(out, g + ".lst"), "w") as f:
            f.write("\n".join(paths) + "\n")
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=0)
    with open(os.path.join(out, "dos.json"), "w") as f:
        json.dump(dos, f, indent=0)
    print("corpus: diff %d, adv %d, trunc %d, fuzz %d, dos %d" % (len(lst["diff"]), len(manifest), len(lst["trunc"]), len(lst["fuzz"]), len(dos)))


if __name__ == "__main__":
    main()
