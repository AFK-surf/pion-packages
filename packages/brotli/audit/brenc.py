#!/usr/bin/env python3
"""Independent bit-exact Brotli (RFC 7932) *stream writer* used by the red-team audit.

It is written from RFC 7932 only (not from `packages/brotli/src`) and can emit every construct the decoder must
handle: all WBITS encodings, metadata / uncompressed / compressed meta-blocks, simple and complex prefix codes
(HSKIP 0/2/3, single-symbol code-length code, RLE codes 16/17, 15-bit deep codes), block switching for all three
categories (NBLTYPES up to 256), context maps with RLE + MTF, all four literal context modes, NPOSTFIX/NDIRECT,
short (ring-buffer) distance codes, implicit distances and static-dictionary references with any transform.

Every knob can also be *broken on purpose* (`Bad*` options) to build precisely malformed streams.
The static dictionary and the context lookup table are dumped from Google's libbrotlicommon, never from Pion.
"""
import random

INSERT_BASE = [0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594]
INSERT_BITS = [0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24]
COPY_BASE = [2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118]
COPY_BITS = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24]
BLEN_BASE = [1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289,
             4337, 8433, 16625]
BLEN_BITS = [2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24]
CL_ORDER = [1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15]
# RFC 7932 §3.5: variable-length code for code-length-code lengths, as (value, nbits) written LSB-first
CL_LEN_CODE = {0: (0, 2), 1: (7, 4), 2: (3, 3), 3: (2, 2), 4: (1, 2), 5: (15, 4)}
NDBITS = [0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5]
# (insert_hi, copy_hi) -> cell for explicit-distance commands (RFC 7932 §5)
CELLS = {(0, 0): 2, (0, 8): 3, (8, 0): 4, (8, 8): 5, (0, 16): 6, (16, 0): 7, (8, 16): 8, (16, 8): 9, (16, 16): 10}


def dict_offsets():
    off, o = [0] * 25, 0
    for l in range(4, 25):
        off[l] = o
        o += l << NDBITS[l]
    return off


DICT_OFF = dict_offsets()


class BW:
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def bits(self, v, n):
        assert 0 <= v < (1 << n) or n == 0, (v, n)
        self.acc |= v << self.n
        self.n += n
        while self.n >= 8:
            self.out.append(self.acc & 0xFF)
            self.acc >>= 8
            self.n -= 8

    def align(self, pad=0):
        if self.n:
            self.bits(pad & ((1 << (8 - self.n)) - 1), 8 - self.n)

    def raw(self, b):
        assert self.n == 0
        self.out += b

    def done(self, pad=0):
        self.align(pad)
        return bytes(self.out)


def bitlen(x):
    return x.bit_length()


def flat_lengths(syms, rot=0, skew=False):
    """Complete prefix code over `syms`.  `rot` permutes which symbols get the short codes; `skew` makes a
    maximally deep code (lengths 1,2,..,15) to exercise 2-level tables."""
    syms = sorted(set(syms))
    k = len(syms)
    if k == 1:
        return {syms[0]: 0}
    order = syms[rot % k:] + syms[:rot % k]
    if skew and k >= 3:
        depth = min(k - 1, 15)
        lens = list(range(1, depth))  # 1..depth-1 ...
        rest = k - len(lens)
        # remaining `rest` symbols share the subtree of weight 2^-(depth-1) at depth >= depth
        L = depth - 1 + max(1, bitlen(rest - 1))
        if L <= 15:
            short = (1 << (L - depth + 1)) - rest
            tail = [L - 1] * short + [L] * (rest - short)
            lens = lens + tail
            assert abs(sum(2.0 ** -x for x in lens) - 1) < 1e-12
            return dict(zip(order, lens))
    L = bitlen(k - 1)
    short = (1 << L) - k
    return {s: (L - 1 if i < short else L) for i, s in enumerate(order)}


def canon(lengths):
    """{sym: len} -> {sym: (code, len)} canonical (codes MSB-first)."""
    items = sorted((l, s) for s, l in lengths.items() if l > 0)
    code, prev, res = 0, 0, {}
    for l, s in items:
        code <<= (l - prev)
        res[s] = (code, l)
        code += 1
        prev = l
    return res


class Code:
    def __init__(self, lengths):
        self.lengths = lengths
        nz = [s for s, l in lengths.items() if l > 0]
        self.single = None if len(nz) >= 2 else (nz[0] if nz else min(lengths))
        self.codes = canon(lengths) if self.single is None else {}

    def put(self, bw, sym):
        if self.single is not None:
            assert sym == self.single, (sym, self.single)
            return
        c, l = self.codes[sym]
        r = 0
        for i in range(l):
            r = (r << 1) | ((c >> i) & 1)
        bw.bits(r, l)


def rle_lengths(seq, use_rle):
    """Code-length sequence -> list of (cl_symbol, extra_value, extra_bits) as the C encoder does."""
    out = []
    if not use_rle:
        return [(v, 0, 0) for v in seq]
    prev = 8
    i = 0
    while i < len(seq):
        v = seq[i]
        j = i
        while j < len(seq) and seq[j] == v:
            j += 1
        reps = j - i
        if v == 0:
            tmp = []
            if reps == 11:
                tmp.append((0, 0, 0))
                reps -= 1
            if reps < 3:
                tmp += [(0, 0, 0)] * reps
            else:
                reps -= 3
                chain = []
                while True:
                    chain.append((17, reps & 7, 3))
                    reps >>= 3
                    if reps == 0:
                        break
                    reps -= 1
                tmp += chain[::-1]
            out += tmp
        else:
            tmp = []
            if prev != v:
                tmp.append((v, 0, 0))
                reps -= 1
            if reps == 7:
                tmp.append((v, 0, 0))
                reps -= 1
            if reps < 3:
                tmp += [(v, 0, 0)] * reps
            else:
                reps -= 3
                chain = []
                while True:
                    chain.append((16, reps & 3, 2))
                    reps >>= 2
                    if reps == 0:
                        break
                    reps -= 1
                tmp += chain[::-1]
            out += tmp
            prev = v
        i = j
    return out


def write_code(bw, alpha, lengths, rng=None, opts=None):
    """Write a prefix code (RFC 7932 §3.4/3.5) and return a Code for encoding symbols with it.
    opts: force_complex, use_rle, hskip, bad_* (malformed variants)."""
    opts = opts or {}
    nz = sorted(s for s, l in lengths.items() if l > 0)
    if not nz:
        nz = [min(lengths)]
    abits = bitlen(alpha - 1)
    simple_ok = len(nz) <= 4 and not opts.get('force_complex')
    if simple_ok:
        ls = sorted(lengths[s] for s in nz)
        shapes = {1: [[0]], 2: [[1, 1]], 3: [[1, 2, 2]], 4: [[2, 2, 2, 2], [1, 2, 3, 3]]}
        if ls not in shapes[len(nz)]:
            simple_ok = False
    if simple_ok:
        syms = sorted(nz, key=lambda s: (lengths.get(s, 0), s))
        if rng is not None and len(syms) >= 2:
            # order within equal lengths is free in the stream
            groups = {}
            for s in syms:
                groups.setdefault(lengths.get(s, 0), []).append(s)
            syms = []
            for l in sorted(groups):
                g = groups[l][:]
                rng.shuffle(g)
                syms += g
        if opts.get('bad_dup') and len(syms) >= 2:
            syms[1] = syms[0]
        bw.bits(1, 2)
        bw.bits(len(syms) - 1, 2)
        for s in syms:
            bw.bits(opts.get('bad_sym', s) if s == syms[-1] and 'bad_sym' in opts else s, abits)
        if len(syms) == 4:
            bw.bits(0 if all(lengths[s] == 2 for s in nz) else 1, 1)
        return Code({s: (0 if len(nz) == 1 else lengths[s]) for s in nz})
    # complex code
    last = max(nz)
    seq = [lengths.get(s, 0) for s in range(last + 1)]
    if 'override_seq' in opts:
        seq = opts['override_seq']
    toks = rle_lengths(seq, opts.get('use_rle', True))
    used = sorted(set(t[0] for t in toks))
    cl_lens = flat_lengths(used, rot=(rng.randrange(18) if rng else 0))
    if len(used) == 1:
        cl_lens = {used[0]: 1}  # single code-length symbol: any non-zero length, decoded with 0 bits
    if 'cl_override' in opts:
        cl_lens = opts['cl_override']
    hskip = opts.get('hskip', 0)
    if hskip and any(cl_lens.get(CL_ORDER[i], 0) for i in range(hskip)):
        hskip = 0
    bw.bits(hskip, 2)
    space = 32
    nonzero = 0
    for i in range(hskip, 18):
        l = cl_lens.get(CL_ORDER[i], 0)
        v, n = CL_LEN_CODE[l]
        bw.bits(v, n)
        if l:
            space -= 32 >> l
            nonzero += 1
            if space <= 0:
                break
    clc = Code(cl_lens) if len(used) > 1 else Code({used[0]: 0})
    for sym, ev, eb in toks:
        clc.put(bw, sym)
        if eb:
            bw.bits(ev, eb)
    return Code(lengths)


def write_var8(bw, v):
    if v == 0:
        bw.bits(0, 1)
    elif v == 1:
        bw.bits(1, 1)
        bw.bits(0, 3)
    else:
        n = bitlen(v) - 1
        bw.bits(1, 1)
        bw.bits(n, 3)
        bw.bits(v - (1 << n), n)


def write_wbits(bw, w):
    if w == 16:
        bw.bits(0, 1)
    elif 18 <= w <= 24:
        bw.bits(1, 1)
        bw.bits(w - 17, 3)
    elif w == 17:
        bw.bits(1, 1)
        bw.bits(0, 3)
        bw.bits(0, 3)
    else:
        assert 10 <= w <= 15
        bw.bits(1, 1)
        bw.bits(0, 3)
        bw.bits(w - 8, 3)


def write_mlen(bw, mlen, nibbles=None):
    m = mlen - 1
    nib = nibbles or max(4, (bitlen(m) + 3) // 4)
    bw.bits(nib - 4, 2)
    bw.bits(m, nib * 4)


def code_for(base, bits, v):
    for i in range(len(base) - 1, -1, -1):
        if base[i] <= v:
            assert v - base[i] < (1 << bits[i]), v
            return i, v - base[i]
    raise ValueError(v)


def block_len_code(n):
    return code_for(BLEN_BASE, BLEN_BITS, n)


def dist_code(d, npostfix, ndirect):
    """Distance -> (code, extra_value, extra_bits) using the direct / formula codes (never short codes)."""
    if d <= ndirect:
        return 15 + d, 0, 0
    dd = d - ndirect - 1
    lcode = dd & ((1 << npostfix) - 1)
    v = (dd >> npostfix) + 4
    nbits = bitlen(v) - 2
    prefix = (v >> nbits) & 1
    code = 16 + ndirect + (((2 * (nbits - 1) + prefix) << npostfix) | lcode)
    extra = v - ((2 + prefix) << nbits)
    return code, extra, nbits


def short_codes(d, rb, idx):
    """All short distance codes 0..15 that decode to `d` given ring buffer rb and index of last."""
    last = rb[idx & 3]
    cand = {0: last, 1: rb[(idx + 3) & 3], 2: rb[(idx + 2) & 3], 3: rb[(idx + 1) & 3]}
    for c in range(4, 16):
        base = last if c < 10 else rb[(idx + 3) & 3]
        k = ((c - (4 if c < 10 else 10)) >> 1) + 1
        cand[c] = base - k if (c & 1) == 0 else base + k
    return [c for c, v in cand.items() if v == d]


def ctx_id(lut, mode, p1, p2):
    return lut[mode * 512 + p1] | lut[mode * 512 + 256 + p2]


class Cmd:
    """insert: bytes literals; copy: length; dist: int distance | None (implicit 'last distance') |
    ('dict', length, word_idx, transform)."""

    def __init__(self, insert, copy, dist):
        self.insert = insert
        self.copy = copy
        self.dist = dist


def blocks_for(n_items, ntypes, rng, maxlen=64):
    """Random block partition: list of [type, count] covering n_items, starting with type 0."""
    if ntypes == 1 or n_items == 0:
        return [[0, max(1, n_items)]]
    out, t, left = [], 0, n_items
    while left > 0:
        c = min(left, rng.randint(1, maxlen))
        out.append([t, c])
        left -= c
        nt = rng.randrange(ntypes)
        if nt == t:
            nt = (t + 1) % ntypes
        t = nt
    return out


class BlockWriter:
    def __init__(self, ntypes, blocks, rng):
        self.ntypes = ntypes
        self.blocks = blocks
        self.rng = rng
        self.bi = 0
        self.left = blocks[0][1]
        self.last, self.second = 0, 1
        self.type = 0

    def header(self, bw):
        write_var8(bw, self.ntypes - 1)
        if self.ntypes < 2:
            return
        self.tcode = write_code(bw, self.ntypes + 2, flat_lengths(range(self.ntypes + 2), rot=self.rng.randrange(7)),
                                self.rng)
        self.lcode = write_code(bw, 26, flat_lengths(range(26), rot=self.rng.randrange(26)), self.rng)
        c, e = block_len_code(self.blocks[0][1])
        self.lcode.put(bw, c)
        bw.bits(e, BLEN_BITS[c])

    def step(self, bw):
        """Called before every item of this category; emits a block switch when due."""
        if self.ntypes < 2:
            return
        if self.left == 0:
            self.bi += 1
            t, n = self.blocks[self.bi]
            opts = [t + 2]
            if t == self.second:
                opts.append(0)
            if t == (self.last + 1) % self.ntypes:
                opts.append(1)
            self.tcode.put(bw, self.rng.choice(opts))
            c, e = block_len_code(n)
            self.lcode.put(bw, c)
            bw.bits(e, BLEN_BITS[c])
            self.second, self.last = self.last, t
            self.type = t
            self.left = n
        self.left -= 1


def write_context_map(bw, cmap, ntrees, rng, rlemax=None, mtf=None, bad=None):
    write_var8(bw, ntrees - 1)
    if ntrees < 2:
        return
    rlemax = rng.randrange(17) if rlemax is None else rlemax
    mtf = rng.random() < 0.5 if mtf is None else mtf
    vals = list(cmap)
    if mtf:
        lst = list(range(256))
        enc = []
        for v in vals:
            i = lst.index(v)
            enc.append(i)
            lst.pop(i)
            lst.insert(0, v)
        vals = enc
    toks = []
    i = 0
    while i < len(vals):
        if vals[i] == 0 and rlemax > 0:
            j = i
            while j < len(vals) and vals[j] == 0:
                j += 1
            r = j - i
            while r > 0:
                if r == 1:
                    toks.append((0, 0, 0))
                    r = 0
                    continue
                k = min(rlemax, bitlen(r) - 1)
                take = min(r, (1 << (k + 1)) - 1)
                toks.append((k, take - (1 << k), k))
                r -= take
            i = j
        else:
            toks.append((vals[i] + rlemax if vals[i] else 0, 0, 0))
            i += 1
    if bad == 'tree_oob':
        toks.append((ntrees + rlemax, 0, 0))
    if bad == 'rle_overrun' and rlemax > 0:
        toks.append((rlemax, (1 << rlemax) - 1, rlemax))
    bw.bits(1 if rlemax else 0, 1)
    if rlemax:
        bw.bits(rlemax - 1, 4)
    alpha = ntrees + rlemax + (1 if bad == 'tree_oob' else 0)
    used = sorted(set(t[0] for t in toks))
    code = write_code(bw, ntrees + rlemax, flat_lengths(used, rot=rng.randrange(5)), rng)
    for s, ev, eb in toks:
        code.put(bw, s)
        if eb:
            bw.bits(ev, eb)
    bw.bits(1 if mtf else 0, 1)


class Stream:
    """Builds a whole Brotli stream meta-block by meta-block while tracking decoder state (pos, ring buffer)."""

    def __init__(self, wbits, rng):
        self.bw = BW()
        self.wbits = wbits
        self.window = (1 << wbits) - 16
        self.rng = rng
        self.out = bytearray()  # expected output
        self.rb = [16, 15, 11, 4]
        self.rbi = 3
        write_wbits(self.bw, wbits)

    def dict_word(self, L, idx, t):
        """Dictionary reference command (distance is resolved against the output position at emission)."""
        return Cmd(b'', L, ('dict', L, idx, t))

    def metadata(self, payload=b'', last=False, bad=None):
        bw = self.bw
        bw.bits(1 if last else 0, 1)
        if last:
            bw.bits(0, 1)
        bw.bits(3, 2)
        bw.bits(1 if bad == 'reserved' else 0, 1)
        n = len(payload)
        if n == 0:
            bw.bits(0, 2)
        else:
            nb = (bitlen(n - 1) + 7) // 8 or 1
            if bad == 'noncanon':
                nb += 1
            bw.bits(nb, 2)
            bw.bits(n - 1, nb * 8)
        bw.align(1 if bad == 'pad' else 0)
        bw.raw(payload)

    def uncompressed(self, payload, bad=None, nibbles=None):
        bw = self.bw
        bw.bits(0, 1)
        write_mlen(bw, len(payload), nibbles)
        bw.bits(1, 1)
        bw.align(1 if bad == 'pad' else 0)
        bw.raw(payload)
        self.out += payload

    def finish(self, pad=0, empty_last=True):
        if empty_last:
            self.bw.bits(1, 1)
            self.bw.bits(1, 1)
        return self.bw.done(pad)

    def compressed(self, cmds, last=False, npostfix=0, ndirect=0, ntypes=(1, 1, 1), modes=None, ntrees_l=1,
                   ntrees_d=1, use_short=True, skew=False, code_opts=None, bad=None, mlen_override=None,
                   cmap_l=None, cmap_d=None, rlemax=None, mtf=None):
        """Emit one compressed meta-block made of `cmds`; returns its MLEN.  The last command may set
        copy_ignored=True (its insert ends the meta-block, so copy/distance are never read)."""
        rng = self.rng
        bw = self.bw
        code_opts = code_opts or {}
        nd = ndirect << npostfix
        out = self.out
        out0 = len(out)
        rb, rbi = self.rb, self.rbi
        n_lit = sum(len(c.insert) for c in cmds)
        n_dist_max = len(cmds)
        lb = BlockWriter(ntypes[0], blocks_for(n_lit, ntypes[0], rng), rng)
        cb = BlockWriter(ntypes[1], blocks_for(len(cmds), ntypes[1], rng), rng)
        db = BlockWriter(ntypes[2], blocks_for(n_dist_max, ntypes[2], rng), rng)
        modes = modes or [rng.randrange(4) for _ in range(ntypes[0])]
        cmap_l = cmap_l or [rng.randrange(ntrees_l) for _ in range(64 * ntypes[0])]
        cmap_d = cmap_d or [rng.randrange(ntrees_d) for _ in range(4 * ntypes[2])]
        lit_syms = [set() for _ in range(ntrees_l)]
        cmd_syms = [set() for _ in range(ntypes[1])]
        dst_syms = [set() for _ in range(ntrees_d)]
        # simulated block cursors: [index, left]
        cur = {'l': [0, lb.blocks[0][1]], 'c': [0, cb.blocks[0][1]], 'd': [0, db.blocks[0][1]]}
        blk = {'l': lb.blocks, 'c': cb.blocks, 'd': db.blocks}

        def take(k):
            if cur[k][1] == 0:
                cur[k][0] += 1
                cur[k][1] = blk[k][cur[k][0]][1]
            cur[k][1] -= 1
            return blk[k][cur[k][0]][0]

        plan = []
        for ci, c in enumerate(cmds):
            p = {'cmd': c}
            ctype = take('c')
            lits = []
            for byte in c.insert:
                bt = take('l')
                p1 = out[-1] if len(out) >= 1 else 0
                p2 = out[-2] if len(out) >= 2 else 0
                tree = cmap_l[bt * 64 + ctx_id(LUT, modes[bt], p1, p2)]
                lit_syms[tree].add(byte)
                lits.append(tree)
                out.append(byte)
            p['lit_trees'] = lits
            ic, ie = code_for(INSERT_BASE, INSERT_BITS, len(c.insert))
            cc, ce = code_for(COPY_BASE, COPY_BITS, c.copy)
            ignored = c.copy_ignored and ci == len(cmds) - 1
            implicit = c.dist is None
            if implicit and ic < 8 and cc < 16:
                cell = 0 if cc < 8 else 1
            else:
                assert not implicit or ignored, 'implicit distance needs insert<6 / copy<10 codes'
                cell = CELLS[(ic & ~7, cc & ~7)]
            sym = (cell << 6) | ((ic & 7) << 3) | (cc & 7)
            cmd_syms[ctype].add(sym)
            p['sym'] = (ctype, sym, ic, ie, cc, ce)
            plan.append(p)
            if ignored:
                continue
            maxd = min(len(out), self.window)
            dcode = None
            if implicit:
                d = rb[rbi & 3]
            elif isinstance(c.dist, tuple):
                _, L, idx, t = c.dist[:4]
                d = maxd + 1 + ((t << NDBITS[L]) | idx) if len(c.dist) == 4 else c.dist[4]
                dcode = dist_code(d, npostfix, nd)
            else:
                d = c.dist
                sc = short_codes(d, rb, rbi) if use_short else []
                if sc and rng.random() < 0.7:
                    dcode = (rng.choice(sc), 0, 0)
                else:
                    dcode = dist_code(d, npostfix, nd)
            if cell >= 2:
                dtype = take('d')
                cidx = 3 if c.copy > 4 else c.copy - 2
                tree = cmap_d[dtype * 4 + cidx]
                dst_syms[tree].add(dcode[0])
                p['dist'] = (tree, dcode)
            if d > maxd:
                _, L, idx, t = c.dist[:4]
                start = DICT_OFF[L] + idx * L
                out += apply_transform(DICT[start:start + L], t)
            else:
                for _ in range(c.copy):
                    out.append(out[-d])
                if not implicit and dcode[0] != 0:
                    rbi += 1
                    rb[rbi & 3] = d
        self.rbi = rbi
        real_mlen = len(out) - out0
        # ---- header ----------------------------------------------------------------------------------
        bw.bits(1 if last else 0, 1)
        if last:
            bw.bits(0, 1)
        write_mlen(bw, mlen_override or real_mlen, code_opts.get('mlen_nibbles'))
        if not last:
            bw.bits(0, 1)
        lb.header(bw)
        cb.header(bw)
        db.header(bw)
        bw.bits(npostfix, 2)
        bw.bits(ndirect, 4)
        for m in modes:
            bw.bits(m, 2)
        write_context_map(bw, cmap_l, ntrees_l, rng, rlemax=rlemax, mtf=mtf,
                          bad=bad if bad in ('tree_oob', 'rle_overrun') else None)
        write_context_map(bw, cmap_d, ntrees_d, rng, rlemax=rlemax, mtf=mtf)
        copts = {k: v for k, v in code_opts.items() if k in ('force_complex', 'use_rle', 'hskip')}
        lit_codes = [write_code(bw, 256, flat_lengths(lit_syms[t] or {rng.randrange(256)}, rot=t + rng.randrange(3),
                                                      skew=skew), rng, copts) for t in range(ntrees_l)]
        cmd_codes = [write_code(bw, 704, flat_lengths(cmd_syms[t] or {rng.randrange(704)}, rot=t, skew=skew), rng,
                                copts) for t in range(ntypes[1])]
        dalpha = 16 + nd + (48 << npostfix)
        dst_codes = [write_code(bw, dalpha, flat_lengths(dst_syms[t] or {rng.randrange(dalpha)}, rot=t, skew=skew),
                                rng, copts) for t in range(ntrees_d)]
        # ---- commands --------------------------------------------------------------------------------
        for p in plan:
            c = p['cmd']
            cb.step(bw)
            ctype, sym, ic, ie, cc, ce = p['sym']
            assert ctype == cb.type
            cmd_codes[ctype].put(bw, sym)
            bw.bits(ie, INSERT_BITS[ic])
            bw.bits(ce, COPY_BITS[cc])
            for byte, tree in zip(c.insert, p['lit_trees']):
                lb.step(bw)
                lit_codes[tree].put(bw, byte)
            if 'dist' in p:
                db.step(bw)
                tree, (code, ev, eb) = p['dist']
                dst_codes[tree].put(bw, code)
                if eb:
                    bw.bits(ev, eb)
        return real_mlen


DICT = b''
LUT = b''
TRANSFORMS = []


def load_refs(d):
    """Load the static dictionary, context LUT and transform table dumped from libbrotlicommon by c_audit."""
    global DICT, LUT, TRANSFORMS
    DICT = open(d + '/dict.bin', 'rb').read()
    LUT = open(d + '/lut.bin', 'rb').read()
    b = open(d + '/transforms.bin', 'rb').read()
    i, TRANSFORMS = 0, []
    while i < len(b):
        pl = b[i]
        pre = b[i + 1:i + 1 + pl]
        i += 1 + pl
        t = b[i]
        i += 1
        sl = b[i]
        suf = b[i + 1:i + 1 + sl]
        i += 1 + sl
        TRANSFORMS.append((pre, t, suf))
    assert len(DICT) == 122784 and len(LUT) == 2048 and len(TRANSFORMS) == 121


def to_upper(w, i):
    """RFC 7932 §8 ToUpperCase on w[i:]; bytes past the word end are not touched (the reference XORs scratch
    space that is overwritten by the suffix)."""
    c = w[i]
    if c < 192:
        if 97 <= c <= 122:
            w[i] ^= 32
        return 1
    if c < 224:
        if i + 1 < len(w):
            w[i + 1] ^= 32
        return 2
    if i + 2 < len(w):
        w[i + 2] ^= 5
    return 3


def apply_transform(word, t):
    pre, typ, suf = TRANSFORMS[t]
    w = bytearray(word)
    if 1 <= typ <= 9:
        w = w[:max(0, len(w) - typ)]
    elif 12 <= typ <= 20:
        w = w[typ - 11:]
    if typ == 10 and w:
        to_upper(w, 0)
    elif typ == 11:
        i = 0
        while i < len(w):
            i += to_upper(w, i)
    return bytes(pre) + bytes(w) + bytes(suf)


def word_count(L):
    return 1 << NDBITS[L]


def _cmd_init(self, insert, copy, dist, copy_ignored=False):
    self.insert = bytes(insert)
    self.copy = copy
    self.dist = dist
    self.copy_ignored = copy_ignored


Cmd.__init__ = _cmd_init
