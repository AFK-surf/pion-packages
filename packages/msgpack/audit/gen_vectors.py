#!/usr/bin/env python3
"""Targeted MessagePack edge-case vectors for the three-way differential.

usage: gen_vectors.py <out.tsv>      (one "<category>\t<name>\t<hex>" line per vector)
"""
import struct
import sys

V = []


def add(cat, name, data):
    V.append((cat, name, data.hex()))


def be(fmt, v):
    return struct.pack(">" + fmt, v)


# --- 1. every first byte, complete and truncated -----------------------------------------------
def body_for(b):
    """A minimal complete value starting with marker b (None when b alone is complete)."""
    if b <= 0x7F or b >= 0xE0 or b in (0xC0, 0xC1, 0xC2, 0xC3):
        return b""
    if 0x80 <= b <= 0x8F:
        return b"\x00\xc0" * (b & 0x0F)
    if 0x90 <= b <= 0x9F:
        return b"\x00" * (b & 0x0F)
    if 0xA0 <= b <= 0xBF:
        return b"a" * (b & 0x1F)
    return {
        0xC4: b"\x01\xff", 0xC5: b"\x00\x01\xff", 0xC6: b"\x00\x00\x00\x01\xff",
        0xC7: b"\x01\x05\xaa", 0xC8: b"\x00\x01\x05\xaa", 0xC9: b"\x00\x00\x00\x01\x05\xaa",
        0xCA: be("f", 1.5), 0xCB: be("d", 1.5),
        0xCC: b"\xff", 0xCD: b"\xff\xff", 0xCE: b"\xff" * 4, 0xCF: b"\xff" * 8,
        0xD0: b"\x80", 0xD1: b"\x80\x00", 0xD2: b"\x80" + b"\x00" * 3, 0xD3: b"\x80" + b"\x00" * 7,
        0xD4: b"\x05\xaa", 0xD5: b"\x05" + b"\xaa" * 2, 0xD6: b"\x05" + b"\xaa" * 4,
        0xD7: b"\x05" + b"\xaa" * 8, 0xD8: b"\x05" + b"\xaa" * 16,
        0xD9: b"\x02hi", 0xDA: b"\x00\x02hi", 0xDB: b"\x00\x00\x00\x02hi",
        0xDC: b"\x00\x01\x00", 0xDD: b"\x00\x00\x00\x01\x00",
        0xDE: b"\x00\x01\x00\xc0", 0xDF: b"\x00\x00\x00\x01\x00\xc0",
    }[b]


for b in range(256):
    body = body_for(b)
    add("marker", "%02x-complete" % b, bytes([b]) + body)
    if body:
        add("marker", "%02x-truncated" % b, bytes([b]) + body[:-1])

# --- 2. integer boundaries in every width (canonical and overlong) ------------------------------
U = [0, 1, 5, 0x7F, 0x80, 0xFF, 0x100, 0xFFFF, 0x10000, 0xFFFFFFFF, 0x100000000,
     0x7FFFFFFFFFFFFFFF, 0x8000000000000000, 0xFFFFFFFFFFFFFFFF]
for u in U:
    for m, fmt, lim in ((0xCC, "B", 0xFF), (0xCD, "H", 0xFFFF), (0xCE, "I", 0xFFFFFFFF), (0xCF, "Q", 1 << 64)):
        if u <= lim:
            add("int", "uint%s(%d)" % (fmt, u), bytes([m]) + be(fmt, u))
S = [0, 1, 5, -1, -32, -33, -128, -129, -32768, -32769, -2147483648, -2147483649,
     -9223372036854775808, 127, 32767, 2147483647, 9223372036854775807]
for s in S:
    for m, fmt, lo, hi in ((0xD0, "b", -128, 127), (0xD1, "h", -32768, 32767),
                           (0xD2, "i", -(1 << 31), (1 << 31) - 1), (0xD3, "q", -(1 << 63), (1 << 63) - 1)):
        if lo <= s <= hi:
            add("int", "int%s(%d)" % (fmt, s), bytes([m]) + be(fmt, s))

# --- 3. IEEE-754 exact bit patterns -------------------------------------------------------------
F32 = [0x00000000, 0x80000000, 0x00000001, 0x80000001, 0x007FFFFF, 0x00800000, 0x7F7FFFFF,
       0x7F800000, 0xFF800000, 0x7FC00000, 0xFFC00000, 0x7F800001, 0x7FBFFFFF, 0xFFC00001,
       0x7FFFFFFF, 0x3F800000, 0x33800000, 0x4B800001]
for bits in F32:
    add("float", "f32(%08x)" % bits, b"\xca" + be("I", bits))
F64 = [0, 1 << 63, 1, 0x000FFFFFFFFFFFFF, 0x0010000000000000, 0x7FEFFFFFFFFFFFFF,
       0x7FF0000000000000, 0xFFF0000000000000, 0x7FF8000000000000, 0x7FF0000000000001,
       0x7FF7FFFFFFFFFFFF, 0xFFF8000000000001, 0x7FF8000020000000, 0x3FF0000000000000,
       0x4170000010000000, 0x483D6329F1C35CA5, 0x37A16C262777579C]
for bits in F64:
    add("float", "f64(%016x)" % bits, b"\xcb" + be("Q", bits))

# --- 4. Timestamp ext -1 --------------------------------------------------------------------------
def ts64(sec, nsec):
    return (nsec << 34) | sec


for sec in (0, 1, 0xFFFFFFFF):
    add("ts", "ts32(%d)" % sec, b"\xd6\xff" + be("I", sec))
for sec, nsec in ((0, 0), (0, 1), (1, 999999999), (0x100000000, 0), ((1 << 34) - 1, 999999999),
                  (0, 1000000000), (5, (1 << 30) - 1)):
    add("ts", "ts64(%d,%d)" % (sec, nsec), b"\xd7\xff" + be("Q", ts64(sec, nsec)))
for sec, nsec in ((-1, 0), (-(1 << 63), 0), ((1 << 63) - 1, 999999999), (0, 0), (1 << 34, 0),
                  (-1, 1000000000), (-1, 0xFFFFFFFF), (5, 5)):
    add("ts", "ts96(%d,%d)" % (sec, nsec), b"\xc7\x0c\xff" + be("I", nsec) + be("q", sec))
# non-canonical containers for the same payloads
add("ts", "ts32-in-ext8", b"\xc7\x04\xff" + be("I", 7))
add("ts", "ts32-in-ext16", b"\xc8\x00\x04\xff" + be("I", 7))
add("ts", "ts64-in-ext8", b"\xc7\x08\xff" + be("Q", ts64(7, 7)))
add("ts", "ts64-in-ext16", b"\xc8\x00\x08\xff" + be("Q", ts64(7, 7)))
add("ts", "ts96-in-ext16", b"\xc8\x00\x0c\xff" + be("I", 7) + be("q", -7))
add("ts", "ts96-in-ext32", b"\xc9\x00\x00\x00\x0c\xff" + be("I", 7) + be("q", -7))
add("ts", "ts64-sec0-nsec0", b"\xd7\xff" + b"\x00" * 8)
for n in (0, 1, 2, 3, 5, 7, 9, 11, 13, 16):
    if n in (1, 2, 16):
        add("ts", "ts-fixext%d" % n, bytes([{1: 0xD4, 2: 0xD5, 16: 0xD8}[n]]) + b"\xff" + b"\x00" * n)
    add("ts", "ts-ext8-len%d" % n, b"\xc7" + bytes([n]) + b"\xff" + b"\x00" * n)

# --- 5. require_canonical overlong forms -------------------------------------------------------------
add("canon", "str8-len5", b"\xd9\x05hello")
add("canon", "str8-len31", b"\xd9\x1f" + b"a" * 31)
add("canon", "str8-len32", b"\xd9\x20" + b"a" * 32)
add("canon", "str16-len255", b"\xda\x00\xff" + b"a" * 255)
add("canon", "str32-len5", b"\xdb\x00\x00\x00\x05hello")
add("canon", "bin16-len10", b"\xc5\x00\x0a" + b"\x00" * 10)
add("canon", "bin32-len10", b"\xc6\x00\x00\x00\x0a" + b"\x00" * 10)
add("canon", "ext8-len4", b"\xc7\x04\x05" + b"\x00" * 4)
add("canon", "ext8-len3", b"\xc7\x03\x05" + b"\x00" * 3)
add("canon", "ext16-len3", b"\xc8\x00\x03\x05" + b"\x00" * 3)
add("canon", "ext8-len0", b"\xc7\x00\x05")
add("canon", "array16-len2", b"\xdc\x00\x02\x01\x02")
add("canon", "array32-len2", b"\xdd\x00\x00\x00\x02\x01\x02")
add("canon", "map16-len2", b"\xde\x00\x02\x01\x01\x02\x02")
add("canon", "map32-len1", b"\xdf\x00\x00\x00\x01\x01\x01")
add("canon", "float64-1.5", b"\xcb" + be("d", 1.5))
add("canon", "nested-overlong", b"\x91\x91\xd0\x05")

# --- 6. UTF-8 -----------------------------------------------------------------------------------
UTF = {
    "ascii": b"abc", "nul": b"a\x00b", "2byte-min": "\u0080".encode(), "2byte-max": "߿".encode(),
    "3byte-min": "ࠀ".encode(), "3byte-max": "￿".encode(), "4byte-min": "\U00010000".encode(),
    "4byte-max": "\U0010ffff".encode(), "bom": b"\xef\xbb\xbf", "U+D7FF": b"\xed\x9f\xbf",
    "U+E000": b"\xee\x80\x80", "overlong2-c0": b"\xc0\x80", "overlong2-c1": b"\xc1\xbf",
    "overlong3": b"\xe0\x80\x80", "overlong3b": b"\xe0\x9f\xbf", "overlong4": b"\xf0\x80\x80\x80",
    "overlong4b": b"\xf0\x8f\xbf\xbf", "surrogate-hi": b"\xed\xa0\x80", "surrogate-lo": b"\xed\xbf\xbf",
    "surrogate-pair": b"\xed\xa0\xbd\xed\xb8\x80", ">10FFFF": b"\xf4\x90\x80\x80", "f5": b"\xf5\x80\x80\x80",
    "ff": b"\xff", "lone-cont": b"\x80", "trunc2": b"\xc3", "trunc3": b"\xe2\x82", "trunc4": b"\xf0\x9f\x98",
    "trunc-mid": b"\xe2\x82a", "5byte": b"\xf8\x88\x80\x80\x80",
}
for name, raw in UTF.items():
    add("utf8", name, (bytes([0xA0 | len(raw)]) if len(raw) < 32 else b"\xd9" + bytes([len(raw)])) + raw)
# invalid bin next to a valid str (the <= 2 MiB `data.to_string()` path)
add("utf8", "bin-ff-then-str", b"\x92\xc4\x02\xff\xfe\xa3\xe2\x9c\x93")
add("utf8", "str-then-bin-ff-then-str", b"\x93\xa2\xc3\xa9\xc4\x03\xc3\xff\x80\xa2\xc3\xa9")

# --- 7. duplicate-key semantics ---------------------------------------------------------------------
DUP = {
    "fixint0-uint8-0": b"\x82\x00\x01\xcc\x00\x02",
    "fixint0-int8-0": b"\x82\x00\x01\xd0\x00\x02",
    "int64-5-uint64-5": b"\x82\xd3" + be("q", 5) + b"\x01\xcf" + be("Q", 5) + b"\x02",
    "neg1-uint64max": b"\x82\xff\x01\xcf" + be("Q", (1 << 64) - 1) + b"\x02",
    "f64-0-f32-0": b"\x82\xcb" + be("d", 0.0) + b"\x01\xca" + be("f", 0.0) + b"\x02",
    "f64-0-f64-neg0": b"\x82\xcb" + be("d", 0.0) + b"\x01\xcb" + be("d", -0.0) + b"\x02",
    "f64-nan-same": b"\x82\xcb" + be("Q", 0x7FF8000000000000) + b"\x01\xcb" + be("Q", 0x7FF8000000000000) + b"\x02",
    "f64-nan-diff": b"\x82\xcb" + be("Q", 0x7FF8000000000000) + b"\x01\xcb" + be("Q", 0x7FF8000000000001) + b"\x02",
    "str-vs-bin": b"\x82\xa1a\x01\xc4\x01a\x02",
    "fixstr-str8": b"\x82\xa1a\x01\xd9\x01a\x02",
    "ts32-ts64-same": b"\x82\xd6\xff\x00\x00\x00\x07\x01\xd7\xff" + be("Q", 7) + b"\x02",
    "array-keys": b"\x82\x91\x01\x01\x91\xcc\x01\x02",
    "nil-nil": b"\x82\xc0\x01\xc0\x02",
}
for name, raw in DUP.items():
    add("dup", name, raw)
# 9+ keys switch to the hash table: same tests via map16 padded with distinct filler keys
for name, raw in DUP.items():
    pairs = raw[1:]
    filler = b"".join(bytes([0xA2]) + b"k" + bytes([0x61 + i]) + b"\xc0" for i in range(10))
    add("dup", "big-" + name, b"\xde\x00\x0c" + filler + pairs)

# --- 8. depth boundary (recursive 64 -> iterative switch, 1024 tree cap) ----------------------------
for d in (63, 64, 65, 66, 128, 129):
    add("depth", "arr%d" % d, b"\x91" * d + b"\x01")
    add("depth", "map%d" % d, b"\x81\x00" * d + b"\x01")

with open(sys.argv[1], "w") as f:
    for cat, name, h in V:
        f.write("%s\t%s\t%s\n" % (cat, name, h))
print("wrote %d vectors" % len(V))
