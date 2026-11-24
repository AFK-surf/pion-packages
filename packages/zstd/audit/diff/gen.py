#!/usr/bin/env python3
"""RT-zstd corpus generator. usage: gen.py <out_dir> <fuzz_n> [<oracle_bin>]

Writes containers (u32 LE length + bytes records) and a JSON index per group into <out_dir>:
  raw.bin        raw inputs (edge sizes, text, binary, CJK, repetitive, random, 128 KiB +- 1, 256 KiB, 1 MiB)
  valid.bin      the raw inputs compressed by the official zstd CLI (levels --fast=5..-19, --ultra -20..-22, --long,
                 small windows, every strategy, --no-check / --no-content-size, streamed from stdin), by libzstd
                 (bulk) and by ruzstd, plus multi-frame / skippable concatenations; `want` = the raw input
  crafted.bin    hand-built adversarial frames (zmodel writer), `want` = ok:<content> / err from the RFC text
  fuzz.bin       <fuzz_n> mutations of small valid frames (bit flips, byte sets, truncation, splicing, insertion,
                 header field rewrites) and random bytes behind a magic number
Each index line: {"name", "group", "want": "ok"|"err"|null, "fnv", "len", "model": "OK <len> <fnv>"|"ERR <kind>",
"feat": [...], "limits": [4 ints] | null}.
"""
import json
import os
import random
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import zmodel as Z  # noqa: E402

OUT = sys.argv[1]
FUZZ_N = int(sys.argv[2])
ORACLE = sys.argv[3] if len(sys.argv) > 3 else None
os.makedirs(OUT, exist_ok=True)
TMP = os.path.join(OUT, "tmp")
os.makedirs(TMP, exist_ok=True)


def model_line(data, limits=None):
    feat = set()
    kw = {}
    if limits:
        kw = dict(max_out=limits[1], max_window=limits[2], max_frames=limits[3])
    try:
        if limits and len(data) > limits[0]:
            raise Z.ZErr("LimitExceeded", "input")
        o = Z.decode(data, feat=feat, **kw)
        return "OK %d %016x" % (len(o), Z.fnv64(o)), sorted(feat), o
    except Z.ZErr as e:
        return "ERR " + e.kind, sorted(feat), None


class Group:
    def __init__(self, name):
        self.name, self.recs, self.idx = name, [], []

    def add(self, name, data, want=None, content=None, limits=None, model=True):
        if model and self.name == "valid" and content is not None and len(content) > 140000:
            model = False  # the pure-Python model is slow: large valid inputs are checked by libzstd / ruzstd
        rec = {"name": name, "group": self.name, "want": want, "limits": limits}
        if content is not None:
            rec["len"], rec["fnv"] = len(content), "%016x" % Z.fnv64(content)
        if model:
            rec["model"], rec["feat"], out = model_line(data, limits)
            if content is None and want == "ok" and out is not None:
                rec["len"], rec["fnv"] = len(out), "%016x" % Z.fnv64(out)
        self.recs.append(bytes(data))
        self.idx.append(rec)

    def write(self):
        with open(os.path.join(OUT, self.name + ".bin"), "wb") as f:
            for r in self.recs:
                f.write(len(r).to_bytes(4, "little") + r)
        with open(os.path.join(OUT, self.name + ".json"), "w") as f:
            for r in self.idx:
                f.write(json.dumps(r) + "\n")
        return len(self.recs)


def container(recs):
    return b"".join(len(r).to_bytes(4, "little") + r for r in recs)


def records(blob):
    out, p = [], 0
    while p + 4 <= len(blob):
        n = int.from_bytes(blob[p:p + 4], "little")
        out.append(blob[p + 4:p + 4 + n])
        p += 4 + n
    return out


# ------------------------------------------------------------------ raw inputs
R = random.Random(8878)


def text(n, seed):
    r = random.Random(seed)
    words = ("zstd frame block literal sequence offset window huffman entropy table state stream checksum "
             "the of and a to in is that for it as with was on be by this an are or from at which").split()
    out = bytearray()
    while len(out) < n:
        out += r.choice(words).encode() + (b"\n" if r.random() < 0.08 else b" ")
    return bytes(out[:n])


def html(n, seed):
    r = random.Random(seed)
    out = bytearray()
    i = 0
    while len(out) < n:
        out += (b'<div class="row r%d"><span id="s%d">{"k":%d,"v":"%s"}</span></div>\n'
                % (i % 7, i, r.randrange(1000), b"x" * r.randrange(20)))
        i += 1
    return bytes(out[:n])


def binlog(n, seed):
    r = random.Random(seed)
    out = bytearray()
    t = 1700000000
    while len(out) < n:
        t += r.randrange(5)
        out += t.to_bytes(8, "little") + r.randrange(16).to_bytes(2, "little") + bytes([r.randrange(4)] * 6)
    return bytes(out[:n])


def rnd(n, seed):
    return random.Random(seed).randbytes(n) if hasattr(random.Random, "randbytes") else bytes(
        random.Random(seed).getrandbits(8) for _ in range(n))


def cjk(n):
    s = ("压缩算法标准帧格式熵编码霍夫曼有限状态熵窗口校验和" * 1000).encode("utf-8")
    return (s * (n // len(s) + 1))[:n]


RAW = {}
for n in [0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 31, 32, 33, 47, 48, 63, 64, 100, 127, 128, 255, 256, 257, 511, 512, 1000,
          1023, 1024]:
    RAW["text_%d" % n] = text(n, n)
for n in [1, 3, 17, 255, 256, 1024]:
    RAW["rand_%d" % n] = rnd(n, n)
RAW["zero_1024"] = bytes(1024)
RAW["ab_4096"] = b"ab" * 2048
RAW["period7_70000"] = (b"abcdefg" * 10001)[:70000]
RAW["text_131071"] = text(131071, 1)
RAW["text_131072"] = text(131072, 2)
RAW["text_131073"] = text(131073, 3)
RAW["html_262144"] = html(262144, 4)
RAW["binlog_262144"] = binlog(262144, 5)
RAW["cjk_65536"] = cjk(65536)
RAW["rand_131072"] = rnd(131072, 6)
RAW["mixed_300000"] = text(100000, 7) + rnd(100000, 8) + bytes(100000)
RAW["html_1048576"] = html(1048576, 9)
RAW["binlog_1048576"] = binlog(1048576, 10)
RAW["rle_200000"] = b"\x5a" * 200000
for name, d in RAW.items():
    with open(os.path.join(TMP, name), "wb") as f:
        f.write(d)
raw = Group("raw")
for name, d in RAW.items():
    raw.add(name, d, content=d, model=False)

# ------------------------------------------------------------------ valid: official encoders
valid = Group("valid")
SMALL = [k for k, v in RAW.items() if len(v) <= 4096]
BIG = [k for k, v in RAW.items() if len(v) > 4096]


def zstd_cli(args, name, stdin=False):
    src = os.path.join(TMP, name)
    if stdin:
        with open(src, "rb") as f:
            return subprocess.run(["zstd", "-q", "-c"] + args, stdin=f, capture_output=True, check=True).stdout
    return subprocess.run(["zstd", "-q", "-c"] + args + [src], capture_output=True, check=True).stdout


LEVELS_SMALL = ["--fast=5", "--fast=1", "-1", "-2", "-3", "-5", "-7", "-9", "-12", "-15", "-17", "-19"]
for name in SMALL:
    for lv in LEVELS_SMALL:
        valid.add("cli%s_%s" % (lv, name), zstd_cli([lv], name), "ok", RAW[name])
    valid.add("cli-19-nocheck-nofcs_%s" % name, zstd_cli(["-19", "--no-check"], name, stdin=True), "ok", RAW[name])
LEVELS_BIG = ["--fast=3", "-1", "-3", "-6", "-9", "-13", "-16", "-19"]
for name in BIG:
    for lv in LEVELS_BIG:
        valid.add("cli%s_%s" % (lv, name), zstd_cli([lv], name), "ok", RAW[name])
    for extra in (["--ultra", "-20"], ["--ultra", "-22"], ["--long=24", "-3"], ["--single-thread", "-8"],
                  ["-3", "--no-check"], ["-19", "--zstd=wlog=10"], ["-3", "--zstd=wlog=11,hlog=6"],
                  ["-1", "--zstd=strategy=1"], ["-5", "--zstd=strategy=3"], ["-9", "--zstd=strategy=6"],
                  ["-19", "--zstd=strategy=9,wlog=17"], ["-T2", "-B262144", "-3"]):
        valid.add("cli%s_%s" % ("".join(extra), name), zstd_cli(extra, name), "ok", RAW[name])
    valid.add("cli-3-stdin_%s" % name, zstd_cli(["-3"], name, stdin=True), "ok", RAW[name])
# streamed frames whose window exceeds the default 8 MiB limit: valid zstd, Pion needs raised limits
for name in ["html_262144"]:
    d = zstd_cli(["--ultra", "-22"], name, stdin=True)
    valid.add("cli-ultra-22-stdin-128MiB-window_%s" % name, d, "ok", RAW[name], limits=[1 << 26, 1 << 26, 1 << 30, 1024])
    valid.add("cli-ultra-22-stdin-128MiB-window-default-limits_%s" % name, d, "err", RAW[name])
    d = zstd_cli(["--long=27", "-3"], name, stdin=True)
    valid.add("cli-long27-stdin_%s" % name, d, "ok", RAW[name], limits=[1 << 26, 1 << 26, 1 << 30, 1024])
# multi-frame + skippable concatenations
a, b, c = RAW["text_1000"], RAW["rand_256"], RAW["text_131073"]
fa, fb, fc = zstd_cli(["-3"], "text_1000"), zstd_cli(["-19"], "rand_256"), zstd_cli(["-1"], "text_131073")
sk = Z.skippable(b"SKIP" * 3, 7)
valid.add("multi_abc", fa + fb + fc, "ok", a + b + c)
valid.add("multi_skip_front_mid_end", sk + fa + Z.skippable(b"", 15) + fb + sk, "ok", a + b)
valid.add("multi_skip_16_nibbles", b"".join(Z.skippable(bytes([i]) * i, i) for i in range(16)) + fa, "ok", a)
valid.add("multi_100_frames", fb * 100, "ok", b * 100)
# libzstd bulk + ruzstd encoder (via the oracle)
if ORACLE:
    names = list(RAW)
    inp = os.path.join(TMP, "raw.bin")
    with open(inp, "wb") as f:
        f.write(container([RAW[k] for k in names]))
    for enc, lvls in (("zstd", [-5, 1, 3, 7, 12, 19, 22]), ("ruzstd", [0, 1])):
        for lv in lvls:
            o = os.path.join(TMP, "o.bin")
            r = subprocess.run([ORACLE, "enc", enc, str(lv), inp, o], capture_output=True)
            if r.returncode != 0:
                print("  note: oracle enc %s %d failed: %s" % (enc, lv, r.stderr.decode()[-200:]), file=sys.stderr)
                continue
            for k, rec in zip(names, records(open(o, "rb").read())):
                if rec:
                    valid.add("%s%d_%s" % (enc, lv, k), rec, "ok", RAW[k])

# ------------------------------------------------------------------ crafted adversarial frames
cr = Group("crafted")
F, H = Z.frame, Z.frame_header
raw_b, rle_b, cmp_b, skip = Z.raw_block, Z.rle_block, Z.cmp_block, Z.skippable


def ok(name, data, content, limits=None):
    cr.add(name, data, "ok", content, limits)


def err(name, data, limits=None):
    cr.add(name, data, "err", None, limits)


def info(name, data, limits=None):
    """RFC leaves it open (or decoders legitimately differ): no expectation, all decoders are compared."""
    cr.add(name, data, None, None, limits)


T = text(5000, 42)
f_ok = F([raw_b(b"hello")], fcs=5, single=True)
# --- dimension 1: frames
err("F01_empty_input", b"")
err("F02_magic_only", f_ok[:4])
ok("F03_skippable_only_empty", skip(b""), b"")
ok("F04_skippable_16_consecutive", b"".join(skip(b"x" * i, i) for i in range(16)), b"")
ok("F05_skippable_around_frames", skip(b"a") + f_ok + skip(b"bb", 3) + f_ok + skip(b"", 15), b"hellohello")
err("F06_skippable_len_past_end", skip(b"abc", 0, size=4))
err("F07_skippable_len_ffffffff", skip(b"abc", 0, size=0xFFFFFFFF))
err("F08_skippable_size_truncated", skip(b"")[:6])
err("F09a_magic_184D2A4F", (0x184D2A4F).to_bytes(4, "little") + (0).to_bytes(4, "little"))
err("F09b_magic_184D2A60", (0x184D2A60).to_bytes(4, "little") + (0).to_bytes(4, "little"))
err("F09c_magic_FD2FB527", (0xFD2FB527).to_bytes(4, "little") + f_ok[4:])
err("F10a_trailing_1_byte", f_ok + b"\x00")
err("F10b_trailing_3_bytes", f_ok + b"\x28\xb5\x2f")
err("F10c_trailing_bad_magic", f_ok + b"\x00\x00\x00\x00")
err("F11_fhd_reserved_bit", F([raw_b(b"hello")], fcs=5, single=True, reserved=True))
ok("F12_fhd_unused_bit_ignored", F([raw_b(b"hello")], fcs=5, single=True, unused=True), b"hello")
for n in (0, 1, 255):
    ok("F13a_fcs1_single_%d" % n, F([raw_b(T[:n])], fcs=n, single=True), T[:n])
for n in (256, 257, 4000):
    ok("F13b_fcs2_plus256_single_%d" % n, F([raw_b(T[:n])], fcs=n, single=True), T[:n])
X = (T * 14)[:65791]
ok("F13c_fcs2_plus256_max_65791", F([raw_b(X)], fcs=65791, single=True), X)
ok("F13d_fcs4_single", F([raw_b(T[:300])], fcs=300, single=True, fcs_flag=2), T[:300])
ok("F13e_fcs8_single", F([raw_b(T[:300])], fcs=300, single=True, fcs_flag=3), T[:300])
ok("F13f_fcs8_nonsingle_window", F([raw_b(T[:300])], fcs=300, fcs_flag=3, window_log=10), T[:300])
ok("F14_fcs2_nonsingle", F([raw_b(T[:300])], fcs=300, window_log=10), T[:300])
for d, nm in ((-1, "minus1"), (1, "plus1")):
    err("F15a_fcs_%s" % nm, F([raw_b(T[:300])], fcs=300 + d, window_log=10))
err("F15b_fcs0_but_1_byte", F([raw_b(b"x")], fcs=0, single=True))
err("F15c_fcs5_but_empty", F([raw_b(b"")], fcs=5, window_log=10, fcs_flag=2))
err("F15d_fcs1byte_single_mismatch", F([raw_b(b"hell")], fcs=5, single=True))
ok("F16_no_fcs_window", F([raw_b(T[:1000])], window_log=10), T[:1000])
for did, fl in ((0, 1), (0, 2), (0, 3)):
    ok("F18a_dictid0_flag%d" % fl, F([raw_b(b"hello")], fcs=5, single=True, did=did, did_flag=fl), b"hello")
for did, fl in ((1, 1), (0xFFFF, 2), (0xFFFFFFFF, 3), (32768, 3)):
    err("F18b_dictid_%x_flag%d" % (did, fl), F([raw_b(b"hello")], fcs=5, single=True, did=did, did_flag=fl))
ok("F19a_window_1KiB_block_1024", F([raw_b(T[:1024])], wd=0x00), T[:1024])
err("F19b_window_1KiB_block_1025", F([raw_b(T[:1025])], wd=0x00))
ok("F19c_window_mantissa7_1920", F([raw_b(T[:1920])], wd=0x07), T[:1920])
err("F19d_window_mantissa7_1921", F([raw_b(T[:1921])], wd=0x07))
err("F20a_window_9MiB_default_limit", F([raw_b(b"x")], wd=(13 << 3) | 1))
ok("F20b_window_8MiB_exact", F([raw_b(b"x")], wd=13 << 3), b"x")
err("F20c_window_exp31", F([raw_b(b"x")], wd=0xF8))
err("F20d_window_exp31_mantissa7", F([raw_b(b"x")], wd=0xFF))
err("F21_single_fcs_9MiB_default_limit", H(fcs=9 << 20, single=True) + raw_b(b"x"))
ok("F22_single_fcs0_empty_raw", F([raw_b(b"")], fcs=0, single=True), b"")
err("F23_single_fcs0_raw_1", F([raw_b(b"x")], fcs=0, single=True))
ok("F24a_checksum_ok", F([raw_b(T[:777])], fcs=777, single=True, checksum=True, content=T[:777]), T[:777])
fb_ = bytearray(F([raw_b(T[:777])], fcs=777, single=True, checksum=True, content=T[:777]))
for bit in (0, 1, 7):
    x = bytearray(fb_)
    x[-1] ^= 1 << bit
    err("F24b_checksum_bitflip_last_byte_bit%d" % bit, bytes(x))
for k in range(4):
    x = bytearray(fb_)
    x[-4 + k] ^= 0x80
    err("F24c_checksum_byte%d_bit7" % k, bytes(x))
for pos in (12, 100, 776):
    x = bytearray(fb_)
    x[pos] ^= 0x01
    err("F24d_payload_bitflip_%d" % pos, bytes(x))
for k in (1, 2, 3, 4):
    err("F24e_checksum_truncated_%d" % k, bytes(fb_[:-k]))
ok("F25_two_frames_two_checksums",
   F([raw_b(b"one")], fcs=3, single=True, checksum=True, content=b"one") +
   F([raw_b(b"two!")], fcs=4, single=True, checksum=True, content=b"two!"), b"onetwo!")
full = F([raw_b(b"hello")], fcs=5, single=True, checksum=True, content=b"hello")
for cut in range(1, len(full)):
    err("F26_truncated_at_%02d" % cut, full[:cut])
err("F27a_fcs_100GB_tiny_body", H(fcs=100 << 30, window_log=20, fcs_flag=3) + raw_b(b"x"))
err("F27b_fcs_u64max", H(fcs=(1 << 64) - 1, window_log=20, fcs_flag=3) + raw_b(b"x"))
err("F27c_fcs_60MiB_truncated", H(fcs=60 << 20, window_log=20, fcs_flag=2) + raw_b(b"x", last=False))
err("F28_no_last_block", H(window_log=10) + raw_b(b"abc", last=False))
ok("F29_fcs8_value_lt_2_32", F([raw_b(b"x")], fcs=1, single=True, fcs_flag=3), b"x")

# --- dimension 2: blocks
err("B01_block_type_3", F([Z.block(3, b"abc")], window_log=10))
err("B01b_block_type_3_size0", F([Z.block(3, b"")], window_log=10))
big = text(131073, 77)
ok("B02a_raw_128KiB", F([raw_b(big[:131072])], window_log=20), big[:131072])
err("B02b_raw_128KiB_plus1", F([raw_b(big)], window_log=20))
err("B03_raw_truncated", F([raw_b(b"abcdef")], window_log=10)[:-2])
ok("B04a_rle_128KiB", F([rle_b(0x41, 131072)], window_log=20), b"A" * 131072)
err("B04b_rle_128KiB_plus1", F([rle_b(0x41, 131073)], window_log=20))
err("B04c_rle_missing_byte", F([rle_b(0x41, 10)], window_log=10)[:-1])
ok("B05_rle_size0", F([rle_b(0x41, 0)], window_log=10), b"")
err("B06_compressed_size0", F([cmp_b(b"")], window_log=10))
err("B07_compressed_gt_block_max", F([cmp_b(Z.lits_raw(T[:1030]) + b"\x00")], wd=0x00))
err("B08_trailing_after_nseq0", F([cmp_b(Z.lits_raw(b"abc") + b"\x00" + b"\x00")], window_log=10))
ok("B09_empty_raw_then_raw", F([raw_b(b"", last=False), raw_b(b"xy")], window_log=10), b"xy")
ok("B10_rle_single_segment_fcs", F([rle_b(0x30, 100)], fcs=100, single=True), b"0" * 100)
err("B11_rle_exceeds_single_segment_window", F([rle_b(0x30, 101)], fcs=100, single=True))

# --- dimension 2: literals
ok("L01a_raw_sf0", F([cmp_b(Z.lits_raw(b"abc", 0) + b"\x00")], window_log=10), b"abc")
ok("L01b_raw_sf2_alias", F([cmp_b(Z.lits_raw(b"abc", 2) + b"\x00")], window_log=10), b"abc")
ok("L01c_raw_sf1", F([cmp_b(Z.lits_raw(T[:900], 1) + b"\x00")], window_log=10), T[:900])
ok("L01d_raw_sf3", F([cmp_b(Z.lits_raw(T[:900], 3) + b"\x00")], window_log=10), T[:900])
ok("L01e_raw_sf3_100KiB", F([cmp_b(Z.lits_raw(big[:100000], 3) + b"\x00")], window_log=17), big[:100000])
ok("L02a_rle_sf0", F([cmp_b(Z.lits_rle(0x41, 31, 0) + b"\x00")], window_log=10), b"A" * 31)
ok("L02b_rle_sf1", F([cmp_b(Z.lits_rle(0x41, 4000, 1) + b"\x00")], window_log=12), b"A" * 4000)
ok("L02c_rle_sf3", F([cmp_b(Z.lits_rle(0x41, 100000, 3) + b"\x00")], window_log=17), b"A" * 100000)
err("L03a_raw_lits_gt_block_max", F([cmp_b(Z.lits_raw(T[:1025], 1) + b"\x00")], wd=0x00))
err("L03b_rle_lits_gt_block_max", F([cmp_b(Z.lits_rle(0x41, 1025, 1) + b"\x00")], wd=0x00))
err("L03c_raw_lits_truncated", F([cmp_b(Z.lits_raw(T[:100], 1)[:-5])], window_log=10))
err("L03d_rle_lits_missing_byte", F([cmp_b(Z.lits_rle(0x41, 100, 1)[:-1])], window_log=10))
HT = text(3000, 5)
lit1, h1 = Z.lits_huff(HT[:900])
ok("L04_huff_1stream_direct", F([cmp_b(lit1 + b"\x00")], window_log=12), HT[:900])
lit4, h4 = Z.lits_huff(HT[:2000], four=True)
ok("L05_huff_4stream_direct", F([cmp_b(lit4 + b"\x00")], window_log=12), HT[:2000])
wide = bytes(range(256)) * 2 + HT[:400]
litf1, hf = Z.lits_huff(wide, fse_weights=True)
ok("L06a_huff_1stream_fse_weights_256sym", F([cmp_b(litf1 + b"\x00")], window_log=12), wide)
wide = bytes(range(256)) * 4 + HT[:1000]
litf4, _ = Z.lits_huff(wide, four=True, fse_weights=True)
ok("L06b_huff_4stream_fse_weights", F([cmp_b(litf4 + b"\x00")], window_log=12), wide)
litf5, _ = Z.lits_huff(HT[:2000], four=True, fse_weights=True, sf=3)
ok("L06c_huff_4stream_5byte_header", F([cmp_b(litf5 + b"\x00")], window_log=12), HT[:2000])
tl, _ = Z.lits_huff(HT[:500], treeless_with=h1)
err("L07_treeless_first_block", F([cmp_b(tl + b"\x00")], window_log=12))
ok("L08_treeless_after_compressed", F([cmp_b(lit1 + b"\x00", last=False), cmp_b(tl + b"\x00")], window_log=12),
   HT[:900] + HT[:500])
err("L09_treeless_cross_frame", F([cmp_b(lit1 + b"\x00")], window_log=12) + F([cmp_b(tl + b"\x00")], window_log=12))
ok("L10_treeless_after_raw_lits_block",
   F([cmp_b(lit1 + b"\x00", last=False), cmp_b(Z.lits_raw(b"zz") + b"\x00", last=False), cmp_b(tl + b"\x00")],
     window_log=12), HT[:900] + b"zz" + HT[:500])
tl4, _ = Z.lits_huff(HT[:1200], treeless_with=h1, four=True)
ok("L10b_treeless_4stream", F([cmp_b(lit1 + b"\x00", last=False), cmp_b(tl4 + b"\x00")], window_log=12),
   HT[:900] + HT[:1200])


def direct_tree(ws):
    out = bytearray([127 + len(ws)])
    for i in range(0, len(ws), 2):
        out.append((ws[i] << 4) | (ws[i + 1] if i + 1 < len(ws) else 0))
    return bytes(out)


def huff_with_tree(tree, data=b"\x00\x01" * 20, regen=None, streams=None):
    body = tree + (streams if streams is not None else b"\x01")
    return F([cmp_b(Z.lits_cmp_hdr(len(data) if regen is None else regen, len(body), False) + body + b"\x00")],
             window_log=12)


err("L11a_weights_leftover_not_pow2", huff_with_tree(direct_tree([3, 1])))
err("L12a_weight_12", huff_with_tree(direct_tree([12, 1])))
err("L12b_max_bits_12", huff_with_tree(direct_tree([11, 11])))
err("L12c_weight_15", huff_with_tree(direct_tree([15])))
err("L14_all_weights_zero", huff_with_tree(direct_tree([0, 0, 0])))
d128 = bytes(range(129)) * 3
lw, _ = Z.lits_huff(d128, weights=[1] * 128 + [8])
ok("L13a_direct_128_weights", F([cmp_b(lw + b"\x00")], window_log=12), d128)
w255 = [1] * 256
d256 = bytes(range(256)) * 3
l255, _ = Z.lits_huff(d256, weights=w255, fse_weights=True)
ok("L13b_fse_255_weights_256_symbols", F([cmp_b(l255 + b"\x00")], window_log=12), d256)
# FSE-compressed weights that decode to more than 255 weights
err("L13c_fse_weights_300", huff_with_tree(Z.huff_header_fse([1] * 301)))
lj = bytearray(lit4)
hdr_len = {0: 3, 1: 3, 2: 4, 3: 5}[(lit4[0] >> 2) & 3]
tree_len = len(Z.huff_header_direct(h4.w))
j0 = hdr_len + tree_len
s1 = int.from_bytes(lj[j0:j0 + 2], "little")
lj[j0:j0 + 2] = (s1 + 4000).to_bytes(2, "little")
err("L15_4stream_jump_table_overflow", F([cmp_b(bytes(lj) + b"\x00")], window_log=12))
ls = bytearray(lit4)
seg = (2000 + 3) // 4
s1 = int.from_bytes(ls[j0:j0 + 2], "little")
ls[j0 + 6 + s1 - 1] = 0
err("L16a_4stream_stream1_no_sentinel", F([cmp_b(bytes(ls) + b"\x00")], window_log=12))
ls = bytearray(lit1)
ls[-1] = 0
err("L16b_1stream_last_byte_zero", F([cmp_b(bytes(ls) + b"\x00")], window_log=12))
st = h1.encode(HT[:900])
w_ = Z.BitW()
w_.put(0, 8)
w_.put_rev([(h1.code[b], h1.len[b]) for b in HT[:900]])
extra = w_.bytes()
lx, _ = Z.lits_huff(HT[:900], weights=h1.w, streams=extra)
err("L17_1stream_unconsumed_bits", F([cmp_b(lx + b"\x00")], window_log=12))
lu, _ = Z.lits_huff(HT[:900], weights=h1.w, regen=950, streams=st)
err("L18_1stream_underflow_regen_too_big", F([cmp_b(lu + b"\x00")], window_log=12))
lr, _ = Z.lits_huff(HT[:900], weights=h1.w, regen=899, streams=st)
err("L18b_1stream_regen_too_small", F([cmp_b(lr + b"\x00")], window_log=12))
lb, _ = Z.lits_huff(T[:1100], four=True)
err("L19_huff_regen_gt_block_max", F([cmp_b(lb + b"\x00")], wd=0x00))
lc = bytearray(lit1)
v = int.from_bytes(lc[:3], "little")
v = (v & ((1 << 14) - 1)) | (1023 << 14)
lc[:3] = v.to_bytes(3, "little")
err("L20_comp_size_past_block", F([cmp_b(bytes(lc) + b"\x00")], window_log=12))
for n in (1, 2):
    two = Z.Huff([1, 1])
    body = Z.huff_header_direct([1, 1]) + Z.huff_streams(two, b"\x00\x01\x00"[:n].ljust(n, b"\x00"), True,
                                                          jump=[1, 1, 1])
    err("L21a_4stream_regen_%d" % n, F([cmp_b(Z.lits_cmp_hdr(n, len(body), True) + body + b"\x00")], window_log=10))
for n in (3, 4, 5, 6):
    lt_, _ = Z.lits_huff(b"\x00\x01\x01\x00\x01\x00"[:n], weights=[1, 1], four=True)
    info("L21b_4stream_regen_%d" % n, F([cmp_b(lt_ + b"\x00")], window_log=10))
l2, _ = Z.lits_huff(b"ab" * 50, weights=[0] * 97 + [1, 1])
ok("L22_huff_max_bits_1", F([cmp_b(l2 + b"\x00")], window_log=10), b"ab" * 50)

# --- dimension 2: sequences
P = b"0123456789abcdefghijklmnopqrstuvwxyz"


def seqframe(blocks, **kw):
    kw.setdefault("window_log", 12)
    return F(blocks, **kw)


def sblock(lits, seqs, sw, last=True, **kw):
    return cmp_b(Z.lits_raw(lits) + sw.section(seqs, **kw), last=last)


sw = Z.SeqWriter()
ok("S01a_nseq_1byte", seqframe([sblock(P, [(10, 10 + 3, 20)], sw)]), P[:10] + (P[:10] * 2) + P[10:])
sw = Z.SeqWriter()
info("S01b_nseq_2byte_noncanonical_1", seqframe([sblock(P, [(10, 13, 20)], sw, nseq_bytes=2)]))
sw = Z.SeqWriter()
seqs = [(1, 1 + 3, 3)] * 200
ok("S01c_nseq_2byte_200", seqframe([sblock(b"a" * 200, seqs, sw)]), b"aaaa" * 200)
sw = Z.SeqWriter()
ok("S01d_nseq_3byte_32513", seqframe([cmp_b(Z.lits_raw(b"a") + sw.section([(1, 4, 3)] + [(0, 2, 3)] * 0x7F00))],
                                     window_log=17), b"a" * 97540)
err("S02_nseq0_trailing", seqframe([cmp_b(Z.lits_raw(b"abc") + b"\x00\x00")]))
sw = Z.SeqWriter()
for mb in (1, 2, 3):
    sw = Z.SeqWriter()
    err("S03_reserved_mode_bits_%d" % mb, seqframe([sblock(P, [(10, 13, 20)], sw, mode_byte=mb)]))
for k, sym in (("ll", 36), ("of", 32), ("ml", 53)):
    sw = Z.SeqWriter()
    body = Z.lits_raw(P) + bytes([1, {"ll": 0x40, "of": 0x10, "ml": 0x04}[k], sym]) + b"\x01"
    err("S04_rle_%s_symbol_%d" % (k, sym), seqframe([cmp_b(body)]))
for k, mode in (("ll", ("rep", "pre", "pre")), ("of", ("pre", "rep", "pre")), ("ml", ("pre", "pre", "rep"))):
    sw = Z.SeqWriter()
    sw.prev = {"ll": Z.Fse(Z.PRE_LL, 6), "of": Z.Fse(Z.PRE_OF, 5), "ml": Z.Fse(Z.PRE_ML, 6)}
    err("S05_repeat_%s_first_block" % k, seqframe([sblock(P, [(10, 13, 20)], sw, modes=mode)]))
sw = Z.SeqWriter()
b1 = sblock(P, [(10, 13, 20)], sw, last=False, modes=("rle", "rle", "rle"))
b2 = sblock(P, [(10, 13, 20)], sw, modes=("rep", "rep", "rep"))
ok("S06_repeat_after_rle", seqframe([b1, b2]), (P[:10] + P[:10] * 2 + P[10:]) * 2)
sw = Z.SeqWriter()
b1 = sblock(P, [(10, 13, 20)], sw, modes=("pre", "pre", "pre"))
b2 = sblock(P, [(10, 13, 20)], sw, modes=("rep", "rep", "rep"))
err("S07_repeat_cross_frame", seqframe([b1]) + seqframe([b2]))
sw = Z.SeqWriter()
b1 = sblock(P, [(10, 13, 20)], sw, last=False, modes=("pre", "rle", "pre"))
b0 = cmp_b(Z.lits_raw(b"xyz") + b"\x00", last=False)
b2 = sblock(P, [(10, 13, 20)], sw, modes=("rep", "rep", "rep"))
ok("S08_repeat_after_nseq0_block", seqframe([b1, b0, b2]), (P[:10] + P[:10] * 2 + P[10:]) + b"xyz" +
   (P[:10] + P[:10] * 2 + P[10:]))
for k, alog in (("ll", 9), ("of", 8), ("ml", 9)):
    sw = Z.SeqWriter()
    size = 1 << alog
    nrm = [0] * (Z.MAXSYM[k] + 1)
    codes = {"ll": 10, "of": 3, "ml": 17}
    nrm[codes[k]] = size // 2
    nrm[0 if codes[k] else 1] = size // 2
    modes = tuple("fse" if x == k else "pre" for x in ("ll", "of", "ml"))
    ok("S09a_fse_%s_alog_max_%d" % (k, alog),
       seqframe([sblock(P, [(10, 13, 20)], sw, modes=modes, fse_norm={k: (nrm, alog)})]), P[:10] + P[:10] * 2 + P[10:])
    w = Z.BitW()
    w.put(alog + 1 - 5, 4)
    w.put(0, 16)
    body = Z.lits_raw(P) + bytes([1, {"ll": 0x80, "of": 0x20, "ml": 0x08}[k]]) + w.bytes(False) + b"\x01\x01"
    err("S09b_fse_%s_alog_%d" % (k, alog + 1), seqframe([cmp_b(body)]))
# FSE description that ends (block end) before the probabilities sum to 1 << accuracy_log
body = Z.lits_raw(P) + bytes([1, 0x80, 0x04])
err("S10a_fse_ll_truncated_description", seqframe([cmp_b(body)]))
w = Z.BitW()
w.put(4, 4)
w.put(5, 9)
body = Z.lits_raw(P) + bytes([1, 0x80]) + w.bytes(False)
err("S10b_fse_ll_truncated_after_one_symbol", seqframe([cmp_b(body)]))
# symbol beyond OF max via zero repeats
w = Z.BitW()
w.put(0, 4)
w.put(1, 5)  # p=0
w.put(3, 2)
for _ in range(10):
    w.put(3, 2)
w.put(0, 2)
w.put(33, 6)
body = Z.lits_raw(P) + bytes([1, 0x20]) + w.bytes(False) + b"\x01\x01\x01"
err("S11_fse_of_symbol_beyond_31", seqframe([cmp_b(body)]))
sw = Z.SeqWriter()
err("S12a_offset_gt_output", seqframe([sblock(P, [(10, 11 + 3, 5)], sw)]))
sw = Z.SeqWriter()
pre = raw_b(T[:750], last=False) + raw_b(T[750:1500], last=False)
err("S12b_offset_gt_window_1KiB", F([pre, sblock(b"", [(0, 1400 + 3, 10)], sw)], wd=0x00))
sw = Z.SeqWriter()
ok("S12c_offset_eq_window_1KiB", F([pre, sblock(b"", [(0, 1024 + 3, 10)], sw)], wd=0x00),
   T[:1500] + (T[:1500] + b"")[1500 - 1024:1500 - 1024 + 10])
sw = Z.SeqWriter()
err("S12d_offset_window_plus1", F([pre, sblock(b"", [(0, 1025 + 3, 10)], sw)], wd=0x00))
sw = Z.SeqWriter()
ok("S13a_overlap_offset1", seqframe([sblock(b"x", [(1, 1 + 3, 1000)], sw)]), b"x" * 1001)
sw = Z.SeqWriter()
ok("S13b_overlap_offset2", seqframe([sblock(b"xy", [(2, 2 + 3, 999)], sw)]), (b"xy" * 600)[:1001])
sw = Z.SeqWriter()
ok("S13c_overlap_offset7_len100", seqframe([sblock(P[:7], [(7, 7 + 3, 100)], sw)]), (P[:7] * 20)[:107])
# repeat offsets: initial [1, 4, 8]
H16 = P[:16]
for ov, off in ((1, 1), (2, 4), (3, 8)):
    sw = Z.SeqWriter()
    out = bytearray(H16[:9])
    for _ in range(5):
        out.append(out[-off])
    ok("S14a_rep_ll_gt0_ov%d_offset%d" % (ov, off), seqframe([sblock(H16[:9], [(9, ov, 5)], sw)]), bytes(out))
for ov, off in ((1, 4), (2, 8)):
    sw = Z.SeqWriter()
    out = bytearray(H16)
    for _ in range(6):
        out.append(out[-off])
    ok("S14b_rep_ll0_ov%d_offset%d" % (ov, off), seqframe([raw_b(H16, last=False), sblock(b"", [(0, ov, 6)], sw)]),
       bytes(out))
sw = Z.SeqWriter()
err("S14c_rep_ll0_ov3_rep1_eq_1", seqframe([raw_b(H16, last=False), sblock(b"", [(0, 3, 6)], sw)]))
sw = Z.SeqWriter()
# rep1 = 5 then ll0 ov3 -> 4
out = bytearray(H16 + H16[:2])
for _ in range(4):
    out.append(out[-5])
o2 = bytearray(out)
for _ in range(4):
    o2.append(o2[-4])
ok("S14d_rep_ll0_ov3_rep1_minus1", seqframe([raw_b(H16, last=False),
                                             sblock(H16[:2], [(2, 5 + 3, 4), (0, 3, 4)], sw)]), bytes(o2))
# rep1==2 -> ll0 ov3 -> 1; then again -> 0 invalid
sw = Z.SeqWriter()
err("S14e_rep_ll0_ov3_twice_to_zero",
    seqframe([raw_b(H16, last=False), sblock(H16[:2], [(2, 2 + 3, 4), (0, 3, 4), (0, 3, 4)], sw)]))
# rep state across blocks: block1 sets rep1=5, block2 ll>0 ov1 -> 5
sw = Z.SeqWriter()
b1 = sblock(H16, [(16, 5 + 3, 4)], sw, last=False)
b2 = sblock(b"Z", [(1, 1, 4)], sw)
o = bytearray(H16)
for _ in range(4):
    o.append(o[-5])
o += b"Z"
for _ in range(4):
    o.append(o[-5])
ok("S15a_rep_persists_across_blocks", seqframe([b1, b2]), bytes(o))
# rep reset across frames: frame1 rep1=5, frame2 ll>0 ov1 must use 1
sw = Z.SeqWriter()
fr1 = seqframe([sblock(H16, [(16, 5 + 3, 4)], sw)])
sw = Z.SeqWriter()
fr2 = seqframe([sblock(b"Q", [(1, 1, 4)], sw)])
ok("S15b_rep_reset_across_frames", fr1 + fr2, bytes(o[:20]) + b"QQQQQ")
# raw block between compressed blocks keeps reps
sw = Z.SeqWriter()
b1 = sblock(H16, [(16, 5 + 3, 4)], sw, last=False)
b2 = raw_b(b"RAW", last=False)
b3 = sblock(b"Z", [(1, 1, 4)], sw)
o = bytearray(H16)
for _ in range(4):
    o.append(o[-5])
o += b"RAWZ"
for _ in range(4):
    o.append(o[-5])
ok("S15c_rep_survives_raw_block", seqframe([b1, b2, b3]), bytes(o))
sw = Z.SeqWriter()
err("S17_literal_length_overrun", seqframe([sblock(P[:5], [(6, 1, 3)], sw)]))
sw = Z.SeqWriter()
err("S18_match_exceeds_block_max", F([sblock(P[:10], [(10, 1, 1015)], sw)], wd=0x00))
sw = Z.SeqWriter()
ok("S18b_match_fills_block_max", F([sblock(P[:10], [(10, 1, 1014)], sw)], wd=0x00), P[:10] + P[9:10] * 1014)
sw = Z.SeqWriter()
err("S19_trailing_lits_exceed_block_max", F([sblock(T[:1000], [(10, 1, 30)], sw)], wd=0x00))
sw = Z.SeqWriter()
good = sblock(P, [(10, 13, 20), (5, 1, 7)], sw)
bad = bytearray(good)
bad[-1] = 0
err("S20a_seq_no_sentinel", seqframe([cmp_b(bytes(bad[3:]))]))
sw = Z.SeqWriter()
err("S20b_seq_unconsumed_bits", seqframe([sblock(P, [(10, 13, 20), (5, 1, 7)], sw, extra_bits=8)]))
sw = Z.SeqWriter()
err("S20c_seq_truncated_bits", seqframe([sblock(P, [(10, 13, 20), (5, 1, 7)], sw, drop_bits=3)]))
sw = Z.SeqWriter()
err("S20d_seq_trailing_byte", seqframe([sblock(P, [(10, 13, 20)], sw, tail=b"\x01")]))
sw = Z.SeqWriter()
b1 = raw_b(T[:3000], last=False)
ok("S22_match_into_previous_block", seqframe([b1, sblock(b"", [(0, 2500 + 3, 100)], sw)]),
   T[:3000] + T[500:600])
sw = Z.SeqWriter()
err("S23_offset_into_previous_frame", seqframe([raw_b(T[:100])]) + seqframe([sblock(b"ab", [(2, 50 + 3, 10)], sw)]))
sw = Z.SeqWriter()
err("S24_ml_131074", F([sblock(b"a", [(1, 1, 131074)], sw)], window_log=17))
sw = Z.SeqWriter()
err("S25_of_code_31", seqframe([sblock(P, [(10, (1 << 31) + 5, 4)], sw, modes=("pre", "rle", "pre"))]))
sw = Z.SeqWriter()
err("S25b_of_code_30_window", seqframe([sblock(P, [(10, (1 << 30) + 5, 4)], sw, modes=("pre", "rle", "pre"))]))
sw = Z.SeqWriter()
seq_mix = [(3, 9, 4), (0, 1, 5), (2, 2, 6), (0, 2, 3), (1, 3, 4), (0, 3, 8), (4, 20, 9)]
info("S26_predefined_mixed_reps", seqframe([raw_b(H16, last=False), sblock(P, seq_mix, sw)]))
# multi-block: RLE -> Predefined -> Repeat keeps the Predefined table
sw = Z.SeqWriter()
b1 = sblock(P, [(10, 13, 20)], sw, last=False, modes=("rle", "rle", "rle"))
b2 = sblock(P, [(10, 13, 20), (2, 1, 5)], sw, last=False, modes=("pre", "pre", "pre"))
b3 = sblock(P, [(3, 2, 6), (1, 1, 9)], sw, modes=("rep", "rep", "rep"))
info("S27_rle_pre_repeat_chain", seqframe([b1, b2, b3]))
# compressed block decompressing to more than declared but frame FCS mismatch
sw = Z.SeqWriter()
err("S28_compressed_fcs_mismatch", seqframe([sblock(P, [(10, 13, 20)], sw)], fcs=40, fcs_flag=2))
# limit variants
lim1k = [1 << 20, 1024, 1 << 23, 1024]
ok("X01_out_limit_exact_1024", F([rle_b(0x41, 1024)], window_log=12), b"A" * 1024, limits=lim1k)
err("X02_out_limit_1025", F([rle_b(0x41, 1025)], window_log=12), limits=lim1k)
err("X03_out_limit_fcs_1025", F([rle_b(0x41, 1025)], fcs=1025, window_log=12), limits=lim1k)
err("X04_frames_limit", f_ok * 3, limits=[1 << 20, 1 << 20, 1 << 23, 2])
ok("X05_frames_limit_exact", f_ok * 2, b"hello" * 2, limits=[1 << 20, 1 << 20, 1 << 23, 2])
err("X06_input_limit", f_ok, limits=[len(f_ok) - 1, 1 << 20, 1 << 23, 10])
ok("X07_window_limit_exact", F([raw_b(b"x")], wd=0x00), b"x", limits=[1 << 20, 1 << 20, 1024, 10])
err("X08_window_limit_1023", F([raw_b(b"x")], wd=0x00), limits=[1 << 20, 1 << 20, 1023, 10])
err("X09_negative_limit", f_ok, limits=[-1, 1 << 20, 1 << 23, 10])
err("X10_zero_output_limit", f_ok, limits=[1 << 20, 0, 1 << 23, 10])
ok("X11_zero_output_limit_empty_frame", F([raw_b(b"")], fcs=0, single=True), b"", limits=[1 << 20, 0, 0, 10])
err("X12_zero_frames_limit", f_ok, limits=[1 << 20, 1 << 20, 1 << 23, 0])
err("X13_skippable_counts_as_frame", skip(b"") + f_ok, limits=[1 << 20, 1 << 20, 1 << 23, 1])

# ------------------------------------------------------------------ fuzz
fz = Group("fuzz")
seeds = []
for k in ("text_100", "text_1000", "rand_255", "text_32", "ab_4096", "zero_1024", "text_512"):
    for lv in ("-1", "-3", "-19", "--fast=3"):
        for extra in ([], ["--no-check"]):
            seeds.append(zstd_cli([lv] + extra, k))
seeds += [r for r in cr.recs if 8 < len(r) < 6000]
FR = random.Random(1234)


def mutate(d):
    d = bytearray(d)
    op = FR.randrange(9)
    if op == 0 and d:
        for _ in range(FR.randrange(1, 4)):
            i = FR.randrange(len(d))
            d[i] ^= 1 << FR.randrange(8)
    elif op == 1 and d:
        for _ in range(FR.randrange(1, 4)):
            d[FR.randrange(len(d))] = FR.choice([0, 1, 0x7F, 0x80, 0xFF, FR.randrange(256)])
    elif op == 2 and len(d) > 1:
        d = d[:FR.randrange(1, len(d))]
    elif op == 3:
        i = FR.randrange(len(d) + 1)
        d[i:i] = bytes(FR.randrange(256) for _ in range(FR.randrange(1, 8)))
    elif op == 4 and len(d) > 4:
        i = FR.randrange(len(d))
        del d[i:i + FR.randrange(1, 8)]
    elif op == 5:
        o = FR.choice(seeds)
        i, j = FR.randrange(len(d) + 1), FR.randrange(len(o) + 1)
        d = d[:i] + o[j:]
    elif op == 6 and len(d) > 6:
        i = FR.randrange(4, min(len(d), 20))
        d[i] = FR.randrange(256)
    elif op == 7 and len(d) > 8:
        i = FR.randrange(len(d) - 2)
        v = FR.choice([0, 1, 0xFFFF, FR.randrange(1 << 16)])
        d[i:i + 2] = v.to_bytes(2, "little")
    else:
        d = bytearray((0xFD2FB528).to_bytes(4, "little")) + bytes(FR.randrange(256) for _ in range(FR.randrange(1, 64)))
    return bytes(d)


RG = random.Random(8878)


def rand_frame(rg):
    """A random *valid* frame built with the zmodel writer: random block types, literal types (raw / RLE /
    Huffman 1- and 4-stream with Direct or FSE weights / Treeless), sequence counts, symbol compression modes
    (Predefined / RLE / FSE_Compressed / Repeat) and offsets (new and all repeat codes, tracked like a decoder)."""
    wl = rg.randrange(10, 18)
    window = 1 << wl
    bmax = min(window, 1 << 17)
    out = bytearray()
    blocks = []
    sw = Z.SeqWriter()
    rep = [1, 4, 8]
    huf = None
    alpha = bytes(rg.sample(range(128 if rg.random() < 0.5 else 256), rg.randrange(2, 40)))
    for bi in range(rg.randrange(1, 5)):
        t = rg.random()
        if t < 0.15:
            d = bytes(rg.choice(alpha) for _ in range(rg.randrange(0, 300)))
            blocks.append(Z.raw_block(d, last=False))
            out += d
            continue
        if t < 0.25:
            n = rg.randrange(0, 500)
            b = rg.choice(alpha)
            blocks.append(Z.rle_block(b, n, last=False))
            out += bytes([b]) * n
            continue
        nl = rg.randrange(0, 600)
        lits = bytes(rg.choice(alpha) for _ in range(nl))
        lt = rg.random()
        try:
            if nl == 0 or lt < 0.2:
                lsec = Z.lits_raw(lits)
            elif lt < 0.3:
                lits = bytes([lits[0]]) * nl
                lsec = Z.lits_rle(lits[0], nl)
            elif lt < 0.45 and huf is not None and set(lits) <= set(huf.code):
                four = nl > 1023 or (nl >= 6 and rg.random() < 0.5)
                lsec, _ = Z.lits_huff(lits, treeless_with=huf, four=four)
            elif len(set(lits)) >= 2:
                four = nl > 1023 or (nl >= 6 and rg.random() < 0.5)
                lsec, huf = Z.lits_huff(lits, four=four, fse_weights=rg.random() < 0.5)
            else:
                lsec = Z.lits_raw(lits)
        except (AssertionError, ValueError, OverflowError):
            lsec = Z.lits_raw(lits)
        seqs = []
        lp = 0
        bout = 0
        hist = len(out)
        r = list(rep)
        for _ in range(rg.randrange(0, 25)):
            ll = rg.randrange(0, min(nl - lp, 40) + 1)
            avail = min(hist + ll, window)
            if avail < 1:
                break
            ml = rg.randrange(3, 40)
            if bout + ll + ml > bmax:
                break
            code = rg.random()
            if code < 0.5:
                off = rg.randrange(1, avail + 1)
                ov = off + 3
                nr = [off, r[0], r[1]]
            else:
                ov = rg.randrange(1, 4)
                idx = ov if ll == 0 else ov - 1
                if idx == 0:
                    off, nr = r[0], list(r)
                elif idx == 3:
                    off = r[0] - 1
                    nr = [off, r[0], r[1]]
                elif idx == 1:
                    off, nr = r[1], [r[1], r[0], r[2]]
                else:
                    off, nr = r[2], [r[2], r[0], r[1]]
                if not 1 <= off <= avail:
                    continue
            seqs.append((ll, ov, ml))
            r = nr
            lp += ll
            hist += ll + ml
            bout += ll + ml
        modes = []
        norms = {}
        codes = {"ll": [Z.code_of(l, Z.LL_BASE, Z.LL_BITS) for l, _, _ in seqs],
                 "of": [Z.hb(o) for _, o, _ in seqs], "ml": [Z.code_of(m, Z.ML_BASE, Z.ML_BITS) for _, _, m in seqs]}
        for k in ("ll", "of", "ml"):
            c = codes[k]
            m = rg.choice(["pre", "pre", "rle", "fse", "rep"])
            if m == "rle" and len(set(c)) != 1:
                m = "pre"
            if m == "rep":
                pt = sw.prev[k]
                try:
                    if pt is None:
                        raise ValueError
                    Z.chain(pt, c)
                except ValueError:
                    m = "pre"
            if m == "pre" and k == "of" and c and max(c) > 28:
                m = "fse"
            if m == "fse" and not c:
                m = "pre"
            if m == "fse":
                cnt = [0] * (max(c) + 2)
                for x in c:
                    cnt[x] += 1
                if sum(1 for x in cnt if x) < 2:
                    cnt[-1] = 1
                alog = rg.randrange(5, Z.MAXLOG[k] + 1)
                norms[k] = (Z.normalize(cnt, alog), alog)
            modes.append(m)
        try:
            body = lsec + sw.section(seqs, modes=tuple(modes), fse_norm=norms)
        except ValueError:
            return None
        blocks.append(Z.cmp_block(body, last=False))
        rep = r if seqs else rep
        # keep a byte-exact running output for the offset bounds: decode the partial frame with the model
        part = Z.frame_header(window_log=wl) + b"".join(blocks[:-1]) + Z.cmp_block(body)
        try:
            out = bytearray(Z.decode(part))
        except Z.ZErr:
            return None
    if not blocks:
        return None
    blocks[-1] = bytes([blocks[-1][0] | 1]) + blocks[-1][1:]
    content = bytes(out)
    chk = rg.random() < 0.5
    if rg.random() < 0.3 and len(content) >= 4096:
        return Z.frame(blocks, content=content, checksum=chk, fcs=len(content), single=True), content
    return Z.frame(blocks, content=content, checksum=chk, window_log=wl,
                   fcs=len(content) if rg.random() < 0.5 else None), content


RAND_N = max(FUZZ_N // 6, 1)
rand_ok = 0
for i in range(RAND_N):
    got = None
    while got is None:
        got = rand_frame(RG)
        if got is not None:
            try:
                if Z.decode(got[0]) != got[1]:
                    got = None
            except Z.ZErr:
                got = None
    fz.add("rand_%05d" % i, got[0], "ok", got[1])
    if 8 < len(got[0]) < 6000:
        seeds.append(got[0])
for i in range(FUZZ_N):
    d = FR.choice(seeds)
    for _ in range(FR.randrange(1, 4)):
        d = mutate(d)
    fz.add("fuzz_%05d" % i, d)

counts = {g.name: g.write() for g in (raw, valid, cr, fz)}
print("%(raw)d raw %(valid)d valid %(crafted)d crafted %(fuzz)d fuzz" % counts)
