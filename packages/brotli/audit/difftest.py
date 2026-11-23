#!/usr/bin/env python3
"""Red-team differential harness for `packages/brotli` (RFC 7932 decoder).

Every input is decoded by four implementations and the verdicts + output (length, FNV-1a 64) are compared:

  pion        Pion native  (`audit/src/main.pion`, --release)
  pion_wasm   Pion wasm32  (same source, node + pion_wasm_rt.mjs)
  c           Google libbrotlidec 1.2.x (`diff/c/c_audit.c`, streaming API)  <- reference oracle
  rust        Rust brotli-decompressor 4.0.3 (the decoder of `brotli 7.0.0`) <- second opinion

Inputs come from `brenc.py` (an independent RFC 7932 stream writer that also tracks the expected output) and from
Google's libbrotlienc at every quality q0..q11 and window lgwin 10..24.

Sections:
  vectors   RFC 7932 edge / malformed vectors (headers, WBITS 10..24, metadata, uncompressed, prefix codes, block
            switching, context maps, NPOSTFIX x NDIRECT, ring buffer, window wrap) + all 121 transforms over all
            13,504 dictionary words + libbrotlienc q0..q11 x lgwin 10..24 corpora
  fuzz      >= 20,000 mutated streams (bit flip / byte set / truncate / insert / delete / splice / structured
            malformed generation): crash, hang, native-vs-wasm and pion-vs-C disagreement detection
  all       both

Usage: python3 difftest.py <section> [--fuzz N] [--seed S]
Artifacts: $AUDIT_OUT (default /private/tmp/pion-brotli-audit).  Exit code != 0 when a Pion defect is found.
Verdict mapping: pion `TrailingData` == C/Rust success with unread input (`TRAIL`); pion `OutputLimitExceeded` ==
harness `ERR LIMIT`.  Rust-only divergences from C are reported as reference notes, never as Pion defects.
"""
import argparse
import json
import os
import random
import struct
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import brenc as E  # noqa: E402

OUT = os.environ.get('AUDIT_OUT', '/private/tmp/pion-brotli-audit')
BIN = os.path.join(OUT, 'bin')
LIMIT = 64 * 1024 * 1024
RT = os.path.expanduser('~/.pion/share/pion/pion_wasm_rt.mjs')
IMPLS = {
    'pion': lambda: [os.path.join(BIN, 'pion_audit')],
    'pion_wasm': lambda: ['node', RT, os.path.join(BIN, 'pion_audit.wasm')],
    'c': lambda: [os.path.join(BIN, 'c_audit')],
    'rust': lambda: [os.path.join(BIN, 'rust_audit')],
}


def fnv(b):
    h = 14695981039346656037
    for x in b:
        h = ((h ^ x) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return h


def ok_line(b):
    return f'OK {len(b)} {fnv(b)}'


def pack(recs):
    return b''.join(struct.pack('<I', len(r)) + r for r in recs)


def run_batch(impl, recs, tag, chunk=4000, timeout=600):
    """Run one implementation over all records; crashes / hangs are isolated to the offending record."""
    res = []
    for c0 in range(0, len(recs), chunk):
        part = recs[c0:c0 + chunk]
        lines = _run(impl, part, f'{tag}_{c0}', timeout)
        if lines is None or len(lines) != len(part):
            lines = []
            for i, r in enumerate(part):
                l1 = _run(impl, [r], f'{tag}_{c0}_{i}', 60)
                lines.append(l1[0] if l1 and len(l1) == 1 else (l1 and l1[0]) or 'CRASH')
        res += lines
    return res


def _run(impl, recs, tag, timeout):
    path = os.path.join(OUT, f'cases_{impl}_{tag}.bin')
    open(path, 'wb').write(pack(recs))
    try:
        p = subprocess.run(IMPLS[impl]() + ['batch', path, str(LIMIT)], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.unlink(path)
        return ['TIMEOUT'] if len(recs) == 1 else None
    os.unlink(path)
    lines = p.stdout.decode(errors='replace').splitlines()
    if p.returncode != 0:
        if len(recs) == 1:
            err = p.stderr.decode(errors='replace').strip().splitlines()
            return ['CRASH ' + (err[-1][:120] if err else f'rc={p.returncode}')]
        return None
    return lines


def verdict(line):
    """Canonical verdict used for cross-implementation comparison."""
    if line.startswith('OK'):
        return line
    if line.startswith('TRAIL') or line == 'ERR TrailingData':
        return 'TRAIL'
    if line in ('ERR LIMIT', 'ERR OutputLimitExceeded'):
        return 'LIMIT'
    if line.startswith('ERR'):
        return 'ERR'
    return line.split()[0]  # CRASH / TIMEOUT / PANIC


# ---------------------------------------------------------------------------------------------------------------
# Vector generation
# ---------------------------------------------------------------------------------------------------------------

def gen_corpora(rng):
    words = [w.decode('latin-1') for w in rng.sample(sorted(set(E.DICT[E.DICT_OFF[5]:E.DICT_OFF[6]][i:i + 5]
                                                     for i in range(0, 5 << 10, 5))), 400)]
    text = ' '.join(rng.choice(words) for _ in range(9000)).encode('latin-1')
    html = b''.join(b'<div class="c%d"><a href="https://example.com/p/%d">%s</a></div>\n' %
                    (rng.randrange(50), rng.randrange(10 ** 6), rng.choice(words).encode('latin-1')) for _ in range(900))
    js = b''.join(b'{"id":%d,"name":"%s","tags":["%s","%s"],"v":%f},' % (i, rng.choice(words).encode('latin-1'),
                  rng.choice(words).encode('latin-1'), rng.choice(words).encode('latin-1'), rng.random()) for i in range(700))
    utf8 = ''.join(rng.choice(['你好世界', 'Ünïcödé', 'привет', '😀🚀', 'ÀÉÎÕÜ', 'ﬁ', 'Ωmega', 'ǅ', 'abc '])
                   for _ in range(4000)).encode()
    rnd = bytes(rng.randrange(256) for _ in range(32768))
    zeros = b'\0' * 65536
    ab = bytes(rng.choice(b'ab') for _ in range(32768))
    binary = b''.join(struct.pack('<HhI', rng.randrange(4096), rng.randrange(-300, 300), i * 7) for i in range(4000))
    return {'text': text[:40000], 'html': html[:40000], 'json': js[:40000], 'utf8': utf8[:40000], 'random': rnd,
            'zeros': zeros, 'ab': ab, 'binary': binary, 'tiny1': b'a', 'tiny3': b'xyz'}


def c_encode(recs, q, lgwin):
    i = os.path.join(OUT, f'enc_in_{q}_{lgwin}.bin')
    o = os.path.join(OUT, f'enc_out_{q}_{lgwin}.bin')
    open(i, 'wb').write(pack(recs))
    subprocess.run([os.path.join(BIN, 'c_audit'), 'enc', str(q), str(lgwin), i, o], check=True)
    b = open(o, 'rb').read()
    os.unlink(i)
    os.unlink(o)
    out, p = [], 0
    while p + 4 <= len(b):
        n = struct.unpack_from('<I', b, p)[0]
        out.append(b[p + 4:p + 4 + n])
        p += 4 + n
    return out


class V:
    def __init__(self):
        self.items = []  # (id, data, expect)  expect: bytes | 'ERR' | 'TRAIL' | None (oracle = C)

    def add(self, vid, data, expect=None):
        self.items.append((vid, bytes(data), expect))


def lz_cmds(rng, n, window, alphabet=b'abcdefgh', allow_dict=True, far=False):
    """Random command list; tracks output length to keep distances valid."""
    cmds, pos = [], 0
    for _ in range(n):
        ins = bytes(rng.choice(alphabet) if rng.random() < .8 else rng.randrange(256)
                    for _ in range(rng.choice([0, 0, 1, 2, 5, 17, 70]) if pos else rng.randint(1, 9)))
        pos += len(ins)
        if allow_dict and rng.random() < 0.15:
            L = rng.randint(4, 24)
            cmds.append(E.Cmd(ins, L, ('dict', L, rng.randrange(E.word_count(L)), rng.randrange(121))))
            continue
        maxd = min(pos, window)
        d = maxd if far and rng.random() < .3 else rng.randint(1, maxd)
        cp = rng.choice([2, 3, 4, 5, 9, 10, 17, 130, 1100, 2200])
        implicit = rng.random() < 0.15 and len(ins) < 6 and cp < 10 and cmds and cmds[-1].dist is not None \
            and not isinstance(cmds[-1].dist, tuple)
        if implicit:
            cmds.append(E.Cmd(ins, cp, None))
            # implicit distance is the last *pushed* distance; brenc resolves it from its ring buffer
        else:
            cmds.append(E.Cmd(ins, cp, d))
        pos += cp
    return cmds


def build_compressed(rng, wbits, ncmds, **kw):
    s = E.Stream(wbits, rng)
    cmds = lz_cmds(rng, ncmds, (1 << wbits) - 16, far=kw.pop('far', False))
    cmds.append(E.Cmd(b'end', 4, None, copy_ignored=True))
    s.compressed(cmds, last=kw.pop('last', False), **kw)
    return s


def gen_vectors(rng, quick=False):
    v = V()
    # ---- 1. headers / empty streams ---------------------------------------------------------------------
    v.add('empty_0x06', b'\x06', b'')
    v.add('empty_0x3b', b'\x3b', b'')
    v.add('empty_input', b'', 'ERR')
    for w in range(10, 25):
        s = E.Stream(w, rng)
        v.add(f'empty_wbits{w}', s.finish(), b'')
        s = E.Stream(w, rng)
        v.add(f'empty_wbits{w}_pad1', s.finish(pad=1), 'ERR' if s.bw.n else None)
    bw = E.BW()
    bw.bits(1, 1); bw.bits(0, 3); bw.bits(1, 3); bw.bits(1, 1); bw.bits(1, 1)
    v.add('wbits_large_window_marker', bw.done(), 'ERR')
    for w in range(18, 25):
        s = E.Stream(w, rng)
        v.add(f'wbits{w}_header_only_truncated', s.bw.done(), 'ERR')
    v.add('trailing_zero_byte', b'\x06\x00', 'TRAIL')
    v.add('trailing_garbage_4', b'\x06garb', 'TRAIL')
    v.add('trailing_second_stream', b'\x06\x06', 'TRAIL')
    v.add('nonzero_final_padding', b'\x86', 'ERR')
    # ---- 2. metadata meta-blocks ---------------------------------------------------------------------------
    for n in (0, 1, 2, 255, 256, 257, 65535, 65536, 65537, 1 << 20, (1 << 24)):
        s = E.Stream(16, rng)
        s.metadata(bytes(rng.randrange(256) for _ in range(min(n, 70000))) if n <= 70000 else b'\xaa' * n)
        v.add(f'metadata_skip{n}', s.finish(), b'')
    s = E.Stream(16, rng)
    s.metadata(b'abc', bad='reserved')
    v.add('metadata_reserved_bit', s.finish(), 'ERR')
    s = E.Stream(16, rng)
    s.metadata(b'abc', bad='noncanon')
    v.add('metadata_noncanonical_MSKIPLEN', s.finish(), 'ERR')
    s = E.Stream(16, rng)
    s.metadata(b'abc', bad='pad')
    v.add('metadata_nonzero_padding', s.finish(), 'ERR' if True else None)
    s = E.Stream(16, rng)
    s.metadata(b'abcdef')
    v.add('metadata_truncated', s.finish()[:-3], 'ERR')
    s = E.Stream(16, rng)
    s.metadata(b'xyz', last=True)
    v.add('metadata_as_last_block', s.finish(empty_last=False), None)
    s = E.Stream(16, rng)
    for _ in range(1000):
        s.metadata(b'')
    v.add('metadata_x1000_empty', s.finish(), b'')
    s = E.Stream(16, rng)
    s.metadata(b'hdr')
    s.uncompressed(b'payload')
    s.metadata(b'mid')
    s.compressed([E.Cmd(b'lit', 6, 3), E.Cmd(b'!', 4, None, copy_ignored=True)])
    v.add('metadata_interleaved', s.finish(), bytes(s.out))
    # ---- 3. uncompressed meta-blocks / MLEN nibble boundaries ------------------------------------------------
    for n in (1, 2, 16, 65535, 65536, 65537, 1 << 20, (1 << 20) + 1, 1 << 22):
        s = E.Stream(rng.choice([10, 16, 22, 24]), rng)
        s.uncompressed(bytes(rng.randrange(256) for _ in range(min(n, 4096))) * (n // 4096) +
                       bytes(rng.randrange(256) for _ in range(n % 4096)) if n > 4096 else
                       bytes(rng.randrange(256) for _ in range(n)))
        v.add(f'uncompressed_mlen{n}', s.finish(), bytes(s.out))
    s = E.Stream(24, rng)
    s.uncompressed(b'\x5a' * (1 << 24))
    v.add('uncompressed_mlen_max_16MiB', s.finish(), bytes(s.out))
    s = E.Stream(16, rng)
    s.uncompressed(b'abc', nibbles=5)
    v.add('uncompressed_noncanonical_MLEN_5nib', s.finish(), 'ERR')
    s = E.Stream(16, rng)
    s.uncompressed(b'abc' * 30000, nibbles=6)
    v.add('uncompressed_noncanonical_MLEN_6nib', s.finish(), 'ERR')
    s = E.Stream(16, rng)
    s.uncompressed(b'abc', bad='pad')
    v.add('uncompressed_nonzero_padding', s.finish(), 'ERR')
    s = E.Stream(16, rng)
    s.uncompressed(b'abcdefgh')
    v.add('uncompressed_truncated', s.finish()[:-4], 'ERR')
    s = E.Stream(10, rng)
    for i in range(50):
        s.uncompressed(bytes([i]) * 333)
    s.compressed([E.Cmd(b'', 1000, 1008), E.Cmd(b'Z', 4, None, copy_ignored=True)])
    v.add('uncompressed_x50_then_copy_at_window_w10', s.finish(), bytes(s.out))
    # ---- 4. compressed: NPOSTFIX x NDIRECT, block switching, context maps, codes -----------------------------
    n_rand = 4 if quick else 1
    for P in range(4):
        for N in range(16):
            for k in range(n_rand):
                w = rng.choice([10, 12, 16, 18, 22, 24])
                s = build_compressed(rng, w, rng.randint(5, 60), npostfix=P, ndirect=N,
                                     ntypes=(rng.randint(1, 3), rng.randint(1, 3), rng.randint(1, 3)),
                                     ntrees_l=rng.randint(1, 4), ntrees_d=rng.randint(1, 4))
                v.add(f'dist_P{P}_N{N}_w{w}_{k}', s.finish(), bytes(s.out))
    for nt in (2, 3, 4, 17, 64, 255, 256):
        for cat in range(3):
            ntypes = [1, 1, 1]
            ntypes[cat] = nt
            s = build_compressed(rng, 16, 200 if nt < 64 else 600, ntypes=tuple(ntypes),
                                 ntrees_l=rng.randint(1, 4), ntrees_d=rng.randint(1, 3))
            v.add(f'nbltypes_{"LID"[cat]}{nt}', s.finish(), bytes(s.out))
    s = build_compressed(rng, 16, 900, ntypes=(256, 256, 256), ntrees_l=256, ntrees_d=256)
    v.add('nbltypes_all256_ntrees256', s.finish(), bytes(s.out))
    for nt in (2, 5, 16, 100, 255, 256):
        for rle in (0, 1, 4, 16):
            for mtf in (False, True):
                cm = [0] * 64
                for i in range(64):
                    cm[i] = 0 if rng.random() < 0.5 else rng.randrange(nt)
                s = build_compressed(rng, 16, 60, ntrees_l=nt, ntrees_d=min(nt, rng.randint(1, 8)), rlemax=rle,
                                     mtf=mtf, cmap_l=cm, modes=[rng.randrange(4)])
                v.add(f'cmap_nt{nt}_rle{rle}_mtf{int(mtf)}', s.finish(), bytes(s.out))
    for mode in range(4):
        for k in range(3):
            s = E.Stream(16, rng)
            txt = rng.choice([b'Hello World', 'Ünïcödé 你好 😀'.encode(), bytes(range(256)), b'\xff\x80\x7f\x00'])
            cmds = [E.Cmd(bytes(rng.choice(txt) for _ in range(rng.randint(1, 300))), 4, rng.randint(1, 1))
                    for _ in range(20)]
            cmds.append(E.Cmd(b'.', 4, None, copy_ignored=True))
            s.compressed(cmds, modes=[mode], ntrees_l=64, cmap_l=list(range(64)))
            v.add(f'context_mode{mode}_64trees_{k}', s.finish(), bytes(s.out))
    for skew in (False, True):
        for opts in ({'use_rle': False}, {'use_rle': True}, {'hskip': 2}, {'hskip': 3}, {'force_complex': True}):
            s = build_compressed(rng, 18, 120, skew=skew, code_opts=dict(opts), ntrees_l=3)
            v.add(f'codes_skew{int(skew)}_{"_".join(f"{a}{b}" for a, b in opts.items())}', s.finish(),
                  bytes(s.out))
    # 2-level table with every literal at a 15-bit code
    s = E.Stream(16, rng)
    lits = bytes(range(256)) * 3
    s.compressed([E.Cmd(lits, 4, None, copy_ignored=True)], skew=True)
    v.add('codes_deep_all256_literals', s.finish(), bytes(s.out))
    for last in (False, True):
        s = build_compressed(rng, 16, 30, last=last)
        v.add(f'compressed_islast{int(last)}', s.finish(empty_last=not last), bytes(s.out))
    # ---- 5. window wrap / ring buffer for every WBITS ----------------------------------------------------------
    for w in range(10, 25):
        win = (1 << w) - 16
        s = E.Stream(w, rng)
        total = 0
        target = min(3 * win, 1 << 22) if w < 24 else (1 << 24) + 4096
        while total < target:
            seg = bytes(rng.randrange(256) for _ in range(rng.randint(1, 64)))
            cmds = [E.Cmd(seg, 4, None, copy_ignored=True)] if total == 0 else []
            mb = 0
            if total:
                pos = total
                while mb < (1 << 20) and pos < target:
                    maxd = min(pos, win)
                    d = rng.choice([maxd, maxd - 1, 1, rng.randint(1, maxd)])
                    cp = rng.choice([4, 64, 2118, 50000]) if maxd > 5000 else rng.randint(2, 40)
                    cmds.append(E.Cmd(b'', cp, d))
                    pos += cp
                    mb += cp
                cmds.append(E.Cmd(b'q', 4, None, copy_ignored=True))
            total += s.compressed(cmds, npostfix=rng.randrange(4), ndirect=rng.randrange(16))
        s.compressed([E.Cmd(b'', 4, ('dict', 4, 0, 0)), E.Cmd(b'', 4, min(win, len(s.out))),
                      E.Cmd(b'.', 4, None, copy_ignored=True)])
        v.add(f'window_wrap_w{w}', s.finish(), bytes(s.out))
    # ---- 6. static dictionary: all 121 transforms x all 13,504 words ---------------------------------------------
    for t in range(121):
        s = E.Stream(24, rng)
        cmds = []
        for L in range(4, 25):
            for idx in range(E.word_count(L)):
                cmds.append(E.Cmd(b'', L, ('dict', L, idx, t)))
        for i in range(0, len(cmds), 3000):
            part = cmds[i:i + 3000] + [E.Cmd(b'|', 4, None, copy_ignored=True)]
            s.compressed(part, npostfix=rng.randrange(4), ndirect=rng.randrange(16))
        v.add(f'dict_transform{t:03d}_all_words', s.finish(), bytes(s.out))
    # small window: dictionary distance base = window
    for t in rng.sample(range(121), 12):
        s = E.Stream(10, rng)
        s.uncompressed(bytes(rng.randrange(256) for _ in range(2000)))
        cmds = [E.Cmd(b'', L, ('dict', L, rng.randrange(E.word_count(L)), t)) for L in range(4, 25)]
        cmds.append(E.Cmd(b'.', 4, None, copy_ignored=True))
        s.compressed(cmds)
        v.add(f'dict_w10_transform{t}', s.finish(), bytes(s.out))
    # ---- 7. libbrotlienc q0..q11 x lgwin 10..24 ----------------------------------------------------------------------
    corp = gen_corpora(rng)
    names = sorted(corp)
    for q in range(12):
        for w in range(10, 25):
            sel = names if not quick else names[:3]
            enc = c_encode([corp[n] for n in sel], q, w)
            for n, e in zip(sel, enc):
                v.add(f'libbrotli_q{q}_w{w}_{n}', e, corp[n])
    big = (corp['text'] + corp['html'] + corp['utf8'] + corp['binary']) * 40
    for q in (0, 1, 5, 9, 11):
        e = c_encode([big], q, 24)[0]
        v.add(f'libbrotli_q{q}_w24_mixed_{len(big)}B', e, big)
    return v


def gen_malformed(rng):
    v = V()
    s = E.Stream(16, rng)
    s.compressed([E.Cmd(b'abc', 4, None, copy_ignored=True)], mlen_override=2)
    v.add('bad_insert_exceeds_MLEN', s.finish(), 'ERR')
    s = E.Stream(16, rng)
    s.compressed([E.Cmd(b'abc', 10, 1), E.Cmd(b'x', 4, None, copy_ignored=True)], mlen_override=8)
    v.add('bad_copy_exceeds_MLEN', s.finish(), 'ERR')
    s = E.Stream(16, rng)
    s.compressed([E.Cmd(b'abc', 10, ('dict', 10, 5, 0)), E.Cmd(b'x', 4, None, copy_ignored=True)],
                 mlen_override=8)
    v.add('bad_dict_word_exceeds_MLEN', s.finish(), 'ERR')
    for L in (2, 3, 25, 26, 100):
        s = E.Stream(16, rng)
        s.compressed([E.Cmd(b'abc', L, ('dict', 4, 0, 0, 4)), E.Cmd(b'x', 4, None, copy_ignored=True)],
                     mlen_override=3 + L + 1)
        v.add(f'bad_dict_copylen{L}', s.finish(), 'ERR')
    for t in (121, 122, 127):
        for L in (4, 24):
            s = E.Stream(16, rng)
            s.compressed([E.Cmd(b'abc', L, ('dict', L, 0, 0, 3 + 1 + (t << E.NDBITS[L]))),
                          E.Cmd(b'x', 4, None, copy_ignored=True)], mlen_override=3 + L + 1)
            v.add(f'bad_dict_transform{t}_L{L}', s.finish(), 'ERR')
    s = E.Stream(16, rng)
    s.compressed([E.Cmd(b'a', 4, None, copy_ignored=True)], bad='tree_oob', ntrees_l=3)
    v.add('bad_cmap_tree_oob', s.finish(), 'ERR')
    s = E.Stream(16, rng)
    s.compressed([E.Cmd(b'a', 4, None, copy_ignored=True)], bad='rle_overrun', ntrees_l=3, rlemax=6)
    v.add('bad_cmap_rle_overrun', s.finish(), 'ERR')
    # simple code with duplicate symbols / out-of-range symbol, built through write_code options
    for name, alpha, lens, opts in [
        ('simple_dup2', 256, {65: 1, 66: 1}, {'bad_dup': True}),
        ('simple_dup4', 256, {65: 2, 66: 2, 67: 2, 68: 2}, {'bad_dup': True}),
        ('simple_cmd_sym_ge_704', 704, {3: 1, 25: 1}, {'bad_sym': 1000}),
    ]:
        s = E.Stream(16, rng)
        bw = s.bw
        bw.bits(1, 1); bw.bits(0, 1)
        E.write_mlen(bw, 1)
        for _ in range(3):
            E.write_var8(bw, 0)
        bw.bits(0, 2); bw.bits(0, 4); bw.bits(0, 2)
        E.write_var8(bw, 0); E.write_var8(bw, 0)
        if alpha == 704:
            E.write_code(bw, 256, {65: 0})
        E.write_code(bw, alpha, lens, None, opts)
        v.add(f'bad_{name}', s.bw.done() + b'\0\0\0\0', 'ERR')
    # complex literal codes: incomplete / oversubscribed / repeat past alphabet / bad code-length code
    complex_cases = {
        'complex_incomplete': [1, 2, 3, 3, 4],
        'complex_oversubscribed': [1, 1, 2],
        'complex_single_len1': [0] * 10 + [1],
    }
    for name, seq in complex_cases.items():
        s = E.Stream(16, rng)
        bw = s.bw
        bw.bits(1, 1); bw.bits(0, 1)
        E.write_mlen(bw, 1)
        for _ in range(3):
            E.write_var8(bw, 0)
        bw.bits(0, 2); bw.bits(0, 4); bw.bits(0, 2)
        E.write_var8(bw, 0); E.write_var8(bw, 0)
        E.write_code(bw, 256, {i: 1 for i in range(5)}, None, {'force_complex': True, 'override_seq': seq,
                                                              'use_rle': False})
        v.add(f'bad_{name}', s.bw.done() + b'\0' * 8, 'ERR')
    for name, cl in [('cl_incomplete', {1: 1, 2: 2, 0: 3}), ('cl_oversubscribed', {1: 1, 2: 1, 0: 1}),
                     ('cl_zero_codes', {})]:
        s = E.Stream(16, rng)
        bw = s.bw
        bw.bits(1, 1); bw.bits(0, 1)
        E.write_mlen(bw, 1)
        for _ in range(3):
            E.write_var8(bw, 0)
        bw.bits(0, 2); bw.bits(0, 4); bw.bits(0, 2)
        E.write_var8(bw, 0); E.write_var8(bw, 0)
        bw.bits(0, 2)
        sp = 32
        for i in range(18):
            l = cl.get(E.CL_ORDER[i], 0)
            bw.bits(*E.CL_LEN_CODE[l])
            if l:
                sp -= 32 >> l
                if sp <= 0:
                    break
        v.add(f'bad_{name}', s.bw.done() + b'\0' * 8, 'ERR')
    # repeat code running past the alphabet (alphabet 26 = block-count code): 17 with max extra twice
    s = E.Stream(16, rng)
    bw = s.bw
    bw.bits(1, 1); bw.bits(0, 1)
    E.write_mlen(bw, 1)
    E.write_var8(bw, 1)  # NBLTYPESL = 2 -> block type code (4) + block count code (26)
    E.write_code(bw, 4, {0: 1, 1: 2, 2: 3, 3: 3})
    bw.bits(0, 2)  # complex, hskip 0
    cl = {1: 1, 17: 1}
    sp = 32
    for i in range(18):
        l = cl.get(E.CL_ORDER[i], 0)
        bw.bits(*E.CL_LEN_CODE[l])
        if l:
            sp -= 32 >> l
            if sp <= 0:
                break
    clc = E.Code(cl)
    clc.put(bw, 1); clc.put(bw, 17); bw.bits(7, 3); clc.put(bw, 17); bw.bits(7, 3)
    v.add('bad_repeat_past_alphabet', s.bw.done() + b'\0' * 8, 'ERR')
    # distance before any output that cannot be a dictionary word, and short codes yielding <= 0
    s = E.Stream(16, rng)
    s.compressed([E.Cmd(b'ab', 3, ('dict', 4, 0, 0, 3)), E.Cmd(b'x', 4, None, copy_ignored=True)], mlen_override=6)
    v.add('bad_distance_beyond_output_copy3', s.finish(), 'ERR')
    # ring buffer: last distance 4 -> code 4 = last-1 ... craft distance 1 then code 4 (1-1 = 0)
    s = E.Stream(16, rng)
    cmds = [E.Cmd(b'abcdef', 4, 1)]
    s.compressed(cmds + [E.Cmd(b'x', 4, None, copy_ignored=True)], use_short=False)
    good = s.finish()
    v.add('shortcode_base_ok', good, bytes(s.out))
    return v


# ---------------------------------------------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------------------------------------------

def compare(items, tag, report, impls=('pion', 'pion_wasm', 'c', 'rust')):
    recs = [d for _, d, _ in items]
    t0 = time.time()
    res = {}
    for impl in impls:
        t = time.time()
        res[impl] = run_batch(impl, recs, tag)
        print(f'  {impl:10s} {len(recs)} cases in {time.time() - t:6.1f}s', flush=True)
    rows = []
    for i, (vid, data, exp) in enumerate(items):
        r = {k: res[k][i] for k in impls}
        vp, vc = verdict(r['pion']), verdict(r['c'])
        row = {'id': vid, 'len': len(data), **r}
        if exp is not None:
            ev = ok_line(exp) if isinstance(exp, bytes) else exp
            row['expect'] = ev
            if vc != ev and not (ev == 'ERR' and vc in ('ERR', 'TRAIL')):
                report['oracle_notes'].append(f'{tag}:{vid}: C={r["c"]} expected {ev} (vector expectation off)')
        if vp.split()[0] in ('CRASH', 'TIMEOUT', 'PANIC'):
            report['defects'].append(f'{tag}:{vid}: pion {r["pion"]}')
        if 'pion_wasm' in r and r['pion'] != r['pion_wasm']:
            report['defects'].append(f'{tag}:{vid}: native {r["pion"]} != wasm {r["pion_wasm"]}')
        if vp != vc:
            report['defects'].append(f'{tag}:{vid}: pion {r["pion"]} != C {r["c"]}')
            report.setdefault('repro', {})[f'{tag}:{vid}'] = data.hex() if len(data) <= 4096 else f'<{len(data)} B>'
        if 'rust' in r and verdict(r['rust']) != vc:
            report['rust_divergence'].append(f'{tag}:{vid}: rust {r["rust"]} vs C {r["c"]}')
        rows.append(row)
    report['counts'][tag] = len(items)
    report['elapsed'][tag] = round(time.time() - t0, 1)
    return rows


# ---------------------------------------------------------------------------------------------------------------
# Fuzz
# ---------------------------------------------------------------------------------------------------------------

def mutate(rng, seeds):
    d = bytearray(rng.choice(seeds))
    op = rng.randrange(9)
    if not d:
        return bytes([rng.randrange(256)]), 'byte'
    if op == 0:
        for _ in range(rng.randint(1, 8)):
            i = rng.randrange(len(d) * 8)
            d[i >> 3] ^= 1 << (i & 7)
        return bytes(d), 'bitflip'
    if op == 1:
        i = rng.randrange(min(len(d), 16)) * 8 + rng.randrange(8)  # header-focused flips
        if i // 8 < len(d):
            d[i >> 3] ^= 1 << (i & 7)
        return bytes(d), 'hdrflip'
    if op == 2:
        for _ in range(rng.randint(1, 4)):
            d[rng.randrange(len(d))] = rng.choice([0, 0xff, 0x80, 0x7f, rng.randrange(256)])
        return bytes(d), 'byteset'
    if op == 3:
        return bytes(d[:rng.randrange(len(d))]), 'truncate'
    if op == 4:
        i = rng.randrange(len(d) + 1)
        return bytes(d[:i] + bytes(rng.randrange(256) for _ in range(rng.randint(1, 8))) + d[i:]), 'insert'
    if op == 5:
        i = rng.randrange(len(d))
        return bytes(d[:i] + d[i + rng.randint(1, 8):]), 'delete'
    if op == 6:
        e = rng.choice(seeds)
        return bytes(d[:rng.randrange(len(d) + 1)] + e[rng.randrange(len(e) + 1):]), 'splice'
    if op == 7:
        return bytes(d) + bytes(rng.randrange(256) for _ in range(rng.randint(1, 4))), 'append'
    i = rng.randrange(len(d))
    d[i] = (d[i] + rng.choice([1, -1, 16, -16])) & 0xFF
    return bytes(d), 'arith'


def structured(rng):
    """Random *valid-looking* stream from brenc with random knobs; a fraction gets a random tail bit flip."""
    w = rng.choice([10, 11, 16, 17, 20, 24])
    s = E.Stream(w, rng)
    for _ in range(rng.randint(1, 3)):
        k = rng.random()
        if k < 0.15:
            s.metadata(bytes(rng.randrange(256) for _ in range(rng.randint(0, 20))))
        elif k < 0.3:
            s.uncompressed(bytes(rng.randrange(256) for _ in range(rng.randint(1, 40))))
        else:
            cmds = lz_cmds(rng, rng.randint(1, 25), (1 << w) - 16, far=True) if s.out else \
                [E.Cmd(b'seed', 4, None, copy_ignored=True)]
            if s.out:
                cmds.append(E.Cmd(b'e', 4, None, copy_ignored=True))
            else:
                cmds = cmds
            s.compressed(cmds if s.out else cmds, npostfix=rng.randrange(4), ndirect=rng.randrange(16),
                         ntypes=(rng.randint(1, 4), rng.randint(1, 4), rng.randint(1, 4)),
                         ntrees_l=rng.randint(1, 6), ntrees_d=rng.randint(1, 6), skew=rng.random() < .3,
                         code_opts={'use_rle': rng.random() < .7, 'hskip': rng.choice([0, 0, 2, 3])})
    return s.finish(), bytes(s.out)


def run_fuzz(n, seed, seeds, report):
    rng = random.Random(seed)
    items = []
    n_struct = n // 5
    for i in range(n_struct):
        data, exp = structured(rng)
        items.append((f'struct{i}', data, exp))
    pool = [d for d in seeds if 0 < len(d) <= 65536] + [d for _, d, _ in items[:2000]]
    kinds = {}
    for i in range(n - n_struct):
        data, k = mutate(rng, pool)
        kinds[k] = kinds.get(k, 0) + 1
        items.append((f'mut{i}_{k}', data, None))
    report['fuzz_ops'] = kinds
    rows = compare(items, 'fuzz', report)
    acc = sum(1 for r in rows if verdict(r['pion']).startswith('OK'))
    report['fuzz_accept'] = {'pion_ok': acc, 'total': len(rows)}
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('section', choices=['vectors', 'fuzz', 'all'])
    ap.add_argument('--fuzz', type=int, default=24000)
    ap.add_argument('--seed', type=int, default=7932)
    ap.add_argument('--quick', action='store_true')
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    E.load_refs(OUT)
    report = {'defects': [], 'oracle_notes': [], 'rust_divergence': [], 'counts': {}, 'elapsed': {}}
    rng = random.Random(a.seed)
    t = time.time()
    vec = gen_vectors(rng, a.quick)
    mal = gen_malformed(rng)
    print(f'==> generated {len(vec.items)} vectors + {len(mal.items)} malformed in {time.time() - t:.1f}s', flush=True)
    if a.section in ('vectors', 'all'):
        rows = compare(vec.items, 'vectors', report) + compare(mal.items, 'malformed', report)
        json.dump(rows, open(os.path.join(OUT, 'vectors.json'), 'w'), indent=1)
    if a.section in ('fuzz', 'all'):
        seeds = [d for _, d, _ in vec.items + mal.items]
        rows = run_fuzz(a.fuzz, a.seed, seeds, report)
        json.dump(rows, open(os.path.join(OUT, 'fuzz.json'), 'w'))
    json.dump(report, open(os.path.join(OUT, f'report_{a.section}.json'), 'w'), indent=1)
    print(f'==> counts {report["counts"]}  elapsed {report["elapsed"]}')
    for k in ('defects', 'oracle_notes', 'rust_divergence'):
        print(f'==> {k}: {len(report[k])}')
        for x in report[k][:40]:
            print('   ', x)
    if 'fuzz_accept' in report:
        print('==> fuzz ops', report['fuzz_ops'], 'accepted', report['fuzz_accept'])
    sys.exit(1 if report['defects'] else 0)


if __name__ == '__main__':
    main()
