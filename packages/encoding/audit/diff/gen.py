#!/usr/bin/env python3
"""Deterministic case corpus for the packages/encoding red-team audit (protocol: diff/oracle/src/main.rs).

  python3 -I gen.py <out_dir> [stream_n]

Writes one case file per group into <out_dir>/<group>.cases and prints the case count of each group.
Nothing here depends on Python's own codecs: every expectation comes from the encoding_rs oracle.
"""
import os
import random
import sys

ENCODINGS = [
    "UTF-8", "UTF-16LE", "UTF-16BE", "replacement", "x-user-defined", "GBK", "gb18030", "Big5", "EUC-JP",
    "ISO-2022-JP", "Shift_JIS", "EUC-KR", "IBM866", "ISO-8859-2", "ISO-8859-3", "ISO-8859-4", "ISO-8859-5",
    "ISO-8859-6", "ISO-8859-7", "ISO-8859-8", "ISO-8859-8-I", "ISO-8859-10", "ISO-8859-13", "ISO-8859-14",
    "ISO-8859-15", "ISO-8859-16", "KOI8-R", "KOI8-U", "macintosh", "windows-874", "windows-1250", "windows-1251",
    "windows-1252", "windows-1253", "windows-1254", "windows-1255", "windows-1256", "windows-1257",
    "windows-1258", "x-mac-cyrillic",
]
SINGLE = ENCODINGS[12:] + ["x-user-defined"]
DBCS = ["GBK", "gb18030", "Big5", "EUC-KR", "Shift_JIS", "EUC-JP"]
OPTS = ["nb", "fb", "ni", "fi"]
WS = [0x09, 0x0A, 0x0C, 0x0D, 0x20]


def hx(b):
    return bytes(b).hex() if len(b) else "-"


class W:
    def __init__(self, out, name):
        self.f = open(os.path.join(out, name + ".cases"), "w")
        self.n = 0

    def d(self, enc, opts, chunks, data):
        self.f.write("D %s %s %s %s\n" % (enc, opts, chunks, hx(data)))
        self.n += 1

    def x(self, enc, opts, pieces):
        self.f.write("D %s %s x %s\n" % (enc, opts, ".".join(hx(p) for p in pieces)))
        self.n += 1

    def raw(self, line):
        self.f.write(line + "\n")
        self.n += 1

    def close(self):
        self.f.close()
        return self.n


def labels(out):
    w = W(out, "labels")
    rs_labels = LABELS
    for lab in rs_labels:
        b = lab.encode()
        vs = [b, b.upper(), b.title(), b"\x00" + b, b + b"\x00"]
        for c in WS:
            vs += [bytes([c]) + b, b + bytes([c]), bytes([c, c]) + b + bytes([c, c])]
        vs += [b"\x0b" + b, b + b"\x0b", b"\xc2\xa0" + b, b + b"\xc2\xa0", b"\xe3\x80\x80" + b, b + b"\xe3\x80\x80",
               b"\x85" + b, b"\x1c" + b, b[:1] + b" " + b[1:], b + b + b"", b"\t\n\x0c\r " * 20 + b + b" " * 50]
        # Unicode case folding traps: Kelvin sign / dotless i / long s must NOT match (ASCII-only case folding)
        vs += [b.replace(b"k", "K".encode()), b.replace(b"i", "İ".encode()), b.replace(b"s", "ſ".encode())]
        for v in vs:
            w.raw("L " + v.hex())
    for v in [b"", b" ", b"\t\n", b"x" * 41, b" utf-8" + b"x" * 60, b"utf-7", b"utf-32", b"iso-8859-1 ", b"UTF8",
              b"unicode-1-1-utf-7", b"iso-2022-cn-ext ", b"x-user-defined\x0c", b"\xff\xfe", b"\x00"]:
        w.raw("L " + (v.hex() if v else "-"))
    return w.close()


def single_byte(out):
    w = W(out, "single")
    for enc in SINGLE:
        for b in range(256):
            for o in ("nb", "fb"):
                w.d(enc, o, "w", [b])
        allb = list(range(256))
        for o in OPTS:
            w.d(enc, o, "w", allb)
            w.d(enc, o, "k1", allb)
            w.d(enc, o, "k7", allb)
    return w.close()


def dbcs(out):
    """Every lead 0x80..0xFF x every trail 0x00..0xFF, followed by 'A' (restore rules), non-fatal + fatal."""
    w = W(out, "dbcs")
    for enc in DBCS:
        for lead in range(0x80, 0x100):
            for trail in range(256):
                w.d(enc, "nb", "w", [lead, trail, 0x41])
                w.d(enc, "fb", "w", [lead, trail])
            w.d(enc, "nb", "w", [lead])  # lead at EOF
            w.d(enc, "fb", "w", [lead])
    return w.close()


def three_byte(out):
    """EUC-JP 0x8F JIS0212 (every lead x every trail) and 0x8E; gb18030/GBK second-byte digit paths."""
    w = W(out, "threebyte")
    for l2 in range(256):
        w.d("EUC-JP", "nb", "w", [0x8F, l2, 0x41])
        w.d("EUC-JP", "nb", "w", [0x8F, l2])
        for t in range(0xA0, 0x100):
            if 0xA1 <= l2 <= 0xFE:
                w.d("EUC-JP", "nb", "w", [0x8F, l2, t])
        for t in (0x00, 0x21, 0x41, 0x7F, 0x80, 0x9F):
            w.d("EUC-JP", "nb", "w", [0x8F, l2, t, 0x42])
        w.d("EUC-JP", "nb", "w", [0x8E, l2, 0x41])
    for enc in ("gb18030", "GBK"):
        for first in range(0x81, 0xFF):
            for second in range(0x30, 0x3A):
                for third in (0x00, 0x30, 0x41, 0x7F, 0x80, 0x81, 0xA0, 0xFE, 0xFF):
                    w.d(enc, "nb", "w", [first, second, third, 0x42])
                w.d(enc, "nb", "w", [first, second])
                w.d(enc, "nb", "w", [first, second, 0x81])
    return w.close()


def gb_ptr_bytes(p):
    b1, r = divmod(p, 12600)
    b2, r = divmod(r, 1260)
    b3, b4 = divmod(r, 10)
    return [b1 + 0x81, b2 + 0x30, b3 + 0x81, b4 + 0x30]


def four_byte(out, rnd):
    w = W(out, "fourbyte")
    # every BMP-range pointer 0..39419 plus the neighbourhood of every interesting boundary
    pts = set(range(0, 39420 + 8))
    for c in (189000, 1237575, 39419, 7457):
        pts.update(range(c - 300, c + 300))
    pts.update(rnd.randrange(39420, 189000) for _ in range(4000))
    pts.update(rnd.randrange(189000, 1237576) for _ in range(20000))
    pts.update(rnd.randrange(1237576, 126 * 12600) for _ in range(4000))
    pts.update(range(126 * 12600 - 50, 126 * 12600))
    for p in sorted(x for x in pts if 0 <= x < 126 * 12600):
        w.d("gb18030", "nb", "w", gb_ptr_bytes(p))
        if p % 7 == 0:
            w.d("GBK", "fb", "w", gb_ptr_bytes(p))
    # explicit edge cases from the brief
    for c in ([0x81, 0x30, 0x81, 0x20], [0xE3, 0x32, 0x9A, 0x36], [0xE3, 0x32, 0x9A, 0x35], [0x84, 0x31, 0xA4, 0x39],
              [0x84, 0x31, 0xA5, 0x30], [0x90, 0x30, 0x81, 0x30], [0xFE, 0x39, 0xFE, 0x39], [0x81, 0x35, 0xF4, 0x37]):
        for o in OPTS:
            for ch in ("w", "k1", "k2", "k3", "e1"):
                w.d("gb18030", o, ch, c)
                w.d("gb18030", o, ch, c[:3])
                w.d("gb18030", o, ch, c[:3] + [0x41])
    # every fourth byte after a valid 3-byte prefix, every third byte after a valid 2-byte prefix
    for pre in ([0x81, 0x30, 0x81], [0x84, 0x31, 0xA4], [0x90, 0x30, 0x81], [0xE3, 0x32, 0x9A], [0xFE, 0x39, 0xFE]):
        for b in range(256):
            w.d("gb18030", "nb", "w", pre + [b, 0x41])
            w.d("gb18030", "nb", "k1", pre + [b, 0x41])
            w.d("gb18030", "nb", "w", pre[:2] + [b, 0x30, 0x41])
    # GB18030-2022 changed 2-byte and 4-byte mappings (vertical forms, PUA swaps)
    for lead in (0xA6, 0xA8, 0xA9, 0xFE, 0xD7):
        for trail in range(0x40, 0xFF):
            w.d("gb18030", "nb", "w", [lead, trail])
    return w.close()


ISO_ALPHA = [0x1B, 0x24, 0x28, 0x42, 0x40, 0x4A, 0x49, 0x44, 0x0E, 0x0F, 0x21, 0x30, 0x5C, 0x7E, 0x80, 0x0A]


def iso2022jp(out, rnd):
    w = W(out, "iso2022jp")
    # exhaustive over a 16-symbol alphabet up to length 4 (69 904 sequences), prefixed by every mode switch
    seqs = [[]]
    allseq = []
    for _ in range(4):
        seqs = [s + [a] for s in seqs for a in ISO_ALPHA]
        allseq += seqs
    for s in allseq:
        w.d("ISO-2022-JP", "nb", "w", s)
    prefixes = [[0x1B, 0x24, 0x42], [0x1B, 0x28, 0x4A], [0x1B, 0x28, 0x49], [0x1B, 0x24, 0x40], [0x1B, 0x28, 0x42]]
    for p in prefixes:
        for s in allseq[: 16 + 256 + 4096]:
            w.d("ISO-2022-JP", "nb", "w", p + s)
    # every JIS0208 row/cell pair, plus streaming splits of escape sequences
    for l in range(0x20, 0x80):
        for t in range(0x20, 0x80):
            w.d("ISO-2022-JP", "nb", "w", [0x1B, 0x24, 0x42, l, t])
    for _ in range(20000):
        s = [rnd.choice(ISO_ALPHA) if rnd.random() < 0.7 else rnd.randrange(256) for _ in range(rnd.randrange(1, 14))]
        o = rnd.choice(OPTS)
        for ch in ("w", "k1", "k2", "k3", "e1"):
            w.d("ISO-2022-JP", o, ch, s)
    return w.close()


def utf(out, rnd):
    w = W(out, "utf")
    for b0 in range(256):
        w.d("UTF-8", "nb", "w", [b0])
        for b1 in range(256):
            w.d("UTF-8", "nb", "w", [b0, b1])
    edges = [0x00, 0x41, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF, 0xE0, 0xED, 0xEF, 0xF0,
             0xF4, 0xF5, 0xFF]
    for b0 in range(0xC0, 0x100):
        for b1 in edges:
            for b2 in edges:
                w.d("UTF-8", "nb", "w", [b0, b1, b2])
                for b3 in (0x41, 0x80, 0xBF, 0xC0):
                    w.d("UTF-8", "nb", "w", [b0, b1, b2, b3])
    # every 3-byte lead with every second byte 0x80..0xBF (this covers EF BB xx, the BOM look-alikes the BOM state
    # machine has to hand back to the UTF-8 decoder) and edge third bytes, with and without BOM handling
    for b0 in range(0xE0, 0xF0):
        for b1 in range(0x80, 0xC0):
            for b2 in edges + [0xBB, 0xBE]:
                for o in ("nb", "ni"):
                    w.d("UTF-8", o, "w", [b0, b1, b2, 0x41])
                    if b0 == 0xEF:
                        w.d("UTF-8", o, "k1", [b0, b1, b2, 0x80])
    units = [0x0041, 0x00FE, 0x00FF, 0xFEFF, 0xFFFE, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xD83D, 0xDE00, 0x4E2D, 0xFFFF]
    for enc, be in (("UTF-16LE", False), ("UTF-16BE", True)):
        seqs = [[]]
        for _ in range(3):
            seqs = [s + [u] for s in seqs for u in units]
            for s in seqs:
                b = []
                for u in s:
                    b += [u >> 8, u & 0xFF] if be else [u & 0xFF, u >> 8]
                w.d(enc, "nb", "w", b)
                w.d(enc, "nb", "w", b + [0x41])  # odd trailing byte
                w.d(enc, "fb", "w", b)
                w.d(enc, "ni", "k1", b)
    for _ in range(20000):
        enc = rnd.choice(["UTF-8", "UTF-16LE", "UTF-16BE"])
        b = [rnd.choice(edges + [0x3D, 0xD8, 0xDC, 0xFE, 0xBB]) for _ in range(rnd.randrange(1, 12))]
        o = rnd.choice(OPTS)
        for ch in ("w", "k1", "k2", "k3", "e1"):
            w.d(enc, o, ch, b)
    return w.close()


def bom(out):
    w = W(out, "bom")
    boms = {"UTF-8": [0xEF, 0xBB, 0xBF], "UTF-16LE": [0xFF, 0xFE], "UTF-16BE": [0xFE, 0xFF]}
    tails = [[], [0x41], [0x41, 0x00], [0x00, 0x41], [0xEF], [0xEF, 0xBB], [0xEF, 0xBB, 0xBF], [0xFF, 0xFE],
             [0xFE, 0xFF], [0xEF, 0xBB, 0x00], [0xEF, 0xBC, 0x80], [0xEF, 0xBB, 0xC0], [0xEF, 0xBB, 0xBE], [0xEF, 0xBB, 0xBE, 0x80],
             [0xEF, 0xBB, 0x80], [0xEF, 0xBF, 0xBF], [0x80], [0xD8, 0x00]]
    for enc in ENCODINGS:
        for bname, bb in boms.items():
            for t in tails:
                data = bb + t
                for o in OPTS:
                    for ch in ("w", "k1", "k2", "e1", "r", "u"):
                        w.d(enc, o, ch, data)
                    # BOM split across chunks at every position, plus an empty chunk at the split
                    for cut in range(len(data) + 1):
                        w.x(enc, o, [data[:cut], data[cut:]])
                        w.x(enc, o, [data[:cut], [], data[cut:]])
                w.raw("S %s %s" % (enc, hx(data)))
                w.raw("S %s %s" % (enc, hx(t)))
        for t in tails:
            for o in OPTS:
                w.d(enc, o, "w", t)
                w.d(enc, o, "k1", t)
    return w.close()


def interesting_bytes(enc):
    if enc in ("GBK", "gb18030"):
        return [0x80, 0x81, 0x84, 0x30, 0x39, 0x3A, 0xA1, 0xB0, 0xD6, 0xFE, 0xFF, 0x40, 0x7F, 0xE3, 0x32, 0x9A]
    if enc == "Big5":
        return [0x80, 0x81, 0x87, 0x88, 0x62, 0x64, 0xA1, 0xA4, 0xFE, 0xFF, 0x40, 0x7E, 0x7F, 0xA0, 0xC8, 0xF9]
    if enc == "EUC-JP":
        return [0x8E, 0x8F, 0xA1, 0xA4, 0xB0, 0xDF, 0xFE, 0xFF, 0x80, 0x41, 0x7F, 0xE0, 0xF9, 0xA0]
    if enc == "Shift_JIS":
        return [0x80, 0x81, 0x82, 0x83, 0x88, 0x9F, 0xA0, 0xA1, 0xDF, 0xE0, 0xEF, 0xF0, 0xFC, 0xFD, 0x40, 0x7F]
    if enc == "EUC-KR":
        return [0x80, 0x81, 0xA1, 0xB0, 0xC6, 0xC7, 0xC8, 0xFE, 0xFF, 0x41, 0x5A, 0x5B, 0x61, 0x7B, 0xA0, 0x52]
    if enc == "ISO-2022-JP":
        return ISO_ALPHA
    if enc == "UTF-8":
        return [0xEF, 0xBB, 0xBF, 0xBE, 0xE0, 0xA0, 0x80, 0xF0, 0x90, 0xF4, 0x8F, 0xC2, 0xED, 0x9F, 0xFF, 0x41, 0xC0]
    if enc in ("UTF-16LE", "UTF-16BE"):
        return [0xFF, 0xFE, 0xD8, 0xDB, 0xDC, 0xDF, 0x00, 0x41, 0x3D, 0xFD]
    return [0x00, 0x41, 0x7F, 0x80, 0x81, 0x9F, 0xA0, 0xC0, 0xFE, 0xFF, 0xEF, 0xBB, 0xBF]


def stream(out, rnd, n):
    """Random byte strings per encoding under every chunking: chunk boundaries must never change the result."""
    w = W(out, "stream")
    for enc in ENCODINGS:
        alpha = interesting_bytes(enc)
        for _ in range(n):
            ln = rnd.randrange(0, 20)
            b = [rnd.choice(alpha) if rnd.random() < 0.75 else rnd.randrange(256) for _ in range(ln)]
            o = rnd.choice(OPTS)
            for ch in ("w", "k1", "k2", "k3", "e1", "r", "u"):
                w.d(enc, o, ch, b)
            cuts = sorted(rnd.sample(range(ln + 1), min(ln + 1, rnd.randrange(1, 5))))
            pieces, prev = [], 0
            for c in cuts:
                pieces.append(b[prev:c])
                prev = c
            pieces.append(b[prev:])
            w.x(enc, o, pieces)
    return w.close()


def cps_bmp():
    return [c for c in range(0x80, 0x10000) if not 0xD800 <= c <= 0xDFFF]


def encoders(out, rnd):
    w = W(out, "encode")
    bmp = cps_bmp()
    astral = list(range(0x10000, 0x110000, 0x101)) + [0x10FFFF, 0x10000, 0x20000, 0x2A6D6, 0x2000B, 0x26C21, 0x27607]
    for enc in ENCODINGS:
        step = 64
        for i in range(0, len(bmp), step):
            s = "".join(chr(c) for c in bmp[i:i + step]).encode()
            w.raw("E %s h %s" % (enc, s.hex()))
            w.raw("E %s s %s" % (enc, s.hex()))
        for i in range(0, len(astral), 64):
            s = "".join(chr(c) for c in astral[i:i + 64]).encode()
            w.raw("E %s h %s" % (enc, s.hex()))
        w.raw("E %s h %s" % (enc, bytes(range(128)).hex()))
        w.raw("E %s s %s" % (enc, bytes(range(128)).hex()))
        w.raw("E %s s -" % enc)
        w.raw("E %s h -" % enc)
    # strict per code point for the CJK encoders (mapping must agree code point by code point)
    for enc in ("GBK", "gb18030", "Big5", "EUC-KR", "Shift_JIS", "EUC-JP", "ISO-2022-JP"):
        for c in bmp:
            w.raw("E %s s %s" % (enc, chr(c).encode().hex()))
    # ISO-2022-JP encoder state machine: random strings over mode-switching characters
    alpha = ["A", "\\", "~", "¥", "‾", "あ", "ｱ", "\x0e", "\x0f", "\x1b", "\U0001F600", "中",
             "−", "－", "é", "\n", "&", "ﾞ", "｡"]
    for _ in range(20000):
        s = "".join(rnd.choice(alpha) for _ in range(rnd.randrange(1, 9))).encode()
        w.raw("E ISO-2022-JP h %s" % s.hex())
        w.raw("E ISO-2022-JP s %s" % s.hex())
    return w.close()


def main():
    out = sys.argv[1]
    sn = int(sys.argv[2]) if len(sys.argv) > 2 else 300
    os.makedirs(out, exist_ok=True)
    rnd = random.Random(0xE7C7)
    groups = [("labels", lambda: labels(out)), ("single", lambda: single_byte(out)), ("dbcs", lambda: dbcs(out)),
              ("threebyte", lambda: three_byte(out)), ("fourbyte", lambda: four_byte(out, rnd)),
              ("iso2022jp", lambda: iso2022jp(out, rnd)), ("utf", lambda: utf(out, rnd)), ("bom", lambda: bom(out)),
              ("stream", lambda: stream(out, rnd, sn)), ("encode", lambda: encoders(out, rnd))]
    for name, fn in groups:
        print("%s %d" % (name, fn()))


LABELS = []
if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    LABELS = [l for l in open(os.path.join(here, "labels.txt")).read().split("\n") if l]
    main()
