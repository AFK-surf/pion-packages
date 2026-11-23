#!/usr/bin/env python3
"""Deterministic RFC 7541 HPACK differential corpus for Pion vs Go x/net/http2/hpack vs Rust h2 hpack.

Output: one case per line, `<name>\t<block1 hex>,<block2 hex>,...`. Every case is decoded by a fresh
decoder (SETTINGS_HEADER_TABLE_SIZE = 4096, no header-list limit); blocks of a case share the decoder
so dynamic-table state (insertion, eviction, size updates) is exercised across blocks.

Families
  valid_*     random but legal blocks from an independent Python encoder (all representations,
              Huffman on/off, size updates, eviction, overlong-but-legal integers)        -> 3,000
  mut_*       byte flip / truncate / insert / splice mutations of valid blocks            -> 2,000
  huff_*      every symbol 0..255 alone, with 1..7 bit all-1 padding                     ->   256
  hpad_*      padding edge cases: non-1 bits, 8..15 bit padding, explicit EOS at every
              bit offset 0..7, EOS straddling bytes, truncated codes                      -> ~140
  int_*       integer edge cases (prefix boundaries, 2^31/2^32/2^63 indices, long 0x80 runs)
  sz_*        dynamic table size update attacks (after field, multiple, >SETTINGS, 0 then ref)
Usage: gen_hpack_corpus.py <out.txt> [huffman_table_source=go tables.go path]
"""
import random
import re
import sys

STATIC = [
    (":authority", ""), (":method", "GET"), (":method", "POST"), (":path", "/"),
    (":path", "/index.html"), (":scheme", "http"), (":scheme", "https"), (":status", "200"),
    (":status", "204"), (":status", "206"), (":status", "304"), (":status", "400"),
    (":status", "404"), (":status", "500"), ("accept-charset", ""), ("accept-encoding", "gzip, deflate"),
    ("accept-language", ""), ("accept-ranges", ""), ("accept", ""), ("access-control-allow-origin", ""),
    ("age", ""), ("allow", ""), ("authorization", ""), ("cache-control", ""), ("content-disposition", ""),
    ("content-encoding", ""), ("content-language", ""), ("content-length", ""), ("content-location", ""),
    ("content-range", ""), ("content-type", ""), ("cookie", ""), ("date", ""), ("etag", ""), ("expect", ""),
    ("expires", ""), ("from", ""), ("host", ""), ("if-match", ""), ("if-modified-since", ""),
    ("if-none-match", ""), ("if-range", ""), ("if-unmodified-since", ""), ("last-modified", ""),
    ("link", ""), ("location", ""), ("max-forwards", ""), ("proxy-authenticate", ""),
    ("proxy-authorization", ""), ("range", ""), ("referer", ""), ("refresh", ""), ("retry-after", ""),
    ("server", ""), ("set-cookie", ""), ("strict-transport-security", ""), ("transfer-encoding", ""),
    ("user-agent", ""), ("vary", ""), ("via", ""), ("www-authenticate", ""),
]


def load_huffman(path):
    src = open(path).read()
    codes = re.search(r"huffmanCodes = \[256\]uint32\{(.*?)\}", src, re.S).group(1)
    lens = re.search(r"huffmanCodeLen = \[256\]uint8\{(.*?)\}", src, re.S).group(1)
    codes = [int(x, 16) for x in re.findall(r"0x[0-9a-f]+", codes)]
    lens = [int(x) for x in re.findall(r"\d+", lens)]
    assert len(codes) == 256 and len(lens) == 256
    return codes, lens


CODES, LENS = None, None


def huff(raw: bytes, pad_bits=None, pad_value=None) -> bytes:
    acc, n = 0, 0
    for b in raw:
        acc = (acc << LENS[b]) | CODES[b]
        n += LENS[b]
    pad = (-n) % 8 if pad_bits is None else pad_bits
    pv = ((1 << pad) - 1) if pad_value is None else pad_value
    acc = (acc << pad) | pv
    n += pad
    assert n % 8 == 0
    return acc.to_bytes(n // 8, "big") if n else b""


def enc_int(v, prefix, mask, extra_zero_cont=0):
    m = (1 << prefix) - 1
    if v < m:
        return bytes([mask | v])
    out = [mask | m]
    v -= m
    while v >= 128:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    if extra_zero_cont:
        out.append(v | 0x80)
        out += [0x80] * (extra_zero_cont - 1)
        out.append(0x00)
    else:
        out.append(v)
    return bytes(out)


def enc_str(s: bytes, use_huff: bool) -> bytes:
    if use_huff:
        h = huff(s)
        return enc_int(len(h), 7, 0x80) + h
    return enc_int(len(s), 7, 0x00) + s


NAMES = [b"x-req-id", b"x-trace", b"cookie", b"user-agent", b"accept", b"x-a", b"content-type",
         b"x-forwarded-for", b"cache-control", b"x-long-header-name-for-eviction", b"etag", b"via"]


def rnd_value(r):
    k = r.random()
    if k < 0.1:
        return b""
    if k < 0.8:
        n = r.randint(1, 40)
        return bytes(r.choice(b"abcdefghijklmnopqrstuvwxyz0123456789-_./=;, ") for _ in range(n))
    if k < 0.95:
        return bytes(r.randint(0x21, 0x7E) for _ in range(r.randint(1, 300)))
    return bytes(r.choice([0x80, 0x9F, 0xC3, 0xE9, 0xFF, 0x20, 0x41]) for _ in range(r.randint(1, 20)))


class Model:
    """Reference RFC 7541 dynamic table (used only to know which indices are valid)."""

    def __init__(self, max_size=4096):
        self.entries = []  # newest first
        self.size = 0
        self.max = max_size

    def insert(self, n, v):
        es = len(n) + len(v) + 32
        while self.entries and self.size + es > self.max:
            on, ov = self.entries.pop()
            self.size -= len(on) + len(ov) + 32
        if es <= self.max:
            self.entries.insert(0, (n, v))
            self.size += es

    def resize(self, m):
        self.max = m
        while self.entries and self.size > self.max:
            on, ov = self.entries.pop()
            self.size -= len(on) + len(ov) + 32


def valid_block(r, model: Model, first: bool):
    out = b""
    if r.random() < 0.15:
        for _ in range(r.randint(1, 3)):
            m = r.choice([0, 32, 100, 256, 1000, 4096, r.randint(0, 4096)])
            out += enc_int(m, 5, 0x20, extra_zero_cont=r.choice([0, 0, 0, 1]) if m >= 31 else 0)
            model.resize(m)
    for _ in range(r.randint(0, 12)):
        k = r.random()
        uh = r.random() < 0.6
        if k < 0.2:
            idx = r.randint(1, 61)
            out += enc_int(idx, 7, 0x80)
        elif k < 0.35 and model.entries:
            idx = 62 + r.randrange(len(model.entries))
            out += enc_int(idx, 7, 0x80, extra_zero_cont=r.choice([0, 0, 0, 2]))
        else:
            v = rnd_value(r)
            rep = r.choice(["inc", "inc", "noidx", "never"])
            if r.random() < 0.5:
                total = 61 + len(model.entries)
                ni = r.randint(1, total)
                name = STATIC[ni - 1][0].encode() if ni <= 61 else model.entries[ni - 62][0]
                hdr = {"inc": enc_int(ni, 6, 0x40), "noidx": enc_int(ni, 4, 0x00), "never": enc_int(ni, 4, 0x10)}[rep]
            else:
                name = r.choice(NAMES)
                hdr = {"inc": b"\x40", "noidx": b"\x00", "never": b"\x10"}[rep] + enc_str(name, uh)
            out += hdr + enc_str(v, r.random() < 0.6)
            if rep == "inc":
                model.insert(name, v)
    return out


def mutate(r, b: bytes) -> bytes:
    if not b:
        return bytes([r.randint(0, 255)])
    b = bytearray(b)
    for _ in range(r.randint(1, 3)):
        op = r.randrange(5)
        i = r.randrange(len(b)) if b else 0
        if op == 0 and b:
            b[i] ^= 1 << r.randrange(8)
        elif op == 1 and b:
            b[i] = r.randint(0, 255)
        elif op == 2:
            b = b[: r.randint(0, len(b))]
        elif op == 3:
            b.insert(i, r.choice([0x80, 0xFF, 0x7F, 0x3F, 0x20, 0x1F, 0x00, 0x40, 0x10]))
        else:
            b = b + bytes([r.randint(0, 255) for _ in range(r.randint(1, 4))])
    return bytes(b)


def main():
    global CODES, LENS
    out_path = sys.argv[1]
    tables = sys.argv[2]
    CODES, LENS = load_huffman(tables)
    r = random.Random(0x48325254)  # "H2RT"
    cases = []

    for i in range(3000):
        m = Model()
        blocks = [valid_block(r, m, j == 0) for j in range(r.randint(1, 4))]
        cases.append((f"valid_{i}", blocks))

    for i in range(2000):
        m = Model()
        blocks = [valid_block(r, m, j == 0) for j in range(r.randint(1, 3))]
        k = r.randrange(len(blocks))
        blocks[k] = mutate(r, blocks[k])
        cases.append((f"mut_{i}", blocks))

    # Every symbol, literal value w/o indexing: 0x00 0x01 'x' <huffman value>
    for s in range(256):
        h = huff(bytes([s]))
        cases.append((f"huff_sym_{s}", [b"\x00\x01x" + enc_int(len(h), 7, 0x80) + h]))

    # All 256 symbols in one string, and long random strings
    allb = bytes(range(256))
    h = huff(allb)
    cases.append(("huff_all256", [b"\x00\x01x" + enc_int(len(h), 7, 0x80) + h]))

    def lit_h(hbytes):
        return b"\x00\x01x" + enc_int(len(hbytes), 7, 0x80) + hbytes

    # padding edge cases on symbol 'a' (5 bits: 00011) and '0' (5 bits) and 'q' etc.
    for sym in [ord("a"), ord("0"), ord("%"), ord("&"), 0x00, 0xFF, ord("Z")]:
        L = LENS[sym]
        need = (-L) % 8
        for pad in range(0, 16):
            if (L + pad) % 8:
                continue
            for pv in sorted({(1 << pad) - 1, 0, ((1 << pad) - 1) ^ 1 if pad else 0}):
                cases.append((f"hpad_s{sym}_p{pad}_v{pv:x}", [lit_h(huff(bytes([sym]), pad, pv))]))
        _ = need
    # Explicit EOS (30 ones) after k leading symbol bits at every bit offset.
    for prefix in [b"", b"a", b"ab", b"abc", b"\x00", b"aa0", b"%&"]:
        acc, n = 0, 0
        for b in prefix:
            acc = (acc << LENS[b]) | CODES[b]
            n += LENS[b]
        acc = (acc << 30) | 0x3FFFFFFF
        n += 30
        pad = (-n) % 8
        acc = (acc << pad) | ((1 << pad) - 1)
        n += pad
        cases.append((f"hpad_eos_after_{prefix.hex() or 'none'}", [lit_h(acc.to_bytes(n // 8, "big"))]))
    # truncated long codes (cut a 28-bit symbol mid-way) and 7-bit padding that is a prefix of a code
    for sym in [0x00, 0x01, 0x0A, 0x16, 0xFE]:
        full = huff(bytes([sym]))
        for cut in range(1, len(full)):
            cases.append((f"hpad_trunc_s{sym}_{cut}", [lit_h(full[:cut])]))
    for k in range(1, 5):
        cases.append((f"hpad_ff_x{k}", [lit_h(b"\xff" * k)]))

    # Integer edge cases (indexed representation)
    for idx in [0, 1, 61, 62, 126, 127, 128, 2**31 - 1, 2**31, 2**32 - 1, 2**32, 2**32 + 1, 2**32 + 2,
                2**32 + 61, 2**32 + 62, 2**33 + 4, 2**62, 2**63 - 1]:
        cases.append((f"int_idx_{idx}", [enc_int(idx, 7, 0x80)]))
    for idx in [2**32 + 1, 2**32 - 1, 2**31]:
        cases.append((f"int_litname_{idx}", [enc_int(idx, 6, 0x40) + b"\x01a"]))
        cases.append((f"int_neverName_{idx}", [enc_int(idx, 4, 0x10) + b"\x01a"]))
        cases.append((f"int_noidxName_{idx}", [enc_int(idx, 4, 0x00) + b"\x01a"]))
    for k in range(1, 13):
        cases.append((f"int_zero_cont_{k}", [b"\xff" + b"\x80" * k + b"\x00"]))  # overlong 127 + 0
        cases.append((f"int_ff_cont_{k}", [b"\xff" + b"\xff" * k + b"\x01"]))
    cases.append(("int_trunc_cont", [b"\xff\x80"]))
    cases.append(("int_strlen_2pow32", [b"\x00\x01x" + enc_int(2**32 + 1, 7, 0x00) + b"a"]))
    cases.append(("int_strlen_huge", [b"\x00\x01x" + enc_int(2**40, 7, 0x00)]))

    # Size update attacks
    lit_a = b"\x40\x01a\x01b"
    cases.append(("sz_after_field", [b"\x82" + enc_int(0, 5, 0x20)]))
    cases.append(("sz_multi_down_up", [enc_int(100, 5, 0x20) + enc_int(0, 5, 0x20) + enc_int(4096, 5, 0x20) + b"\x82"]))
    cases.append(("sz_over_settings", [enc_int(4097, 5, 0x20)]))
    cases.append(("sz_zero_then_ref", [lit_a, enc_int(0, 5, 0x20) + b"\xbe"]))
    cases.append(("sz_zero_up_then_ref", [lit_a, enc_int(0, 5, 0x20) + enc_int(4096, 5, 0x20) + b"\xbe"]))
    cases.append(("sz_shrink_evicts", [lit_a + b"\x40\x01c\x01d", enc_int(34, 5, 0x20) + b"\xbe\xbf"]))
    cases.append(("sz_second_block_ok", [lit_a, enc_int(2048, 5, 0x20) + b"\xbe"]))
    cases.append(("sz_after_field_second_block", [lit_a, b"\xbe" + enc_int(100, 5, 0x20)]))
    cases.append(("sz_2pow32", [enc_int(2**32, 5, 0x20)]))
    cases.append(("sz_many_at_start", [enc_int(4096, 5, 0x20) * 50 + b"\x82"]))

    with open(out_path, "w") as f:
        for name, blocks in cases:
            f.write(name + "\t" + ",".join(b.hex() for b in blocks) + "\n")
    print(f"{len(cases)} cases -> {out_path}")


if __name__ == "__main__":
    main()
