#!/usr/bin/env python3
"""Red-team differential harness for `packages/woff2` (run with the audit venv: fontTools + brotli).

Decoders compared on identical inputs (canonical line = per-table tag/len/FNV-64 + whole-font checksum):
  pion        Pion native  (`audit/src/main.pion`, --release)
  pion_wasm   Pion wasm32  (same source, node + pion_wasm_rt.mjs)
  rust        Rust `wuff =0.2.10` (`audit/diff/rust`)
  fontTools   (real section only) semantic glyph / metrics comparison against the *original* SFNT

Sections:
  real     real system fonts (TrueType, composite, overlap, CFF/OTF, variable, 50k-glyph CJK, TTC) encoded by
           fontTools as WOFF2 (glyf/loca transform, +hmtx transform, null transform) and WOFF1 (zlib, stored)
  vectors  hand-built W3C WOFF 2.0 / 1.0 edge and malformed files with a spec/reference expectation
  limits   DecodeLimits boundaries (<= 0, exact, exact-1)
  fuzz     mutated files (byte level + structure aware: re-compressed glyf/hmtx streams, WOFF1 directory
           forging): crash / trap / hang, native-vs-wasm, and Pion-vs-wuff verdict disagreement
  all      everything above

Usage: difftest.py <section> [--out DIR] [--fuzz N] [--seed S]
"""
import argparse
import collections
import glob
import json
import os
import random
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # keep the repository clean
sys.path.insert(0, HERE)
import woff2lib as W  # noqa: E402

FONT_DIRS = ['/System/Library/Fonts', '/System/Library/Fonts/Supplemental', '/Library/Fonts']
REAL_FONTS_QUICK = [('Arial.ttf', 0), ('STIXGeneral.otf', 0)]
REAL_FONTS = [
    ('Arial.ttf', 0), ('Monaco.ttf', 0), ('Times New Roman.ttf', 0), ('Georgia.ttf', 0),
    ('Verdana.ttf', 0), ('Geneva.ttf', 0), ('Apple Chancery.ttf', 0), ('Zapfino.ttf', 0),
    ('Apple Symbols.ttf', 0), ('Skia.ttf', 0), ('NewYork.ttf', 0), ('SFNSMono.ttf', 0),
    ('SFNS.ttf', 0), ('STIXTwoText.ttf', 0), ('STIXGeneral.otf', 0), ('STIXTwoMath.otf', 0),
    ('NotoSansJavanese-Regular.otf', 0), ('LastResort.otf', 0), ('Hoefler Text.ttc', 0),
    ('Helvetica.ttc', 1), ('SFIndia.ttc', 0), ('Arial Unicode.ttf', 0),
]
COLLECTIONS = ['Menlo.ttc', 'Avenir.ttc']


def find_font(name):
    for d in FONT_DIRS:
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    return None


# ------------------------------------------------------------------------------------------------
# Running decoders
# ------------------------------------------------------------------------------------------------

def pack(cases):
    return b''.join(struct.pack('<I', len(c)) + c for c in cases)


class Tools:
    def __init__(self, out):
        self.out = out
        b = os.path.join(out, 'bin')
        rt = os.path.expanduser('~/.pion/share/pion/pion_wasm_rt.mjs')
        self.cmds = {
            'pion': [os.path.join(b, 'pion_audit')],
            'pion_wasm': ['node', rt, os.path.join(b, 'pion_audit.wasm')],
            'rust': [os.path.join(b, 'rust_audit')],
        }

    def _run(self, name, args, timeout):
        t0 = time.time()
        try:
            p = subprocess.run(self.cmds[name] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=timeout)
        except subprocess.TimeoutExpired:
            return None, 'TIMEOUT', b'', time.time() - t0
        return p.stdout.decode('latin-1').splitlines(), p.returncode, p.stderr, time.time() - t0

    def file(self, name, path, limits=None, out=None, timeout=300):
        args = ['file', path]
        if name != 'rust':
            args += [str(x) for x in (limits or (67108864, 256, 65536))]
        if out:
            args += [out]
        lines, rc, err, dt = self._run(name, args, timeout)
        if lines is None:
            return 'HANG', dt
        if rc != 0 or not lines:
            return 'CRASH rc=%s %s' % (rc, err.decode('latin-1').strip().splitlines()[-1:] if err else ''), dt
        return lines[0], dt

    def batch(self, name, cases, tag, limits=None, timeout=900):
        """Run a batch; on crash/hang bisect by re-running the remainder so every case gets a verdict."""
        res = []
        start = 0
        while start < len(cases):
            path = os.path.join(self.out, f'cases_{tag}_{name}.bin')
            with open(path, 'wb') as f:
                f.write(pack(cases[start:]))
            args = ['batch', path] + ([str(x) for x in limits] if limits and name != 'rust' else [])
            lines, rc, err, _ = self._run(name, args, timeout)
            if lines is None:
                lines = []
                rc = 'TIMEOUT'
            res += lines[:len(cases) - start]
            done = start + len(lines)
            if done >= len(cases):
                break
            # the case at index `done` crashed (or hung): isolate it
            single = os.path.join(self.out, f'case_{tag}_{name}.bin')
            with open(single, 'wb') as f:
                f.write(pack([cases[done]]))
            l2, rc2, err2, _ = self._run(name, ['batch', single] + (
                [str(x) for x in limits] if limits and name != 'rust' else []), 60)
            if l2 is None:
                res.append('HANG')
            elif rc2 != 0 or not l2:
                msg = err2.decode('latin-1').strip().splitlines()
                res.append('CRASH ' + (msg[0][:160] if msg else f'rc={rc2}'))
            else:  # only crashed inside a larger batch (should not happen): keep its verdict
                res.append(l2[0])
            start = done + 1
        return res


def verdict(line):
    if line.startswith('OK'):
        return 'ok'
    if line.startswith('ERR'):
        return 'err'
    return line.split(' ')[0]  # CRASH / HANG / PANIC


def canon_tables(line):
    """'OK n ck=ok tag:len:h ...' -> (n, ck, {tag: (len, h)})"""
    parts = line.split(' ')
    tabs = {}
    for p in parts[3:]:
        t = p.split(':')
        if len(t) == 3:
            tabs[t[0]] = (int(t[1]), t[2])
    return int(parts[1]), parts[2], tabs


# ------------------------------------------------------------------------------------------------
# Section: real fonts
# ------------------------------------------------------------------------------------------------

def encode_variants(src, idx, outdir):
    from fontTools.ttLib import TTFont
    from fontTools.ttLib import woff2 as ftw2
    base = os.path.splitext(os.path.basename(src))[0].replace(' ', '_') + (f'_{idx}' if src.endswith('.ttc') else '')
    ttf = os.path.join(outdir, base + '.sfnt')
    f = TTFont(src, fontNumber=idx, recalcBBoxes=False, recalcTimestamp=False)
    f.save(ttf, reorderTables=False)
    sfnt = open(ttf, 'rb').read()
    out = {}
    has_glyf = b'glyf' in W.sfnt_tables(sfnt)
    for name, tt in (('w2_glyf', None), ('w2_hmtx', {'glyf', 'loca', 'hmtx'}), ('w2_null', set())):
        if name == 'w2_hmtx' and not has_glyf:
            tt = {'hmtx'}
        p = os.path.join(outdir, f'{base}.{name}.woff2')
        try:
            ftw2.compress(ttf, p, transform_tables=tt)
            out[name] = p
        except Exception as e:  # noqa
            out[name] = 'ENCODE-FAIL ' + str(e)[:80]
    p = os.path.join(outdir, f'{base}.w1_zlib.woff')
    g = TTFont(ttf, recalcBBoxes=False, recalcTimestamp=False)
    g.flavor = 'woff'
    g.save(p, reorderTables=False)
    out['w1_zlib'] = p
    tabs = W.sfnt_tables(sfnt)
    p = os.path.join(outdir, f'{base}.w1_stored.woff')
    order = sorted(tabs)
    open(p, 'wb').write(W.woff1([(t, tabs[t]) for t in order], flavor=struct.unpack('>I', sfnt[:4])[0],
                                compress=False))
    out['w1_stored'] = p
    return ttf, out


def semantic_glyf_compare(orig_path, dec_path):
    """Compare every glyph (contours, on/off flags, overlap bit, instructions, components) and hmtx."""
    from fontTools.ttLib import TTFont
    o = TTFont(orig_path)
    d = TTFont(dec_path)
    bad = []
    if 'glyf' in o:
        og, dg = o['glyf'], d['glyf']
        for name in o.getGlyphOrder():
            a, b = og[name], dg[name]
            if a.numberOfContours != b.numberOfContours:
                bad.append(f'{name}:ncont')
            elif a.numberOfContours > 0:
                if (list(a.coordinates) != list(b.coordinates) or a.endPtsOfContours != b.endPtsOfContours
                        or [x & 1 for x in a.flags] != [x & 1 for x in b.flags]
                        or (a.flags[0] & 0x40) != (b.flags[0] & 0x40)
                        or a.program.getBytecode() != b.program.getBytecode()):
                    bad.append(f'{name}:simple')
            elif a.numberOfContours < 0:
                ca = [(c.glyphName, c.flags & ~0x0200 & ~0x0400, getattr(c, 'x', None), getattr(c, 'y', None),
                       getattr(c, 'transform', None)) for c in a.components]
                cb = [(c.glyphName, c.flags & ~0x0200 & ~0x0400, getattr(c, 'x', None), getattr(c, 'y', None),
                       getattr(c, 'transform', None)) for c in b.components]
                pa = a.program.getBytecode() if hasattr(a, 'program') else b''
                pb = b.program.getBytecode() if hasattr(b, 'program') else b''
                if ca != cb or pa != pb:
                    bad.append(f'{name}:composite')
            if a.numberOfContours != 0 and (a.xMin, a.yMin, a.xMax, a.yMax) != (b.xMin, b.yMin, b.xMax, b.yMax):
                bad.append(f'{name}:bbox')
            if len(bad) > 20:
                break
    if 'hmtx' in o and o['hmtx'].metrics != d['hmtx'].metrics:
        bad.append('hmtx:metrics')
    return bad


def section_real(tools, report, args):
    out = os.path.join(args.out, 'real')
    os.makedirs(out, exist_ok=True)
    rows = []
    for name, idx in REAL_FONTS:
        src = find_font(name)
        if not src:
            rows.append(dict(font=name, variant='-', status='MISSING'))
            continue
        ttf, variants = encode_variants(src, idx, out)
        orig = W.sfnt_tables(open(ttf, 'rb').read())
        for var, path in variants.items():
            row = dict(font=f'{name}#{idx}', variant=var, size=os.path.getsize(ttf))
            if path.startswith('ENCODE-FAIL'):
                row['status'] = path
                rows.append(row)
                continue
            pout = path + '.pion.ttf'
            rout = path + '.rust.ttf'
            p, dt_p = tools.file('pion', path, out=pout)
            r, dt_r = tools.file('rust', path, out=rout)
            w = p if os.path.getsize(path) > 4_000_000 else tools.file('pion_wasm', path)[0]
            row.update(pion=p[:60], rust=r[:60], pion_s=round(dt_p, 3), rust_s=round(dt_r, 3))
            issues = []
            if verdict(p) != 'ok':
                issues.append('pion-rejects-valid:' + p[:60])
            if w != p:
                issues.append('native!=wasm')
            if verdict(p) == 'ok':
                n, ck, tabs = canon_tables(p)
                if ck != 'ck=ok':
                    issues.append('bad-whole-font-checksum')
                dec = W.sfnt_tables(open(pout, 'rb').read())
                # byte-exact table comparison against the original SFNT
                skip = {b'glyf', b'loca', b'head', b'DSIG'} if var.startswith('w2') else {b'head'}
                if var.startswith('w2') and var != 'w2_null':
                    skip.add(b'hmtx')
                for t, data in orig.items():
                    if t in skip:
                        continue
                    if t not in dec:
                        if not (t == b'DSIG' and var.startswith('w2')):
                            issues.append(f'missing:{t.decode()}')
                    elif dec[t] != data:
                        issues.append(f'table-bytes:{t.decode()}')
                if b'head' in orig:
                    a, b = bytearray(orig[b'head']), bytearray(dec[b'head'])
                    a[8:12] = b[8:12] = b'\0\0\0\0'
                    a[16] &= ~0x08  # head.flags bit 11 is set by WOFF2 encoders (lossless-transformed)
                    b[16] &= ~0x08
                    if var.startswith('w2'):
                        a[50:52] = b[50:52]
                        a[20:36] = b[20:36]  # fontTools' WOFF2 encoder rewrites the head timestamps
                    if a != b:
                        issues.append('head')
                if var == 'w2_null' or var.startswith('w1'):
                    for t in (b'glyf', b'loca'):
                        if t in orig and dec.get(t) != orig[t]:
                            issues.append(f'table-bytes:{t.decode()}')
                if var.startswith('w2') and b'glyf' in orig:
                    sem = semantic_glyf_compare(ttf, pout)
                    if sem:
                        issues.append('glyf-semantic:' + ','.join(sem[:5]))
                elif b'hmtx' in orig and var == 'w2_hmtx':
                    sem = semantic_glyf_compare(ttf, pout)
                    if sem:
                        issues.append('semantic:' + ','.join(sem[:5]))
                if verdict(r) == 'ok':
                    _, _, rt = canon_tables(r)
                    diff = sorted(t for t in set(tabs) | set(rt) if tabs.get(t) != rt.get(t))
                    row['vs_wuff_table_diff'] = ','.join(diff)
            row['issues'] = issues
            row['status'] = 'PASS' if not issues else 'FAIL'
            rows.append(row)
            print(f"  {row['font'][:28]:28s} {var:10s} {row['status']:5s} pion={p[:22]:22s} {dt_p:6.3f}s "
                  f"wuff={r[:14]:14s} {dt_r:6.3f}s diff-vs-wuff=[{row.get('vs_wuff_table_diff', '')}] "
                  f"{' '.join(issues)[:120]}", flush=True)
    # WOFF2 collections (fontTools encodes TTC -> WOFF2 collection directory)
    from fontTools.ttLib import TTCollection
    for name in COLLECTIONS:
        src = find_font(name)
        if not src:
            continue
        import io
        from fontTools.ttLib import woff2 as ftw2
        c = TTCollection(src)
        fonts = []
        for f in c.fonts[:4]:
            buf, wbuf = io.BytesIO(), io.BytesIO()
            f.save(buf, reorderTables=False)
            buf.seek(0)
            ftw2.compress(buf, wbuf)
            _, ents, _ = W.parse_woff2(wbuf.getvalue())
            fonts.append((struct.unpack('>I', buf.getvalue()[:4])[0], ents))
        p = os.path.join(out, name.replace(' ', '_') + '.collection.woff2')
        open(p, 'wb').write(W.woff2_collection(fonts))
        pr, _ = tools.file('pion', p)
        rr, _ = tools.file('rust', p)
        st = 'PASS' if verdict(pr) == 'ok' else 'FAIL'
        rows.append(dict(font=name, variant='w2_ttc', pion=pr[:60], rust=rr[:60], status=st,
                         issues=[] if st == 'PASS' else ['collection-unsupported']))
        print(f'  {name:28s} w2_ttc     {st:5s} pion={pr[:40]} wuff={rr[:40]}', flush=True)
    fails = [r for r in rows if r.get('status') != 'PASS']
    report['real'] = rows
    for r in fails:
        report['findings'].append(f"real/{r['font']}/{r['variant']}: {r.get('status')} {r.get('issues')}")
    print(f'  real: {len(rows)} decodes, {len(fails)} with issues')


# ------------------------------------------------------------------------------------------------
# Synthetic fonts for vectors
# ------------------------------------------------------------------------------------------------

SQUARE = [[(0, 0, True), (0, 700, True), (500, 700, True), (500, 0, True)]]


def comp_rec(flags, gidx, args):
    return struct.pack('>HH', flags, gidx) + args


def base_glyphs():
    return [
        None,
        W.Simple(SQUARE, instr=b'\xb0\x01'),
        W.Composite([comp_rec(0x0001 | 0x0002 | 0x0020, 1, struct.pack('>hh', 1000, -300)),  # words, xy, more
                     comp_rec(0x0002 | 0x0008 | 0x0020, 1, struct.pack('>bb', 5, 6) + struct.pack('>h', 0x2000)),
                     comp_rec(0x0002 | 0x0040 | 0x0020, 1, struct.pack('>bbhh', -5, 6, 0x4000, 0x2000)),
                     comp_rec(0x0002 | 0x0080 | 0x0100, 1, struct.pack('>bbhhhh', 1, 2, 0x4000, 0, 0, 0x4000))],
                    bbox=(-50, -300, 1500, 700), instr=b'\xb0\x07'),
        W.Simple([[(10, 10, True), (10, 20, False), (30, 20, True)],
                  [(-2000, 3000, True), (4000, -3000, False), (100, 100, True), (100, 1379, True),
                   (1379, 1379, False), (-40000 // 4, 100, True), (32000, -32000, True)]],
                 instr=b'', overlap=True),
        W.Simple(SQUARE, bbox=(-100, -100, 600, 800)),
    ]


def raw_simple(contours, instr=b'', bbox=None):
    pts = [p for c in contours for p in c]
    bb = bbox or W.bbox_of(contours)
    out = struct.pack('>hhhhh', len(contours), *bb)
    e = -1
    for c in contours:
        e += len(c)
        out += struct.pack('>H', e)
    out += struct.pack('>H', len(instr)) + instr
    out += bytes([1 if on else 0 for (_, _, on) in pts])
    px = py = 0
    xs = ys = b''
    for (x, y, _) in pts:
        xs += struct.pack('>h', x - px)
        ys += struct.pack('>h', y - py)
        px, py = x, y
    out += xs + ys
    return out + b'\0' * ((-len(out)) % 4)


def font_entries(glyphs=None, hmtx_flags=None, index_format=1, glyf_kw=None, nmetrics=None,
                 loca_orig=None, glyf_orig=None, maxp_count=None, raw_glyf=False, raw_loca_override=None):
    glyphs = base_glyphs() if glyphs is None else glyphs
    n = len(glyphs)
    xmins = []
    for g in glyphs:
        if g is None:
            xmins.append(0)
        elif isinstance(g, W.Composite):
            xmins.append(g.bbox[0])
        else:
            xmins.append((g.bbox or W.bbox_of(g.contours))[0])
    nm = n if nmetrics is None else nmetrics
    advs = [600 + i for i in range(min(nm, n))] if nm <= n else [600] * nm
    ents = [W.Entry(b'head', W.head_table(index_format)), W.Entry(b'hhea', W.hhea_table(nm))]
    if hmtx_flags is None:
        ents.append(W.Entry(b'hmtx', W.hmtx_table(advs, xmins)))
    else:
        ents.append(W.Entry(b'hmtx', W.hmtx_transformed(advs, xmins, hmtx_flags), version=1,
                            orig_len=len(W.hmtx_table(advs, xmins))))
    ents.append(W.Entry(b'maxp', W.maxp_table(n if maxp_count is None else maxp_count)))
    if raw_glyf:
        blobs = [b'' if g is None else raw_simple(g.contours, g.instr, g.bbox) for g in glyphs]
        glyf = b''.join(blobs)
        offs = [0]
        for b in blobs:
            offs.append(offs[-1] + len(b))
        loca = raw_loca_override if raw_loca_override is not None else b''.join(struct.pack('>I', o) for o in offs)
        ents.append(W.Entry(b'glyf', glyf, version=3))
        ents.append(W.Entry(b'loca', loca, version=3))
    else:
        tg = W.transform_glyf(glyphs, index_format=index_format, **(glyf_kw or {}))
        ents.append(W.Entry(b'glyf', tg, version=0, orig_len=glyf_orig if glyf_orig is not None else 4096))
        lo = (n + 1) * (4 if index_format else 2)
        ents.append(W.Entry(b'loca', b'', version=0, orig_len=lo if loca_orig is None else loca_orig,
                            transform_len=0))
    return ents


def font_file(**kw):
    wkw = kw.pop('woff', {})
    return W.woff2(font_entries(**kw), **wkw)


def build_vectors():
    V = []

    def add(vid, data, exp, note, check=None):
        V.append((vid, data, exp, note, check))

    add('w2/base-valid', font_file(), 'ok', 'simple, 4 composite scale kinds, overlap bit, explicit bbox, all triplet ranges')
    for fl in (1, 2, 3):
        add(f'w2/hmtx-transform-flags={fl}', font_file(hmtx_flags=fl), 'ok', '§5.4 lsb omitted (proportional/monospace)')
    add('w2/hmtx-transform-flags=0', font_file(hmtx_flags=0), 'err', '§5.4: at least one of bits 0/1 MUST be set')
    add('w2/hmtx-transform-flags=4', font_file(hmtx_flags=4 | 1), 'err', '§5.4: reserved bits MUST be 0')
    add('w2/hmtx-nmetrics=0', font_file(hmtx_flags=1, nmetrics=0), 'err', 'numberOfHMetrics must be >= 1')
    add('w2/hmtx-nmetrics>numGlyphs', font_file(hmtx_flags=1, nmetrics=9), 'err', 'numberOfHMetrics > numGlyphs')
    add('w2/hmtx-maxp>glyf-count', font_file(hmtx_flags=1, maxp_count=9), 'ref', 'maxp.numGlyphs (9) > glyf numGlyphs (5)')
    simple3 = [None, W.Simple(SQUARE), W.Simple(SQUARE, bbox=(-5, 0, 500, 700))]
    add('w2/hmtx-maxp<glyf-count', font_file(hmtx_flags=1, maxp_count=3, nmetrics=2), 'ref',
        'maxp.numGlyphs (3) < glyf numGlyphs (5): which count sizes hmtx?')
    add('w2/hmtx-xform+null-glyf', font_file(glyphs=simple3, hmtx_flags=1, raw_glyf=True), 'ref',
        'hmtx transformed while glyf/loca use the null transform (wuff/google woff2 reject)')
    neg = struct.pack('>4I', 0, 0xFFFFFF9C, 0x30, 0x60)
    add('w2/hmtx-null-glyf-loca-negative', font_file(glyphs=simple3, hmtx_flags=1, raw_glyf=True,
                                                     raw_loca_override=neg), 'err',
        'long loca offset 0xFFFFFF9C -> Int -100 in extract_xmins_from_raw_glyf')
    big = struct.pack('>4I', 0, 0x7FFFFFFE, 0x30, 0x60)
    add('w2/hmtx-null-glyf-loca-0x7FFFFFFE', font_file(glyphs=simple3, hmtx_flags=1, raw_glyf=True,
                                                       raw_loca_override=big), 'err',
        'g_start + 4 overflows Int32 in extract_xmins_from_raw_glyf')
    wrap = struct.pack('>4I', 0x7FFFFFFC, 0x7FFFFFFF, 0x30, 0x60)
    add('w2/hmtx-null-glyf-loca-0x7FFFFFFC', font_file(glyphs=simple3, hmtx_flags=1, raw_glyf=True,
                                                       raw_loca_override=wrap), 'err',
        'g_start + 4 wraps to Int.MIN, passes `<= glyf.len`, then indexes glyf.start + 0x7FFFFFFE')
    neg_end = struct.pack('>4I', 0x80000000, 0x30, 0x30, 0x60)
    add('w2/hmtx-null-glyf-loca-0x80000000', font_file(glyphs=simple3, hmtx_flags=1, raw_glyf=True,
                                                       raw_loca_override=neg_end), 'err',
        'loca[0] = 0x80000000 -> Int.MIN')
    # UIntBase128
    e = font_entries()
    e[0].orig_raw = b'\x80\x36'
    add('w2/b128-leading-zero', W.woff2(e), 'err', '§4.1 UIntBase128 MUST NOT start with 0x80')
    e = font_entries()
    e[0].orig_raw = b'\x81\x80\x80\x80\x80\x00'
    add('w2/b128-6-bytes', W.woff2(e), 'err', '§4.1 more than 5 bytes')
    e = font_entries()
    e[0].orig_raw = b'\x90\x80\x80\x80\x00'
    add('w2/b128-2^32', W.woff2(e), 'err', '§4.1 value > 2^32-1')
    e = font_entries()
    e[0].orig_raw = b'\x8f\xff\xff\xff\x7f'
    add('w2/b128-2^32-1', W.woff2(e), 'err', 'origLength 0xFFFFFFFF on a null-transform table (stream mismatch)')
    add('w2/glyf-origLength-2^28', font_file(glyf_orig=1 << 28, woff=dict(total_sfnt=440)), 'ok',
        'transformed glyf origLength is only a hint (5-byte UIntBase128), honest totalSfntSize')
    add('w2/glyf-origLength-2^31-1', font_file(glyf_orig=0x7FFFFFFF, woff=dict(total_sfnt=440)), 'ok',
        'origLength hint at Int.MAX, honest totalSfntSize')
    add('w2/glyf-origLength-2^28-sfnt-sized', font_file(glyf_orig=1 << 28), 'ok-or-err',
        'same, totalSfntSize derived from origLength (> 64 MiB default)')
    # 255UInt16 boundaries in nPoints
    pts = []
    forms = []
    for n_, form in ((252, None), (253, None), (505, None), (506, None), (761, None), (762, None),
                     (5, 'w253'), (300, 'w253'), (508, 'p253')):
        c = [(i % 50, (i * 7) % 90, i % 3 != 0) for i in range(n_)]
        c[0] = (0, 0, True)
        pts.append(c)
        forms.append(form)
    add('w2/255UInt16-boundaries', font_file(glyphs=[None, W.Simple(pts, npoints_forms=forms)]), 'ok',
        'nPoints 252/253/505/506/761/762 and non-canonical 253-word form')
    e = font_entries()
    e.append(W.Entry(b'head', W.head_table()))
    add('w2/duplicate-tag', W.woff2(e), 'err', 'duplicate head')
    add('w2/loca-origLength-mismatch', font_file(loca_orig=4), 'ref',
        'loca origLength != reconstructed size (wuff/google woff2 reject)')
    e = font_entries()
    e[-1].transform_len = 4
    e[-1].data = b'\0' * 4
    add('w2/loca-transformLength!=0', W.woff2(e), 'err', '§5.1 transformed loca transformLength MUST be 0')
    e = font_entries()
    e[-1].version = 3
    e[-1].data = b'\0' * 24
    e[-1].orig_len = 24
    add('w2/glyf-xform+loca-null', W.woff2(e), 'err', 'glyf and loca transform must match')
    e = [x for x in font_entries() if x.tag != b'loca']
    add('w2/glyf-xform-no-loca', W.woff2(e), 'err', 'glyf without loca')
    e = [x for x in font_entries(glyphs=simple3, raw_glyf=True) if x.tag != b'loca']
    add('w2/glyf-null-no-loca', W.woff2(e), 'ref', 'null-transform glyf without loca (wuff rejects)')
    for v in (1, 2):
        e = font_entries()
        e[-2].version = v
        add(f'w2/glyf-version={v}', W.woff2(e), 'err', 'glyf transform version 1/2 undefined')
    e = font_entries()
    e[0].version = 1
    e[0].transform_len = len(e[0].data)
    add('w2/head-version=1', W.woff2(e), 'err', 'non-null transform on a table without a defined transform')
    e = font_entries()
    stream = b''.join(x.data for x in e)
    add('w2/stream-extra-bytes', W.woff2(e, stream=stream + b'\0' * 64), 'err',
        'conform-mustRejectExtraData: decompressed size != sum of table lengths')
    add('w2/stream-short', W.woff2(e, stream=stream[:-1]), 'err', 'decompressed stream shorter')
    comp = __import__('brotli').compress(stream)
    add('w2/totalCompressedSize-too-big', W.woff2(e, compressed=comp + b'\0' * 8), 'err',
        'garbage after the Brotli stream inside totalCompressedSize')
    add('w2/totalCompressedSize-too-small', W.woff2(e, compressed=comp, comp_size=len(comp) - 4), 'err',
        'truncated Brotli stream')
    good = font_file()
    add('w2/length<filesize', W.woff2(font_entries(), trailing=b'\0' * 8,
                                      length=len(good)), 'err', 'header length != file size (trailing bytes)')
    add('w2/length>filesize', W.woff2(font_entries(), length=len(good) + 4), 'err', 'header length > file size')
    add('w2/reserved!=0', font_file(woff=dict(reserved=1)), 'ok',
        'conform-mustNotUseReservedValue: WOFF2 decoders MUST ignore a non-zero reserved field')
    add('w2/numTables=0', W.woff2([], stream=b'x'), 'err', 'numTables 0')
    add('w2/totalSfntSize-bogus', font_file(woff=dict(total_sfnt=12)), 'ok-or-err',
        'totalSfntSize is advisory in WOFF2 (wuff ignores it)')
    add('w2/meta+priv-blocks', font_file(woff=dict(meta=b'<metadata/>', priv=b'PRIV')), 'ok',
        'valid extended metadata + private data blocks')
    # glyf transform details
    rr = random.Random(7)
    big_glyphs = [None] + [W.Simple([[(rr.randrange(-3000, 3000), rr.randrange(-3000, 3000), rr.random() < .5)
                                      for i in range(1500)]]) for _ in range(40)]
    add('w2/short-loca-overflow', font_file(glyphs=big_glyphs, index_format=0), 'err',
        'indexFormat 0 with glyf > 131070 bytes')
    add('w2/short-loca-valid', font_file(index_format=0), 'ok', 'indexFormat 0 (head.indexToLocFormat patched)')
    add('w2/glyf-indexFormat=2', font_file(glyf_kw=dict(), index_format=2), 'err', 'indexFormat must be 0/1')
    add('w2/glyf-version-field=1', font_file(glyf_kw=dict(version=1)), 'ok-or-err',
        'reserved glyf header version != 0')
    add('w2/composite-no-bbox', _composite_without_bbox(), 'err', 'composite glyph MUST have explicit bbox')
    add('w2/empty-with-bbox', _empty_with_bbox(), 'err', 'empty glyph MUST NOT have bbox')
    add('w2/glyf-numGlyphs+1-empty', _glyf_count_plus_one([None, None]), 'err',
        'numGlyphs one larger than nContourStream (truncated nContourStream error path)')
    add('w2/glyf-numGlyphs+1-base', _glyf_count_plus_one(None), 'err', 'same on the 5-glyph base font')
    add('w2/composite-bbox-truncated', _composite_bbox_truncated(), 'err',
        'composite glyph whose bbox bit is set but the bboxStream ends (truncated composite bbox)')
    add('w2/nContours=-2', font_file(glyf_kw=dict(ncontours_override=struct.pack('>5h', 0, 1, -2, 2, 1))),
        'err', 'nContours < -1')
    add('w2/glyf-substream-size-0xFFFFFFFF', font_file(glyf_kw=dict(sizes_override={3: 0xFFFFFFFF})), 'err',
        'substream size > Int.MAX')
    add('w2/glyf-substream-overrun', font_file(glyf_kw=dict(sizes_override={6: 1000})), 'err',
        'instructionStream exceeds table')
    add('w2/glyf-numGlyphs-0', font_file(glyphs=[]), 'ok-or-err', 'glyf with 0 glyphs')
    add('w2/contour-with-0-points', font_file(glyphs=[None, W.Simple([[]] + SQUARE)]), 'ok-or-err',
        'contour with zero points (endPts = -1)')
    pts_ovf = [[(0, 0, True)] + [(65535 * (i + 1), rr.randrange(-2000, 2000), True) for i in range(40000)]]
    add('w2/coord-int32-overflow', font_file(glyphs=[None, W.Simple(pts_ovf)]), 'ok-or-err',
        '40001 points with dx = +65535 each: absolute x exceeds 2^31 (Int32 wrap)')
    add('w2/coord-int32-overflow-compact',
        font_file(glyphs=[None, W.Simple([[(0, 0, True)] + [(65535 * (i + 1), 0, True) for i in range(40000)]])]),
        'ok-or-err', 'same overflow, compressible (wuff rejects it by its 100:1 ratio guard first)')
    pts_65536 = [[(rr.randrange(4000), rr.randrange(4000), rr.random() < .5) for i in range(65535)], [(0, 5, True)]]
    add('w2/points=65536', font_file(glyphs=[None, W.Simple(pts_65536)]), 'ok-or-err', 'total points 65536')
    pts_65537 = pts_65536[:1] + [[(0, 5, True), (1, 5, True)]]
    add('w2/points=65537', font_file(glyphs=[None, W.Simple(pts_65537)]), 'err', 'endPtsOfContours > 65535')
    add('w2/custom-tag-for-known', W.woff2([_force_custom(x) for x in font_entries()]), 'ok',
        'known tags spelled with flag 63 + explicit tag')
    e = [x for x in font_entries(hmtx_flags=1) if x.tag != b'hhea']
    add('w2/hmtx-xform-no-hhea', W.woff2(e), 'err', 'transformed hmtx without hhea')
    add('w2/glyf-xform-no-head', W.woff2([x for x in font_entries() if x.tag != b'head']), 'ok-or-err',
        'no head table to patch indexToLocFormat')
    add('w2/flavor-OTTO-with-glyf', font_file(woff=dict(flavor=0x4F54544F)), 'ok-or-err', 'flavor passthrough')

    # ---------------- WOFF 1.0 ----------------
    tabs = [(b'head', W.head_table()), (b'hhea', W.hhea_table(1)), (b'maxp', W.maxp_table(1)),
            (b'name', b'N' * 300), (b'post', b'\0\x03' + b'p' * 30)]
    add('w1/valid-zlib', W.woff1(tabs), 'ok', 'per-table zlib')
    add('w1/valid-stored', W.woff1(tabs, compress=False), 'ok', 'stored tables')
    add('w1/compLength>origLength', W.woff1(tabs, compress=False, comp_lens=[None, None, None, 301, None],
                                            orig_lens=[None, None, None, 300, None]), 'err',
        'compLength > origLength')
    add('w1/offset-unaligned', W.woff1(tabs, compress=False, align=False), 'ref',
        'table offsets not 4-byte aligned (WOFF1 §5 says MUST be aligned)')
    f = W.woff1(tabs, compress=False)
    add('w1/table-out-of-bounds', W.woff1(tabs, compress=False, offsets=[None, None, None, len(f) - 10, None]),
        'err', 'table extends past end of file')
    off_head = struct.unpack('>I', f[44 + 4:44 + 8])[0]
    add('w1/tables-overlap', W.woff1(tabs, compress=False, offsets=[None, off_head, None, None, None],
                                     comp_lens=[None, 36, None, None, None]),
        'err', 'two tables share the same bytes (WOFF1 conform: overlapping tables invalid)')
    add('w1/table-inside-header', W.woff1(tabs, compress=False, offsets=[0, None, None, None, None]), 'err',
        'table data inside the WOFF header/directory')
    add('w1/totalSfntSize-wrong', W.woff1(tabs, total_sfnt=1000), 'ref',
        'totalSfntSize != computed SFNT size (WOFF1 says it MUST be correct)')
    add('w1/length<filesize', W.woff1(tabs, trailing=b'\0' * 4, length=len(W.woff1(tabs))), 'err',
        'header length != file size')
    add('w1/length>filesize', W.woff1(tabs, length=len(W.woff1(tabs)) + 4), 'err', 'header length > file')
    add('w1/reserved!=0', W.woff1(tabs, reserved=1), 'err', 'WOFF1 conform-reserved: MUST reject')
    add('w1/numTables=0', W.woff1([], ), 'err', 'numTables 0')
    zl = __import__('zlib').compress(b'N' * 300)
    add('w1/zlib-short', W.woff1(tabs, raw_blobs=[None, None, None, __import__('zlib').compress(b'N' * 299), None],
                                 orig_lens=[None, None, None, 300, None]), 'err',
        'zlib output shorter than origLength')
    bad = bytearray(zl)
    bad[-1] ^= 1
    add('w1/zlib-adler-bad', W.woff1(tabs, raw_blobs=[None, None, None, bytes(bad), None]), 'err', 'Adler-32 mismatch')
    add('w1/zlib-long', W.woff1(tabs, raw_blobs=[None, None, None, __import__('zlib').compress(b'N' * 301), None],
                                orig_lens=[None, None, None, 300, None]), 'err', 'zlib output longer than origLength')
    add('w1/duplicate-tag', W.woff1(tabs + [(b'name', b'x' * 8)], compress=False), 'err', 'duplicate tag')
    add('w1/directory-unsorted', W.woff1(list(reversed(tabs))), 'ok-or-err', 'directory not sorted by tag')
    add('w1/origLength-0x80000010', W.woff1(tabs, compress=False, raw_blobs=[None, None, None, zl, None],
                                            orig_lens=[None, None, None, 0x80000010, None]), 'err',
        'origLength > Int.MAX with compLength < origLength')
    add('w1/origLength-0xFFFFFFFF', W.woff1(tabs, compress=False, raw_blobs=[None, None, None, zl, None],
                                            orig_lens=[None, None, None, 0xFFFFFFFF, None]), 'err',
        'origLength 2^32-1')
    add('w1/offset-0xFFFFFFF0', W.woff1(tabs, compress=False, offsets=[None, None, None, 0xFFFFFFF0, None]),
        'err', 'u32 offset wraps Int')
    return V


def _force_custom(e):
    e.force_custom = True
    return e


def _composite_without_bbox():
    g = [None, W.Simple(SQUARE), W.Composite([comp_rec(0x2, 1, b'\0\0')], bbox=(0, 0, 1, 1))]
    tg = bytearray(W.transform_glyf(g))
    # clear glyph 2's bbox bit and drop its 8 bbox bytes from the bbox stream
    sizes = list(struct.unpack('>7I', tg[8:36]))
    off = 36 + sum(sizes[:5])
    tg[off] &= ~0x20
    bb_end = off + sizes[5]
    tg = tg[:bb_end - 8] + tg[bb_end:]
    sizes[5] -= 8
    tg[8:36] = struct.pack('>7I', *sizes)
    e = font_entries(glyphs=g)
    e[-2].data = bytes(tg)
    return W.woff2(e)


def _glyf_count_plus_one(glyphs):
    e = font_entries(glyphs=glyphs)
    g = bytearray(e[-2].data)
    g[4:6] = struct.pack('>H', struct.unpack('>H', g[4:6])[0] + 1)
    e[-2].data = bytes(g)
    return W.woff2(e)


def _composite_bbox_truncated():
    g = [None, W.Simple(SQUARE), W.Composite([comp_rec(0x2, 1, b'\0\0')], bbox=(0, 0, 1, 1))]
    tg = bytearray(W.transform_glyf(g))
    sizes = list(struct.unpack('>7I', tg[8:36]))
    bb_end = 36 + sum(sizes[:6])
    tg = tg[:bb_end - 2] + tg[bb_end:]
    sizes[5] -= 2
    tg[8:36] = struct.pack('>7I', *sizes)
    e = font_entries(glyphs=g)
    e[-2].data = bytes(tg)
    return W.woff2(e)


def _empty_with_bbox():
    g = [None, W.Simple(SQUARE)]
    tg = bytearray(W.transform_glyf(g))
    sizes = list(struct.unpack('>7I', tg[8:36]))
    off = 36 + sum(sizes[:5])
    tg[off] |= 0x80
    bb_end = off + sizes[5]
    tg = tg[:bb_end] + struct.pack('>4h', 0, 0, 1, 1) + tg[bb_end:]
    sizes[5] += 8
    tg[8:36] = struct.pack('>7I', *sizes)
    e = font_entries(glyphs=g)
    e[-2].data = bytes(tg)
    return W.woff2(e)


def section_vectors(tools, report, args):
    V = build_vectors()
    os.makedirs(os.path.join(args.out, 'vectors'), exist_ok=True)
    cases = [v[1] for v in V]
    res = {impl: tools.batch(impl, cases, 'vectors') for impl in ('pion', 'pion_wasm', 'rust')}
    rows = []
    print(f'  {"id":38s} {"exp":9s} {"pion":34s} {"wasm":4s} {"wuff":20s} verdict')
    for i, (vid, data, exp, note, _) in enumerate(V):
        open(os.path.join(args.out, 'vectors', vid.replace('/', '_') + '.bin'), 'wb').write(data)
        p, w, r = res['pion'][i], res['pion_wasm'][i], res['rust'][i]
        vp, vr = verdict(p), verdict(r)
        flag = ''
        if vp not in ('ok', 'err'):
            flag = 'DEFECT:crash'
        elif w != p:
            flag = 'DEFECT:native!=wasm'
        elif exp == 'ok' and vp != 'ok':
            flag = 'SPEC:rejects-valid'
        elif exp == 'err' and vp != 'err':
            flag = 'SPEC:accepts-invalid'
        elif exp == 'ref' and vp != vr:
            flag = 'REF:diverges-from-wuff'
        elif vp == 'ok' and vr == 'ok' and p != r:
            _, _, a = canon_tables(p)
            _, _, b = canon_tables(r)
            flag = 'bytes-differ:' + ','.join(sorted(t for t in set(a) | set(b) if a.get(t) != b.get(t)))
        if exp == 'ok-or-err' and vp != vr and not flag.startswith('DEFECT'):
            flag = (flag + ' ' if flag else '') + 'note:wuff=' + vr
        rows.append(dict(id=vid, expect=exp, pion=p[:80], wasm_same=(w == p), wuff=r[:80], flag=flag, note=note))
        print(f'  {vid:38s} {exp:9s} {p[:34]:34s} {"=" if w == p else "DIFF":4s} {r[:20]:20s} {flag}', flush=True)
        if flag.startswith(('DEFECT', 'SPEC', 'REF')):
            report['findings'].append(f'vectors/{vid}: {flag} pion={p[:60]} wuff={r[:40]} ({note})')
    report['vectors'] = rows


# ------------------------------------------------------------------------------------------------
# Section: limits
# ------------------------------------------------------------------------------------------------

def section_limits(tools, report, args):
    d = os.path.join(args.out, 'limits')
    os.makedirs(d, exist_ok=True)
    w2 = os.path.join(d, 'base.woff2')
    open(w2, 'wb').write(font_file(woff=dict(total_sfnt=440)))  # honest totalSfntSize (decoded size)
    w1 = os.path.join(d, 'base.woff')
    open(w1, 'wb').write(W.woff1([(b'head', W.head_table()), (b'name', b'N' * 300)]))
    p_ok, _ = tools.file('pion', w2, limits=(1 << 30, 0, 0))
    total = canon_tables(p_ok)[0] if p_ok.startswith('OK') else 0
    rows = []
    for label, path, lim in [
        ('w2 default', w2, (67108864, 256, 65536)),
        ('w2 max_output=0', w2, (0, 256, 65536)), ('w2 max_output=-1', w2, (-1, 256, 65536)),
        ('w1 max_output=0', w1, (0, 256, 65536)), ('w1 max_output=-1', w1, (-1, 256, 65536)),
        ('w2 max_output=exact', w2, (total, 256, 65536)), ('w2 max_output=exact-1', w2, (total - 1, 256, 65536)),
        ('w2 max_tables=6 (exact)', w2, (67108864, 6, 65536)), ('w2 max_tables=5', w2, (67108864, 5, 65536)),
        ('w2 max_tables=0', w2, (67108864, 0, 65536)), ('w2 max_glyphs=5 (exact)', w2, (67108864, 256, 5)),
        ('w2 max_glyphs=4', w2, (67108864, 256, 4)), ('w2 max_glyphs=0', w2, (67108864, 256, 0)),
        ('w2 max_glyphs=-1', w2, (67108864, 256, -1)),
    ]:
        r, _ = tools.file('pion', path, limits=lim)
        rows.append(dict(case=label, limits=lim, result=r[:60]))
        print(f'  {label:28s} {str(lim):28s} {r[:60]}')
    report['limits'] = rows


# ------------------------------------------------------------------------------------------------
# Section: bombs (tiny inputs vs. peak RSS / time)
# ------------------------------------------------------------------------------------------------

def timed(cmd, timeout=600):
    t0 = time.time()
    try:
        p = subprocess.run(['/usr/bin/time', '-l'] + cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        return 'HANG', time.time() - t0, 0
    err = p.stderr.decode('latin-1')
    rss = 0
    for ln in err.splitlines():
        if 'maximum resident set size' in ln:
            rss = int(ln.split()[0])
    out = p.stdout.decode('latin-1').strip().splitlines()
    line = out[0][:48] if out else ('CRASH rc=%d' % p.returncode)
    return line, time.time() - t0, rss / 1048576


def build_bombs():
    import brotli
    import zlib
    B = []
    B.append(('B1 glyf origLength=2^31-1 (hint), honest header', font_file(glyf_orig=0x7FFFFFFF, woff=dict(total_sfnt=440)),
              None))
    e = font_entries()
    stream = b''.join(x.data for x in e)
    B.append(('B2 +60 MiB of zeros after the tables in the Brotli stream',
              W.woff2(e, stream=stream + bytes(60 << 20)), None))
    B.append(('B3 +200 MiB of zeros after the tables (exceeds 64 MiB limit)',
              W.woff2(e, stream=stream + bytes(200 << 20)), None))
    e = font_entries()
    e.append(W.Entry(b'name', bytes(60 << 20)))
    B.append(('B4 WOFF2 declared 60 MiB name table of zeros', W.woff2(e), None))
    tabs = [(b'head', W.head_table()), (b'name', bytes(60 << 20))]
    B.append(('B5 WOFF1 declared 60 MiB zlib name table of zeros', W.woff1(tabs), None))
    n = 65535
    ents = [W.Entry(struct.pack('>I', 0x7A7A7A7A - i), b'') for i in range(n)]
    for x in ents:
        x.force_custom = True
    B.append(('B6 WOFF2 65535 empty tables, max_tables=0 (unlimited)', W.woff2(ents, stream=b''),
              (1 << 30, 0, 0)))
    B.append(('B6b same, default limits', W.woff2(ents, stream=b''), None))
    w1tabs = [(struct.pack('>I', 0x7A7A7A7A - i), b'') for i in range(n)]
    B.append(('B7 WOFF1 65535 empty tables (descending tags), max_tables=0', W.woff1(w1tabs, compress=False),
              (1 << 30, 0, 0)))
    rr = random.Random(3)
    g = [None] + [W.Simple([[(rr.randrange(-30000, 30000), rr.randrange(-30000, 30000), True)
                             for _ in range(60000)]]) for _ in range(3)]
    B.append(('B8 3 glyphs x 60000 random points', font_file(glyphs=g), None))
    return B


def section_bombs(tools, report, args):
    d = os.path.join(args.out, 'bombs')
    os.makedirs(d, exist_ok=True)
    rows = []
    for label, data, lim in build_bombs():
        path = os.path.join(d, label.split(' ')[0] + '.bin')
        open(path, 'wb').write(data)
        lim = lim or (67108864, 256, 65536)
        p = timed(tools.cmds['pion'] + ['file', path] + [str(x) for x in lim])
        r = timed(tools.cmds['rust'] + ['file', path])
        rows.append(dict(case=label, input_bytes=len(data), pion=p, wuff=r))
        print(f'  {label:62s} in={len(data):>8d}B  pion: {p[0][:26]:26s} {p[1]:6.2f}s {p[2]:7.1f} MiB | '
              f'wuff: {r[0][:22]:22s} {r[1]:6.2f}s {r[2]:7.1f} MiB', flush=True)
    report['bombs'] = rows


# ------------------------------------------------------------------------------------------------
# Section: fuzz
# ------------------------------------------------------------------------------------------------

def fuzz_seeds(args):
    """Small real seeds (fontTools subsets) + synthetic ones."""
    from fontTools import subset
    from fontTools.ttLib import TTFont
    from fontTools.ttLib import woff2 as ftw2
    d = os.path.join(args.out, 'seeds')
    os.makedirs(d, exist_ok=True)
    seeds_w2, seeds_w1 = [], []
    for name, text in (('Arial.ttf', 'Hello ÀÉÎõü%&@'), ('SFNS.ttf', 'Agx€ÅØ'), ('Times New Roman.ttf', 'Wéñ'),
                       ('STIXGeneral.otf', 'abc∑'), ('Monaco.ttf', 'mono{}'), ('Zapfino.ttf', 'Zq')):
        src = find_font(name)
        if not src:
            continue
        opts = subset.Options()
        opts.glyph_names = True
        opts.notdef_outline = True
        opts.hinting = True
        f = TTFont(src)
        s = subset.Subsetter(opts)
        s.populate(text=text)
        s.subset(f)
        base = os.path.join(d, name.split('.')[0].replace(' ', '_'))
        f.save(base + '.ttf')
        for tt, suf in ((None, 'a'), ({'glyf', 'loca', 'hmtx'}, 'b'), (set(), 'c')):
            try:
                ftw2.compress(base + '.ttf', f'{base}.{suf}.woff2', transform_tables=tt)
                seeds_w2.append(open(f'{base}.{suf}.woff2', 'rb').read())
            except Exception:  # noqa
                pass
        g = TTFont(base + '.ttf')
        g.flavor = 'woff'
        g.save(base + '.woff')
        seeds_w1.append(open(base + '.woff', 'rb').read())
    seeds_w2.append(font_file())
    seeds_w2.append(font_file(hmtx_flags=3))
    seeds_w2.append(font_file(glyphs=[None, W.Simple(SQUARE), W.Simple(SQUARE, bbox=(-5, 0, 500, 700))],
                              hmtx_flags=1, raw_glyf=True))
    return seeds_w2, seeds_w1


def mutate_bytes(rng, b):
    b = bytearray(b)
    k = rng.random()
    n = rng.randint(1, 8)
    if k < 0.35:
        for _ in range(n):
            i = rng.randrange(len(b))
            b[i] ^= 1 << rng.randrange(8)
    elif k < 0.55:
        for _ in range(n):
            i = rng.randrange(len(b))
            b[i] = rng.choice([0, 0xFF, 0x7F, 0x80, 0x3F, 0xC0, rng.randrange(256)])
    elif k < 0.65:
        b = b[:rng.randrange(len(b))]
    elif k < 0.8:  # header/directory field (first 200 bytes): set 16/32-bit word to an extreme
        i = rng.randrange(min(len(b) - 4, 200))
        v = rng.choice([0, 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0xFFFF, 0x10000, rng.getrandbits(32)])
        b[i:i + 4] = struct.pack('>I', v)
    elif k < 0.9:
        i, j = sorted(rng.randrange(len(b)) for _ in range(2))
        b[i:i] = b[i:j]
    else:
        i = rng.randrange(len(b))
        b[i:i + rng.randint(1, 16)] = b''
    return bytes(b)


def mutate_woff2_stream(rng, data):
    """Structure-aware: decompress, mutate one table (mostly the transformed glyf/hmtx), recompress."""
    _, entries, _ = W.parse_woff2(data)
    tgt = [e for e in entries if e.data]
    pref = [e for e in tgt if e.tag in (b'glyf', b'hmtx', b'hhea', b'maxp', b'head')]
    e = rng.choice(pref if pref and rng.random() < 0.85 else tgt)
    d = bytearray(e.data)
    for _ in range(rng.randint(1, 6)):
        if not d:
            break
        k = rng.random()
        i = rng.randrange(len(d))
        if e.tag == b'glyf' and e.version == 0 and k < 0.35 and len(d) >= 36:
            # glyf header: numGlyphs / indexFormat / the seven stream sizes
            j = rng.choice([4, 6] + [8 + 4 * s for s in range(7)])
            if j < 8:
                d[j:j + 2] = struct.pack('>H', rng.choice([0, 1, 0xFFFF, 0x8000, rng.randrange(65536)]))
            else:
                old = struct.unpack('>I', d[j:j + 4])[0]
                d[j:j + 4] = struct.pack('>I', rng.choice([0, old + 1, max(old - 1, 0), 0xFFFFFFFF, old * 2]))
        elif k < 0.7:
            d[i] ^= 1 << rng.randrange(8)
        elif k < 0.85:
            d[i] = rng.choice([0, 0xFF, 0x80, 0x7F, 0xFD, 0xFE])
        else:
            d = d[:i] + d[i + rng.randint(1, 8):] if rng.random() < 0.5 else d[:i] + d[i:i + 8] + d[i:]
    e.data = bytes(d)
    if e.transformed():
        e.transform_len = len(e.data)
    else:
        e.orig_len = len(e.data)
    if rng.random() < 0.1:
        e2 = rng.choice(entries)
        e2.orig_len = rng.choice([0, 1, 0x7FFFFFFF, (e2.orig_len or 0) + 1])
    for x in entries:
        x.orig_raw = None
        x.tlen_raw = None
    return W.woff2(entries, quality=1)


def mutate_woff1_dir(rng, data):
    b = bytearray(data)
    nt = struct.unpack('>H', b[12:14])[0]
    t = rng.randrange(nt)
    field = rng.choice([4, 8, 12])
    rec = 44 + 20 * t + field
    old = struct.unpack('>I', b[rec:rec + 4])[0]
    v = rng.choice([0, 1, 2, 3, old + 1, max(old - 1, 0), old ^ 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF,
                    rng.randrange(len(b) + 8)])
    b[rec:rec + 4] = struct.pack('>I', v)
    if rng.random() < 0.3:
        b[16:20] = struct.pack('>I', rng.choice([0, 1, 0xFFFFFFFF, rng.getrandbits(32)]))
    return bytes(b)


def section_fuzz(tools, report, args):
    rng = random.Random(args.seed)
    seeds_w2, seeds_w1 = fuzz_seeds(args)
    cases = []
    kinds = []
    N = args.fuzz
    for i in range(N):
        k = i % 10
        if k < 3:
            cases.append(mutate_bytes(rng, rng.choice(seeds_w2)))
            kinds.append('w2-bytes')
        elif k < 7:
            try:
                cases.append(mutate_woff2_stream(rng, rng.choice(seeds_w2)))
                kinds.append('w2-stream')
            except Exception:  # noqa
                cases.append(mutate_bytes(rng, rng.choice(seeds_w2)))
                kinds.append('w2-bytes')
        elif k < 9:
            s = rng.choice(seeds_w1)
            cases.append(mutate_woff1_dir(rng, s) if rng.random() < 0.6 else mutate_bytes(rng, s))
            kinds.append('w1')
        else:
            n = rng.randrange(4, 300)
            sig = rng.choice([b'wOF2', b'wOFF'])
            cases.append(sig + bytes(rng.getrandbits(8) for _ in range(n)))
            kinds.append('random')
    with open(os.path.join(args.out, 'fuzz_all_cases.bin'), 'wb') as f:
        f.write(pack(cases))
    t0 = time.time()
    res = {}
    for impl in ('pion', 'pion_wasm', 'rust'):
        t1 = time.time()
        res[impl] = tools.batch(impl, cases, 'fuzz', timeout=1800)
        print(f'  {impl}: {len(res[impl])} verdicts in {time.time() - t1:.1f}s', flush=True)
    stats = collections.Counter()
    crashes, mism, accept_only_pion, reject_only_pion, ok_diff = [], [], [], [], collections.Counter()
    fz = os.path.join(args.out, 'fuzz_findings')
    os.makedirs(fz, exist_ok=True)
    for i, c in enumerate(cases):
        p, w, r = res['pion'][i], res['pion_wasm'][i], res['rust'][i]
        vp, vr = verdict(p), verdict(r)
        stats[(kinds[i], vp, vr)] += 1
        if vp not in ('ok', 'err') or verdict(w) not in ('ok', 'err'):
            crashes.append((i, kinds[i], p[:120], w[:120]))
            open(os.path.join(fz, f'crash_{i}.bin'), 'wb').write(c)
        elif w != p:
            mism.append((i, p[:60], w[:60]))
            open(os.path.join(fz, f'wasm_mismatch_{i}.bin'), 'wb').write(c)
        if vp == 'ok' and vr == 'err':
            accept_only_pion.append(i)
            if len(accept_only_pion) <= 40:
                open(os.path.join(fz, f'pion_accepts_{i}.bin'), 'wb').write(c)
        elif vp == 'err' and vr == 'ok':
            reject_only_pion.append((i, p))
            open(os.path.join(fz, f'pion_rejects_{i}.bin'), 'wb').write(c)
        elif vp == 'ok' and vr == 'ok' and p != r:
            _, _, a = canon_tables(p)
            _, _, b = canon_tables(r)
            ok_diff[','.join(sorted(t for t in set(a) | set(b) if a.get(t) != b.get(t)))] += 1
    summary = dict(cases=N, seconds=round(time.time() - t0, 1), crashes=len(crashes), native_vs_wasm=len(mism),
                   pion_ok_wuff_err=len(accept_only_pion), pion_err_wuff_ok=len(reject_only_pion),
                   both_ok_table_diff=dict(ok_diff),
                   by_kind={f'{a}|{b}|{c}': n for (a, b, c), n in sorted(stats.items())})
    report['fuzz'] = summary
    report['fuzz_crashes'] = crashes[:50]
    report['fuzz_pion_rejects'] = [(i, p[:80]) for i, p in reject_only_pion[:50]]
    print(json.dumps(summary, indent=1))
    for c in crashes[:20]:
        print('  CRASH', c)
    for c in reject_only_pion[:20]:
        print('  pion-rejects/wuff-accepts', c[0], c[1][:80])
    if crashes:
        report['defects'].append(f'fuzz: {len(crashes)} crashes/hangs (see {fz})')
    if mism:
        report['defects'].append(f'fuzz: {len(mism)} native-vs-wasm mismatches')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('section')
    ap.add_argument('--out', default=os.environ.get('AUDIT_OUT', '/private/tmp/pion-woff2-audit'))
    ap.add_argument('--fuzz', type=int, default=12000)
    ap.add_argument('--seed', type=int, default=20261123)
    args = ap.parse_args()
    tools = Tools(args.out)
    report = dict(defects=[], findings=[])
    secs = ['real', 'vectors', 'limits', 'fuzz'] if args.section == 'all' else [args.section]
    for s in secs:
        print(f'==> {s}', flush=True)
        globals()['section_' + s](tools, report, args)
    path = os.path.join(args.out, f'report_{args.section}.json')
    json.dump(report, open(path, 'w'), indent=1, default=str)
    print(f'==> {len(report["defects"])} defects, {len(report["findings"])} findings -> {path}')
    for d in report['defects']:
        print('  DEFECT', d)
    sys.exit(1 if report['defects'] else 0)


if __name__ == '__main__':
    main()
