"""Comparisons for the idna red-team audit.

  compare.py same  <a> <b>                       byte-identical dumps (4-mode determinism); prints first difference
  compare.py model <corpus> <pion> <model>       Pion vs the independent Python model (diff/model.py)
  compare.py rust  <corpus> <pion> <rust>        Pion vs Rust idna 1.1.0 (profiles U and N)

`model` / `rust` classify every divergence: either an open finding of REPORT.md explains it (printed as
`[P1-1] ...` and listed on the `FINDINGS` line), or a documented, non-defect difference (`[INFO-n]`), or it is
UNEXPLAINED. Exit status 1 if any divergence is unexplained.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# NFC_Quick_Check=Maybe code points (valid in UTS #46) that packages/idna's cp_may_need_nfc misses (P1-1).
# Derived from DerivedNormalizationProps.txt 16.0.0 in `static` of run_audit.sh; repeated here for speed.
NFC_GAP = {0x114B0, 0x114BA, 0x114BD, 0x115AF, 0x11930, 0x16D67, 0x16D68} | set(range(0x1611E, 0x1612A))


def blocks(path):
    d = {}
    order = []
    cur = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("="):
                cur = line[1:]
                d[cur] = {}
                order.append(cur)
            elif cur is not None and line:
                fl = line.split(" ")
                d[cur][fl[0] + " " + fl[1] if fl[0] in ("A", "U") else fl[0]] = fl
    return d, order


def corpus(path):
    out = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if "\t" in line:
                k, v = line.split("\t", 1)
                out[k] = bytes.fromhex(v)
    return out


def cps(raw):
    try:
        return [ord(c) for c in raw.decode("utf-8")]
    except UnicodeDecodeError:
        return None


def unhex(x):
    return b"" if x == "-" else bytes.fromhex(x)


def is_ascii_hex(x):
    return all(b < 0x80 for b in unhex(x))


def same(a, b):
    with open(a, "rb") as fa, open(b, "rb") as fb:
        la = fa.read().split(b"\n")
        lb = fb.read().split(b"\n")
    if la == lb:
        return 0
    for i, (x, y) in enumerate(zip(la, lb)):
        if x != y:
            print("  first difference at line %d:\n    %s\n    %s" % (i + 1, x[:200], y[:200]))
            break
    else:
        print("  lengths differ: %d vs %d lines" % (len(la), len(lb)))
    return 1


class Tally:
    def __init__(self):
        self.explained = {}
        self.unexplained = []
        self.checks = 0
        self.agree = 0

    def add(self, fid, name, key, got, want):
        if fid:
            self.explained.setdefault(fid, []).append((name, key, got, want))
        else:
            self.unexplained.append((name, key, got, want))

    def report(self, label):
        print("  %s: %d checks, %d agree, %d explained, %d unexplained" %
              (label, self.checks, self.agree, sum(len(v) for v in self.explained.values()), len(self.unexplained)))
        for fid in sorted(self.explained):
            e = self.explained[fid]
            print("    [%s] %d, e.g. %s %s pion=%s other=%s" % (fid, len(e), e[0][0], e[0][1], " ".join(e[0][2])[:90],
                                                                " ".join(e[0][3])[:90]))
        for e in self.unexplained[:30]:
            print("    [UNEXPLAINED] %s %s pion=%s other=%s" % (e[0], e[1], " ".join(e[2])[:150], " ".join(e[3])[:150]))
        if len(self.unexplained) > 30:
            print("    ... %d more unexplained" % (len(self.unexplained) - 30))


def model_cmp(cpath, ppath, mpath):
    C = corpus(cpath)
    P, order = blocks(ppath)
    M, _ = blocks(mpath)
    t = Tally()
    for name in order:
        raw = C[name]
        cp = cps(raw) or []
        gap = any(c in NFC_GAP for c in cp)
        p, m = P[name], M[name]
        for key, mv in m.items():
            pv = p.get(key)
            if pv is None:
                t.checks += 1
                t.add(None, name, key, ["<missing>"], mv)
                continue
            t.checks += 1
            ok = False
            fid = None
            if key[0] == "A":
                prof = key[2]
                if mv[2] == "LIMIT":
                    ok = pv[2] == "ERR"
                else:
                    ok = pv[2] == mv[2] and (pv[2] != "OK" or pv[3] == mv[3])
                if not ok:
                    if gap:
                        fid = "P1-1"
                    elif prof == "T" and 0x1E9E in cp:
                        fid = "P2-4"
                    elif pv[2] == "OK" and mv[2] == "ERR" and mv[3] == "V4" and prof in ("U", "R"):
                        fid = "P2-1"
                    elif pv[2] == "OK" and mv[2] == "ERR" and prof == "I" and \
                            mv[3] in ("P4", "P4-ascii", "P4-nonascii", "V4"):
                        fid = "P2-2"
                    elif prof == "S" and pv[2] == "ERR" and mv[2] == "OK" and 0x30FB in cp:
                        fid = "P2-3"
            elif key[0] == "U":
                prof = key[2]
                if mv[2] == "LIMIT":
                    ok = pv[2] == "0"
                else:
                    ok = pv[2] == mv[2] and pv[5] == mv[4]
                    if not ok and pv[2] == mv[2] == "0":
                        fid = "INFO-1"  # best-effort output of an invalid domain (see REPORT.md)
                if not ok and fid is None:
                    if gap:
                        fid = "P1-1"
                    elif pv[2] == "1" and mv[3] == "V4" and prof in ("U", "R"):
                        fid = "P2-1"
                    elif pv[2] == "1" and prof == "I" and mv[3] in ("P4", "P4-ascii", "P4-nonascii", "V4"):
                        fid = "P2-2"
                    elif prof == "S" and pv[2] == "0" and mv[2] == "1" and 0x30FB in cp:
                        fid = "P2-3"
            elif key == "K":
                if mv[1] == "?":
                    ok = True
                else:
                    ok = pv[1] == mv[2] or (pv[1] == mv[1] and mv[1] == mv[2])
                    if not ok and pv[1] == mv[1]:
                        fid = "P1-5"
            elif key == "C":
                ok = mv[1] == "?" or pv[1] == mv[1]
            elif key == "D":
                if mv[3] == "RAW":
                    ok = pv[1] == "1" and pv[2] == "InvalidIdna"
                    if ok and not is_ascii_hex(pv[3]):
                        t.add("P1-2", name, key, pv, mv)
                        t.checks += 0
                else:
                    ok = pv[1] == mv[1] and set(pv[2].split(",")) == set(mv[2].split(",")) and pv[3] == mv[3] and \
                        pv[4] == mv[4]
                if not ok:
                    if gap:
                        fid = "P1-1"
                    elif any(0x116D0 <= c <= 0x116E3 for c in cp) and "MixedNumberingSystems" in mv[2]:
                        fid = "P2-8"
                    elif 0x30FB in cp and pv[2] == "InvalidIdna":
                        fid = "P2-3"
            elif key in ("P", "Q"):
                ok = pv[1] == mv[1] and (pv[1] != "OK" or pv[2] == mv[2])
            else:
                ok = pv == mv
            if ok:
                t.agree += 1
            else:
                t.add(fid, name, key, pv, mv)
    return t


def rust_cmp(cpath, ppath, rpath, assigned):
    C = corpus(cpath)
    P, order = blocks(ppath)
    R, _ = blocks(rpath)
    t = Tally()
    lines_agree = 0
    for name in order:
        raw = C[name]
        cp = cps(raw) or []
        gap = any(c in NFC_GAP for c in cp)
        p, r = P[name], R[name]
        dec = cps(unhex(p["U U"][5])) or []
        unassigned16 = any(c not in assigned for c in cp + dec)
        all_ok = True
        for key, rv in r.items():
            pv = p[key]
            t.checks += 1
            fid = None
            if key[0] == "A":
                ok = pv[2] == rv[2] and (pv[2] != "OK" or pv[3] == rv[3])
            else:
                ok = pv[2] == rv[2] and (pv[2] == "0" or pv[5] == rv[3])
            if not ok:
                all_ok = False
                pk = pv[3] if key[0] == "A" else pv[4]
                if gap:
                    fid = "P1-1"
                elif pk == "LimitExceeded":
                    fid = "INFO-4"  # IdnaLimits (documented DoS bounds) stricter than Rust's
                elif unassigned16 and (pv[2] in ("ERR", "0")) and rv[2] in ("OK", "1"):
                    fid = "INFO-3"  # Rust idna 1.1.0 / ICU4X 2.4 data is Unicode 17: code points unassigned in 16.0
            if ok:
                t.agree += 1
            else:
                t.add(fid, name, key, pv, rv)
        lines_agree += all_ok
    print("  inputs with identical U+N results: %d/%d" % (lines_agree, len(order)))
    return t


def main():
    mode = sys.argv[1]
    if mode == "same":
        sys.exit(same(sys.argv[2], sys.argv[3]))
    if mode == "model":
        t = model_cmp(sys.argv[2], sys.argv[3], sys.argv[4])
        t.report("pion vs model")
    elif mode == "rust":
        from ucd import data
        t = rust_cmp(sys.argv[2], sys.argv[3], sys.argv[4], set(data().gc))
        t.report("pion vs rust idna 1.1.0")
    else:
        sys.exit(2)
    print("FINDINGS " + " ".join(sorted(k for k in t.explained if k.startswith("P"))))
    sys.exit(1 if t.unexplained else 0)


if __name__ == "__main__":
    main()
