#!/usr/bin/env python3
"""Deterministic red-team corpus for the uuid/ulid differential (Pion vs Rust uuid 1.29.3 / ulid 1.2.1).

Usage: python3 gen_corpus.py <out.tsv>

Each line is `op<TAB>arg...`; string inputs are hex-encoded raw bytes so that
whitespace, CR/LF, NUL and invalid UTF-8 survive the TSV transport unchanged.
"""

import random
import sys

U = "67e55044-10b1-426f-9247-bb680e5fe0c8"
SIMPLE = U.replace("-", "")
NS = {
    "dns": "6ba7b8109dad11d180b400c04fd430c8",
    "url": "6ba7b8119dad11d180b400c04fd430c8",
    "oid": "6ba7b8129dad11d180b400c04fd430c8",
    "x500": "6ba7b8149dad11d180b400c04fd430c8",
    "nil": "0" * 32,
    "max": "f" * 32,
    "rnd": "0123456789abcdeffedcba9876543210",
}
ULID = "01AN4Z07BY79KA1307SR9X4MV3"
CROCK = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

out = []


def h(b):
    if isinstance(b, str):
        b = b.encode("utf-8")
    return b.hex()


def case(op, *args):
    out.append("\t".join([op] + [str(a) for a in args]))


rng = random.Random(0xA0D17)

# ---------------------------------------------------------------- UUID parse
valid_forms = [
    U, U.upper(), SIMPLE, SIMPLE.upper(), "{" + U + "}", "{" + U.upper() + "}",
    "urn:uuid:" + U, "URN:UUID:" + U, "urn:UUID:" + U, "Urn:Uuid:" + U.upper(),
    "00000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff",
    "F9168C5E-CEB2-4faa-B6BF-329BF39FA1E4",
]
for s in valid_forms:
    case("uparse", h(s))

bad_forms = [
    "", " ", U[:-1], U + "0", " " + U, U + " ", "\t" + U, U + "\n", U + "\r\n", U + "\0", "﻿" + U,
    "{" + U, U + "}", "{" + U + ")", "(" + U + ")", "[" + U + "]", "{" + SIMPLE + "}", "{urn:uuid:" + U + "}",
    "urn:uuid:" + SIMPLE, "urn:uuid:{" + U + "}", "urn-uuid:" + U, "urn:uuid;" + U, "uuid:" + U,
    "urn:uuid:" + U[:-1] + "g", "urn::uuid" + U, "0x" + SIMPLE[2:], "+" + SIMPLE[1:], "-" + SIMPLE[1:],
    U.replace("-", "_"), U.replace("-", ""), SIMPLE[:8] + "-" + SIMPLE[8:],
    "67e5504-410b1-426f-9247-bb680e5fe0c8", "67e55044-10b14-26f-9247-bb680e5fe0c8",
    "67e55044-10b1-426f9-247-bb680e5fe0c8", "67e55044-10b1-426f-9247b-b680e5fe0c8",
    "67e55044-10b1-426f-9247-bb680e5fe0c-", "-7e55044-10b1-426f-9247-bb680e5fe0c8",
    "67e55044--0b1-426f-9247-bb680e5fe0c8", "g7e55044-10b1-426f-9247-bb680e5fe0c8",
    "67e55044-10b1-426f-9247-bb680e5fe0cG", "67e55044-10b1-426f-9247-bb680e5fe0c ",
    "67e55044-10b1-426f-9247-bb680e5fe0c8".replace("e", "е"),  # Cyrillic e (2 bytes)
    U[:-1] + "١",  # Arabic-indic digit one
    U[:-1] + "８",  # fullwidth 8
    U[:-2] + "é",  # 2-byte é replacing 2 chars -> still 36 bytes
    SIMPLE[:-2] + "é", "{" + U[:-2] + "é}",
]
for s in bad_forms:
    case("uparse", h(s))

# High-bit aliases of valid hex/hyphen bytes at every position (LUT `& 0x7F` / sign-extension probes)
for alias in (0x80, 0xB0, 0xB9, 0xC1, 0xE1, 0xE6, 0xAD, 0xFF, 0xC0):
    for i in range(36):
        b = bytearray(U.encode())
        b[i] = alias
        case("uparse", b.hex())
    for i in range(32):
        b = bytearray(SIMPLE.encode())
        b[i] = alias
        case("uparse", b.hex())
    b = bytearray(("urn:uuid:" + U).encode())
    b[rng.randrange(45)] = alias
    case("uparse", b.hex())

# Case-folding probes in the URN prefix: `| 32` tricks accept non-letters?
for i in range(9):
    for repl in ("U", "R", "N", "I", "D", ":", "\x1a", "\x15", "\x0e", "\x09", "\x04", "Z", "@", "\x7f"):
        s = list("urn:uuid:" + U)
        s[i] = repl
        case("uparse", h("".join(s)))

# Random hex strings of every length 0..50 and random-byte mutations
for n in range(0, 51):
    case("uparse", h("".join(rng.choice("0123456789abcdefABCDEF-{}") for _ in range(n))))
forms = [U, SIMPLE, "{" + U + "}", "urn:uuid:" + U]
for _ in range(3000):
    b = bytearray(rng.choice(forms).encode())
    for _k in range(rng.choice((1, 1, 1, 2, 3))):
        b[rng.randrange(len(b))] = rng.randrange(256)
    case("uparse", b.hex())

# ---------------------------------------------------------------- v3 / v5
for ns in NS.values():
    for name in (b"", b"a", b"abc", b"www.example.com", b"python.org", b"\x00", b"\xff" * 3):
        case("v3", ns, name.hex())
        case("v5", ns, name.hex())
for ln in list(range(0, 200)) + [239, 240, 247, 248, 255, 256, 511, 512, 1000, 4095, 4096, 65535, 65536, 1 << 20]:
    for nsk in ("dns", "max"):
        case("v3len", NS[nsk], ln, ln + 1)
        case("v5len", NS[nsk], ln, ln + 1)

# ---------------------------------------------------------------- v7 / v1 / v6 / v4 / v8
v7_ts = [0, 1, 1700000000000, 0xFFFFFFFFFFFF - 1, 0xFFFFFFFFFFFF]
for ts in v7_ts:
    for r in ("00" * 10, "ff" * 10, "0123456789abcdef0123", "".join("%02x" % rng.randrange(256) for _ in range(10))):
        case("v7", ts, r)
# policy probes (Rust truncates silently, Pion rejects)
for ts in (0x1000000000000, 0xFFFFFFFFFFFFFFFF, 1 << 63):
    case("v7", ts, "0123456789abcdef0123")

for ticks in (0, 1, 0x1B21DD213814000, 0x0FFFFFFFFFFFFFFF, rng.randrange(1 << 60)):
    for cs in (0, 1, 0x1234, 0x3FFF):
        for node in ("000000000000", "ffffffffffff", "0102030405ff"):
            case("v1", ticks, cs, node)
            case("v6", ticks, cs, node)
for ticks, cs in ((1 << 60, 0), (0, 0x4000), (0, 0xFFFF)):
    case("v1", ticks, cs, "0102030405ff")
    case("v6", ticks, cs, "0102030405ff")

for b in ("00" * 16, "ff" * 16, "0123456789abcdef0123456789abcdef"):
    case("v4", b)
    case("v8", b)
for _ in range(50):
    b = "".join("%02x" % rng.randrange(256) for _ in range(16))
    case("v4", b)
    case("v8", b)

# ---------------------------------------------------------------- version / variant matrix
for ver in range(16):
    for var_byte in (0x00, 0x3F, 0x40, 0x7F, 0x80, 0xA0, 0xBF, 0xC0, 0xDF, 0xE0, 0xFF):
        hi = 0x123456789ABC0DEF | (ver << 12)
        lo = (var_byte << 56) | 0x00123456789ABC
        case("uinfo", "%016x%016x" % (hi, lo))
for x in ("0" * 32, "f" * 32, "0" * 31 + "1", "f" * 31 + "e", "00000000000070008000000000000000",
          "017f22e279b07cc398c4dc0c0c07398f", "1ec9414c232a6b00b3c89f6bdeced846",
          "c232ab00943111beab8a0800200c9a66", "ffffffffffffffff0000000000000000"):
    case("uinfo", x)

# ---------------------------------------------------------------- ULID parse / format
ulid_valid = [ULID, ULID.lower(), "01an4Z07by79KA1307sr9x4mv3", "0" * 26, "7" + "Z" * 25, "7" + "z" * 25,
              "01ARZ3NDEKTSV4RRFFQ69G5FAV"]
for s in ulid_valid:
    case("ulparse", h(s))
ulid_bad = ["", ULID[:-1], ULID + "0", "8" + "0" * 25, "Z" * 26, "80000000000000000000000000",
            "ZZZZZZZZZZZZZZZZZZZZZZZZZZ", " " + ULID[1:], ULID[:-1] + " ", ULID[:10] + "-" + ULID[11:],
            ULID[:-1] + "\n", "﻿" + ULID[3:], ULID[:-2] + "é", ULID[:-1] + "０"[:1]]
for s in ulid_bad:
    case("ulparse", h(s))
for i in range(26):
    for c in "ILOUiluo*@[`{_":
        s = list(ULID)
        s[i] = c
        case("ulparse", h("".join(s)))
for first in CROCK + CROCK.lower():
    case("ulparse", h(first + ULID[1:]))
for alias in (0x80, 0xB0, 0xB7, 0xC1, 0xDA, 0xE1, 0xFA, 0xFF):
    for i in range(26):
        b = bytearray(ULID.encode())
        b[i] = alias
        case("ulparse", b.hex())
for _ in range(2000):
    b = bytearray(ULID.encode())
    b[rng.randrange(26)] = rng.randrange(256)
    case("ulparse", b.hex())

for x in ("0" * 32, "f" * 32, "0001" + "0" * 28, "ffffffffffff" + "0" * 20, "000000000000ffff" + "f" * 16):
    case("ulfmt", x)
    case("ulinc", x)
for _ in range(100):
    x = "".join("%02x" % rng.randrange(256) for _ in range(16))
    case("ulfmt", x)
    case("ulinc", x)
for x in ("0123456789ab" + "0000" + "f" * 16, "0123456789ab" + "fffe" + "f" * 16, "0123456789ab" + "ffff" + "f" * 16,
          "ffffffffffff" + "ffff" + "f" * 16, "0123456789ab" + "0000" + "f" * 15 + "e"):
    case("ulinc", x)
for ts in (0, 1, 1469918176385, 0xFFFFFFFFFFFF):
    for r in ("00" * 10, "ff" * 10, "0123456789abcdef0123"):
        case("ulparts", ts, r)
for ts in (0x1000000000000, 0xFFFFFFFFFFFFFFFF):
    case("ulparts", ts, "0123456789abcdef0123")

# ---------------------------------------------------------------- sorting
kinds = ["random", "equal", "sorted", "reverse", "lo64", "lastbyte", "signed", "dup33", "deep33", "sawtooth"]
for op in ("sort_uuid", "sort_raw", "sort_fixed", "sort_ulid"):
    for kind in kinds:
        for n in (0, 1, 2, 31, 32, 33, 34, 100, 1000, 5000):
            case(op, kind, n, 7)

# ---------------------------------------------------------------- batch line parsers
def uuid_line(i, style):
    r = random.Random(i)
    hx = "%032x" % r.getrandbits(128)
    hy = "%s-%s-%s-%s-%s" % (hx[:8], hx[8:12], hx[12:16], hx[16:20], hx[20:])
    return [hy, hy.upper(), hx, "{" + hy + "}", "urn:uuid:" + hy, "URN:UUID:" + hy][style % 6]


normal = "\n".join(uuid_line(i, i) for i in range(120)) + "\n"
line_cases = [
    normal,
    normal.replace("\n", "\r\n"),
    normal[:-1],  # no trailing newline
    "\n\n\n\n" + SIMPLE + "\n",  # 4 blank lines + simple => window of exactly 36 bytes ends at '\n'
    "\r\n\r\n" + SIMPLE + "\r\n",  # CRLF variant (byte 36 is '\r' -> slow path, OK)
    "\n" + "\r\n" * 18 + SIMPLE + "\r\n",  # CRLF run whose byte 36 is '\n' -> fast path mis-split
    "\n" * 37,  # only blank lines (37 => '\n' at index 36)
    "\n" * 36 + U + "\n",
    U + "\n\n" + U + "\n",
    U + "\n" + "\n" * 36 + U + "\n",
    "\n".join([U] * 3) + "\n\n\n\n" + SIMPLE + "\n",
    U + " \n",
    U + "\r\r\n",
    "\r\n",
    "\r",
    "",
    U + "\n" + U[:-1] + "\n",
]
for c in line_cases:
    case("lines", h(c))
    case("lines_fixed", h(c))

def ulid_line(i):
    r = random.Random(1000 + i)
    return r.choice(CROCK[:8]) + "".join(r.choice(CROCK) for _ in range(25))


ul_normal = "\n".join(ulid_line(i) for i in range(100)) + "\n"
ul_cases = [
    ul_normal,
    ul_normal.replace("\n", "\r\n"),
    ul_normal.lower(),
    "\n" * 27,
    "\n" * 26 + ULID + "\n",
    ULID + "\n" + "\n" * 26 + ULID + "\n",
    "\r\n" * 13 + "\n" + ULID + "\n",
    ULID + "\n\n" + ULID + "\n",
    ULID[:-1] + "I\n",
    "8" + ULID[1:] + "\n",
    "",
]
for c in ul_cases:
    case("ullines", h(c))
    case("ullines_fixed", h(c))

with open(sys.argv[1], "w") as f:
    f.write("# uuid red-team differential corpus (generated by gen_corpus.py)\n")
    f.write("\n".join(out) + "\n")
print(f"wrote {len(out)} cases to {sys.argv[1]}", file=sys.stderr)
