#!/usr/bin/env python3
"""Red-team differential harness for `packages/flate`.

Runs the same inputs through five decoders and compares verdict + output (length, CRC-32):

  pion        Pion native  (`audit/src/main.pion`, --release)
  pion_wasm   Pion wasm32  (same source, run under node + pion_wasm_rt.mjs)
  go          Go compress/{flate,zlib,gzip}
  rust        Rust flate2 1.1.11 rust_backend (miniz_oxide)
  python      CPython zlib (real zlib / zlib-ng)

Sections:
  vectors   hand-built RFC 1951/1950/1952 edge & malformed streams with an RFC-derived expectation
  fuzz      >= 20,000 mutated (bit flip / truncate / splice / byte set) streams: crash, hang, native-vs-wasm and
            cross-decoder disagreement detection
  compress  Pion deflate levels 0..9 over pathological corpora, decoded by Go / Rust / Python
  all       everything above

Usage: python3 difftest.py <section> [--out DIR] [--fuzz N] [--seed S]
Exit code is non-zero when any *defect* (expectation miss, crash, native/wasm mismatch, compress interop
failure) is found.  Pure "decoders disagree on an RFC-ambiguous input" rows are reported but not fatal.
"""
import argparse
import hashlib
import json
import os
import random
import struct
import subprocess
import sys
import time
import zlib
import gzip as pygzip

LIMIT = 16 * 1024 * 1024

# ---------------------------------------------------------------------------------------------------
# Bit-level stream builders
# ---------------------------------------------------------------------------------------------------


class BW:
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def bits(self, v, n):
        self.acc |= (v & ((1 << n) - 1)) << self.n
        self.n += n
        while self.n >= 8:
            self.out.append(self.acc & 0xFF)
            self.acc >>= 8
            self.n -= 8

    def huff(self, code, n):
        # Huffman codes are sent MSB-first
        r = 0
        for i in range(n):
            r = (r << 1) | ((code >> i) & 1)
        self.bits(r, n)

    def align(self, pad=0):
        if self.n:
            self.bits(pad, 8 - self.n)

    def raw(self, b):
        assert self.n == 0
        self.out += b

    def done(self):
        if self.n:
            self.out.append(self.acc & 0xFF)
            self.acc = 0
            self.n = 0
        return bytes(self.out)


def canon(lengths):
    """Canonical Huffman codes (RFC 1951 §3.2.2). Returns {sym: (code, len)}."""
    mx = max(lengths) if lengths else 0
    bl = [0] * (max(mx, 15) + 1)
    for l in lengths:
        if l:
            bl[l] += 1
    code = 0
    nxt = [0] * (len(bl) + 1)
    for b in range(1, len(bl)):
        code = (code + bl[b - 1]) << 1
        nxt[b] = code
    out = {}
    for s, l in enumerate(lengths):
        if l:
            out[s] = (nxt[l], l)
            nxt[l] += 1
    return out


FIX_LIT = [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8
FIX_DIST = [5] * 32
LBASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
LEXT = [0] * 8 + [1] * 4 + [2] * 4 + [3] * 4 + [4] * 4 + [5] * 4 + [0]
DBASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
         4097, 6145, 8193, 12289, 16385, 24577]
DEXT = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
CL_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]


def len_sym(L):
    for i in range(28, -1, -1):
        if L >= LBASE[i] and (i != 28 or L == 258):
            if i == 27 and L == 258:
                continue
            return i
    raise ValueError(L)


def dist_sym(D):
    for i in range(29, -1, -1):
        if D >= DBASE[i]:
            return i
    raise ValueError(D)


def emit_tokens(bw, toks, lit, dist):
    """toks: list of int literal, ('m', len, dist), ('sym', litsym) raw, ('dsym', sym) raw; then EOB unless 'noeob'."""
    for t in toks:
        if isinstance(t, int):
            bw.huff(*lit[t])
        elif t[0] == 'm':
            _, L, D = t
            li = len_sym(L)
            bw.huff(*lit[257 + li])
            if LEXT[li]:
                bw.bits(L - LBASE[li], LEXT[li])
            di = dist_sym(D)
            bw.huff(*dist[di])
            if DEXT[di]:
                bw.bits(D - DBASE[di], DEXT[di])
        elif t[0] == 'sym':
            bw.huff(*lit[t[1]])
        elif t[0] == 'dsym':
            bw.huff(*dist[t[1]])
        elif t[0] == 'eob':
            bw.huff(*lit[256])


def fixed_block(bw, toks, final=True, eob=True):
    bw.bits(1 if final else 0, 1)
    bw.bits(1, 2)
    lit, dist = canon(FIX_LIT), canon(FIX_DIST)
    emit_tokens(bw, toks + ([('eob',)] if eob else []), lit, dist)


def stored_block(bw, payload, final=True, pad=0, nlen=None):
    bw.bits(1 if final else 0, 1)
    bw.bits(0, 2)
    bw.align(pad)
    L = len(payload)
    bw.raw(struct.pack('<HH', L, (~L & 0xFFFF) if nlen is None else nlen))
    bw.raw(payload)


def dyn_block(bw, lit_lens, dist_lens, toks, final=True, cl_seq=None, hlit=None, hdist=None, cl_lens=None,
              eob=True, hclen=None):
    """Dynamic block. `cl_seq` overrides the code-length RLE sequence: list of (sym, extra_value)."""
    hlit = len(lit_lens) if hlit is None else hlit
    hdist = len(dist_lens) if hdist is None else hdist
    if cl_seq is None:
        cl_seq = [(l, None) for l in list(lit_lens) + list(dist_lens)]
    if cl_lens is None:
        freq = [0] * 19
        for s, _ in cl_seq:
            freq[s] += 1
        cl_lens = huff_lengths(freq, 7)
    if hclen is None:
        hclen = 19
        while hclen > 4 and cl_lens[CL_ORDER[hclen - 1]] == 0:
            hclen -= 1
    bw.bits(1 if final else 0, 1)
    bw.bits(2, 2)
    bw.bits(hlit - 257, 5)
    bw.bits(hdist - 1, 5)
    bw.bits(hclen - 4, 4)
    for i in range(hclen):
        bw.bits(cl_lens[CL_ORDER[i]], 3)
    clc = canon(cl_lens)
    for s, ex in cl_seq:
        bw.huff(*clc[s])
        if s == 16:
            bw.bits(ex, 2)
        elif s == 17:
            bw.bits(ex, 3)
        elif s == 18:
            bw.bits(ex, 7)
    lit = canon(list(lit_lens))
    dist = canon(list(dist_lens)) if any(dist_lens) else {}
    emit_tokens(bw, toks + ([('eob',)] if eob else []), lit, dist)


def huff_lengths(freq, maxbits):
    """Simple length-limited Huffman (heap + heuristic fix) good enough for building test vectors."""
    import heapq
    syms = [i for i, f in enumerate(freq) if f]
    L = [0] * len(freq)
    if not syms:
        return L
    if len(syms) == 1:
        L[syms[0]] = 1
        return L
    h = [(freq[s], i, [s]) for i, s in enumerate(syms)]
    heapq.heapify(h)
    cnt = len(h)
    while len(h) > 1:
        a = heapq.heappop(h)
        b = heapq.heappop(h)
        for s in a[2] + b[2]:
            L[s] += 1
        cnt += 1
        heapq.heappush(h, (a[0] + b[0], cnt, a[2] + b[2]))
    # clamp + repair Kraft
    for s in syms:
        L[s] = min(L[s], maxbits)
    while sum(2.0 ** -L[s] for s in syms) > 1.0:
        s = max((s for s in syms if L[s] < maxbits), key=lambda s: L[s])
        L[s] += 1
    return L


def lens(spec, n):
    """spec: dict sym->len."""
    a = [0] * n
    for k, v in spec.items():
        a[k] = v
    return a


def zlib_wrap(raw, data, cmf=0x78, flg=None, adler=None):
    if flg is None:
        flg = 0x9C
    adl = zlib.adler32(data) if adler is None else adler
    return bytes([cmf, flg]) + raw + struct.pack('>I', adl & 0xFFFFFFFF)


def fix_fcheck(cmf, flg):
    flg &= 0xE0
    r = (cmf * 256 + flg) % 31
    return flg + ((31 - r) % 31)


def gz_member(data, raw=None, flg=0, extra=None, name=None, comment=None, hcrc=None, crc=None, isize=None,
              magic=b'\x1f\x8b', cm=8):
    if raw is None:
        c = zlib.compressobj(6, zlib.DEFLATED, -15)
        raw = c.compress(data) + c.flush()
    h = bytearray(magic + bytes([cm, flg]) + b'\0\0\0\0' + b'\0\xff')
    if extra is not None:
        h += struct.pack('<H', len(extra)) + extra
    if name is not None:
        h += name
    if comment is not None:
        h += comment
    if flg & 2:
        h += struct.pack('<H', (zlib.crc32(bytes(h)) & 0xFFFF) if hcrc is None else hcrc)
    crcv = zlib.crc32(data) if crc is None else crc
    iz = len(data) if isize is None else isize
    return bytes(h) + raw + struct.pack('<II', crcv & 0xFFFFFFFF, iz & 0xFFFFFFFF)


def ok(data):
    return ('ok', len(data), zlib.crc32(data))


ERR = ('err',)
ANY = ('any',)  # RFC-ambiguous; record behaviour only


def raw_deflate(data, level=6):
    c = zlib.compressobj(level, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()


# ---------------------------------------------------------------------------------------------------
# Hand-built vectors.  Each: (id, op, bytes, expectation, note)
# ---------------------------------------------------------------------------------------------------


def build_vectors():
    V = []

    def add(vid, op, b, exp, note):
        V.append((vid, op, b, exp, note))

    hello = b'hello'
    # --- Dynamic tree shapes -------------------------------------------------------------------
    # literals h,e,l,o + EOB; distance tree with ZERO codes (HDIST=1, len 0): legal for literal-only blocks.
    lit = lens({ord('h'): 2, ord('e'): 2, ord('l'): 2, ord('o'): 3, 256: 3}, 257)
    bw = BW()
    dyn_block(bw, lit, [0], list(hello))
    add('D01_dist_tree_zero_codes', 'inflate', bw.done(), ok(hello), 'RFC1951 §3.2.7: one distance code of zero bits means no distance codes are used')

    bw = BW()
    dyn_block(bw, lit, [1], list(hello))
    add('D02_dist_tree_single_len1', 'inflate', bw.done(), ok(hello), 'single 1-bit distance code (zlib: incomplete allowed only for single length-1 code)')

    # single distance code with length 1 and it IS used
    lit2 = lens({ord('a'): 2, 256: 2, 257 + 0: 1}, 258)  # len sym 257 (len 3)
    bw = BW()
    dyn_block(bw, lit2, [1], [ord('a'), ('m', 3, 1)])
    add('D03_dist_single_len1_used', 'inflate', bw.done(), ok(b'aaaa'), 'single-symbol distance tree actually used')

    bw = BW()
    dyn_block(bw, lit, [2], list(hello))
    add('D04_dist_single_len2_incomplete', 'inflate', bw.done(), ANY, 'incomplete single distance code of length 2: zlib rejects, miniz accepts')

    # litlen with only EOB (single code length 1) -> empty output; emitted by some encoders for empty input
    bw = BW()
    dyn_block(bw, lens({256: 1}, 257), [0], [])
    add('D05_litlen_only_eob_len1', 'inflate', bw.done(), ok(b''), 'single-symbol litlen tree (EOB only, 1 bit)')

    # oversubscribed litlen
    bw = BW()
    dyn_block(bw, lens({ord('h'): 1, ord('e'): 1, ord('l'): 1, 256: 2, ord('o'): 2}, 257), [0], [])
    add('D06_litlen_oversubscribed', 'inflate', bw.done(), ERR, 'Kraft sum > 1')

    # incomplete (non-single) litlen
    bw = BW()
    dyn_block(bw, lens({ord('h'): 2, ord('e'): 2, 256: 2}, 257), [0], [ord('h')])
    add('D07_litlen_incomplete', 'inflate', bw.done(), ERR, 'incomplete multi-symbol litlen tree')

    # missing EOB: 256 has len 0
    bw = BW()
    l = lens({ord('h'): 1, ord('e'): 1}, 257)
    dyn_block(bw, l, [0], [ord('h')], eob=False)
    add('D08_missing_eob_len0', 'inflate', bw.done() + b'\0\0', ERR, 'code length of symbol 256 is zero')

    # 15-bit codes: lengths 1,2,...,14,15,15 (complete).  Use the two 15-bit codes.
    syms = [ord('a') + i for i in range(14)] + [256, ord('z')]
    ln = list(range(1, 15)) + [15, 15]
    l15 = lens(dict(zip(syms, ln)), 257)
    payload = [ord('z'), ord('a'), ord('n'), ord('z')]
    bw = BW()
    dyn_block(bw, l15, [0], payload)
    add('D09_15bit_codes', 'inflate', bw.done(), ok(bytes(payload)), 'longest legal code length 15 (second-level LUT)')

    # 15-bit distance codes
    dl = list(range(1, 15)) + [15, 15]  # 16 dist codes
    l = lens({ord('q'): 1, 256: 2, 257: 2}, 258)
    bw = BW()
    toks = [ord('q')] * 3 + [('m', 3, 1)]
    dyn_block(bw, l, dl, toks)
    add('D10_15bit_dist_codes', 'inflate', bw.done(), ok(b'q' * 6), 'distance tree depth 15 (subtable path for distance)')

    # HLIT = 287/288 (HLIT field 30/31)
    for hl in (287, 288):
        bw = BW()
        l = lens({ord('h'): 1, 256: 1}, hl)
        dyn_block(bw, l, [0], [ord('h')])
        add(f'D11_hlit_{hl}', 'inflate', bw.done(), ERR, 'HLIT > 286 must be rejected')
    for hd in (31, 32):
        bw = BW()
        l = lens({ord('h'): 1, 256: 1}, 257)
        dyn_block(bw, l, lens({0: 1, 1: 1}, hd), [ord('h')])
        add(f'D12_hdist_{hd}', 'inflate', bw.done(), ERR, 'HDIST > 30 must be rejected')

    # RLE code-length runs crossing the HLIT|HDIST boundary (RFC 1951 §3.2.7: allowed).
    # litlen: 'a'=1, 256..259=3 ; dist: 3,3,2,1.  The repeat-16 after symbol 256 copies "3" into
    # litlen 257,258,259 AND distance 0 -> a single run spans the boundary.
    l = lens({ord('a'): 1, 256: 3, 257: 3, 258: 3, 259: 3}, 260)
    d = [3, 3, 2, 1]
    seq = [(18, ord('a') - 11), (1, None), (18, 138 - 11), (18, 20 - 11), (3, None), (16, 4 - 3), (3, None),
           (2, None), (1, None)]
    bw = BW()
    dyn_block(bw, l, d, [ord('a'), ('m', 3, 1), ('m', 4, 2), ('m', 5, 3)], cl_seq=seq)
    add('D13_rle16_crosses_hlit_hdist', 'inflate', bw.done(), ok(b'a' * 13), 'repeat-16 run spans last litlen and first distance length (RFC 1951 §3.2.7)')

    # 17/18 zero run crossing boundary: litlen tail zeros + leading dist zeros
    l = lens({ord('a'): 1, 256: 1}, 286)
    d = [0] * 29 + [1]
    seq = [(18, ord('a') - 11), (1, None), (18, 138 - 11), (18, 20 - 11), (1, None),
           (18, (29 + 29) - 11), (1, None)]  # 257..285 = 29 zeros + 29 dist zeros = 58
    bw = BW()
    dyn_block(bw, l, d, [ord('a')], cl_seq=seq)
    add('D14_rle18_crosses_hlit_hdist', 'inflate', bw.done(), ok(b'a'), 'repeat-18 zero run spans HLIT/HDIST boundary')

    # repeat 16 at index 0
    l = lens({0: 1, 256: 1}, 257)
    seq = [(16, 0)] + [(0, None)] * 0
    bw = BW()
    dyn_block(bw, l, [0], [], cl_seq=[(16, 0), (1, None)], cl_lens=lens({16: 1, 1: 1}, 19))
    add('D15_rle16_at_index0', 'inflate', bw.done() + b'\0' * 64, ERR, 'repeat-previous with no previous length')

    # repeat 18 overflows HLIT+HDIST
    bw = BW()
    dyn_block(bw, lens({0: 1, 256: 1}, 257), [0], [], cl_seq=[(1, None), (18, 127), (18, 127), (18, 127)],
              cl_lens=lens({18: 1, 1: 1}, 19))
    add('D16_rle18_overflow', 'inflate', bw.done() + b'\0' * 64, ERR, 'code-length repeat runs past HLIT+HDIST')

    # incomplete code-length (CL) tree
    bw = BW()
    l = lens({ord('h'): 1, 256: 1}, 257)
    dyn_block(bw, l, [0], [ord('h')], cl_lens=lens({0: 2, 1: 2, 18: 2}, 19))
    add('D17_cl_tree_incomplete', 'inflate', bw.done(), ERR, 'incomplete code-length code (3 codes of length 2)')

    # all-zero CL tree
    bw = BW()
    bw.bits(1, 1); bw.bits(2, 2); bw.bits(0, 5); bw.bits(0, 5); bw.bits(15, 4)
    for _ in range(19):
        bw.bits(0, 3)
    add('D18_cl_tree_empty', 'inflate', bw.done() + b'\0' * 64, ERR, 'all code-length code lengths zero')

    # distance symbol used while distance tree is empty
    bw = BW()
    l = lens({ord('a'): 2, 256: 2, 257: 1}, 258)
    dyn_block(bw, l, [0], [ord('a'), ('sym', 257)], eob=False)
    add('D19_dist_used_with_empty_tree', 'inflate', bw.done() + b'\0' * 8, ERR, 'length symbol with an empty distance tree')

    # --- Stored blocks -----------------------------------------------------------------------
    bw = BW()
    stored_block(bw, b'abc', nlen=0x1234)
    add('S01_stored_nlen_mismatch', 'inflate', bw.done(), ERR, 'LEN != ~NLEN')
    bw = BW()
    stored_block(bw, b'abc', pad=0x1F)
    add('S02_stored_nonzero_pad', 'inflate', bw.done(), ok(b'abc'), 'non-zero padding bits before LEN are ignored (RFC: "ignored")')
    bw = BW()
    stored_block(bw, b'')
    add('S03_stored_empty', 'inflate', bw.done(), ok(b''), 'empty stored block')
    bw = BW()
    stored_block(bw, b'abcdef')
    add('S04_stored_truncated', 'inflate', bw.done()[:-2], ERR, 'stored payload truncated')
    bw = BW()
    stored_block(bw, os.urandom(65535) if False else bytes(range(256)) * 255 + bytes(255))
    add('S05_stored_65535', 'inflate', bw.done(), ok(bytes(range(256)) * 255 + bytes(255)), 'maximum stored block length')

    # --- Block type / symbols ---------------------------------------------------------------
    bw = BW(); bw.bits(1, 1); bw.bits(3, 2)
    add('B01_btype_11', 'inflate', bw.done() + b'\0' * 8, ERR, 'reserved BTYPE=11')
    for s in (286, 287):
        bw = BW(); fixed_block(bw, [ord('x'), ('sym', s)], eob=False)
        add(f'B02_fixed_litlen_{s}', 'inflate', bw.done() + b'\0' * 8, ERR, f'fixed literal/length symbol {s} never valid')
    for s in (30, 31):
        bw = BW(); fixed_block(bw, [ord('x'), ('sym', 257), ('dsym', s)], eob=False)
        add(f'B03_fixed_dist_{s}', 'inflate', bw.done() + b'\0' * 8, ERR, f'fixed distance symbol {s} never valid')

    # distances
    bw = BW(); fixed_block(bw, [ord('x'), ('m', 3, 2)])
    add('W01_dist_gt_output', 'inflate', bw.done(), ERR, 'distance 2 with 1 byte of history')
    bw = BW(); fixed_block(bw, [('m', 3, 1)])
    add('W02_dist_at_start', 'inflate', bw.done(), ERR, 'back-reference before any output')
    bw = BW(); fixed_block(bw, [ord('x'), ord('y'), ('m', 3, 2)])
    add('W03_dist_eq_output', 'inflate', bw.done(), ok(b'xyxyx'), 'distance exactly equal to output length')
    for dd in (1, 2, 3, 7):
        seed = bytes((ord('a') + i) for i in range(dd))
        bw = BW(); fixed_block(bw, list(seed) + [('m', 258, dd)] * 4)
        exp = (seed * ((dd + 258 * 4) // dd + 2))[:dd + 258 * 4]
        add(f'W04_overlap_dist{dd}_len258x4', 'inflate', bw.done(), ok(exp), 'overlapping copy dist < len')

    # 32 KiB window across Stored + Fixed + Dynamic blocks
    rnd = random.Random(1951)
    first = bytes(rnd.randrange(256) for _ in range(32768))
    bw = BW()
    stored_block(bw, first[:20000], final=False)
    fixed_block(bw, list(first[20000:20010]), final=False)
    # dynamic block that copies from distance 32768 (start of the stored block) and from 32768 at end
    stored_block(bw, first[20010:], final=False)
    dl = [0] * 30
    dl[29] = 1
    dl[0] = 1
    l = lens({256: 1, 257 + 28: 1}, 286)
    dyn_block(bw, l, dl, [('m', 258, 32768), ('m', 258, 32768)])
    exp = bytearray(first)
    for _ in range(516):
        exp.append(exp[-32768])
    add('W05_window_32768_mixed_blocks', 'inflate', bw.done(), ok(bytes(exp)), 'max distance 32768 reaching back through stored+fixed+stored blocks into a dynamic block')
    bw = BW()
    stored_block(bw, first[:32767], final=False)
    fixed_block(bw, [('m', 3, 32768)])
    add('W06_dist_32768_one_short', 'inflate', bw.done(), ERR, 'distance 32768 with only 32767 bytes of history')

    # many empty blocks
    bw = BW()
    for _ in range(5000):
        fixed_block(bw, [], final=False)
    fixed_block(bw, list(b'end'))
    add('M01_5000_empty_fixed_blocks', 'inflate', bw.done(), ok(b'end'), '5000 empty non-final fixed blocks')
    bw = BW()
    for _ in range(5000):
        stored_block(bw, b'', final=False)
    stored_block(bw, b'end')
    add('M02_5000_empty_stored_blocks', 'inflate', bw.done(), ok(b'end'), '5000 empty non-final stored blocks')

    # no final block
    bw = BW(); fixed_block(bw, list(b'abc'), final=False)
    add('M03_no_final_block', 'inflate', bw.done(), ERR, 'stream ends without BFINAL=1')
    # trailing garbage after a raw stream
    add('M04_trailing_garbage_raw', 'inflate', raw_deflate(b'payload') + b'GARBAGE', ok(b'payload'), 'raw DEFLATE: bytes after final block are not part of the stream (all reference decoders ignore)')
    add('M05_empty_input', 'inflate', b'', ERR, 'empty input')

    # --- zlib ---------------------------------------------------------------------------------
    raw = raw_deflate(b'zlib payload')
    zp = b'zlib payload'
    add('Z01_valid', 'zlib', zlib_wrap(raw, zp), ok(zp), 'control')
    add('Z02_cm7', 'zlib', zlib_wrap(raw, zp, cmf=0x77, flg=fix_fcheck(0x77, 0x80)), ERR, 'CM != 8')
    add('Z03_cinfo8', 'zlib', zlib_wrap(raw, zp, cmf=0x88, flg=fix_fcheck(0x88, 0x80)), ERR, 'CINFO > 7')
    add('Z04_fcheck_bad', 'zlib', zlib_wrap(raw, zp, flg=0x9D), ERR, 'FCHECK mismatch')
    add('Z05_fdict_no_dict', 'zlib', bytes([0x78, fix_fcheck(0x78, 0xA0)]) + struct.pack('>I', zlib.adler32(b'dict')) + raw + struct.pack('>I', zlib.adler32(zp)), ERR, 'FDICT set but no dictionary supplied')
    add('Z06_adler_bad', 'zlib', zlib_wrap(raw, zp, adler=zlib.adler32(zp) ^ 1), ERR, 'Adler-32 mismatch')
    add('Z07_adler_truncated', 'zlib', zlib_wrap(raw, zp)[:-1], ERR, 'Adler-32 trailer truncated')
    add('Z08_trailing_garbage', 'zlib', zlib_wrap(raw, zp) + b'XYZ', ANY, 'bytes after Adler-32 (RFC 1950 silent; Python errors? Go/Rust ignore)')
    add('Z09_empty_raw_min', 'zlib', bytes([0x78, 0x9c, 3, 0, 0, 0, 0, 1]), ok(b''), 'smallest legal zlib stream (8 bytes)')
    add('Z10_cinfo0_256B_window', 'zlib', zlib_wrap(raw, zp, cmf=0x08, flg=fix_fcheck(0x08, 0x80)), ok(zp), 'CINFO=0 (256-byte window) with short data is valid')
    # CINFO small but stream references a distance beyond window size: RFC says invalid; most decoders don't police
    far = b'A' * 300 + b'B'
    rawf = BW(); fixed_block(rawf, list(far) + [('m', 3, 300)])
    farexp = far + b'AAA'
    add('Z11_cinfo0_dist_gt_window', 'zlib', zlib_wrap(rawf.done(), farexp, cmf=0x08, flg=fix_fcheck(0x08, 0x80)), ANY, 'CINFO=0 declares 256 B window, stream uses distance 300')

    # --- gzip -----------------------------------------------------------------------------------
    gp = b'gzip payload'
    add('G01_valid', 'gzip', gz_member(gp), ok(gp), 'control')
    add('G02_bad_magic', 'gzip', gz_member(gp, magic=b'\x1f\x8c'), ERR, 'magic != 1f 8b')
    add('G03_cm7', 'gzip', gz_member(gp, cm=7), ERR, 'CM != 8')
    for bit in (0x20, 0x40, 0x80):
        add(f'G04_reserved_flg_{bit:02x}', 'gzip', gz_member(gp, flg=bit), ERR, 'reserved FLG bits must be rejected (RFC 1952 §2.3.1.2)')
    add('G05_fextra_truncated', 'gzip', gz_member(gp, flg=4, extra=b'AB')[:10] + b'\xff\x7f' + b'xx', ERR, 'XLEN larger than remaining input')
    add('G06_fextra_ok', 'gzip', gz_member(gp, flg=4, extra=b'AP\x02\x00hi'), ok(gp), 'FEXTRA subfield')
    add('G07_fname_unterminated', 'gzip', gz_member(b'', raw=b'', flg=8, name=b'no-nul-here'), ERR, 'FNAME without NUL terminator')
    add('G08_fname_latin1', 'gzip', gz_member(gp, flg=8, name=b'caf\xe9.txt\0'), ok(gp), 'FNAME in ISO-8859-1 (0xE9) - mandated charset')
    add('G09_fcomment_ctrl', 'gzip', gz_member(gp, flg=16, comment=b'line1\nline2\x01\x7f\xff\0'), ok(gp), 'FCOMMENT with control / high bytes')
    add('G10_fhcrc_ok', 'gzip', gz_member(gp, flg=2 | 8, name=b'n\0'), ok(gp), 'FHCRC correct')
    add('G11_fhcrc_bad', 'gzip', gz_member(gp, flg=2, hcrc=0xBEEF), ERR, 'FHCRC mismatch')
    add('G12_crc_bad', 'gzip', gz_member(gp, crc=zlib.crc32(gp) ^ 1), ERR, 'CRC-32 mismatch')
    add('G13_isize_bad', 'gzip', gz_member(gp, isize=len(gp) + 1), ERR, 'ISIZE mismatch')
    add('G14_two_members', 'gzip', gz_member(b'one,') + gz_member(b'two'), ok(b'one,two'), 'concatenated members')
    add('G15_empty_member_between', 'gzip', gz_member(b'one,') + gz_member(b'') + gz_member(b'two'), ok(b'one,two'), 'empty member between members')
    add('G16_bad_second_member', 'gzip', gz_member(b'one,') + gz_member(b'two', crc=1), ERR, 'second member CRC mismatch')
    add('G17_truncated_second_member', 'gzip', gz_member(b'one,') + gz_member(b'two')[:15], ERR, 'second member truncated')
    add('G18_trailing_garbage', 'gzip', gz_member(gp) + b'GARBAGE!', ANY, 'non-gzip bytes after last member (gzip(1): warning; Go: error; miniz MultiGz: error)')
    add('G19_trailing_zeros', 'gzip', gz_member(gp) + b'\0' * 512, ANY, 'zero padding after last member (tape/block padding; gzip(1) ignores)')
    add('G20_header_only', 'gzip', gz_member(gp)[:10], ERR, 'header only')
    add('G21_min_empty_member', 'gzip', gz_member(b'', raw=b'\x03\x00'), ok(b''), 'smallest legal gzip member (20 bytes)')
    add('G22_isize_mod_2_32', 'gzip', gz_member(gp, isize=len(gp) + (1 << 32)), ok(gp), 'ISIZE is size mod 2^32 (same 4 bytes)')
    add('G23_trailing_1_byte', 'gzip', gz_member(gp) + b'\x1f', ANY, 'single stray byte after last member')
    return V


# ---------------------------------------------------------------------------------------------------
# Runners
# ---------------------------------------------------------------------------------------------------


def pack(cases):
    return b''.join(struct.pack('<I', len(c)) + c for c in cases)


def py_decode(op, data, limit=LIMIT):
    try:
        if op == 'gzip':
            out = pygzip.decompress(data)
            if len(out) > limit:
                return ('err', 'OutputLimitExceeded')
            return ('ok', len(out), zlib.crc32(out))
        wbits = -15 if op == 'inflate' else 15
        d = zlib.decompressobj(wbits)
        out = d.decompress(data, limit + 1)
        if len(out) > limit:
            return ('err', 'OutputLimitExceeded')
        if not d.eof:
            out += d.flush()
            if not d.eof:
                return ('err', 'incomplete')
        return ('ok', len(out), zlib.crc32(out))
    except Exception as e:  # noqa
        return ('err', type(e).__name__ + ':' + str(e).replace(' ', '_')[:60])


class Tools:
    def __init__(self, out):
        self.out = out
        b = os.path.join(out, 'bin')
        rt = os.path.expanduser('~/.pion/share/pion/pion_wasm_rt.mjs')
        self.cmds = {
            'pion': [os.path.join(b, 'pion_audit')],
            'pion_wasm': ['node', rt, os.path.join(b, 'pion_audit.wasm')],
            'go': [os.path.join(b, 'go_audit')],
            'rust': [os.path.join(b, 'rust_audit')],
        }

    def batch(self, name, op, cases, limit=LIMIT, timeout=600):
        path = os.path.join(self.out, f'cases_{name}_{op}.bin')
        with open(path, 'wb') as f:
            f.write(pack(cases))
        t0 = time.time()
        try:
            p = subprocess.run(self.cmds[name] + ['batch', op, path, str(limit)], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=timeout)
        except subprocess.TimeoutExpired:
            return None, 'TIMEOUT', time.time() - t0
        lines = p.stdout.decode('latin-1').splitlines()
        res = []
        for ln in lines:
            parts = ln.split(' ')
            if parts[0] == 'OK':
                res.append(('ok', int(parts[1]), int(parts[2])))
            else:
                res.append(('err', parts[1] if len(parts) > 1 else ''))
        status = f'rc={p.returncode}'
        if p.returncode != 0 or len(res) != len(cases):
            status += f' CRASH lines={len(res)}/{len(cases)} stderr={p.stderr.decode("latin-1")[-300:]!r}'
        return res, status, time.time() - t0


def verdict_key(r):
    return r[:3] if r[0] == 'ok' else ('err',)


# ---------------------------------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------------------------------


def section_vectors(tools, report):
    V = build_vectors()
    impls = ['pion', 'pion_wasm', 'go', 'rust']
    results = {}
    for op in ('inflate', 'zlib', 'gzip'):
        sub = [v for v in V if v[1] == op]
        for impl in impls:
            res, status, _ = tools.batch(impl, op, [v[2] for v in sub])
            if res is None or 'CRASH' in status:
                report['defects'].append(f'vectors/{op}/{impl}: {status}')
                res = (res or []) + [('err', 'CRASH')] * (len(sub) - len(res or []))
            for v, r in zip(sub, res):
                results.setdefault(v[0], {})[impl] = r
        for v in sub:
            results[v[0]]['python'] = py_decode(op, v[2])
    rows = []
    for vid, op, b, exp, note in V:
        r = results[vid]
        pion = r['pion']
        miss = False
        if exp[0] == 'ok':
            miss = verdict_key(pion) != exp
        elif exp[0] == 'err':
            miss = pion[0] != 'err'
        if verdict_key(r['pion']) != verdict_key(r['pion_wasm']):
            report['defects'].append(f'{vid}: native {r["pion"]} != wasm {r["pion_wasm"]}')
        refs = {k: verdict_key(r[k]) for k in ('go', 'rust', 'python')}
        rows.append({'id': vid, 'op': op, 'expect': exp[0], 'note': note,
                     'pion': fmt(r['pion']), 'wasm': fmt(r['pion_wasm']), 'go': fmt(r['go']),
                     'rust': fmt(r['rust']), 'python': fmt(r['python']), 'pion_meets_rfc': not miss,
                     'pion_vs_refs': 'same' if all(verdict_key(pion) == x for x in refs.values()) else 'DIFF'})
        if miss:
            report['defects'].append(f'{vid}: expected {exp[0]} got {fmt(pion)} ({note})')
    report['vectors'] = rows
    print_table(rows)


def fmt(r):
    if r[0] == 'ok':
        return f'OK({r[1]})'
    return 'ERR:' + str(r[1])[:28]


def print_table(rows):
    print(f'{"id":34s} {"exp":4s} {"pion":22s} {"wasm":10s} {"go":22s} {"rust":22s} {"python":22s} rfc  refs')
    for r in rows:
        print(f'{r["id"]:34s} {r["expect"]:4s} {r["pion"][:22]:22s} {("=" if r["wasm"] == r["pion"] else r["wasm"])[:10]:10s} '
              f'{r["go"][:22]:22s} {r["rust"][:22]:22s} {r["python"][:22]:22s} {"ok " if r["pion_meets_rfc"] else "BAD"}  {r["pion_vs_refs"]}')


def seeds():
    rnd = random.Random(7)
    texts = [
        b'',
        b'a',
        b'hello, world! ' * 40,
        bytes(rnd.randrange(256) for _ in range(3000)),
        (b'<div class="x">lorem ipsum</div>\n' * 120),
        bytes(rnd.choice(b'ACGT') for _ in range(5000)),
        b'\0' * 70000,
        bytes(range(256)) * 20,
    ]
    out = []
    for t in texts:
        for lvl in (0, 1, 6, 9):
            out.append(('inflate', raw_deflate(t, lvl)))
        out.append(('inflate', fixed_only(t)))
        out.append(('zlib', zlib.compress(t, 6)))
        out.append(('gzip', gz_member(t, flg=2 | 4 | 8 | 16, extra=b'XY\x01\x00z', name=b'f\0', comment=b'c\0')))
        out.append(('gzip', gz_member(t) + gz_member(t[:50])))
    return out


def fixed_only(t):
    c = zlib.compressobj(6, zlib.DEFLATED, -15, 9, zlib.Z_FIXED)
    return c.compress(t) + c.flush()


def mutate(rnd, b):
    b = bytearray(b)
    k = rnd.randrange(7)
    if not b:
        return bytes(rnd.randrange(256) for _ in range(rnd.randrange(1, 16)))
    if k <= 2:
        for _ in range(rnd.randrange(1, 4)):
            i = rnd.randrange(len(b))
            b[i] ^= 1 << rnd.randrange(8)
    elif k == 3:
        b = b[:rnd.randrange(len(b))]
    elif k == 4:
        i = rnd.randrange(len(b))
        b[i] = rnd.choice([0, 0xFF, 0x7F, 0x80, rnd.randrange(256)])
    elif k == 5:
        i = rnd.randrange(len(b))
        j = rnd.randrange(len(b))
        b[i:i] = b[j:j + rnd.randrange(1, 9)]
    else:
        i = rnd.randrange(len(b))
        del b[i:i + rnd.randrange(1, 9)]
    return bytes(b)


def section_fuzz(tools, report, n, seed):
    rnd = random.Random(seed)
    base = seeds()
    by_op = {'inflate': [], 'zlib': [], 'gzip': []}
    for i in range(n):
        op, b = base[rnd.randrange(len(base))]
        m = b
        for _ in range(rnd.randrange(1, 3)):
            m = mutate(rnd, m)
        by_op[op].append(m)
    summary = {}
    for op, cases in by_op.items():
        res = {}
        for impl in ('pion', 'pion_wasm', 'go', 'rust'):
            r, status, dt = tools.batch(impl, op, cases, timeout=900)
            res[impl] = r
            summary[f'{op}/{impl}'] = {'cases': len(cases), 'status': status, 'seconds': round(dt, 2)}
            if r is None or 'CRASH' in status:
                report['defects'].append(f'fuzz/{op}/{impl}: {status}')
        py = [py_decode(op, c) for c in cases]
        nat, wasm = res['pion'] or [], res['pion_wasm'] or []
        mism = sum(1 for a, b in zip(nat, wasm) if verdict_key(a) != verdict_key(b))
        if mism:
            report['defects'].append(f'fuzz/{op}: {mism} native-vs-wasm mismatches')
        # cross-decoder: count cases where pion disagrees with unanimous refs
        dis = []
        stats = {'pion_ok': 0, 'pion_err': 0, 'refs_unanimous': 0, 'pion_vs_unanimous_refs': 0}
        for i, c in enumerate(cases):
            p = verdict_key(nat[i]) if i < len(nat) else ('err',)
            stats['pion_ok' if p[0] == 'ok' else 'pion_err'] += 1
            refs = [verdict_key(res['go'][i]), verdict_key(res['rust'][i]), verdict_key(py[i])]
            if refs[0] == refs[1] == refs[2]:
                stats['refs_unanimous'] += 1
                if p != refs[0]:
                    stats['pion_vs_unanimous_refs'] += 1
                    if len(dis) < 8:
                        dis.append({'hex': c.hex()[:400], 'len': len(c), 'pion': fmt(nat[i]), 'refs': fmt(res['go'][i])})
        summary[f'{op}/diff'] = stats
        summary[f'{op}/native_vs_wasm_mismatch'] = mism
        if dis:
            summary[f'{op}/examples'] = dis
            save = os.path.join(tools.out, f'fuzz_disagree_{op}.json')
            json.dump(dis, open(save, 'w'), indent=1)
        if stats['pion_vs_unanimous_refs']:
            report['defects'].append(f'fuzz/{op}: pion disagrees with unanimous Go+Rust+Python on {stats["pion_vs_unanimous_refs"]} cases')
    report['fuzz'] = summary
    print(json.dumps(summary, indent=1)[:6000])


def fib_corpus():
    # literal frequencies follow Fibonacci numbers -> optimal Huffman depth = #symbols-1 (forces 15-bit limiting)
    fib = [1, 1]
    while len(fib) < 25:
        fib.append(fib[-1] + fib[-2])
    syms = []
    for i, f in enumerate(fib[:22]):
        syms += [i * 11 + 1] * f
    rnd = random.Random(42)
    rnd.shuffle(syms)
    # shuffle prevents LZ77 matches dominating; keep < 32768 tokens per block by size
    return bytes(syms[:40000])


def corpora():
    rnd = random.Random(12)
    c = {
        'empty': b'',
        'one_byte': b'Z',
        'zeros_1MiB': b'\0' * (1 << 20),
        'random_256KiB': bytes(rnd.getrandbits(8) for _ in range(256 * 1024)),
        'repeat_long_100KiB': (b'The quick brown fox jumps over the lazy dog; ' * 2400)[:100 * 1024],
        'beyond_window_96KiB': (bytes(rnd.getrandbits(8) for _ in range(40000)) * 3)[:96 * 1024],
        'fibonacci_freqs': fib_corpus(),
        'abc_3byte_1MiB': b'abc' * (1 << 18),
        'small_alphabet_512KiB': bytes(rnd.choice(b'ab') for _ in range(512 * 1024)),
        'text_json_mix': json.dumps([{'id': i, 'name': f'user{i}', 'tags': ['a', 'b', str(i % 7)]} for i in range(6000)]).encode(),
    }
    return c


def section_compress(tools, report):
    cs = corpora()
    names = list(cs)
    rows = []
    allok = True
    for lvl in range(10):
        path = os.path.join(tools.out, 'corpora.bin')
        with open(path, 'wb') as f:
            f.write(pack([cs[k] for k in names]))
        outp = os.path.join(tools.out, f'pion_l{lvl}.bin')
        t0 = time.time()
        p = subprocess.run(tools.cmds['pion'] + ['compress', str(lvl), path, outp], capture_output=True, timeout=600)
        dt = time.time() - t0
        if p.returncode != 0:
            report['defects'].append(f'compress L{lvl}: pion exit {p.returncode} {p.stderr[-200:]!r}')
            allok = False
            continue
        blob = open(outp, 'rb').read()
        comp = []
        q = 0
        while q + 4 <= len(blob):
            ln = struct.unpack_from('<I', blob, q)[0]
            comp.append(blob[q + 4:q + 4 + ln])
            q += 4 + ln
        dec = {impl: tools.batch(impl, 'inflate', comp)[0] for impl in ('pion', 'go', 'rust')}
        for i, k in enumerate(names):
            want = ('ok', len(cs[k]), zlib.crc32(cs[k]))
            py = py_decode('inflate', comp[i], 1 << 30)
            got = {'python': verdict_key(py), 'go': verdict_key(dec['go'][i]), 'rust': verdict_key(dec['rust'][i]),
                   'pion': verdict_key(dec['pion'][i])}
            bad = [n for n, g in got.items() if g != want]
            if bad:
                allok = False
                report['defects'].append(f'compress L{lvl} {k}: not decodable/identical by {bad}')
            zl = len(zlib.compress(cs[k], lvl)) - 6 if True else 0
            rows.append({'level': lvl, 'corpus': k, 'in': len(cs[k]), 'pion': len(comp[i]), 'zlib': zl,
                         'interop': 'OK' if not bad else 'FAIL:' + ','.join(bad)})
        rows.append({'level': lvl, 'corpus': '(batch wall seconds)', 'in': 0, 'pion': round(dt, 3), 'zlib': 0, 'interop': ''})
    report['compress'] = rows
    for r in rows:
        print(f'L{r["level"]} {r["corpus"]:24s} in={r["in"]:8d} pion={r["pion"]:>9} zlib={r["zlib"]:8d} {r["interop"]}')
    return allok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('section', choices=['vectors', 'fuzz', 'compress', 'all'])
    ap.add_argument('--out', default=os.environ.get('AUDIT_OUT', '/private/tmp/pion-flate-audit'))
    ap.add_argument('--fuzz', type=int, default=24000)
    ap.add_argument('--seed', type=int, default=20261123)
    a = ap.parse_args()
    tools = Tools(a.out)
    report = {'defects': []}
    if a.section in ('vectors', 'all'):
        section_vectors(tools, report)
    if a.section in ('compress', 'all'):
        section_compress(tools, report)
    if a.section in ('fuzz', 'all'):
        section_fuzz(tools, report, a.fuzz, a.seed)
    json.dump(report, open(os.path.join(a.out, f'difftest_{a.section}.json'), 'w'), indent=1)
    print('\nDEFECTS (%d):' % len(report['defects']))
    for d in report['defects']:
        print('  - ' + d)
    sys.exit(1 if report['defects'] else 0)


if __name__ == '__main__':
    main()
