#!/usr/bin/env python3
"""Differential red-team harness: Pion packages/zip vs Go 1.27 archive/zip vs Rust zip =2.2.3 vs Python zipfile.

  python3 difftest.py vectors   # crafted P0 parser-differential / bomb / ZIP64 / EOCD cases
  python3 difftest.py fuzz      # random mutation fuzzing (crash / panic / trap / divergence census)
  python3 difftest.py paths     # clean_extract_path vs Go filepath.IsLocal vs Rust enclosed_name
  python3 difftest.py writer    # Pion ZipWriter output verified by Go / Rust / Python
  python3 difftest.py modes     # native debug/release + wasm32 debug/release byte-identical outputs
  python3 difftest.py dos       # zip bombs, HashDoS, 100k entries, EOCD scan timings

All artifacts live in $AUDIT_OUT (default /private/tmp/pion-zip-audit); binaries in $AUDIT_OUT/bin.
"""

import io
import os
import random
import struct
import subprocess
import sys
import time
import zipfile
import zlib

sys.dont_write_bytecode = True  # keep the worktree clean (no __pycache__)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zipcraft import Entry, build, deflate, u16, u32, u64, z64extra  # noqa: E402

OUT = os.environ.get("AUDIT_OUT", "/private/tmp/pion-zip-audit")
BIN = OUT + "/bin"
WASM_RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")


# ----------------------------------------------------------------------------------------------
# runners


def pack(records):
    return b"".join(u32(len(r)) + r for r in records)


def py_line(data):
    try:
        z = zipfile.ZipFile(io.BytesIO(data))
        infos = z.infolist()
    except Exception as e:  # noqa: BLE001
        return "ERR " + type(e).__name__
    parts = ["OK n=%d" % len(infos)]
    for i in infos:
        raw = i.orig_filename.encode("utf-8" if i.flag_bits & 0x800 else "cp437", "surrogateescape")
        try:
            d = z.open(i).read()
            parts.append("|%s:OK:%d:%d" % (raw.hex(), len(d), zlib.crc32(d)))
        except Exception as e:  # noqa: BLE001
            parts.append("|%s:ERR:%s" % (raw.hex(), type(e).__name__))
    return " ".join(parts)


def run_batch(tool, recs, extra=(), timeout=600):
    path = "%s/cases_%s.bin" % (OUT, os.getpid())
    with open(path, "wb") as f:
        f.write(pack(recs))
    if tool == "py":
        return [py_line(r) for r in recs]
    if tool.startswith("pion"):
        mode = "permissive" if tool.endswith("perm") else "default"
        variant = os.environ.get("PION_BIN", BIN + "/pion_audit")
        cmd = [variant, "batch", path, mode]
    else:
        cmd = [BIN + "/%s_audit" % tool, "batch", path]
    p = subprocess.run(cmd + list(extra), capture_output=True, timeout=timeout)
    lines = p.stdout.decode("utf-8", "replace").splitlines()
    if p.returncode != 0 or len(lines) != len(recs):
        # crashed somewhere: bisect one by one to attribute the crash
        lines = []
        for r in recs:
            with open(path, "wb") as f:
                f.write(pack([r]))
            q = subprocess.run(cmd, capture_output=True, timeout=timeout)
            if q.returncode != 0:
                tail = q.stderr.decode("utf-8", "replace").strip().splitlines()
                lines.append("CRASH rc=%d %s" % (q.returncode, (tail[-1] if tail else "")[:120]))
            else:
                lines.append(q.stdout.decode("utf-8", "replace").strip())
    return lines


def parse(line):
    """-> ('ERR'|'OK'|'CRASH'|'PANIC', [(name_hex, status, len, crc)])"""
    if not line.startswith("OK"):
        return (line.split(" ")[0], [])
    ents = []
    for part in line.split(" |")[1:]:
        f = part.split(":")
        ents.append((f[0], f[1], f[2] if f[1] == "OK" else "", f[3] if f[1] == "OK" else ""))
    return ("OK", ents)


def summarize(line, maxe=3):
    st, ents = parse(line)
    if st != "OK":
        return line[:60]
    s = "OK n=%d" % len(ents)
    for nm, ok, ln, crc in ents[:maxe]:
        try:
            nmv = bytes.fromhex(nm).decode("utf-8", "replace")[:12]
        except ValueError:
            nmv = nm[:12]
        s += " %s=%s" % (nmv, ("%s/%s" % (ln, crc[-4:])) if ok == "OK" else "ERR")
    if len(ents) > maxe:
        s += " …"
    return s


def canon(line):
    """Semantic view used for divergence: open status, names, per-entry ok + content crc."""
    st, ents = parse(line)
    return (st, tuple((n, o, ln, c) for n, o, ln, c in ents))


# ----------------------------------------------------------------------------------------------
# crafted vectors


def _crc_forge(buf, patch_at, crc_field_at, data_start):
    """Choose 4 bytes at patch_at so that crc32(buf[data_start:]) == u32 stored at crc_field_at (both inside)."""
    buf = bytearray(buf)
    target = 0x5A5A5A5A
    buf[crc_field_at:crc_field_at + 4] = u32(target)

    def f(pb):
        b = bytearray(buf)
        b[patch_at:patch_at + 4] = pb
        return zlib.crc32(bytes(b[data_start:]))
    base = f(b"\0\0\0\0")
    cols = [f(struct.pack("<I", 1 << i)) ^ base for i in range(32)]
    # solve sum(x_i * cols[i]) == target ^ base over GF(2)
    rows = [(cols[i], 1 << i) for i in range(32)]
    want = target ^ base
    basis = []
    for v, m in rows:
        for bv, bm in basis:
            if v ^ bv < v:
                v, m = v ^ bv, m ^ bm
        if v:
            basis.append((v, m))
            basis.sort(reverse=True)
    sol = 0
    for bv, bm in basis:
        if want ^ bv < want:
            want, sol = want ^ bv, sol ^ bm
    assert want == 0, "crc forge failed"
    buf[patch_at:patch_at + 4] = struct.pack("<I", sol)
    assert zlib.crc32(bytes(buf[data_start:])) == target
    return bytes(buf)


def forge_clamped_store():
    size = 0x0FFFFF00
    e = Entry("x.bin", b"C" * 300, 0, cd={"csize": size, "usize": size}, lfh={"csize": size, "usize": size, "crc": 0x5A5A5A5A},
              comment=b"PATC")
    lfh_len = 30 + 5 + 300
    cdsz = 46 + 5 + 4
    arch = build([e], zip64={"cd_off": (1 << 62) + lfh_len, "cd_size": (1 << 62) + cdsz})
    cd = lfh_len
    return _crc_forge(arch, cd + 46 + 5, cd + 16, 30 + 5)


class _NoSeek(io.RawIOBase):
    def __init__(self):
        self.buf = bytearray()

    def writable(self):
        return True

    def write(self, b):
        self.buf += b
        return len(b)


def py_stream_zip64():
    s = _NoSeek()
    with zipfile.ZipFile(s, "w", zipfile.ZIP_DEFLATED) as z:
        with z.open("streamed.txt", "w", force_zip64=True) as w:
            w.write(b"hello world " * 20)
    return bytes(s.buf)


def E(name, data=b"hello world " * 20, method=8, **kw):
    return Entry(name, data, method, **kw)


def vectors():
    V = []

    def add(cid, sev, desc, data):
        V.append((cid, sev, desc, data))

    good = E("good.txt")
    add("base_ok", "-", "control: well-formed 1-entry archive", build([good]))
    # --- LFH vs CD -------------------------------------------------------------------------------
    add("lfh_name_differs", "P0", "LFH name 'evil.sh' vs CD name 'good.txt'",
        build([E("good.txt", lfh={"name": b"evil.sh"})]))
    add("lfh_method_store_cd_deflate", "P1", "LFH method 0, CD method 8",
        build([E("a.txt", lfh={"method": 0})]))
    add("lfh_crc_wrong", "P1", "LFH CRC forged (no bit 3), CD CRC correct",
        build([E("a.txt", lfh={"crc": 0xDEADBEEF})]))
    add("lfh_csize_wrong", "P1", "LFH compressed_size forged (no bit 3)",
        build([E("a.txt", lfh={"csize": 7})]))
    add("lfh_usize_wrong", "P1", "LFH uncompressed_size forged (no bit 3)",
        build([E("a.txt", lfh={"usize": 1})]))
    add("lfh_flags_differ_utf8", "P2", "LFH bit 11 set, CD clear",
        build([E("a.txt", lfh={"flags": 0x800})]))
    add("dd_both_sig", "-", "control: bit 3 in both, LFH zeros, signed DD",
        build([E("a.txt", flags=8, dd="sig")]))
    add("dd_both_nosig", "-", "control: bit 3 in both, LFH zeros, unsigned DD",
        build([E("a.txt", flags=8, dd="nosig")]))
    e = E("a.txt", flags=8, dd="sig")
    e.lfh = {"crc": 0x11111111, "csize": 3, "usize": 5}
    add("dd_lfh_forged_nonzero", "P1", "bit 3 set, LFH carries forged non-zero crc/sizes, DD+CD correct",
        build([e]))
    add("dd_cd_only", "P1", "CD bit 3 set, LFH bit 3 clear (LFH has real values), DD present",
        build([E("a.txt", flags=0, cd={"flags": 8}, dd="sig")]))
    add("dd_lfh_only", "P1", "LFH bit 3 set (zeros), CD bit 3 clear, DD present",
        build([E("a.txt", flags=0, lfh={"flags": 8, "crc": 0, "csize": 0, "usize": 0}, dd="sig")]))
    add("dd_wrong_crc", "P1", "bit 3, DD CRC wrong (CD correct)",
        build([E("a.txt", flags=8, dd=u32(0x08074B50) + u32(0xBAD) + u32(len(deflate(b"hello world " * 20))) + u32(240))]))
    add("dd_wrong_sizes", "P1", "bit 3, DD sizes wrong (CD correct)",
        build([E("a.txt", flags=8, dd=u32(0x08074B50) + u32(zlib.crc32(b"hello world " * 20)) + u32(1) + u32(2))]))
    add("dd_missing", "P1", "bit 3 but no descriptor bytes before CD",
        build([E("a.txt", flags=8, dd=None)]))
    add("dd_zip64_lfh_extra_small", "P1",
        "streaming writer: LFH ZIP64 extra + bit 3 + 24-byte ZIP64 DD, CD uses plain 32-bit sizes (APPNOTE 4.3.9.2)",
        build([E("a.txt", flags=8, dd="sig64", lfh={"ver": 45, "extra": z64extra(0, 0)})]))
    add("py_stream_force_zip64", "P1",
        "CPython zipfile writing to a non-seekable stream with force_zip64=True (real-world producer)", py_stream_zip64())
    add("lfh_extra_len_differs", "-", "LFH extra 8B, CD extra none (data start must use LFH lengths)",
        build([E("a.txt", lfh_extra=u16(0xCAFE) + u16(4) + b"abcd")]))
    add("lfh_namelen_swallow", "P1", "LFH name_len +16 so payload start shifts (Android 'master key' style)",
        build([E("a.txt", data=b"A" * 400, method=0, lfh={"name_len": 5 + 16})]))
    # --- prefix / trailing -----------------------------------------------------------------------
    add("prefix128_unadjusted", "P1", "128 B SFX stub prepended, offsets NOT adjusted (cat stub.bin a.zip)",
        build([E("a.txt"), E("b.txt", method=0)], prefix=b"#!/bin/sh\n" + b"X" * 118))
    add("prefix128_adjusted", "-", "control: 128 B prefix, offsets adjusted (zip -A)",
        build([E("a.txt"), E("b.txt", method=0)], prefix=b"S" * 128, adjust_prefix=True))
    add("trailing_16", "P2", "16 junk bytes after EOCD (comment_len=0)",
        build([E("a.txt")], trailing=b"\0" * 16))
    add("comment_len_short", "P2", "EOCD comment_len smaller than real trailing comment",
        build([E("a.txt")], comment=b"real comment", eocd={"comment_len": 4}))
    add("comment_len_long", "P1", "EOCD comment_len points past EOF",
        build([E("a.txt")], comment=b"abc", eocd={"comment_len": 40}))
    # --- EOCD confusion --------------------------------------------------------------------------
    inner = build([E("decoy.txt", data=b"decoy")])
    real = build([E("real.txt", data=b"real")])
    add("concat_two_zips", "P1", "zip1 || zip2 (which central directory wins?)", inner + real)
    fake_cd_target = build([E("real.txt", data=b"real")])
    # fake EOCD inside comment, consistent comment length pointing to end-of-file
    fake = u32(0x06054B50) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(0) + u16(0)
    blob = build([E("real.txt", data=b"real")], comment=b"hdr" + fake[:-2] + u16(0))
    add("eocd_fake_in_comment_empty", "P1", "comment ends with a 22B EOCD declaring 0 entries", blob)
    add("cd_count_short", "P1", "EOCD says 1 entry, CD has 2",
        build([E("a.txt"), E("b.txt")], eocd={"n": 1, "n_disk": 1}))
    add("cd_count_long", "P1", "EOCD says 3 entries, CD has 2",
        build([E("a.txt"), E("b.txt")], eocd={"n": 3, "n_disk": 3}))
    add("gap_cd_eocd", "P2", "16 junk bytes between CD end and EOCD",
        build([E("a.txt")], gap_after_cd=b"J" * 16))
    # --- ZIP64 -----------------------------------------------------------------------------------
    d = b"zip64 payload " * 30
    p = deflate(d)
    add("z64_only_usize", "-", "CD usize=0xFFFFFFFF only; extra=[usize]",
        build([E("a.txt", data=d, cd={"usize": 0xFFFFFFFF, "ver": 45}, cd_extra=z64extra(len(d)))], zip64={}))
    add("z64_only_csize", "P0", "CD csize=0xFFFFFFFF only; extra=[csize] (APPNOTE 4.5.3 order)",
        build([E("a.txt", data=d, cd={"csize": 0xFFFFFFFF, "ver": 45}, cd_extra=z64extra(len(p)))], zip64={}))
    add("z64_only_csize_fullextra", "P1", "CD csize sentinel only, extra carries BOTH usize,csize (non-conforming writer)",
        build([E("a.txt", data=d, cd={"csize": 0xFFFFFFFF, "ver": 45}, cd_extra=z64extra(len(d), len(p)))], zip64={}))
    add("z64_only_offset", "-", "CD offset sentinel only; extra=[offset]",
        build([E("a.txt", data=d, cd={"off": 0xFFFFFFFF, "ver": 45}, cd_extra=z64extra(0))], zip64={}))
    add("z64_extra_truncated", "P1", "CD usize sentinel, ZIP64 extra body only 4 bytes",
        build([E("a.txt", data=d, cd={"usize": 0xFFFFFFFF}, cd_extra=z64extra(raw=b"\x01\x02\x03\x04"))], zip64={}))
    add("z64_extra_overruns", "P1", "extra header length claims 0xFFF0 bytes",
        build([E("a.txt", data=d, cd={"usize": 0xFFFFFFFF}, cd_extra=u16(1) + u16(0xFFF0) + u64(len(d)))], zip64={}))
    # ZIP64 EOCD present while EOCD has NO sentinel, and the two disagree
    a = E("eocd32.txt", data=b"from 32-bit EOCD")
    b2 = E("eocd64.txt", data=b"from ZIP64 EOCD")
    arch = bytearray(build([a, b2]))
    # rebuild: EOCD -> CD with only entry a; ZIP64 EOCD -> CD with only entry b
    la = 30 + len(a.name) + len(a.payload)
    lb = 30 + len(b2.name) + len(b2.payload)
    cd_a = build([a])[la:la + 46 + len(a.name)]
    full = build([a, b2])
    cd_b = full[la + lb + 46 + len(a.name): la + lb + 2 * 46 + len(a.name) + len(b2.name)]
    body = full[:la + lb] + cd_a + cd_b
    cd_a_off, cd_b_off = la + lb, la + lb + len(cd_a)
    z64off = len(body)
    body += u32(0x06064B50) + u64(44) + u16(0x032D) + u16(45) + u32(0) + u32(0) + u64(1) + u64(1) + u64(len(cd_b)) + u64(cd_b_off)
    body += u32(0x07064B50) + u32(0) + u64(z64off) + u32(1)
    body += u32(0x06054B50) + u16(0) + u16(0) + u16(1) + u16(1) + u32(len(cd_a)) + u32(cd_a_off) + u16(0)
    add("z64_eocd_disagrees_no_sentinel", "P0",
        "EOCD (no 0xFFFF sentinels) -> CD{eocd32.txt}; ZIP64 EOCD+locator -> CD{eocd64.txt}", bytes(body))
    add("z64_sentinel_no_locator", "P2", "EOCD cd_off=0xFFFFFFFF but no ZIP64 locator",
        build([E("a.txt")], eocd={"cd_off": 0xFFFFFFFF}))
    add("z64_locator_off_overflow", "P0", "ZIP64 locator eocd64_offset=0x7FFFFFFFFFFFFFF0 (Int64 + 56 wraps)",
        build([E("a.txt")], zip64={"loc_off": 0x7FFFFFFFFFFFFFF0}))
    add("z64_locator_off_huge", "P1", "ZIP64 locator eocd64_offset=2^40 (out of file)",
        build([E("a.txt")], zip64={"loc_off": 1 << 40}))
    # cd_offset + cd_size wraps Int64 and still passes `> eocd_start`; low 32 bits point at real CD
    good2 = E("a.txt", data=b"B" * 300, method=0)
    lfh_len = 30 + 5 + 300
    cdsz = 46 + 5
    add("z64_cd_offset_size_wrap", "P0", "ZIP64 cd_offset=2^62+real, cd_size=2^62+real (sum wraps negative)",
        build([good2], zip64={"cd_off": (1 << 62) + lfh_len, "cd_size": (1 << 62) + cdsz}))
    big = E("b.bin", data=b"C" * 300, method=0, cd={"csize": 0x7FFFFF00, "usize": 0x7FFFFF00})
    add("z64_wrap_then_oob_size", "P0", "same wrap + CD csize=usize=0x7FFFFF00 (Store) -> slice past EOF",
        build([big], zip64={"cd_off": (1 << 62) + lfh_len, "cd_size": (1 << 62) + cdsz}))
    big2 = E("b.bin", data=b"C" * 300, method=0, cd={"csize": 0x7FFFFF00, "usize": 0x7FFFFF00},
             lfh={"csize": 0x7FFFFF00, "usize": 0x7FFFFF00})
    add("z64_wrap_then_oob_size_lfh", "P0", "same wrap + CD and LFH csize=usize=0x7FFFFF00 (Store) -> slice past EOF",
        build([big2], zip64={"cd_off": (1 << 62) + lfh_len, "cd_size": (1 << 62) + cdsz}))
    # ... and with the CRC forged (4 patch bytes in the CD comment) so the clamped slice verifies: Pion returns
    # "OK" with bytes beyond the entry (its own CD, ZIP64 EOCD, EOCD) and a length != declared size.
    add("z64_wrap_store_clamp_forged_crc", "P0",
        "wrap + Store csize=usize=0x0FFFFF00 + forged CRC: Bytes::slice clamps, read_entry returns OK with wrong length",
        forge_clamped_store())
    far = E("c.bin", data=b"D" * 300, method=0, offset_override=0x10000000)
    add("z64_wrap_then_far_lfh", "P0", "same wrap + LFH offset 0x10000000 (beyond EOF, below wrapped cd_offset)",
        build([far], zip64={"cd_off": (1 << 62) + lfh_len, "cd_size": (1 << 62) + cdsz}))
    add("z64_entries_2pow32p1", "P2", "ZIP64 EOCD total_entries=2^32+1 (Int truncation to 1)",
        build([E("a.txt")], zip64={"n": (1 << 32) + 1}))
    add("z64_entries_neg_as_int", "P2", "ZIP64 EOCD total_entries=0x80000001 (Int truncation negative)",
        build([E("a.txt")], zip64={"n": 0x80000001}))
    add("z64_csize_huge_extra", "P1", "ZIP64 extra csize=0x7FFFFFFFFFFFFF00 (lh_off+30+csize wraps)",
        build([E("a.txt", data=d, cd={"csize": 0xFFFFFFFF}, cd_extra=z64extra(0x7FFFFFFFFFFFFF00))], zip64={}))
    add("z64_offset_huge_extra", "P1", "ZIP64 extra local_header_offset=2^40",
        build([E("a.txt", data=d, cd={"off": 0xFFFFFFFF}, cd_extra=z64extra(1 << 40))], zip64={}))
    # --- bombs / limits --------------------------------------------------------------------------
    zeros = b"\0" * (8 << 20)
    add("bomb_honest_8MiB", "-", "honest 8 MiB zeros (ratio ~1000)", build([E("z.bin", data=zeros)]))
    lie0 = E("z.bin", data=zeros)
    lie0.cd = {"usize": 0}
    lie0.lfh = {"usize": 0}
    add("bomb_lie_usize0", "-", "8 MiB zeros declared usize=0", build([lie0]))
    lie1 = E("z.bin", data=zeros)
    lie1.cd = {"usize": 1}
    lie1.lfh = {"usize": 1}
    add("bomb_lie_usize1", "-", "8 MiB zeros declared usize=1", build([lie1]))
    shared = E("s0.bin", data=b"\0" * (1 << 20))
    n_overlap = 64
    ents = [shared] + [E("s%d.bin" % i, data=b"\0" * (1 << 20), offset_override=0) for i in range(1, n_overlap)]
    # all CD entries point at the same LFH (offset 0); only one LFH is physically written
    blob = bytearray(build([shared]))
    one_lfh = bytes(blob[: 30 + len(shared.name) + len(shared.payload)])
    cd = b""
    for i, en in enumerate(ents):
        nm = b"s0.bin"  # same LFH name length
        cd += u32(0x02014B50) + u16(0x0314) + u16(20) + u16(0) + u16(8) + u16(0) + u16(0x21) + u32(shared.crc)
        cd += u32(len(shared.payload)) + u32(len(shared.data)) + u16(6) + u16(0) + u16(0) + u16(0) + u16(0)
        cd += u32(0) + u32(0) + ("s%02d.bn" % i).encode()[:6]
    arch = one_lfh + cd + u32(0x06054B50) + u16(0) + u16(0) + u16(n_overlap) + u16(n_overlap) + u32(len(cd)) + u32(len(one_lfh)) + u16(0)
    add("bomb_full_overlap_64", "P1", "64 CD entries share one LFH/payload (1 MiB zeros each)", arch)
    # partial overlap (stored): entry 2's LFH lives inside entry 1's stored payload
    inner_e = E("in.txt", data=b"inner", method=0)
    inner_lfh = build([inner_e])[: 30 + 6 + 5]
    outer_payload = b"pad!" + inner_lfh + b"tail"
    outer = E("out.txt", data=outer_payload, method=0)
    arch = bytearray(build([outer]))
    lo = 30 + 7 + len(outer_payload)
    cd_o = arch[lo: lo + 46 + 7]
    cd_i = (u32(0x02014B50) + u16(0x0314) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0x21) + u32(inner_e.crc)
            + u32(5) + u32(5) + u16(6) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(30 + 7 + 4) + b"in.txt")
    arch = bytes(arch[:lo]) + bytes(cd_o) + cd_i + u32(0x06054B50) + u16(0) + u16(0) + u16(2) + u16(2) + u32(len(cd_o) + len(cd_i)) + u32(lo) + u16(0)
    add("overlap_nested_lfh", "P1", "entry 2 LFH nested inside entry 1 stored payload", arch)
    # ratio limit bypass by many medium entries is policy; mixed store+deflate
    add("ratio_99_x12", "-", "12 entries at ~99:1 ratio, each 1 MiB (within default policy)",
        build([E("r%d" % i, data=(b"\0" * 1000 + bytes([i]) * 10) * 104) for i in range(12)]))
    # --- names -----------------------------------------------------------------------------------
    add("name_invalid_utf8_flag", "P2", "bit 11 set, name bytes invalid UTF-8 (C0 AF)",
        build([E(b"a\xc0\xafb", flags=0x800)]))
    add("name_cp437", "P2", "bit 11 clear, CP437 name byte 0x81",
        build([E(b"\x81ber.txt")]))
    add("name_dup", "P1", "two entries named dup.txt",
        build([E("dup.txt", data=b"one"), E("dup.txt", data=b"two")]))
    add("name_nul", "P2", "name contains NUL: 'safe.txt\\0../../x'",
        build([E(b"safe.txt\0../../x")]))
    add("name_dotdot", "P2", "name '../evil' (reader must not reject; extract path sanitizer must)",
        build([E("../evil")]))
    add("encrypted_flag", "-", "bit 0 encrypted set", build([E("a.txt", flags=1)]))
    add("method_99", "-", "AES method 99", build([E("a.txt", method=99)]))
    add("empty_archive", "-", "22-byte empty EOCD only", build([]))
    return V


def section_vectors():
    V = vectors()
    recs = [v[3] for v in V]
    tools = ["pion_perm", "pion_def", "go", "rust", "py"]
    res = {t: run_batch(t, recs) for t in tools}
    diverge = 0
    print("%-32s %-4s | %-34s | %-34s | %-30s | %-30s | %-30s" % ("case", "sev", "pion(permissive)", "pion(default)", "go", "rust", "python"))
    for i, (cid, sev, desc, _) in enumerate(V):
        row = [summarize(res[t][i], 2) for t in tools]
        refs = [canon(res[t][i]) for t in ("go", "rust", "py")]
        pc = canon(res["pion_perm"][i])
        flag = ""
        if res["pion_perm"][i].startswith("CRASH") or res["pion_def"][i].startswith("CRASH"):
            flag = "  <== PION CRASH"
        elif pc not in refs:
            flag = "  <== differs from all refs"
        elif refs.count(pc) < 3:
            flag = "  <~ refs disagree"
        if flag:
            diverge += 1
        print("%-32s %-4s | %-34s | %-34s | %-30s | %-30s | %-30s%s" % (cid, sev, row[0][:34], row[1][:34], row[2][:30], row[3][:30], row[4][:30], flag))
    with open(OUT + "/vectors.txt", "w") as f:
        for i, (cid, sev, desc, _) in enumerate(V):
            f.write("## %s [%s] %s\n" % (cid, sev, desc))
            for t in tools:
                f.write("  %-9s %s\n" % (t, res[t][i][:400]))
    print("vectors: %d cases, %d flagged (full lines: %s/vectors.txt)" % (len(V), diverge, OUT))
    crashes = sum(1 for t in ("pion_perm", "pion_def") for l in res[t] if l.startswith("CRASH"))
    return crashes


# ----------------------------------------------------------------------------------------------
# fuzz


KNOWN_CRASHERS = ("z64_locator_off_overflow", "z64_wrap_then_far_lfh")


def seeds(clean):
    S = [v[3] for v in vectors() if len(v[3]) < 200000 and not (clean and v[0] in KNOWN_CRASHERS)]
    for f in sorted(os.listdir(OUT + "/w")) if os.path.isdir(OUT + "/w") else []:
        b = open(OUT + "/w/" + f, "rb").read()
        if len(b) < 300000:
            S.append(b)
    zb = io.BytesIO()
    with zipfile.ZipFile(zb, "w") as z:
        z.writestr("a.txt", b"python " * 50, zipfile.ZIP_DEFLATED)
        z.writestr("b/", b"")
        z.writestr("c.bin", bytes(range(256)) * 4, zipfile.ZIP_STORED)
    S.append(zb.getvalue())
    zb = io.BytesIO()
    with zipfile.ZipFile(zb, "w", allowZip64=True) as z:
        with z.open("s.txt", "w", force_zip64=True) as w:
            w.write(b"stream " * 100)
    S.append(zb.getvalue())
    return S


def mutate(r, b):
    b = bytearray(b)
    n = r.randrange(1, 6)
    for _ in range(n):
        k = r.randrange(9)
        if not b:
            b = bytearray(b"PK\x05\x06" + b"\0" * 18)
        p = r.randrange(len(b))
        if k == 0:
            b[p] = r.randrange(256)
        elif k == 1:
            b[p] ^= 1 << r.randrange(8)
        elif k == 2:  # interesting 16/32/64-bit values at signature-relative offsets
            v = r.choice([0, 1, 0xFF, 0xFFFF, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 0xFFFE, len(b), len(b) - 1])
            w = r.choice([2, 4, 8])
            b[p:p + w] = v.to_bytes(8, "little")[:w]
        elif k == 3:
            del b[p:p + r.randrange(1, 64)]
        elif k == 4:
            b[p:p] = bytes(r.randrange(256) for _ in range(r.randrange(1, 32)))
        elif k == 5:
            b = b[:p]
        elif k == 6:  # field hit relative to a real signature
            sigs = [i for i in range(len(b) - 3) if b[i] == 0x50 and b[i + 1] == 0x4B]
            if sigs:
                s = r.choice(sigs)
                o = s + r.randrange(4, 46)
                if o + 4 <= len(b):
                    b[o:o + r.choice([1, 2, 4])] = r.choice([b"\xff\xff\xff\xff", b"\0\0\0\0", b"\x08\0", b"\x01\0\0\x80"])[:4]
        elif k == 7:
            q = r.randrange(len(b))
            b[p:p + 8] = b[q:q + 8]
        else:
            b = bytearray(b"J" * r.randrange(1, 200)) + b
    return bytes(b)


def section_fuzz(n):
    rc = 0
    for clean in (True, False):
        tag = "clean" if clean else "all"
        print("-- fuzz pass '%s' seeds (%s the 2 hand-made crash vectors), %d cases" % (tag, "without" if clean else "with", n))
        rc += fuzz_pass(n, clean, tag)
    return rc


def fuzz_pass(n, clean, tag):
    r = random.Random(20261123)
    S = seeds(clean)
    cases = [mutate(r, r.choice(S)) for _ in range(n)]
    with open(OUT + "/fuzz_cases_%s.bin" % tag, "wb") as f:
        f.write(pack(cases))
    tools = ["pion_perm", "pion_def", "go", "rust", "py"]
    res = {}
    for t in tools:
        t0 = time.time()
        res[t] = run_batch(t, cases)
        print("  %-9s %.1fs" % (t, time.time() - t0))
    crash = {t: [i for i, l in enumerate(res[t]) if l.startswith("CRASH") or l.startswith("PANIC")] for t in tools}
    for t in tools:
        print("  %-9s crashes/panics: %d" % (t, len(crash[t])))
    # Acceptance-level divergence: Pion (permissive) extracts content that ALL of Go/Rust/Python reject,
    # or vice versa, or extracted content differs.
    acc_more, acc_less, content = [], [], []
    for i in range(n):
        pc = canon(res["pion_perm"][i])
        refs = [canon(res[t][i]) for t in ("go", "rust", "py")]
        p_ok = {(e[0], e[2], e[3]) for e in pc[1] if e[1] == "OK"}
        r_ok = [{(e[0], e[2], e[3]) for e in rc[1] if e[1] == "OK"} for rc in refs]
        if p_ok - set().union(*r_ok):
            acc_more.append(i)
        if all(rk - p_ok for rk in r_ok) and any(r_ok):
            acc_less.append(i)
    print("  pion extracts an (name,len,crc) no reference extracts: %d" % len(acc_more))
    print("  every reference extracts something pion refuses:     %d" % len(acc_less))
    with open(OUT + "/fuzz_report_%s.txt" % tag, "w") as f:
        for t in tools:
            for i in crash[t]:
                f.write("CRASH %s case %d: %s\n" % (t, i, res[t][i]))
        for tag, lst in (("MORE", acc_more), ("LESS", acc_less)):
            for i in lst[:200]:
                f.write("%s case %d\n" % (tag, i))
                for t in tools:
                    f.write("   %-9s %s\n" % (t, res[t][i][:300]))
    for t in ("pion_perm", "pion_def"):
        if crash[t]:
            i = crash[t][0]
            open(OUT + "/fuzz_crash_%s_%s_first.zip" % (tag, t), "wb").write(cases[i])
            kinds = {}
            for j in crash[t]:
                k = res[t][j].split("index")[0] + ("index<0" if "index -" in res[t][j] else "index>=len")
                kinds[k] = kinds.get(k, 0) + 1
            print("  %s crash classes: %s" % (t, kinds))
    return len(crash["pion_perm"]) + len(crash["pion_def"])


# ----------------------------------------------------------------------------------------------
# paths


PATHS = [
    "a/b/c.txt", "./a", "a//b", "a/./b", "a\\b", "a/b/", "", ".", "..", "../x", "a/..", "a/b/../..",
    "a/../b", "/abs", "\\abs", "C:\\x", "C:x", "\\\\server\\share\\x", "//server/share", "a\0b",
    "CON", "con.txt", "CON .txt", "CON.", "aux.tar.gz", "COM1", "COM0", "LPT9.log", "COM\u00b9", "LPT\u00b2.txt",
    "CONIN$", "CONOUT$", "foo.", "foo ", "foo. ", ".. ", "... ", "..\u0020/x", ". /x", "a/.. /b",
    "a\u2215..\u2215b", "\uff0e\uff0e/x", "a\u202e.txt", "a\x01b", "a\x1fb", "a\x7fb", "\u00e9", "e\u0301",
    "a:stream", "a/b:c", "nul", "NUL.txt", "prn", "clock$", "a/con/b", "x" * 300,
]


def section_paths():
    recs = [s.encode("utf-8") for s in PATHS]
    with open(OUT + "/paths.bin", "wb") as f:
        f.write(pack(recs))
    pion = subprocess.run([BIN + "/pion_audit", "paths", OUT + "/paths.bin"], capture_output=True).stdout.decode().splitlines()
    go = subprocess.run([BIN + "/go_audit", "paths", OUT + "/paths.bin"], capture_output=True).stdout.decode().splitlines()
    zb = io.BytesIO()
    with zipfile.ZipFile(zb, "w") as z:
        for i, s in enumerate(PATHS):
            zi = zipfile.ZipInfo(s if s else "__empty%d" % i)
            z.writestr(zi, b"")
    open(OUT + "/paths.zip", "wb").write(zb.getvalue())
    rust = subprocess.run([BIN + "/rust_audit", "paths", OUT + "/paths.zip"], capture_output=True).stdout.decode().splitlines()
    rust[0:0] = []
    print("%-26s %-28s %-6s %-6s" % ("input", "pion clean_extract_path", "goLoc", "rust"))
    weak = []
    for i, s in enumerate(PATHS):
        pv = pion[i] if i < len(pion) else "?"
        if pv.startswith("OK "):
            pv = "OK " + repr(bytes.fromhex(pv[3:]).decode("utf-8", "replace"))
        rv = rust[i] if i < len(rust) and s else "n/a"
        print("%-26s %-28s %-6s %-6s" % (repr(s)[:26], pv[:28], go[i] if i < len(go) else "?", rv))
        if pv.startswith("OK") and (go[i] == "ERR" or rv == "ERR"):
            weak.append(s)
    print("paths accepted by Pion but rejected by Go IsLocal or Rust enclosed_name: %r" % weak)


# ----------------------------------------------------------------------------------------------
# writer


def section_writer():
    os.makedirs(OUT + "/w", exist_ok=True)
    p = subprocess.run([BIN + "/pion_audit", "writecases", OUT + "/w"], capture_output=True, text=True)
    print(p.stdout.strip())
    for f in sorted(os.listdir(OUT + "/w")):
        path = OUT + "/w/" + f
        outs = {}
        for t in ("go", "rust"):
            outs[t] = subprocess.run([BIN + "/%s_audit" % t, "verify", path], capture_output=True, text=True).stdout
        try:
            z = zipfile.ZipFile(path)
            bad = z.testzip()
            outs["py"] = "OK n=%d testzip=%s" % (len(z.infolist()), bad)
        except Exception as e:  # noqa: BLE001
            outs["py"] = "ERR %r" % e
        print("== %s" % f)
        print("   go:   %s" % outs["go"].splitlines()[0])
        print("   rust: %s" % outs["rust"].splitlines()[0])
        print("   py:   %s" % outs["py"])
        if f.startswith("w06"):
            for t in ("go", "rust"):
                for ln in outs[t].splitlines()[1:]:
                    print("   %-5s %s" % (t, ln[:110]))
            for i in zipfile.ZipFile(path).infolist():
                print("   py    %s %s" % (i.filename, i.date_time))


# ----------------------------------------------------------------------------------------------
# 4-mode consistency (native debug/release, wasm32 debug/release)


def section_modes(audit_dir):
    variants = {
        "native_debug": ([], BIN + "/pion_audit_debug"),
        "native_release": (["--release"], BIN + "/pion_audit"),
        "wasm_debug": (["--target", "wasm32"], BIN + "/pion_audit_debug.wasm"),
        "wasm_release": (["--release", "--target", "wasm32"], BIN + "/pion_audit.wasm"),
    }
    for k, (flags, out) in variants.items():
        if not os.path.exists(out) or k in ("native_debug", "wasm_debug", "wasm_release"):
            subprocess.run(["pionc", "build"] + flags + ["-o", out, audit_dir], check=True)
    inputs = [("vectors", "vectors"), ("fuzz", "fuzz_cases_clean"), ("fuzz_all", "fuzz_cases_all")]
    V = [v[3] for v in vectors() if v[0] not in KNOWN_CRASHERS]
    with open(OUT + "/vectors.bin", "wb") as f:
        f.write(pack(V))
    for v in vectors():
        if v[0] in KNOWN_CRASHERS:
            path = OUT + "/crash_%s.zip" % v[0]
            open(path, "wb").write(v[3])
            row = []
            for k, (flags, out) in variants.items():
                cmd = (["node", WASM_RT, out] if out.endswith(".wasm") else [out]) + ["file", path, "default"]
                p = subprocess.run(cmd, capture_output=True, timeout=120)
                err = p.stderr.decode("utf-8", "replace").strip().splitlines()
                msg = next((l for l in err if "panic" in l), err[-1] if err else "")[:70]
                row.append("%s rc=%d %s" % (k, p.returncode, msg))
            print("  crash %-26s\n     %s" % (v[0], "\n     ".join(row)))
    import hashlib
    ok = True
    for label, name in inputs:
        path = OUT + "/%s.bin" % name
        if not os.path.exists(path):
            continue
        hashes = {}
        for k, (flags, out) in variants.items():
            for lm in ("permissive", "default"):
                if out.endswith(".wasm"):
                    cmd = ["node", WASM_RT, out, "batch", path, lm]
                else:
                    cmd = [out, "batch", path, lm]
                p = subprocess.run(cmd, capture_output=True, timeout=900)
                h = hashlib.sha256(p.stdout).hexdigest()[:16]
                hashes[(k, lm)] = ("crash" if p.returncode else "rc=0", h, len(p.stdout.splitlines()))
        for lm in ("permissive", "default"):
            row = {k: hashes[(k, lm)] for k in variants}
            same = len({v for v in row.values()}) == 1
            ok = ok and same
            print("  %-8s %-10s %s %s" % (label, lm, "IDENTICAL" if same else "DIFFER", row))
    return 0 if ok else 1


# ----------------------------------------------------------------------------------------------
# DoS


def hash_collide_names(pairs):
    """Seed-independent multicollisions for pion_str_hash (pion_rt.c) / hashBytes64 (pion_wasm_rt.mjs).
    Per 8-byte block: h ^= w; h *= K (odd); h ^= h >> 32.  Flipping bit 63 of w flips exactly bits 63 and 31
    of the block output for ANY h (x*K mod 2^64 maps x^2^63 -> x*K ^ 2^63), and the next block's w absorbs that
    difference.  So 2 choices per block pair -> 2^pairs equal-length names with identical hash for every seed.
    """
    base_a = b"zipHASH" + b"a"
    base_b = b"zipHASH" + b"b"
    names = []
    for m in range(1 << pairs):
        s = bytearray()
        for j in range(pairs):
            w1, w2 = bytearray(base_a), bytearray(base_b)
            w1[0] = 0x41 + (j % 26)
            if (m >> j) & 1:
                w1[7] ^= 0x80
                w2[7] ^= 0x80
                w2[3] ^= 0x80
            s += w1 + w2
        s += b".txt0000"
        names.append(bytes(s))
    return names


def store_archive(names, payload=b""):
    ents = [Entry(n, payload, 0) for n in names]
    if len(ents) >= 0xFFFF:
        return build(ents, zip64={}, eocd={"n": 0xFFFF, "n_disk": 0xFFFF})
    return build(ents)


def timed(cmd, timeout=600):
    t0 = time.time()
    try:
        p = subprocess.run(["/usr/bin/time", "-l"] + cmd, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return ("TIMEOUT", timeout, 0)
    dt = time.time() - t0
    rss = 0
    for ln in p.stderr.decode("utf-8", "replace").splitlines():
        if "maximum resident" in ln:
            rss = int(ln.split()[0]) / 1048576
    first = p.stdout.decode("utf-8", "replace").strip()[:48]
    if p.returncode != 0:
        first = "rc=%d %s" % (p.returncode, first)
    return (first, dt, rss)


def py_file(path):
    return ["python3", "-I", "-c",
            "import zipfile,sys,zlib\nz=zipfile.ZipFile(sys.argv[1])\nt=0\nfor i in z.infolist():\n try: t+=len(z.read(i))\n except Exception as e: pass\nprint('OK n=%d bytes=%d'%(len(z.infolist()),t))", path]


def section_dos():
    os.makedirs(OUT + "/dos", exist_ok=True)
    files = []
    # 1. HashDoS: seed-independent collisions vs control names of identical length
    for pairs in (12, 14, 15, 16):
        col = hash_collide_names(pairs)
        ctl = [b"%0*d" % (len(col[0]), i) for i in range(len(col))]
        for tag, nm in (("collide", col), ("control", ctl)):
            p = OUT + "/dos/hash_%s_%d.zip" % (tag, len(nm))
            open(p, "wb").write(store_archive(nm))
            files.append(p)
    # 2. 100k tiny entries: legacy writer (EOCD count = 100000 mod 65536, no ZIP64) and proper ZIP64
    ents100k = [Entry(b"f%06d" % i, b"", 0) for i in range(100000)]
    p = OUT + "/dos/entries_100000_legacy_u16count.zip"
    open(p, "wb").write(build(ents100k))
    files.append(p)
    p = OUT + "/dos/entries_100000_zip64.zip"
    open(p, "wb").write(build(ents100k, zip64={}, eocd={"n": 0xFFFF, "n_disk": 0xFFFF}))
    files.append(p)
    # 3. EOCD scan worst case: 64 KiB comment full of 'P' (Pion fast path) and full of PK\5\6 fragments
    body = build([Entry("a.txt", b"x", 0)])
    for tag, fillb in (("P", b"P"), ("PK56", b"PK\x05\x06")):
        c = (fillb * (65535 // len(fillb) + 1))[:65535]
        arch = body[:-2] + u16(65535) + c
        p = OUT + "/dos/eocd_scan_%s.zip" % tag
        open(p, "wb").write(arch)
        files.append(p)
    # no EOCD at all: 1 MiB of 'PK\5\6' garbage
    p = OUT + "/dos/no_eocd_1MiB.zip"
    open(p, "wb").write(b"PK\x05\x06" * (1 << 18))
    files.append(p)
    # 4. bombs at scale: 1 GiB zeros in one entry (honest), and lying usize
    zeros = b"\0" * (1 << 20)
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    payload = b"".join(c.compress(zeros) for _ in range(256)) + c.flush()
    crc = 0
    for _ in range(256):
        crc = zlib.crc32(zeros, crc)
    for tag, us in (("honest_256MiB", 1 << 28), ("lie_usize_1", 1)):
        e = Entry("bomb.bin", b"", 8)
        e.payload, e.crc = payload, crc
        e.lfh = {"usize": us}
        e.cd = {"usize": us}
        p = OUT + "/dos/bomb_%s.zip" % tag
        open(p, "wb").write(build([e]))
        files.append(p)
    # 5. huge extra fields / comments on 20k entries
    ents = [Entry("e%05d" % i, b"", 0, cd_extra=u16(0xCAFE) + u16(60000) + b"\0" * 60000) for i in range(300)]
    p = OUT + "/dos/extra_60k_x300.zip"
    open(p, "wb").write(build(ents))
    files.append(p)
    print("%-28s | %-48s | %-48s | %-48s | %-48s" % ("input", "pion(default)", "go", "rust", "python"))
    for p in files:
        row = [timed([BIN + "/pion_audit", "file", p, "default"])]
        row.append(timed([BIN + "/go_audit", "file", p]))
        row.append(timed([BIN + "/rust_audit", "file", p]))
        row.append(timed(py_file(p)))
        if "hash_" in p and ("16384" in p):
            w = timed(["node", WASM_RT, BIN + "/pion_audit.wasm", "file", p, "default"])
            print("%-28s | wasm32 release (node): %s %.2fs" % (os.path.basename(p)[:28], w[0][:26], w[1]))
        print("%-28s | %s" % (os.path.basename(p)[:28], " | ".join("%-26s %6.2fs %6.0fMiB" % (r[0][:26], r[1], r[2]) for r in row)))


def main():
    os.makedirs(OUT, exist_ok=True)
    sec = sys.argv[1] if len(sys.argv) > 1 else "vectors"
    n = int(os.environ.get("FUZZ_N", "6000"))
    if sec == "vectors":
        return 1 if section_vectors() else 0
    if sec == "fuzz":
        return 1 if section_fuzz(n) else 0
    if sec == "paths":
        section_paths()
        return 0
    if sec == "writer":
        section_writer()
        return 0
    if sec == "modes":
        return section_modes(os.path.dirname(os.path.abspath(__file__)))
    if sec == "dos":
        section_dos()
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
