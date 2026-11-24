#!/usr/bin/env python3
"""RT-zstd independent RFC 8878 model (stdlib only, written from the RFC text, not from packages/zstd/src).

Two halves:
  * `decode(data, ...)`  - a strict reference decoder: frames, skippable frames, Raw/RLE/Compressed blocks, all
    four literals types, Direct and FSE-compressed Huffman weights, 1 and 4 streams, Predefined / RLE /
    FSE_Compressed / Repeat sequence modes, repeat offsets, xxHash64 checksums. It also records which format
    features each input exercised (`features`), so the corpus coverage claims of REPORT.md are measured.
  * a frame *writer* (`frame`, `block`, `lits_*`, `SeqWriter`) that can emit every field of the format with any
    value, valid or not, used by gen.py to hand-craft the adversarial streams.
Errors raise ZErr(kind, msg); kind is one of the packages/zstd ZstdError variant names, so the model and the Pion
decoder can be compared by variant as well as by OK / ERR.
usage as a script: zmodel.py selftest
"""
import sys

M64 = (1 << 64) - 1
P1, P2, P3, P4, P5 = (0x9E3779B185EBCA87, 0xC2B2AE3D27D4EB4F, 0x165667B19E3779F9, 0x85EBCA77C2B2AE63,
                      0x27D4EB2F165667C5)


def _rotl(x, r):
    return ((x << r) | (x >> (64 - r))) & M64


def _round(acc, v):
    return (_rotl((acc + v * P2) & M64, 31) * P1) & M64


def xxh64(data, seed=0):
    """XXH64 from the xxHash specification (unsigned 64-bit, logical shifts)."""
    seed &= M64
    n = len(data)
    p = 0
    if n >= 32:
        v = [(seed + P1 + P2) & M64, (seed + P2) & M64, seed, (seed - P1) & M64]
        while p + 32 <= n:
            for i in range(4):
                v[i] = _round(v[i], int.from_bytes(data[p + 8 * i:p + 8 * i + 8], "little"))
            p += 32
        h = (_rotl(v[0], 1) + _rotl(v[1], 7) + _rotl(v[2], 12) + _rotl(v[3], 18)) & M64
        for x in v:
            h = ((h ^ _round(0, x)) * P1 + P4) & M64
    else:
        h = (seed + P5) & M64
    h = (h + n) & M64
    while p + 8 <= n:
        h = (_rotl(h ^ _round(0, int.from_bytes(data[p:p + 8], "little")), 27) * P1 + P4) & M64
        p += 8
    if p + 4 <= n:
        h = (_rotl(h ^ ((int.from_bytes(data[p:p + 4], "little") * P1) & M64), 23) * P2 + P3) & M64
        p += 4
    while p < n:
        h = (_rotl(h ^ ((data[p] * P5) & M64), 11) * P1) & M64
        p += 1
    h ^= h >> 33
    h = (h * P2) & M64
    h ^= h >> 29
    h = (h * P3) & M64
    h ^= h >> 32
    return h


def fnv64(data):
    h = 14695981039346656037
    for b in data:
        h = ((h ^ b) * 1099511628211) & M64
    return h


class ZErr(Exception):
    def __init__(self, kind, msg=""):
        Exception.__init__(self, kind + ": " + msg)
        self.kind = kind


LL_BASE = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256,
           512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
LL_BITS = [0] * 16 + [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
ML_BASE = list(range(3, 35)) + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195,
                                16387, 32771, 65539]
ML_BITS = [0] * 32 + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
PRE_LL = [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1,
          -1]
PRE_OF = [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1]
PRE_ML = [1, 4, 3, 2, 2, 2, 2, 2, 2] + [1] * 37 + [-1] * 7
MAXSYM = {"ll": 35, "of": 31, "ml": 52}
MAXLOG = {"ll": 9, "of": 8, "ml": 9}


def hb(v):
    return v.bit_length() - 1


# ---------------------------------------------------------------- FSE
class Fse:
    """Decoding table. sym/nb/base per state; `enc[s]` = [(lo, hi, state)] ranges for the writer."""

    def __init__(self, norm, alog, rle=None):
        if rle is not None:
            self.alog, self.sym, self.nb, self.base, self.norm = 0, [rle], [0], [0], None
            self.rle = rle
            return
        self.rle = None
        self.norm, self.alog = list(norm), alog
        size = 1 << alog
        if sum(1 if p == -1 else p for p in norm) != size or any(p < -1 for p in norm):
            raise ZErr("InvalidFseTable", "probability sum")
        mask, step = size - 1, (size >> 1) + (size >> 3) + 3
        sym = [0] * size
        high = size - 1
        nxt = [0] * len(norm)
        for s, p in enumerate(norm):
            if p == -1:
                sym[high] = s
                high -= 1
                nxt[s] = 1
            elif p > 0:
                nxt[s] = p
        pos = 0
        for s, p in enumerate(norm):
            for _ in range(max(p, 0)):
                sym[pos] = s
                pos = (pos + step) & mask
                while pos > high:
                    pos = (pos + step) & mask
        if pos != 0:
            raise ZErr("InvalidFseTable", "spread")
        self.sym, self.nb, self.base = sym, [0] * size, [0] * size
        for i in range(size):
            s = sym[i]
            ns = nxt[s]
            nxt[s] += 1
            n = alog - hb(ns)
            self.nb[i], self.base[i] = n, (ns << n) - size

    def state_for(self, s, nxt=None):
        """A state emitting symbol s whose transition range covers state `nxt` (None: any). -> (state, bits)."""
        for st in range(len(self.sym)):
            if self.sym[st] != s:
                continue
            if nxt is None:
                return st, 0
            if self.base[st] <= nxt < self.base[st] + (1 << self.nb[st]):
                return st, nxt - self.base[st]
        raise ValueError("symbol %d not encodable (to state %r)" % (s, nxt))


def read_ncount(data, pos, end, maxsym, maxlog):
    """RFC 8878 4.1.1 FSE_Table_Description -> (norm, alog, next_pos)."""
    if pos >= end:
        raise ZErr("UnexpectedEof", "empty FSE header")
    val = int.from_bytes(data[pos:end], "little")
    avail = (end - pos) * 8
    bp = [0]

    def get(n):
        return (val >> bp[0]) & ((1 << n) - 1)

    def take(n):
        if bp[0] + n > avail:
            raise ZErr("UnexpectedEof", "truncated FSE header")
        v = get(n)
        bp[0] += n
        return v

    alog = take(4) + 5
    if alog > maxlog:
        raise ZErr("InvalidFseTable", "accuracy_log %d > %d" % (alog, maxlog))
    remaining, threshold, nbits = (1 << alog) + 1, 1 << alog, alog + 1
    norm = []
    prev0 = False
    while remaining > 1 and len(norm) <= maxsym:
        if prev0:
            while True:
                r = take(2)
                norm.extend([0] * r)
                if r < 3:
                    break
            if len(norm) > maxsym:
                break
        mx = 2 * threshold - 1 - remaining
        if bp[0] + nbits - 1 > avail:
            raise ZErr("UnexpectedEof", "truncated FSE probability")
        low = get(nbits - 1)
        if low < mx:
            v = take(nbits - 1)
        else:
            v = take(nbits)
            if v >= threshold:
                v -= mx
        p = v - 1
        remaining -= 1 if p == -1 else p
        norm.append(p)
        prev0 = p == 0
        while remaining < threshold:
            nbits -= 1
            threshold >>= 1
    if remaining != 1 or len(norm) > maxsym + 1:
        raise ZErr("InvalidFseTable", "distribution does not sum to 1 << accuracy_log")
    return norm, alog, pos + (bp[0] + 7) // 8


class BitW:
    """LSB-first writer; the RFC 8878 backward streams are read from the last written bit."""

    def __init__(self):
        self.v, self.n = 0, 0

    def put(self, val, n):
        if n:
            self.v |= (val & ((1 << n) - 1)) << self.n
            self.n += n

    def put_rev(self, fields):
        for val, n in reversed(fields):
            self.put(val, n)

    def bytes(self, sentinel=True):
        if sentinel:
            self.put(1, 1)
        return self.v.to_bytes((self.n + 7) // 8, "little")


def write_ncount(norm, alog):
    w = BitW()
    w.put(alog - 5, 4)
    remaining, threshold, nbits = (1 << alog) + 1, 1 << alog, alog + 1
    s, n, prev0 = 0, len(norm), False
    while remaining > 1 and s < n:
        if prev0:
            z = s
            while s < n and norm[s] == 0:
                s += 1
            z = s - z
            while z >= 3:
                w.put(3, 2)
                z -= 3
            w.put(z, 2)
        c = norm[s]
        s += 1
        mx = 2 * threshold - 1 - remaining
        remaining -= 1 if c == -1 else c
        c += 1
        if c >= threshold:
            c += mx
        w.put(c, nbits - 1 if c < mx else nbits)
        prev0 = c == 1
        while 0 < remaining < threshold:
            nbits -= 1
            threshold >>= 1
    return w.bytes(sentinel=False)


def normalize(counts, alog, cap_half=True):
    """Simple normalization of raw counts to sum 1 << alog, every present symbol >= 1 (and <= size/2)."""
    size = 1 << alog
    tot = sum(counts)
    present = [i for i, c in enumerate(counts) if c]
    norm = [0] * len(counts)
    for i in present:
        norm[i] = max(1, counts[i] * size // tot)
    cap = size // 2 if cap_half else size
    for i in present:
        norm[i] = min(norm[i], cap)
    while sum(norm) > size:
        i = max(present, key=lambda k: norm[k])
        norm[i] -= 1
    while sum(norm) < size:
        i = min((k for k in present if norm[k] < cap), key=lambda k: norm[k] * tot // max(counts[k], 1))
        norm[i] += 1
    return norm


def chain(tbl, syms):
    """States for emitting syms[0..] in order with `tbl`: -> (initial state, [transition bits after each but last])."""
    st = [0] * len(syms)
    bits = [0] * len(syms)
    nxt = None
    for i in range(len(syms) - 1, -1, -1):
        st[i], b = tbl.state_for(syms[i], nxt)
        if i + 1 < len(syms):
            bits[i] = (b, tbl.nb[st[i]])
        nxt = st[i]
    return st, bits


# ---------------------------------------------------------------- Huffman
class Huff:
    def __init__(self, weights_full):
        """weights_full: weight of every symbol 0..n-1 (last one included)."""
        tot = sum(1 << (w - 1) for w in weights_full if w)
        self.max_bits = hb(tot)
        if tot != 1 << self.max_bits:
            raise ZErr("InvalidHuffmanTable", "weights do not sum to a power of 2")
        self.w = list(weights_full)
        self.code, self.len = {}, {}
        size = 1 << self.max_bits
        self.sym, self.nbt = [0] * size, [0] * size
        idx = 0
        for w in range(1, self.max_bits + 1):
            for s, ws in enumerate(weights_full):
                if ws == w:
                    nb = self.max_bits + 1 - w
                    self.code[s], self.len[s] = idx >> (w - 1), nb
                    for k in range(1 << (w - 1)):
                        self.sym[idx + k], self.nbt[idx + k] = s, nb
                    idx += 1 << (w - 1)

    def encode(self, data):
        w = BitW()
        w.put_rev([(self.code[b], self.len[b]) for b in data])
        return w.bytes()


def huff_from_weights(explicit):
    if not 1 <= len(explicit) <= 255:
        raise ZErr("InvalidHuffmanTable", "weight count")
    if any(w > 11 for w in explicit):
        raise ZErr("InvalidHuffmanTable", "weight > 11")
    tot = sum(1 << (w - 1) for w in explicit if w)
    if tot == 0:
        raise ZErr("InvalidHuffmanTable", "all weights zero")
    mb = hb(tot) + 1
    if mb > 11:
        raise ZErr("InvalidHuffmanTable", "Max_Number_of_Bits > 11")
    left = (1 << mb) - tot
    if left & (left - 1):
        raise ZErr("InvalidHuffmanTable", "leftover not a power of 2")
    return Huff(list(explicit) + [hb(left) + 1])


def huff_weights_for(data, max_bits=11):
    """Length-limited code lengths (package-merge-free heuristic) -> full weights list (len = max symbol + 1)."""
    import heapq
    cnt = [0] * 256
    for b in data:
        cnt[b] += 1
    syms = [s for s in range(256) if cnt[s]]
    if len(syms) < 2:
        raise ValueError("need 2 symbols")
    heap = [(cnt[s], i, [s]) for i, s in enumerate(syms)]
    heapq.heapify(heap)
    depth = {s: 0 for s in syms}
    k = len(heap)
    while len(heap) > 1:
        a, _, x = heapq.heappop(heap)
        b, _, y = heapq.heappop(heap)
        for s in x + y:
            depth[s] += 1
        heapq.heappush(heap, (a + b, k, x + y))
        k += 1
    for s in syms:
        depth[s] = min(depth[s], max_bits)
    # Kraft repair
    while sum(2.0 ** -depth[s] for s in syms) > 1:
        s = max((s for s in syms if depth[s] < max_bits), key=lambda s: (depth[s], -cnt[s]))
        depth[s] += 1
    mb = max(depth.values())
    while True:
        k = sum(1 << (mb - depth[s]) for s in syms)
        if k == 1 << mb:
            break
        s = min((s for s in syms if depth[s] > 1 and (1 << (mb - depth[s] + 1)) - (1 << (mb - depth[s])) <= (1 << mb) - k),
                key=lambda s: (-depth[s], -cnt[s]))
        depth[s] -= 1
    w = [0] * (max(syms) + 1)
    for s in syms:
        w[s] = mb + 1 - depth[s]
    return w


def huff_header_direct(weights_full):
    ex = weights_full[:-1]
    out = bytearray([127 + len(ex)])
    for i in range(0, len(ex), 2):
        out.append((ex[i] << 4) | (ex[i + 1] if i + 1 < len(ex) else 0))
    return bytes(out)


def huff_header_fse(weights_full, alog=6):
    """FSE-compressed weights (two interleaved states), RFC 8878 4.2.1.2."""
    ex = list(weights_full[:-1])
    cnt = [0] * 13
    for w in ex:
        cnt[w] += 1
    while cnt and cnt[-1] == 0:
        cnt.pop()
    if sum(1 for c in cnt if c) < 2:
        cnt = cnt + [0] * (2 - len(cnt)) if len(cnt) < 2 else cnt
        j = next(i for i in range(len(cnt)) if cnt[i] == 0) if 0 in cnt else len(cnt)
        if j == len(cnt):
            cnt.append(0)
        cnt[j] = 1  # an unused second symbol keeps every probability <= size/2
    norm = normalize(cnt, alog)
    tbl = Fse(norm, alog)
    a, b = ex[0::2], ex[1::2]
    sa, ba = chain(tbl, a)
    sb, bb = chain(tbl, b)
    fields = [(sa[0], alog), (sb[0], alog)]
    for i in range(len(ex) - 2):
        fields.append(ba[i // 2] if i % 2 == 0 else bb[i // 2])
    w = BitW()
    w.put_rev(fields)
    stream = w.bytes()
    payload = write_ncount(norm, alog) + stream
    assert len(payload) < 128
    return bytes([len(payload)]) + payload


# ---------------------------------------------------------------- decoder
class BRev:
    def __init__(self, data, start, end):
        if end <= start:
            raise ZErr("InvalidBitstream", "empty bitstream")
        if data[end - 1] == 0:
            raise ZErr("InvalidBitstream", "last byte has no sentinel bit")
        self.v = int.from_bytes(data[start:end], "little")
        self.n = (end - start - 1) * 8 + hb(data[end - 1])

    def read(self, k):
        if k == 0:
            return 0
        if k > self.n:
            raise ZErr("InvalidBitstream", "bitstream underflow")
        self.n -= k
        return (self.v >> self.n) & ((1 << k) - 1)

    def peek(self, k):
        if self.n >= k:
            return (self.v >> (self.n - k)) & ((1 << k) - 1)
        return (self.v << (k - self.n)) & ((1 << k) - 1)


def read_huff_tree(data, pos, end, feat):
    if pos >= end:
        raise ZErr("UnexpectedEof", "Huffman header")
    h = data[pos]
    if h >= 128:
        n = h - 127
        nb = (n + 1) // 2
        if pos + 1 + nb > end:
            raise ZErr("UnexpectedEof", "direct weights")
        ws = []
        for i in range(n):
            b = data[pos + 1 + i // 2]
            ws.append(b >> 4 if i % 2 == 0 else b & 15)
        feat.add("hw_direct")
        return huff_from_weights(ws), pos + 1 + nb
    cend = pos + 1 + h
    if h == 0 or cend > end:
        raise ZErr("UnexpectedEof", "FSE weights")
    norm, alog, sp = read_ncount(data, pos + 1, cend, 12, 6)
    tbl = Fse(norm + [0] * (13 - len(norm)), alog)
    br = BRev(data, sp, cend)
    s1, s2 = br.read(alog), br.read(alog)
    ws = []
    while True:
        ws.append(tbl.sym[s1])
        if br.n < tbl.nb[s1]:
            ws.append(tbl.sym[s2])
            break
        s1 = tbl.base[s1] + br.read(tbl.nb[s1])
        ws.append(tbl.sym[s2])
        if br.n < tbl.nb[s2]:
            ws.append(tbl.sym[s1])
            break
        s2 = tbl.base[s2] + br.read(tbl.nb[s2])
        if len(ws) > 255:
            break
    if len(ws) > 255:
        raise ZErr("InvalidHuffmanTable", "more than 255 weights")
    feat.add("hw_fse")
    return huff_from_weights(ws), cend


def huff_stream(h, data, start, end, n):
    br = BRev(data, start, end)
    out = bytearray()
    for _ in range(n):
        i = br.peek(h.max_bits)
        k = h.nbt[i]
        if k > br.n:
            raise ZErr("InvalidBitstream", "Huffman underflow")
        br.n -= k
        out.append(h.sym[i])
    if br.n:
        raise ZErr("InvalidBitstream", "Huffman stream not consumed")
    return out


class Frame:
    def __init__(self):
        self.rep = [1, 4, 8]
        self.huf = None
        self.tbl = {"ll": None, "of": None, "ml": None}


def lits_section(data, pos, end, fr, bmax, feat):
    b0 = data[pos]
    lt, sf = b0 & 3, (b0 >> 2) & 3
    if lt < 2:
        if sf in (0, 2):
            rs, pos = b0 >> 3, pos + 1
        elif sf == 1:
            if pos + 2 > end:
                raise ZErr("UnexpectedEof", "lits hdr")
            rs, pos = (b0 | data[pos + 1] << 8) >> 4, pos + 2
        else:
            if pos + 3 > end:
                raise ZErr("UnexpectedEof", "lits hdr")
            rs, pos = (b0 | data[pos + 1] << 8 | data[pos + 2] << 16) >> 4, pos + 3
        if rs > bmax:
            raise ZErr("InvalidLiteralsHeader", "literals > Block_Maximum_Size")
        if lt == 0:
            if pos + rs > end:
                raise ZErr("UnexpectedEof", "raw lits")
            feat.add("lit_raw")
            return bytes(data[pos:pos + rs]), pos + rs
        if pos >= end:
            raise ZErr("UnexpectedEof", "rle lit")
        feat.add("lit_rle")
        return bytes([data[pos]]) * rs, pos + 1
    hl = {0: 3, 1: 3, 2: 4, 3: 5}[sf]
    if pos + hl > end:
        raise ZErr("UnexpectedEof", "lits hdr")
    v = int.from_bytes(data[pos:pos + hl], "little")
    bits = {3: 10, 4: 14, 5: 18}[hl]
    rs, cs = (v >> 4) & ((1 << bits) - 1), (v >> (4 + bits)) & ((1 << bits) - 1)
    pos += hl
    if rs > bmax:
        raise ZErr("InvalidLiteralsHeader", "literals > Block_Maximum_Size")
    if pos + cs > end:
        raise ZErr("UnexpectedEof", "compressed lits")
    lend = pos + cs
    if lt == 2:
        fr.huf, pos = read_huff_tree(data, pos, lend, feat)
        feat.add("lit_huf")
    else:
        if fr.huf is None:
            raise ZErr("InvalidLiteralsHeader", "Treeless_Literals_Block without a previous Huffman table")
        feat.add("lit_treeless")
    if sf == 0:
        feat.add("huf_1stream")
        return bytes(huff_stream(fr.huf, data, pos, lend, rs)), lend
    feat.add("huf_4stream")
    if lend - pos < 6:
        raise ZErr("UnexpectedEof", "jump table")
    s1, s2, s3 = (int.from_bytes(data[pos + 2 * i:pos + 2 * i + 2], "little") for i in range(3))
    p1 = pos + 6
    p2, p3, p4 = p1 + s1, p1 + s1 + s2, p1 + s1 + s2 + s3
    if p4 > lend:
        raise ZErr("InvalidLiteralsHeader", "jump table")
    seg = (rs + 3) // 4
    if rs - 3 * seg < 0:
        raise ZErr("InvalidLiteralsHeader", "4 streams with regenerated size < 3*seg")
    out = bytearray()
    for a, b, n in ((p1, p2, seg), (p2, p3, seg), (p3, p4, seg), (p4, lend, rs - 3 * seg)):
        out += huff_stream(fr.huf, data, a, b, n)
    return bytes(out), lend


def seq_table(kind, mode, data, pos, end, fr, feat):
    name = ["pre", "rle", "fse", "rep"][mode]
    feat.add("%s_%s" % (kind, name))
    if mode == 0:
        t = Fse({"ll": PRE_LL, "of": PRE_OF, "ml": PRE_ML}[kind], {"ll": 6, "of": 5, "ml": 6}[kind])
    elif mode == 1:
        if pos >= end:
            raise ZErr("UnexpectedEof", "RLE symbol")
        if data[pos] > MAXSYM[kind]:
            raise ZErr("InvalidSequences", "RLE symbol out of range")
        t = Fse(None, 0, rle=data[pos])
        pos += 1
    elif mode == 2:
        norm, alog, pos = read_ncount(data, pos, end, MAXSYM[kind], MAXLOG[kind])
        t = Fse(norm, alog)
    else:
        t = fr.tbl[kind]
        if t is None:
            raise ZErr("InvalidSequences", "Repeat_Mode without a previous table")
    fr.tbl[kind] = t
    return t, pos


def compressed_block(data, pos, end, fr, out, fstart, window, bmax, feat):
    if pos >= end:
        raise ZErr("UnexpectedEof", "empty compressed block")
    bstart = len(out)
    lits, pos = lits_section(data, pos, end, fr, bmax, feat)
    if pos >= end:
        raise ZErr("UnexpectedEof", "sequences header")
    b0 = data[pos]
    pos += 1
    if b0 < 128:
        nseq = b0
        feat.add("nseq_1b")
    elif b0 < 255:
        if pos >= end:
            raise ZErr("UnexpectedEof", "nseq")
        nseq = ((b0 - 128) << 8) + data[pos]
        pos += 1
        feat.add("nseq_2b")
    else:
        if pos + 2 > end:
            raise ZErr("UnexpectedEof", "nseq")
        nseq = data[pos] + (data[pos + 1] << 8) + 0x7F00
        pos += 2
        feat.add("nseq_3b")
    if nseq == 0:
        if pos != end:
            raise ZErr("InvalidSequences", "bytes after a 0-sequence header")
        feat.add("nseq_0")
        out += lits
        return
    if pos >= end:
        raise ZErr("UnexpectedEof", "modes")
    m = data[pos]
    pos += 1
    if m & 3:
        raise ZErr("InvalidSequences", "reserved mode bits")
    ll, pos = seq_table("ll", m >> 6, data, pos, end, fr, feat)
    of, pos = seq_table("of", (m >> 4) & 3, data, pos, end, fr, feat)
    ml, pos = seq_table("ml", (m >> 2) & 3, data, pos, end, fr, feat)
    br = BRev(data, pos, end)
    sl, so, sm = br.read(ll.alog), br.read(of.alog), br.read(ml.alog)
    lp = 0
    rep = list(fr.rep)
    for i in range(nseq):
        oc, mc, lc = of.sym[so], ml.sym[sm], ll.sym[sl]
        if oc > 31 or mc > 52 or lc > 35:
            raise ZErr("InvalidSequences", "code out of range")
        ofv = (1 << oc) + br.read(oc)
        mlen = ML_BASE[mc] + br.read(ML_BITS[mc])
        llen = LL_BASE[lc] + br.read(LL_BITS[lc])
        if i + 1 < nseq:
            sl = ll.base[sl] + br.read(ll.nb[sl])
            sm = ml.base[sm] + br.read(ml.nb[sm])
            so = of.base[so] + br.read(of.nb[so])
        if ofv > 3:
            off = ofv - 3
            rep = [off, rep[0], rep[1]]
            feat.add("off_new")
        else:
            idx = ofv if llen == 0 else ofv - 1
            feat.add("rep_%s%d" % ("ll0_" if llen == 0 else "", ofv))
            if idx == 0:
                off = rep[0]
            elif idx == 3:
                off = rep[0] - 1
                if off == 0:
                    raise ZErr("InvalidOffset", "rep1 - 1 == 0")
                rep = [off, rep[0], rep[1]]
            elif idx == 1:
                off = rep[1]
                rep = [off, rep[0], rep[2]]
            else:
                off = rep[2]
                rep = [off, rep[0], rep[1]]
        if lp + llen > len(lits):
            raise ZErr("InvalidSequences", "literal length beyond literals")
        if len(out) - bstart + llen + mlen > bmax:
            raise ZErr("InvalidSequences", "block output > Block_Maximum_Size")
        out += lits[lp:lp + llen]
        lp += llen
        if off > len(out) - fstart or off > window:
            raise ZErr("InvalidOffset", "offset %d beyond frame history %d / window %d" % (off, len(out) - fstart, window))
        if off < mlen:
            feat.add("overlap")
        s = len(out) - off
        for k in range(mlen):
            out.append(out[s + k])
    if br.n:
        raise ZErr("InvalidBitstream", "sequence bitstream not consumed")
    if len(out) - bstart + len(lits) - lp > bmax:
        raise ZErr("InvalidSequences", "block output > Block_Maximum_Size")
    out += lits[lp:]
    fr.rep = rep


def decode(data, max_out=1 << 26, max_window=1 << 23, max_frames=1024, feat=None, trace=None):
    """Decode a whole stream. Limits mirror ZstdLimits (input limit not modelled).
    trace: list that receives one dict per frame (header fields and (type, size, decoded) per block)."""
    feat = set() if feat is None else feat
    if not data:
        raise ZErr("UnexpectedEof", "empty input")
    out = bytearray()
    pos, nf, n = 0, 0, len(data)
    while pos < n:
        nf += 1
        if nf > max_frames:
            raise ZErr("LimitExceeded", "frames")
        if pos + 4 > n:
            raise ZErr("UnexpectedEof", "magic")
        magic = int.from_bytes(data[pos:pos + 4], "little")
        pos += 4
        if 0x184D2A50 <= magic <= 0x184D2A5F:
            if pos + 4 > n:
                raise ZErr("UnexpectedEof", "skippable size")
            sz = int.from_bytes(data[pos:pos + 4], "little")
            if pos + 4 + sz > n:
                raise ZErr("UnexpectedEof", "skippable payload")
            pos += 4 + sz
            feat.add("skippable")
            continue
        if magic != 0xFD2FB528:
            raise ZErr("InvalidMagic", hex(magic))
        if pos >= n:
            raise ZErr("UnexpectedEof", "FHD")
        fhd = data[pos]
        pos += 1
        if fhd & 8:
            raise ZErr("InvalidFrameHeader", "reserved bit")
        if fhd & 16:
            feat.add("fhd_unused_bit")
        fcsf, ss, chk, didf = fhd >> 6, (fhd >> 5) & 1, (fhd >> 2) & 1, fhd & 3
        window = 0
        if not ss:
            if pos >= n:
                raise ZErr("UnexpectedEof", "WD")
            wd = data[pos]
            pos += 1
            wl = 10 + (wd >> 3)
            window = (1 << wl) + ((1 << wl) >> 3) * (wd & 7)
            feat.add("window_desc")
            if window > max_window:
                raise ZErr("LimitExceeded", "window")
        else:
            feat.add("single_segment")
        dn = [0, 1, 2, 4][didf]
        if pos + dn > n:
            raise ZErr("UnexpectedEof", "dict id")
        did = int.from_bytes(data[pos:pos + dn], "little")
        pos += dn
        if didf:
            feat.add("dictid_field")
        if did:
            raise ZErr("UnsupportedDictionary", str(did))
        fn = [1 if ss else 0, 2, 4, 8][fcsf]
        if pos + fn > n:
            raise ZErr("UnexpectedEof", "FCS")
        fcs = int.from_bytes(data[pos:pos + fn], "little") + (256 if fn == 2 else 0) if fn else None
        pos += fn
        feat.add("fcs_%d" % fn)
        if fcs is not None:
            if fcs > max_out - len(out):
                raise ZErr("LimitExceeded", "FCS > remaining max_output_bytes")
            if ss:
                if fcs > max_window:
                    raise ZErr("LimitExceeded", "single-segment window")
                window = fcs
        bmax = min(window, 1 << 17)
        if trace is not None:
            trace.append({"fhd": fhd, "window": window, "single": ss, "fcs": fcs, "checksum": chk, "did_flag": didf,
                          "blocks": []})
        fr = Frame()
        fstart = len(out)
        nb = 0
        while True:
            if pos + 3 > n:
                raise ZErr("UnexpectedEof", "block header")
            bh = int.from_bytes(data[pos:pos + 3], "little")
            pos += 3
            last, bt, bs = bh & 1, (bh >> 1) & 3, bh >> 3
            nb += 1
            b_out = len(out)
            if bt == 3:
                raise ZErr("InvalidBlockHeader", "reserved block type")
            if bs > bmax:
                raise ZErr("InvalidBlockHeader", "Block_Size > Block_Maximum_Size")
            if bt == 0:
                if pos + bs > n:
                    raise ZErr("UnexpectedEof", "raw block")
                if len(out) + bs > max_out:
                    raise ZErr("LimitExceeded", "output")
                out += data[pos:pos + bs]
                pos += bs
                feat.add("blk_raw")
            elif bt == 1:
                if pos >= n:
                    raise ZErr("UnexpectedEof", "rle block")
                if len(out) + bs > max_out:
                    raise ZErr("LimitExceeded", "output")
                out += bytes([data[pos]]) * bs
                pos += 1
                feat.add("blk_rle")
            else:
                if pos + bs > n:
                    raise ZErr("UnexpectedEof", "compressed block")
                compressed_block(data, pos, pos + bs, fr, out, fstart, window, bmax, feat)
                if len(out) > max_out:
                    raise ZErr("LimitExceeded", "output")
                pos += bs
                feat.add("blk_cmp")
            if trace is not None:
                trace[-1]["blocks"].append((bt, bs, len(out) - b_out))
            if last:
                break
        if nb > 1:
            feat.add("multi_block")
        if fcs is not None and len(out) - fstart != fcs:
            raise ZErr("ContentSizeMismatch", "%d != %d" % (len(out) - fstart, fcs))
        if chk:
            if pos + 4 > n:
                raise ZErr("UnexpectedEof", "checksum")
            if int.from_bytes(data[pos:pos + 4], "little") != xxh64(bytes(out[fstart:])) & 0xFFFFFFFF:
                raise ZErr("ChecksumMismatch", "")
            pos += 4
            feat.add("checksum")
    if nf > 1:
        feat.add("multi_frame")
    return bytes(out)


# ---------------------------------------------------------------- writer
def frame_header(fcs=None, single=False, window_log=17, wd=None, checksum=False, did=None, did_flag=None,
                 fcs_flag=None, reserved=False, unused=False, fhd=None):
    """Any Frame_Header (fields may be inconsistent on purpose)."""
    if fcs_flag is None:
        if fcs is None:
            fcs_flag = 0
        elif single and fcs < 256:
            fcs_flag = 0
        elif 256 <= fcs < 65536 + 256:
            fcs_flag = 1
        elif fcs < 1 << 32:
            fcs_flag = 2
        else:
            fcs_flag = 3
    if did_flag is None:
        did_flag = 0 if did is None else (1 if did < 256 else 2 if did < 65536 else 3)
    h = (fcs_flag << 6) | (int(single) << 5) | (int(checksum) << 2) | did_flag | (8 if reserved else 0) | (
        16 if unused else 0)
    out = bytearray((0xFD2FB528).to_bytes(4, "little"))
    out.append(h if fhd is None else fhd)
    if not single:
        out.append(((window_log - 10) << 3) if wd is None else wd)
    out += (did or 0).to_bytes([0, 1, 2, 4][did_flag], "little")
    fn = [1 if single else 0, 2, 4, 8][fcs_flag]
    if fn:
        out += ((fcs or 0) - (256 if fn == 2 else 0)).to_bytes(fn, "little")
    return bytes(out)


def block(bt, payload, last=True, size=None):
    if size is None:
        size = 1 if bt == 1 and len(payload) == 1 and False else len(payload)
    return (int(last) | (bt << 1) | (size << 3)).to_bytes(3, "little") + payload


def raw_block(data, last=True):
    return block(0, data, last)


def rle_block(byte, n, last=True):
    return (int(last) | (1 << 1) | (n << 3)).to_bytes(3, "little") + bytes([byte])


def cmp_block(payload, last=True, size=None):
    return block(2, payload, last, size)


def skippable(payload, nibble=0, size=None):
    return (0x184D2A50 + nibble).to_bytes(4, "little") + (len(payload) if size is None else size).to_bytes(4, "little") + payload


def frame(blocks, content=None, checksum=False, bad_checksum=False, **hdr):
    out = frame_header(checksum=checksum, **hdr) + b"".join(blocks)
    if checksum:
        c = xxh64(content or b"") & 0xFFFFFFFF
        if bad_checksum:
            c ^= 1
        out += c.to_bytes(4, "little")
    return out


def lits_raw_hdr(n, lt=0, sf=None):
    if sf is None:
        sf = 0 if n < 32 else 1 if n < 4096 else 3
    if sf in (0, 2):
        return bytes([lt | (sf << 2) | (n << 3)])
    if sf == 1:
        return (lt | (1 << 2) | (n << 4)).to_bytes(2, "little")
    return (lt | (3 << 2) | (n << 4)).to_bytes(3, "little")


def lits_raw(data, sf=None):
    return lits_raw_hdr(len(data), 0, sf) + bytes(data)


def lits_rle(byte, n, sf=None):
    return lits_raw_hdr(n, 1, sf) + bytes([byte])


def lits_cmp_hdr(regen, comp, four, treeless=False, sf=None):
    lt = 3 if treeless else 2
    if sf is None:
        if not four:
            sf = 0
        elif regen < 1024 and comp < 1024:
            sf = 1
        elif regen < 16384 and comp < 16384:
            sf = 2
        else:
            sf = 3
    hl, bits = {0: (3, 10), 1: (3, 10), 2: (4, 14), 3: (5, 18)}[sf]
    return (lt | (sf << 2) | (regen << 4) | (comp << (4 + bits))).to_bytes(hl, "little")


def huff_streams(h, data, four, jump=None):
    if not four:
        return h.encode(data)
    seg = (len(data) + 3) // 4
    parts = [data[0:seg], data[seg:2 * seg], data[2 * seg:3 * seg], data[3 * seg:]]
    st = [h.encode(p) for p in parts]
    j = jump or [len(st[0]), len(st[1]), len(st[2])]
    return b"".join(x.to_bytes(2, "little") for x in j) + b"".join(st)


def lits_huff(data, weights=None, four=False, fse_weights=False, treeless_with=None, regen=None, sf=None, tree=None,
              streams=None):
    """Compressed (or, with treeless_with=<Huff>, Treeless) literals section for `data`."""
    if treeless_with is not None:
        h, tree = treeless_with, b""
    else:
        weights = weights or huff_weights_for(data)
        h = Huff(weights)
        if tree is None:
            tree = huff_header_fse(weights) if fse_weights else huff_header_direct(weights)
    body = tree + (streams if streams is not None else huff_streams(h, data, four))
    hdr = lits_cmp_hdr(len(data) if regen is None else regen, len(body), four, treeless_with is not None, sf)
    return hdr + body, h


def code_of(v, base, bits):
    for c in range(len(base) - 1, -1, -1):
        if base[c] <= v < base[c] + (1 << bits[c]):
            return c
    raise ValueError(v)


class SeqWriter:
    """Builds Sequences_Sections, tracking the previous tables of a frame like a decoder does (for Repeat_Mode)."""

    def __init__(self):
        self.prev = {"ll": None, "of": None, "ml": None}

    def section(self, seqs, modes=("pre", "pre", "pre"), fse_norm=None, nseq=None, nseq_bytes=None, mode_byte=None,
                tail=b"", drop_bits=0, extra_bits=0, rle_sym=None):
        """seqs: [(literal_length, offset_value, match_length)], offset_value = RFC Offset_Value (>3: offset+3)."""
        n = len(seqs) if nseq is None else nseq
        if nseq_bytes is None:
            nseq_bytes = 1 if n < 128 else 2 if n < 0x7F00 else 3
        if nseq_bytes == 1:
            out = bytearray([n])
        elif nseq_bytes == 2:
            out = bytearray([(n >> 8) + 128, n & 255])
        else:
            out = bytearray([255]) + (n - 0x7F00).to_bytes(2, "little")
        if n == 0:
            return bytes(out) + tail
        codes = {
            "ll": [code_of(l, LL_BASE, LL_BITS) for l, _, _ in seqs],
            "of": [hb(o) for _, o, _ in seqs],
            "ml": [code_of(m, ML_BASE, ML_BITS) for _, _, m in seqs],
        }
        mnum = {"pre": 0, "rle": 1, "fse": 2, "rep": 3}
        out.append((mnum[modes[0]] << 6) | (mnum[modes[1]] << 4) | (mnum[modes[2]] << 2) if mode_byte is None else mode_byte)
        tbl = {}
        for k, mode in zip(("ll", "of", "ml"), modes):
            if mode == "pre":
                t = Fse({"ll": PRE_LL, "of": PRE_OF, "ml": PRE_ML}[k], {"ll": 6, "of": 5, "ml": 6}[k])
            elif mode == "rle":
                s = codes[k][0] if not rle_sym or k not in rle_sym else rle_sym[k]
                out.append(s)
                t = Fse(None, 0, rle=s)
            elif mode == "fse":
                norm, alog = fse_norm[k]
                out += write_ncount(norm, alog)
                t = Fse(norm, alog)
            else:
                t = self.prev[k]
            tbl[k] = t
            self.prev[k] = t
        ch = {k: chain(tbl[k], codes[k]) for k in tbl}
        fields = [(ch["ll"][0][0], tbl["ll"].alog), (ch["of"][0][0], tbl["of"].alog), (ch["ml"][0][0], tbl["ml"].alog)]
        for i, (l, o, m) in enumerate(seqs):
            oc, mc, lc = codes["of"][i], codes["ml"][i], codes["ll"][i]
            fields += [(o - (1 << oc), oc), (m - ML_BASE[mc], ML_BITS[mc]), (l - LL_BASE[lc], LL_BITS[lc])]
            if i + 1 < len(seqs):
                fields += [ch["ll"][1][i], ch["ml"][1][i], ch["of"][1][i]]
        w = BitW()
        if extra_bits:
            w.put(0, extra_bits)  # unread low bits: the decoder must see them as unconsumed
        w.put_rev(fields)
        if drop_bits:
            w.v >>= drop_bits
            w.n -= drop_bits
        return bytes(out) + w.bytes() + tail


def selftest():
    assert xxh64(b"") == 0xEF46DB3751D8E999
    assert xxh64(b"", 2654435761) == 0xAC75FDA2929B17EF
    assert xxh64(b"a") == 0xD24EC4F1A98C6E5B
    assert xxh64(b"The quick brown fox jumps over the lazy dog") == 0x0B242D361FDA71BC
    # writer -> model round trips
    sw = SeqWriter()
    lit, h = lits_huff(b"abcabcabd" * 20, four=True)
    seqs = [(9, 9 + 3, 30), (0, 1, 20), (3, 2, 5)]
    body = lit + sw.section(seqs, modes=("pre", "pre", "pre"))
    data = frame([cmp_block(body)], window_log=10)
    feat = set()
    out = decode(data, feat=feat)
    assert len(out) == 180 + 55 + 0, len(out)
    norm = normalize([5, 3, 1, 1], 5)
    assert read_ncount(write_ncount(norm, 5), 0, 99, 35, 9)[0][:4] == norm
    w = huff_weights_for(bytes(range(200)) * 3 + b"a" * 600)
    hdr = huff_header_fse(w)
    hh, _ = read_huff_tree(hdr, 0, len(hdr), set())
    assert hh.w == w, (hh.w, w)
    print("zmodel selftest ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["selftest"]:
        selftest()
