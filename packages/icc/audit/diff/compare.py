#!/usr/bin/env python3
"""Runner, classifier and exact float reference for the packages/icc red-team audit (python3 stdlib only).

  compare.py run <list> <out.txt> <runner...>      dump every listed file; a crash/trap/hang is recorded as
                                                  `CRASH <rc>` / `TIMEOUT` for that file and the run resumes after it
  compare.py same <a.txt> <b.txt>                  records must be byte-identical (mode-vs-mode)
  compare.py adv <manifest.json> <dump.txt>        expectations of a correct parser; exit 1 on P0, prints `open <id>`
  compare.py fuzz <dump.txt>                       exit 1 on any CRASH / TIMEOUT / READFAIL
  compare.py grid <list> <pion> <oracle> <grid.rgb> <work_dir>
                                                  per profile: packages/icc vs exact float reference (ICC.1:2022
                                                  matrix/TRC + clip + IEC 61966-2-1 OETF), qcms 0.3.0, moxcms 0.9.2
"""
import json
import os
import re
import struct
import subprocess
import sys

TIMEOUT_PER_FILE = 20.0


# ----------------------------------------------------------------------------------------------------------------
# run / same / adv / fuzz
# ----------------------------------------------------------------------------------------------------------------


def parse_records(text):
    rec = {}
    order = []
    cur = None
    for line in text.splitlines():
        if line.startswith("== "):
            cur = line[3:]
            rec[cur] = []
            order.append(cur)
        elif cur is not None:
            rec[cur].append(line)
    return rec, order


def cmd_run(lst, out, runner):
    paths = [p for p in open(lst).read().split("\n") if p]
    tmp = out + ".lst"
    done = {}
    i = 0
    crashes = 0
    while i < len(paths):
        rest = paths[i:]
        with open(tmp, "w") as f:
            f.write("\n".join(rest) + "\n")
        try:
            p = subprocess.run(runner + ["dumplist", tmp], capture_output=True, timeout=TIMEOUT_PER_FILE + 0.05 * len(rest))
            text = p.stdout.decode("utf-8", "replace")
            rc = p.returncode
            timed_out = False
        except subprocess.TimeoutExpired as e:
            text = (e.stdout or b"").decode("utf-8", "replace")
            rc = None
            timed_out = True
        rec, order = parse_records(text)
        if rc == 0 and len(order) == len(rest):
            for k in order:
                done[k] = rec[k]
            break
        # the last record started is the culprit unless all completed; keep complete ones
        complete = order[:-1] if order else []
        for k in complete:
            done[k] = rec[k]
        bad_idx = i + len(complete)
        bad = paths[bad_idx]
        done[bad] = ["TIMEOUT" if timed_out else "CRASH %s %s" % (rc, (p.stderr.decode("utf-8", "replace").strip().splitlines() or [""])[-1][:160])]
        crashes += 1
        i = bad_idx + 1
    os.remove(tmp)
    with open(out, "w") as f:
        for k in paths:
            f.write("== " + k + "\n" + "".join(l + "\n" for l in done.get(k, ["MISSING"])))
    print("%d records, %d crash/timeout" % (len(paths), crashes))
    return 0


def cmd_same(a, b):
    x = open(a).read()
    y = open(b).read()
    if x == y:
        return 0
    ra, oa = parse_records(x)
    rb, _ = parse_records(y)
    n = 0
    for k in oa:
        if ra[k] != rb.get(k):
            n += 1
            if n <= 5:
                print("  differs: %s\n    %s\n    %s" % (k, ra[k], rb.get(k)))
    print("  %d records differ" % n)
    return 1


def cmd_adv(manifest, dump):
    m = json.load(open(manifest))
    rec, _ = parse_records(open(dump).read())
    rc = 0
    for c in m:
        lines = rec.get(c["path"], ["MISSING"])
        ok = all(any(re.search(w, l) for l in lines) for w in c["want"])
        shown = " / ".join(l[:140] for l in lines if not l.startswith(("X ", "K ")))
        if ok and c["finding"]:
            print("  fixed %s: %s (finding %s no longer reproduces)" % (c["finding"], c["name"], c["finding"]))
        elif ok:
            print("  ok %s" % c["name"])
        elif c["finding"]:
            print("  open %s: %s :: want %s :: got %s" % (c["finding"], c["name"], c["want"], shown))
            if c["finding"].startswith("P0"):
                rc = 1
        else:
            print("  FAIL (P0, unclassified) %s :: want %s :: got %s" % (c["name"], c["want"], shown))
            rc = 1
    return rc


def cmd_fuzz(dump):
    rec, order = parse_records(open(dump).read())
    bad = [(k, rec[k]) for k in order if any(l.startswith(("CRASH", "TIMEOUT", "READFAIL", "MISSING")) for l in rec[k])]
    verdicts = {}
    for k in order:
        v = " ".join(l.split(" ")[0] + " " + l.split(" ")[1] for l in rec[k] if l[:2] in ("C ", "P ", "T "))
        verdicts[v] = verdicts.get(v, 0) + 1
    print("  %d inputs, %d crash/timeout; verdict classes: %s" % (len(order), len(bad), ", ".join("%s=%d" % kv for kv in sorted(verdicts.items(), key=lambda kv: -kv[1])[:8])))
    for k, v in bad[:10]:
        print("  CRASH/TIMEOUT %s :: %s" % (k, v))
    return 1 if bad else 0


# ----------------------------------------------------------------------------------------------------------------
# exact float reference (independent of packages/icc: own parser, own D50 -> sRGB matrix)
# ----------------------------------------------------------------------------------------------------------------


def m_inv(m):
    a, b, c = m[0]
    d, e, f = m[1]
    g, h, i = m[2]
    A = e * i - f * h
    B = -(d * i - f * g)
    C = d * h - e * g
    det = a * A + b * B + c * C
    return [
        [A / det, -(b * i - c * h) / det, (b * f - c * e) / det],
        [B / det, (a * i - c * g) / det, -(a * f - c * d) / det],
        [C / det, -(a * h - b * g) / det, (a * e - b * d) / det],
    ]


def m_mul(x, y):
    return [[sum(x[r][k] * y[k][c] for k in range(3)) for c in range(len(y[0]))] for r in range(3)]


def xyz_d50_to_srgb():
    """Bradford-adapt the IEC 61966-2-1 primaries (D65) to the ICC PCS illuminant D50 (0.9642, 1, 0.8249), invert."""
    def xy(x, y):
        return [x / y, 1.0, (1 - x - y) / y]

    d65 = xy(0.3127, 0.3290)
    P = [xy(0.64, 0.33), xy(0.30, 0.60), xy(0.15, 0.06)]
    M = [[P[c][r] for c in range(3)] for r in range(3)]
    S = m_mul(m_inv(M), [[d65[0]], [d65[1]], [d65[2]]])
    rgb2xyz65 = [[M[r][c] * S[c][0] for c in range(3)] for r in range(3)]
    brad = [[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367], [0.0389, -0.0685, 1.0296]]
    d50 = [0.9642, 1.0, 0.8249]
    s = m_mul(brad, [[v] for v in d65])
    d = m_mul(brad, [[v] for v in d50])
    adapt = m_mul(m_inv(brad), m_mul([[d[0][0] / s[0][0], 0, 0], [0, d[1][0] / s[1][0], 0], [0, 0, d[2][0] / s[2][0]]], brad))
    return m_inv(m_mul(adapt, rgb2xyz65))


T_PCS = xyz_d50_to_srgb()


def oetf(l):
    l = 0.0 if l != l or l < 0 else (1.0 if l > 1 else l)
    return 12.92 * l if l <= 0.0031308 else 1.055 * l ** (1 / 2.4) - 0.055


def clip01(v):
    return 0.0 if v != v or v < 0 else (1.0 if v > 1 else v)


def s15(d, o):
    return struct.unpack(">i", d[o : o + 4])[0] / 65536.0


class RefProfile:
    def __init__(self, d):
        self.cs = d[16:20]
        n = struct.unpack(">I", d[128:132])[0]
        self.tags = {}
        for i in range(n):
            sig, off, size = struct.unpack(">4sII", d[132 + 12 * i : 144 + 12 * i])
            self.tags.setdefault(sig, (off, size))  # first wins, as in qcms 0.3.0 (find_tag)
        self.d = d

    def xyz(self, sig):
        o, _ = self.tags[sig]
        return [s15(self.d, o + 8 + 4 * k) for k in range(3)]

    def trc(self, sig):
        d = self.d
        o, _ = self.tags[sig]
        t = d[o : o + 4]
        if t == b"curv":
            n = struct.unpack(">I", d[o + 8 : o + 12])[0]
            if n == 0:
                return lambda x: x
            if n == 1:
                g = struct.unpack(">H", d[o + 12 : o + 14])[0] / 256.0
                return lambda x: x ** g
            e = [struct.unpack(">H", d[o + 12 + 2 * i : o + 14 + 2 * i])[0] / 65535.0 for i in range(n)]

            def f(x):
                s = x * (n - 1)
                i = min(int(s), n - 2)
                return e[i] + (e[i + 1] - e[i]) * (s - i)

            return f
        ft = struct.unpack(">H", d[o + 8 : o + 10])[0]
        p = [s15(d, o + 12 + 4 * k) for k in range({0: 1, 1: 3, 2: 4, 3: 5, 4: 7}[ft])] + [0.0] * 7
        g, a, b, c, dd, e, f = p[:7]

        def pw(base):
            return base ** g if base > 0 else 0.0

        if ft == 0:
            return lambda x: x ** g
        if ft == 1:
            return lambda x: pw(a * x + b) if x >= -b / a else 0.0
        if ft == 2:
            return lambda x: pw(a * x + b) + c if x >= -b / a else c
        if ft == 3:
            return lambda x: pw(a * x + b) if x >= dd else c * x
        return lambda x: pw(a * x + b) + e if x >= dd else c * x + f

    def lin_luts(self):
        """Per-channel 256-entry linear-light tables (ICC: curve outputs are clipped to [0, 1])."""
        if self.cs == b"GRAY":
            k = self.trc(b"kTRC")
            t = [clip01(k(i / 255.0)) for i in range(256)]
            return t, t, t
        return tuple([clip01(self.trc(s)(i / 255.0)) for i in range(256)] for s in (b"rTRC", b"gTRC", b"bTRC"))

    def transform(self, rgb):
        lr, lg, lb = self.lin_luts()
        if self.cs == b"GRAY":
            enc = bytes(int(oetf(v) * 255 + 0.5) for v in lr)
            return bytes(enc[v] for v in rgb)
        M = [[self.xyz(s)[r] for s in (b"rXYZ", b"gXYZ", b"bXYZ")] for r in range(3)]
        A = m_mul(T_PCS, M)
        out = bytearray(len(rgb))
        for i in range(0, len(rgb), 3):
            r, g, b = lr[rgb[i]], lg[rgb[i + 1]], lb[rgb[i + 2]]
            for ch in range(3):
                out[i + ch] = int(oetf(A[ch][0] * r + A[ch][1] * g + A[ch][2] * b) * 255 + 0.5)
        return bytes(out)


def stats(a, b, n):
    if len(a) != n or len(b) != n:
        return None
    hist = [0, 0, 0]
    mx = 0
    worst = 0
    for i in range(n):
        dd = abs(a[i] - b[i])
        if dd > mx:
            mx = dd
            worst = i
        hist[min(dd, 2)] += 1
    return mx, hist[0] * 100.0 / n, (hist[0] + hist[1]) * 100.0 / n, worst


def cmd_grid(lst, pion, oracle, grid, work):
    os.makedirs(work, exist_ok=True)
    rgb = open(grid, "rb").read()
    n = len(rgb)
    rc = 0
    rows = []
    for path in [p for p in open(lst).read().split("\n") if p]:
        name = os.path.basename(path)
        base = os.path.join(work, re.sub(r"[^A-Za-z0-9_.-]", "_", name))
        pr = subprocess.run(pion + ["grid", path, grid, base + ".pion"], capture_output=True, text=True)
        d = open(path, "rb").read()
        gray = d[16:20] == b"GRAY"
        if gray:
            subprocess.run([oracle, "gray", path, base], check=True)
            ramp = bytes(range(256))
            ref = RefProfile(d).transform(ramp)
            pion_out = open(base + ".pion", "rb").read() if pr.returncode == 0 else b""
            # packages/icc applies the gray LUT to each byte: the R channel of the R ramp is the gray response
            pion_out = pion_out[0 : 256 * 3 : 3] if pion_out else b""
            q = open(base + ".qcms", "rb").read()
            m = open(base + ".moxcms", "rb").read()
            nn = 256
        else:
            subprocess.run([oracle, "grid", path, grid, base], check=True)
            ref = RefProfile(d).transform(rgb)
            pion_out = open(base + ".pion", "rb").read() if pr.returncode == 0 else b""
            q = open(base + ".qcms", "rb").read()
            m = open(base + ".moxcms", "rb").read()
            nn = n
        s_ref = stats(pion_out, ref, nn)
        s_q = stats(pion_out, q, nn)
        s_m = stats(pion_out, m, nn)
        s_qr = stats(q, ref, nn)
        s_mr = stats(m, ref, nn)
        rows.append((name, pr.stdout.strip(), s_ref, s_q, s_m, s_qr, s_mr, pion_out, ref, nn))
    print("  %-38s %-6s | %-24s | %-24s | %-24s | qcms-ref moxcms-ref" % ("profile", "id", "pion vs exact ref", "pion vs qcms 0.3.0", "pion vs moxcms 0.9.2"))

    def fmt(s):
        return "FAIL" if s is None else "max %d, %6.2f%% =, %6.2f%% <=1" % s[:3]

    worst_ref = 0
    for name, tag, s_ref, s_q, s_m, s_qr, s_mr, po, ref, nn in rows:
        print("  %-38s %-6s | %-24s | %-24s | %-24s | %-8s %s" % (name[:38], tag.replace("OK ", ""), fmt(s_ref), fmt(s_q), fmt(s_m), "-" if s_qr is None else s_qr[0], "-" if s_mr is None else s_mr[0]))
        if s_ref is None:
            print("    FAIL (P0): packages/icc did not transform a well-formed profile: %s" % tag)
            rc = 1
            continue
        if s_ref[0] > worst_ref:
            worst_ref = s_ref[0]
        if s_ref[0] > 1:
            w = 1 if nn == 256 else 3
            i = s_ref[3] - s_ref[3] % w
            src = list(range(256))[i : i + 1] if w == 1 else list(rgb[i : i + 3])
            print("    > %d LSB vs exact reference at input %s: pion %s, reference %s" % (s_ref[0], src, list(po[i : i + w]), list(ref[i : i + w])))
            rc = max(rc, 2)
    print("  worst pion-vs-reference error over the set: %d LSB" % worst_ref)
    return rc


def main():
    cmd = sys.argv[1]
    if cmd == "run":
        sys.exit(cmd_run(sys.argv[2], sys.argv[3], sys.argv[4:]))
    if cmd == "same":
        sys.exit(cmd_same(sys.argv[2], sys.argv[3]))
    if cmd == "adv":
        sys.exit(cmd_adv(sys.argv[2], sys.argv[3]))
    if cmd == "fuzz":
        sys.exit(cmd_fuzz(sys.argv[2]))
    if cmd == "grid":
        sys.exit(cmd_grid(sys.argv[2], sys.argv[3].split(" "), sys.argv[4], sys.argv[5], sys.argv[6]))
    sys.exit(2)


if __name__ == "__main__":
    main()
