#!/usr/bin/env python3
"""RT-qrcode differential driver (stdlib only).

  qrdiff.py gen     OUT          write corpora into OUT/
  qrdiff.py enc     OUT          compare OUT/enc_pion.out vs OUT/enc_gen.out (Nayuki qrcodegen)
  qrdiff.py interop OUT          compare decoders (Pion, rqrr) on matrices from both encoders
  qrdiff.py inject  OUT          compare decoders on RS error-injected qrcodegen matrices
  qrdiff.py seg     OUT          compare Pion optimize_segments with an exact O(n^2) optimum

All randomness is seeded; reruns are byte-identical.
"""
import os
import random
import sys

# ISO/IEC 18004:2015 Table 9 (transcribed in the same layout as Nayuki qrcodegen), index [ec][v]
ECC = {
    "L": [7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    "M": [10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    "Q": [13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    "H": [17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
}
NB = {
    "L": [1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    "M": [1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    "Q": [1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
    "H": [1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
}
# ISO/IEC 18004 Table 9 misdecode-protection codewords p (only these 5 symbols have p > 0)
MISDECODE_P = {(1, "L"): 3, (1, "M"): 2, (1, "Q"): 1, (2, "L"): 2, (3, "L"): 1}
ECS = "LMQH"
ALNUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"


def raw_modules(v):
    r = (16 * v + 128) * v + 64
    if v >= 2:
        na = v // 7 + 2
        r -= (25 * na - 10) * na - 55
        if v >= 7:
            r -= 36
    return r


def total_cw(v):
    return raw_modules(v) // 8


def data_cw(v, ec):
    return total_cw(v) - ECC[ec][v - 1] * NB[ec][v - 1]


def ccb(v, mode):
    t = 0 if v <= 9 else (1 if v <= 26 else 2)
    return {"N": (10, 12, 14), "A": (9, 11, 13), "B": (8, 16, 16), "K": (8, 10, 12)}[mode][t]


def seg_bits(mode, n, v):
    if mode == "N":
        body = (n // 3) * 10 + (0, 4, 7)[n % 3]
    elif mode == "A":
        body = (n // 2) * 11 + (n % 2) * 6
    elif mode == "B":
        body = n * 8
    else:
        body = n * 13
    if n >= (1 << ccb(v, mode)):
        return None
    return 4 + ccb(v, mode) + body


def max_chars(v, ec, mode):
    cap = data_cw(v, ec) * 8
    n = 0
    lo, hi = 0, 8000
    while lo < hi:
        mid = (lo + hi + 1) // 2
        b = seg_bits(mode, mid, v)
        if b is not None and b <= cap:
            lo = mid
        else:
            hi = mid - 1
    n = lo
    return n


# ---------------------------------------------------------------- placement (Nayuki port)
def align_pos(v):
    if v == 1:
        return []
    na = v // 7 + 2
    step = 26 if v == 32 else (v * 4 + na * 2 + 1) // (na * 2 - 2) * 2
    res = [6] + [0] * (na - 1)
    pos = v * 4 + 10
    for i in range(na - 1, 0, -1):
        res[i] = pos
        pos -= step
    return res


def func_mask(v):
    n = v * 4 + 17
    f = [[False] * n for _ in range(n)]

    def box(cx, cy, r):
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                x, y = cx + dx, cy + dy
                if 0 <= x < n and 0 <= y < n:
                    f[y][x] = True

    for i in range(n):
        f[6][i] = f[i][6] = True
    box(3, 3, 4)
    box(n - 4, 3, 4)
    box(3, n - 4, 4)
    ap = align_pos(v)
    for i in range(len(ap)):
        for j in range(len(ap)):
            if (i == 0 and j == 0) or (i == 0 and j == len(ap) - 1) or (i == len(ap) - 1 and j == 0):
                continue
            box(ap[i], ap[j], 2)
    for i in range(9):
        f[8][i] = f[i][8] = True
    for i in range(8):
        f[8][n - 1 - i] = True
        f[n - 1 - i][8] = True
    if v >= 7:
        for i in range(18):
            a, b = n - 11 + i % 3, i // 3
            f[b][a] = f[a][b] = True
    return f


def placement(v):
    """List of (x, y) for every data bit in ISO zigzag order."""
    n = v * 4 + 17
    f = func_mask(v)
    out = []
    right = n - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(n):
            for j in range(2):
                x = right - j
                upward = ((right + 1) & 2) == 0
                y = n - 1 - vert if upward else vert
                if not f[y][x]:
                    out.append((x, y))
        right -= 2
    return out


def block_layout(v, ec):
    """For each block: list of interleaved codeword indices (data then EC)."""
    nb, e = NB[ec][v - 1], ECC[ec][v - 1]
    tot = total_cw(v)
    num_short = nb - tot % nb
    short_data = tot // nb - e
    dlen = data_cw(v, ec)
    blocks = []
    for b in range(nb):
        idx = [j * nb + b for j in range(short_data)]
        if b >= num_short:
            idx.append(short_data * nb + (b - num_short))
        idx += [dlen + k * nb + b for k in range(e)]
        blocks.append(idx)
    return blocks


# ---------------------------------------------------------------- matrix transforms
def rot_cw(bits, n):
    out = ["0"] * (n * n)
    for y in range(n):
        for x in range(n):
            out[x * n + (n - 1 - y)] = bits[y * n + x]
    return "".join(out)


def transpose(bits, n):
    return "".join(bits[x * n + y] for y in range(n) for x in range(n))


# ---------------------------------------------------------------- corpus
def w(path, rows):
    with open(path, "w") as f:
        for r in rows:
            f.write("\t".join(str(c) for c in r) + "\n")


def rnd_bytes(rng, n):
    return bytes(rng.randrange(256) for _ in range(n))


def sjis_valid(rng, n):
    out = bytearray()
    for _ in range(n):
        while True:
            hi = rng.choice(list(range(0x81, 0xA0)) + list(range(0xE0, 0xEC)))
            lo = rng.choice([c for c in range(0x40, 0xFD) if c != 0x7F])
            wv = hi << 8 | lo
            if 0x8140 <= wv <= 0x9FFC or 0xE040 <= wv <= 0xEBBF:
                out += bytes([hi, lo])
                break
    return bytes(out)


def gen(out):
    os.makedirs(out, exist_ok=True)
    rng = random.Random(18004)
    rows = []
    # A. 160 (v, ec) x 8 masks, Byte segment at exact capacity (fills every data module)
    for v in range(1, 41):
        for ec in ECS:
            mb = max_chars(v, ec, "B")
            payload = rnd_bytes(rng, mb)
            for m in range(8):
                rows.append((f"A/{v}{ec}/m{m}", ec, v, v, m, "byte", payload.hex()))
            rows.append((f"A/{v}{ec}/auto", ec, v, v, -1, "byte", payload.hex()))
            rows.append((f"A/{v}{ec}/over", ec, v, v, -1, "byte", rnd_bytes(rng, mb + 1).hex()))
    # B. every mode at exact max and max+1 for all 160 (v, ec), fixed version, auto mask
    for v in range(1, 41):
        for ec in ECS:
            for mode, kind in (("N", "num"), ("A", "alnum"), ("K", "kanji")):
                mc = max_chars(v, ec, mode)
                for extra in (0, 1):
                    n = mc + extra
                    if mode == "N":
                        p = "".join(rng.choice("0123456789") for _ in range(n)).encode()
                    elif mode == "A":
                        p = "".join(rng.choice(ALNUM) for _ in range(n)).encode()
                    else:
                        p = sjis_valid(rng, n)
                    rows.append((f"B/{kind}/{v}{ec}/{'max' if extra == 0 else 'over'}", ec, v, v, -1, kind, p.hex()))
            # ECI designators of each width
            for d in (3, 26, 127, 128, 16383, 16384, 999999):
                p = rnd_bytes(rng, 5)
                rows.append((f"B/eci{d}/{v}{ec}", ec, v, v, -1, f"eci{d}", p.hex()))
    # C. auto-version edge payloads
    edge = {
        "empty": b"",
        "nul": b"\x00",
        "nul3": b"a\x00b",
        "emoji": "😀🚀".encode(),
        "nonutf8": b"\xff\xfe\xc3\x28\x80",
        "v40L_bytes": rnd_bytes(rng, 2953),
        "v40L_bytes+1": rnd_bytes(rng, 2954),
        "v40L_num": b"7" * 7089,
        "v40L_num+1": b"7" * 7090,
        "v40L_alnum": b"Z" * 4296,
        "v40L_alnum+1": b"Z" * 4297,
        "v1H_bytes": b"abcdefg",
        "v1H_num": b"1" * 17,
        "v1H_alnum": b"A" * 10,
    }
    for k, p in edge.items():
        ec = "H" if k.startswith("v1H") else "L"
        rows.append((f"C/{k}", ec, 1, 40, -1, "auto", p.hex()))
    # D. random auto-mode payloads (mixed classes) for every EC level
    alph = [b"0123456789", ALNUM.encode(), b"abcdefghijklmnopqrstuvwxyz/?=&.", bytes(range(256))]
    for i in range(600):
        n = rng.choice([5, 20, 60, 150, 400, 900])
        parts = bytearray()
        while len(parts) < n:
            a = rng.choice(alph[:3] if i % 4 else alph)
            parts += bytes(rng.choice(a) for _ in range(rng.randint(1, 24)))
        rows.append((f"D/{i}", ECS[i % 4], 1, 40, -1, "auto", bytes(parts[:n]).hex()))
    w(os.path.join(out, "enc.tsv"), rows)

    # E. optimiser corpus: short mixed strings, all three char-count tiers
    srows = []
    for i in range(4000):
        n = rng.randint(1, 60)
        s = bytearray()
        while len(s) < n:
            a = rng.choice(alph[:3])
            s += bytes(rng.choice(a) for _ in range(rng.choice([1, 2, 3, 4, 5, 6, 7, 9, 13])))
        for v in (1, 10, 27):
            srows.append((f"E/{i}/v{v}", v, bytes(s[:n]).hex()))
    w(os.path.join(out, "seg.tsv"), srows)
    print(f"enc rows={len(rows)} seg rows={len(srows)}")


# ---------------------------------------------------------------- compare helpers
def load(path):
    d = {}
    with open(path) as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            d[p[0]] = p[1:]
    return d


def cmp_enc(out):
    corpus = {r[0]: r for r in (l.rstrip("\n").split("\t") for l in open(os.path.join(out, "enc.tsv")))}
    P = load(os.path.join(out, "enc_pion.out"))
    G = load(os.path.join(out, "enc_gen.out"))
    stats = {}
    bad = []

    def bump(k):
        stats[k] = stats.get(k, 0) + 1

    for k, row in corpus.items():
        p, g = P.get(k), G.get(k)
        if p is None:
            bad.append((k, "pion missing (crash?)"))
            continue
        fixed_mask = int(row[4]) >= 0 and row[5] not in ("auto", "auto_noopt")
        if p[0] != g[0]:
            bump("status_mismatch")
            bad.append((k, f"pion={p[:1] + p[1:2]} gen={g[:1] + g[1:2]}"))
            continue
        if p[0] == "ERR":
            bump("both_err")
            continue
        if row[5] in ("auto", "auto_noopt"):
            pv, gv = int(p[1]), int(g[1])
            bump("auto_same_version" if pv == gv else ("auto_pion_smaller" if pv < gv else "auto_pion_LARGER"))
            if pv > gv:
                bad.append((k, f"pion picks v{pv}, qrcodegen v{gv}"))
            continue
        if fixed_mask:
            if p[4] == g[4]:
                bump("matrix_identical")
            else:
                bump("matrix_DIFF")
                n = int(p[1]) * 4 + 17
                diffs = [i for i in range(n * n) if p[4][i] != g[4][i]]
                bad.append((k, f"{len(diffs)} modules differ, first at (x={diffs[0] % n},y={diffs[0] // n})"))
        else:
            if p[3] == g[3]:
                bump("automask_same" + ("" if p[4] == g[4] else "_but_matrix_DIFF"))
            else:
                bump("automask_differs")
    print("encoder diff vs Nayuki qrcodegen 1.8.0:", dict(sorted(stats.items())))
    for k, why in bad[:25]:
        print(f"  {k}: {why}")
    return stats, bad


def cmp_interop(out):
    """dec_*.out: decoders run over mat_*.tsv (matrices + transforms); truth from corpus."""
    corpus = {r[0]: r for r in (l.rstrip("\n").split("\t") for l in open(os.path.join(out, "enc.tsv")))}
    res = {}
    for src in ("pion", "gen"):
        for dec in ("pion", "rqrr"):
            path = os.path.join(out, f"dec_{dec}_of_{src}.out")
            D = load(path)
            st = {}
            ex = []
            for k, r in D.items():
                base, tr = k.rsplit("|", 1)
                row = corpus[base]
                truth = bytes.fromhex(row[6])
                kind = row[5]
                key = tr
                if r[0] == "OK":
                    got = bytes.fromhex(r[5]) if len(r) > 5 else b""
                    if got == truth:
                        st[key + ":ok"] = st.get(key + ":ok", 0) + 1
                    else:
                        st[key + ":WRONG"] = st.get(key + ":WRONG", 0) + 1
                        if len(ex) < 6:
                            ex.append((k, kind, truth[:16].hex(), got[:16].hex()))
                else:
                    st[key + ":err:" + r[1]] = st.get(key + ":err:" + r[1], 0) + 1
                    if len(ex) < 6 and tr == "r0":
                        ex.append((k, kind, "ERR", r[1]))
            res[(src, dec)] = st
            print(f"decoder={dec:5s} matrices_from={src:4s}", dict(sorted(st.items())))
            for e in ex:
                print("   ", e)
    return res


def write_matrices(out):
    """Build mat_{pion,gen}.tsv from encoder outputs: r0/r90/r180/r270 + mirror (transpose)."""
    for src in ("pion", "gen"):
        E = load(os.path.join(out, f"enc_{src}.out"))
        rows = []
        for k, r in E.items():
            if r[0] != "OK" or k.endswith("/over"):
                continue
            if not (k.startswith(("A/", "B/", "C/")) and (k.endswith(("/m0", "/m5", "/auto", "/max")) or k.startswith(("B/eci", "C/"))) or k.startswith("D/")):
                continue
            v = int(r[1])
            n = v * 4 + 17
            bits = r[4]
            rows.append((k + "|r0", n, bits))
            if k.startswith(("D/", "C/")) or k.endswith("/auto"):
                b = bits
                for t in ("r90", "r180", "r270"):
                    b = rot_cw(b, n)
                    rows.append((k + "|" + t, n, b))
                rows.append((k + "|mirror", n, transpose(bits, n)))
        w(os.path.join(out, f"mat_{src}.tsv"), rows)
        print(f"mat_{src}.tsv rows={len(rows)}")


def write_inject(out):
    """RS error injection on Nayuki matrices at fixed mask 0: k byte-errors in EVERY block."""
    E = load(os.path.join(out, "enc_gen.out"))
    rng = random.Random(9)
    rows = []
    for v in list(range(1, 11)) + [15, 20, 27, 33, 40]:
        pl = placement(v)
        n = v * 4 + 17
        for ec in ECS:
            r = E[f"A/{v}{ec}/m0"]
            e = ECC[ec][v - 1]
            t = e // 2
            tspec = (e - MISDECODE_P.get((v, ec), 0)) // 2
            layout = block_layout(v, ec)
            for k in sorted(set([1, tspec, t, t + 1, t + 2, t + 4, e])):
                if k < 1:
                    continue
                trials = 40 if v <= 3 else 6
                for trial in range(trials):
                    bits = list(r[4])
                    for blk in layout:
                        for ci in rng.sample(blk, min(k, len(blk))):
                            mag = rng.randrange(1, 256)
                            for bit in range(8):
                                if (mag >> (7 - bit)) & 1:
                                    x, y = pl[ci * 8 + bit]
                                    bits[y * n + x] = "1" if bits[y * n + x] == "0" else "0"
                    rows.append((f"I/{v}{ec}/k{k}/t{t}/ts{tspec}/{trial}", n, "".join(bits)))
    w(os.path.join(out, "inject.tsv"), rows)
    print(f"inject.tsv rows={len(rows)}")


def cmp_inject(out):
    corpus = {r[0]: r for r in (l.rstrip("\n").split("\t") for l in open(os.path.join(out, "enc.tsv")))}
    summary = {}
    for dec in ("pion", "rqrr"):
        D = load(os.path.join(out, f"inject_{dec}.out"))
        for k, r in D.items():
            _, vec, kk, tt, ts, _ = k.split("/")
            truth = bytes.fromhex(corpus[f"A/{vec}/m0"][6])
            kn, t, tspec = int(kk[1:]), int(tt[1:]), int(ts[2:])
            cls = "k<=t_spec" if kn <= tspec else ("t_spec<k<=t" if kn <= t else "k>t")
            if r[0] == "OK":
                o = "ok" if bytes.fromhex(r[5]) == truth else "SILENT_WRONG"
            else:
                o = "err"
            key = (dec, cls)
            summary.setdefault(key, {}).setdefault(o, 0)
            summary[key][o] += 1
            if o == "SILENT_WRONG":
                summary.setdefault((dec, "silent_wrong_cases"), {}).setdefault(f"{vec}/k{kn}", 0)
                summary[(dec, "silent_wrong_cases")][f"{vec}/k{kn}"] += 1
            if cls == "k<=t_spec" and o != "ok":
                summary.setdefault((dec, "FAILED_within_t"), {}).setdefault(f"{vec}/k{kn}", 0)
                summary[(dec, "FAILED_within_t")][f"{vec}/k{kn}"] += 1
    for k in sorted(summary):
        print(f"  {k[0]:5s} {k[1]:20s} {dict(sorted(summary[k].items()))}")
    return summary


# ---------------------------------------------------------------- mask penalty (Nayuki port)
def nayuki_penalty(bits, n):
    """Port of qrcodegen 1.8.0 get_penalty_score (N3 counts 1:1:3:1:1 at any scale, and the
    light quiet zone outside the symbol counts as the 4-module light run)."""
    m = [[bits[y * n + x] == "1" for x in range(n)] for y in range(n)]

    def line_pen(get):
        res = 0
        for a in range(n):
            runcolor, run, hist = False, 0, [0] * 7

            def add(r):
                if hist[0] == 0:
                    r += n
                hist.insert(0, r)
                hist.pop()

            def count():
                k = hist[1]
                core = k > 0 and hist[2] == k and hist[3] == k * 3 and hist[4] == k and hist[5] == k
                return (1 if core and hist[0] >= k * 4 and hist[6] >= k else 0) + (1 if core and hist[6] >= k * 4 and hist[0] >= k else 0)

            for b in range(n):
                c = get(a, b)
                if c == runcolor:
                    run += 1
                    if run == 5:
                        res += 3
                    elif run > 5:
                        res += 1
                else:
                    add(run)
                    if not runcolor:
                        res += count() * 40
                    runcolor, run = c, 1
            if runcolor:
                add(run)
                run = 0
            run += n
            add(run)
            res += count() * 40
        return res

    r = line_pen(lambda a, b: m[a][b]) + line_pen(lambda a, b: m[b][a])
    for y in range(n - 1):
        for x in range(n - 1):
            c = m[y][x]
            if c == m[y][x + 1] == m[y + 1][x] == m[y + 1][x + 1]:
                r += 3
    dark = sum(map(sum, m))
    tot = n * n
    k = (abs(dark * 20 - tot * 10) + tot - 1) // tot - 1
    return r + k * 10


def cmp_masks(out):
    """For each A/*/m0..m7 (same data, all 8 masks) find the Nayuki-optimal mask and check what
    Pion's auto mask (A/*/auto) scores under the Nayuki / zxing N3 rule."""
    P = load(os.path.join(out, "enc_pion.out"))
    G = load(os.path.join(out, "enc_gen.out"))
    worse, same, tot = [], 0, 0
    for v in range(1, 41):
        for ec in ECS:
            n = v * 4 + 17
            pens = [nayuki_penalty(G[f"A/{v}{ec}/m{m}"][4], n) for m in range(8)]
            pm, gm = int(P[f"A/{v}{ec}/auto"][3]), int(G[f"A/{v}{ec}/auto"][3])
            assert pens[gm] == min(pens), (v, ec)
            tot += 1
            if pm == gm:
                same += 1
            elif pens[pm] > pens[gm]:
                worse.append((f"{v}{ec}", pm, pens[pm], gm, pens[gm]))
    print(f"auto mask over the 160 full-capacity symbols: pion==nayuki {same}/{tot}; pion mask scores strictly worse under the reference N1..N4: {len(worse)}")
    for x in worse[:10]:
        print(f"  {x[0]}: pion mask {x[1]} (penalty {x[2]}) vs qrcodegen mask {x[3]} (penalty {x[4]})")
    return worse


# ---------------------------------------------------------------- hostile bitstreams
class Bits:
    def __init__(self):
        self.b = []

    def put(self, val, n):
        self.b += [(val >> (n - 1 - i)) & 1 for i in range(n)]
        return self

    def rep(self, val, n, times):
        for _ in range(times):
            self.put(val, n)
        return self

    def codewords(self, v, ec, pad=True):
        cap = data_cw(v, ec)
        b = self.b[: cap * 8]
        b += [0] * (-len(b) % 8)
        out = bytearray(int("".join(map(str, b[i:i + 8])), 2) for i in range(0, len(b), 8))
        i = 0
        while len(out) < cap:
            out.append((0xEC, 0x11)[i & 1] if pad else 0)
            i += 1
        return bytes(out)


def hostile_cases():
    """(id, v, ec, codewords, expectation) - expectation documents what ISO 18004 / zxing do."""
    B = Bits
    cases = []

    def add(name, v, ec, bits, exp, pad=True):
        cases.append((name, v, ec, bits.codewords(v, ec, pad), exp))

    add("byte_ok", 1, "L", B().put(4, 4).put(3, 8).put(0x41, 8).put(0x42, 8).put(0x43, 8).put(0, 4), "ok:414243")
    add("byte_len255_only2", 1, "L", B().put(4, 4).put(255, 8).put(0x41, 8).put(0x42, 8), "err")
    add("numeric_count1023_trunc", 1, "L", B().put(1, 4).put(1023, 10).put(123, 10), "err")
    add("numeric_triplet_1000", 1, "L", B().put(1, 4).put(3, 10).put(1000, 10).put(0, 4), "err")
    add("numeric_triplet_1023", 1, "L", B().put(1, 4).put(3, 10).put(1023, 10).put(0, 4), "err")
    add("alnum_pair_2047", 1, "L", B().put(2, 4).put(2, 9).put(2047, 11).put(0, 4), "err")
    add("alnum_char_63", 1, "L", B().put(2, 4).put(1, 9).put(63, 6).put(0, 4), "err")
    add("kanji_kv8191", 1, "L", B().put(8, 4).put(1, 8).put(8191, 13).put(0, 4), "any")
    add("kanji_kv_to_0x9FFD", 1, "L", B().put(8, 4).put(1, 8).put(0x1E * 0xC0 + 0xBD, 13).put(0, 4), "reject_or_valid_sjis")
    add("kanji_kv_to_0x81FF", 1, "L", B().put(8, 4).put(1, 8).put(0xBF, 13).put(0, 4), "reject_or_valid_sjis")
    add("kanji_count255_trunc", 1, "L", B().put(8, 4).put(255, 8).put(1, 13), "err")
    add("eci_1byte_26", 1, "L", B().put(7, 4).put(26, 8).put(4, 4).put(1, 8).put(0x5A, 8).put(0, 4), "ok:5a")
    add("eci_3byte_2097151", 1, "L", B().put(7, 4).put(0xDFFFFF, 24).put(4, 4).put(1, 8).put(0x5A, 8).put(0, 4), "err(>999999)")
    add("eci_prefix_111", 1, "L", B().put(7, 4).put(0xE0, 8).put(0, 4), "err")
    add("eci_2byte_truncated_at_end", 1, "L", B().put(4, 4).put(16, 8).rep(0x41, 8, 16).put(7, 4).put(0x80, 8), "err", pad=False)
    add("struct_append_0011", 1, "L", B().put(3, 4).put(0x01, 4).put(0x01, 4).put(0x5A, 8).put(4, 4).put(1, 8).put(0x41, 8).put(0, 4), "ok:41 (zxing)")
    add("fnc1_first_0101", 1, "L", B().put(5, 4).put(4, 4).put(1, 8).put(0x41, 8).put(0, 4), "ok:41")
    add("fnc1_second_1001", 1, "L", B().put(9, 4).put(0x41, 8).put(4, 4).put(1, 8).put(0x42, 8).put(0, 4), "ok:42")
    for m in (6, 10, 11, 12, 13, 14, 15):
        add(f"mode_{m:04b}", 1, "L", B().put(m, 4).put(0, 12), "err")
    add("byte17_4bit_tail", 1, "L", B().put(4, 4).put(17, 8).rep(0x41, 8, 17), "ok:" + "41" * 17, pad=False)
    add("v40_byte_len65535", 40, "L", B().put(4, 4).put(65535, 16).rep(0x41, 8, 100), "err")
    add("v40_numeric_count16383", 40, "L", B().put(1, 4).put(16383, 14).put(1, 10), "err")
    add("v40_kanji_count4095", 40, "L", B().put(8, 4).put(4095, 12).put(1, 13), "err")
    add("all_zero_codewords", 5, "M", B(), "ok:", pad=False)
    rng = random.Random(77)
    for i in range(3000):
        v = rng.choice([1, 2, 5, 9, 10, 20, 26, 27, 40])
        ec = rng.choice(ECS)
        cw = rnd_bytes(rng, data_cw(v, ec))
        cases.append((f"fuzz{i}", v, ec, cw, "nocrash"))
    for i in range(1000):
        # random mode headers + plausible counts: steer the parser into every branch
        v = rng.choice([1, 10, 27])
        ec = rng.choice(ECS)
        b = B()
        for _ in range(rng.randint(1, 6)):
            m = rng.choice([1, 2, 4, 8, 7, 3, 5, 9, 0, 6, 13])
            b.put(m, 4).put(rng.randrange(1 << 16), rng.choice([8, 9, 10, 12, 14, 16])).put(rng.randrange(1 << 20), 20)
        cases.append((f"fuzzhdr{i}", v, ec, b.codewords(v, ec), "nocrash"))
    return cases


def write_hostile(out):
    rows = [(n, ec, v, 0, cw.hex()) for (n, v, ec, cw, _) in hostile_cases()]
    w(os.path.join(out, "cw.tsv"), rows)
    print(f"cw.tsv rows={len(rows)}")


def cmp_hostile(out):
    exp = {n: e for (n, v, ec, cw, e) in hostile_cases()}
    P = load(os.path.join(out, "hostile_pion.out"))
    R = load(os.path.join(out, "hostile_rqrr.out"))
    fuzz = {"pion": {}, "rqrr": {}}
    for n, e in exp.items():
        p, r = P.get(n, ["MISSING"]), R.get(n, ["MISSING"])
        fmt = lambda x: (x[0] + ":" + x[5][:24]) if x[0] == "OK" else ("ERR:" + x[1] if x[0] == "ERR" else x[0])
        if e == "nocrash":
            for who, x in (("pion", p), ("rqrr", r)):
                k = "OK" if x[0] == "OK" else ("ERR" if x[0] == "ERR" else "CRASH/MISSING")
                fuzz[who][k] = fuzz[who].get(k, 0) + 1
            continue
        print(f"  {n:28s} expect={e:22s} pion={fmt(p):34s} rqrr={fmt(r)}")
    print("  random-codeword fuzz (4000 RS-valid symbols):", fuzz)
    return P, fuzz


# ---------------------------------------------------------------- optimiser oracle
def char_ok(mode, c):
    if mode == "N":
        return 48 <= c <= 57
    if mode == "A":
        return chr(c) in ALNUM
    return True


def exact_opt(data, v):
    """Exact minimum bits over all N/A/B segmentations (O(n^2))."""
    n = len(data)
    INF = 1 << 30
    best = [INF] * (n + 1)
    best[0] = 0
    for i in range(1, n + 1):
        for mode in "NAB":
            j = i
            while j > 0 and char_ok(mode, data[j - 1]):
                j -= 1
                b = seg_bits(mode, i - j, v)
                if b is not None and best[j] + b < best[i]:
                    best[i] = best[j] + b
    return best[n]


def cmp_seg(out):
    S = load(os.path.join(out, "seg_pion.out"))
    rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(out, "seg.tsv"))]
    worse = []
    for k, v, hx in rows:
        data = bytes.fromhex(hx)
        opt = exact_opt(data, int(v))
        got = int(S[k][0])
        if got > opt:
            worse.append((got - opt, k, data.decode("latin1"), got, opt, S[k][1]))
    worse.sort(key=lambda x: (-x[0], len(x[2])))
    print(f"optimize_segments: {len(rows)} cases, {len(worse)} longer than the exact optimum; worst excess={worse[0][0] if worse else 0} bits")
    for e in worse[:8]:
        print(f"  +{e[0]} bits {e[1]} {e[2]!r} pion={e[3]} opt={e[4]} segs={e[5]}")
    return worse


if __name__ == "__main__":
    cmd, out = sys.argv[1], sys.argv[2]
    {"gen": gen, "enc": cmp_enc, "interop": cmp_interop, "inject": cmp_inject, "seg": cmp_seg,
     "mats": write_matrices, "mkinject": write_inject, "mkhostile": write_hostile, "hostile": cmp_hostile, "masks": cmp_masks}[cmd](out)
