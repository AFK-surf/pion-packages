#!/usr/bin/env python3
"""Driver + checker for packages/exif/audit (stdlib only; run with `python3 -I`).

  compare.py run <list> <out.txt> <runner...>   robust batch dump: every file of <list> gets exactly one record
                                                (a crashing / hanging file is isolated and recorded as CRASH / TIMEOUT)
  compare.py diff <pion.txt> <oracle.txt>       well-formed corpus: Pion must equal kamadak-exif field by field and
                                                every accessor must equal the value derived from kamadak's fields
  compare.py adv <manifest.json> <pion.txt> <oracle.txt>
                                                adversarial corpus: Pion verdict/accessors vs the expectation of a
                                                correct parser (kamadak result shown for information)
  compare.py fuzz <pion.txt> <oracle.txt> <label>
                                                mutants / truncations: 0 CRASH / TIMEOUT required; differences
                                                against kamadak are classified (see classify())
  compare.py same <a.txt> <b.txt>               two Pion modes must produce identical records

Exit status 1 = a P0 condition (crash, hang, silent value deviation on well-formed input, mode divergence);
3 = only non-P0 findings (expectations from REPORT.md P1/P2 still open); 0 = clean.
"""

import json
import os
import struct
import subprocess
import sys
import time

CHUNK = 400
CHUNK_TIMEOUT = 120.0
FILE_TIMEOUT = 10.0


# ------------------------------------------------------------------------------------------------
# robust runner
# ------------------------------------------------------------------------------------------------

def parse_records(text):
    recs = {}
    order = []
    cur = None
    for line in text.splitlines():
        if line.startswith("== "):
            cur = line[3:]
            recs[cur] = []
            order.append(cur)
        elif cur is not None:
            recs[cur].append(line)
    return recs, order


def complete(lines):
    """A record is complete when it is ERR/READFAIL or an OK with its trailing accessor (Pion) line."""
    if not lines:
        return False
    if lines[0].startswith("ERR") or lines[0] == "READFAIL":
        return True
    if lines[0].startswith("OK"):
        n = int(lines[0].split()[2])
        return len(lines) >= 2 + n and lines[1 + n].startswith("A ")
    return False


def run_batch(runner, files, tmpdir):
    lst = os.path.join(tmpdir, "batch.lst")
    with open(lst, "w") as f:
        f.write("\n".join(files) + "\n")
    t0 = time.time()
    try:
        p = subprocess.run(runner + ["dumplist", lst], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=CHUNK_TIMEOUT if len(files) > 1 else FILE_TIMEOUT)
        out, err, rc, to = p.stdout.decode("latin-1"), p.stderr.decode("latin-1"), p.returncode, False
    except subprocess.TimeoutExpired as ex:
        out = (ex.stdout or b"").decode("latin-1")
        err, rc, to = "timeout", -1, True
    return out, err, rc, to, time.time() - t0


def cmd_run(lst, outp, runner):
    files = [x for x in open(lst).read().splitlines() if x]
    tmpdir = os.path.dirname(os.path.abspath(outp))
    result = {}
    pending = [files[i:i + CHUNK] for i in range(0, len(files), CHUNK)]
    crashes = 0
    while pending:
        chunk = pending.pop(0)
        out, err, rc, to, _ = run_batch(runner, chunk, tmpdir)
        recs, _ = parse_records(out)
        done = [f for f in chunk if f in recs and complete(recs[f])]
        for f in done:
            result[f] = recs[f]
        if rc == 0 and not to and len(done) == len(chunk):
            continue
        rest = [f for f in chunk if f not in result]
        if len(chunk) == 1:
            f = chunk[0]
            msg = [l for l in err.splitlines() if "panic" in l or "rror" in l][:1]
            result[f] = ["TIMEOUT" if to else "CRASH rc=%d %s" % (rc, (msg[0] if msg else err.strip()[-160:]))]
            crashes += 1
            continue
        # isolate: first unfinished file alone, the remainder as a new chunk
        if rest:
            pending.insert(0, rest[1:]) if len(rest) > 1 else None
            pending.insert(0, [rest[0]])
    with open(outp, "w") as f:
        for name in files:
            f.write("== " + name + "\n")
            for l in result[name]:
                f.write(l + "\n")
    print("  run: %d files -> %s (%d crash/timeout)" % (len(files), os.path.basename(outp), crashes))


# ------------------------------------------------------------------------------------------------
# record model
# ------------------------------------------------------------------------------------------------

class Rec:
    def __init__(self, lines):
        self.lines = lines
        self.kind = lines[0].split()[0] if lines else "MISSING"
        self.err = None
        self.fields = []
        self.acc = None
        if self.kind == "ERR":
            parts = lines[0].split(" ", 2)
            self.err = parts[1]
            self.msg = parts[2] if len(parts) > 2 else ""
        elif self.kind == "OK":
            self.bo = lines[0].split()[1]
            for l in lines[1:]:
                if l.startswith("F "):
                    _, ifd, tag, typ, cnt, *val = l.split(" ")
                    self.fields.append((ifd, int(tag, 16), int(typ), cnt, val[0] if val else ""))
                elif l.startswith("A "):
                    self.acc = dict(kv.split("=", 1) for kv in l[2:].split(" "))

    def crashed(self):
        return self.kind in ("CRASH", "TIMEOUT", "MISSING")

    def norm(self):
        """Fields grouped by IFD (parse order is BFS in Pion, DFS in kamadak; order inside an IFD is kept)."""
        g = {}
        for ifd, tag, typ, cnt, val in self.fields:
            g.setdefault(ifd, []).append((tag, typ, "?" if typ == 2 else cnt, val))
        return g

    def short(self):
        if self.kind == "ERR":
            return "ERR %s (%s)" % (self.err, self.msg)
        if self.kind == "OK":
            return "OK %d fields" % len(self.fields)
        return " ".join(self.lines)[:200]


def load(path):
    recs, order = parse_records(open(path, encoding="latin-1").read())
    return {k: Rec(v) for k, v in recs.items()}, order


# ------------------------------------------------------------------------------------------------
# expected accessors, derived independently from kamadak's field list
# ------------------------------------------------------------------------------------------------

INT_TYPES = (1, 3, 4, 6, 8, 9)


def first(rec, ifd, tag):
    for f in rec.fields:
        if f[0] == ifd and f[1] == tag:
            return f
    return None


def ints(val):
    return [int(x) for x in val.split(",")] if val else []


def rats(val):
    out = []
    for x in val.split(",") if val else []:
        n, d = x.split("/")
        out.append((int(n), int(d)))
    return out


def ascii0(val):
    n, _, rest = val.partition(":")
    if n == "0":
        return None
    return bytes.fromhex(rest.split(",")[0])


def dbits(x):
    return "%016x" % struct.unpack("<Q", struct.pack("<d", x))[0]


def expected_acc(rec):
    """Accessor values a correct implementation returns, computed from (kamadak's) decoded fields:
    first IFD0 Orientation of an integer type with value 1..8; GPS from N/S/E/W refs, 3 rationals with non-zero
    denominators, |lat| <= 90, |lon| <= 180; altitude negated when AltitudeRef == 1, rejected for other refs."""
    acc = {}
    f = first(rec, "T0", 0x0112)
    v = ints(f[4]) if f and f[2] in INT_TYPES else []
    acc["ori"] = str(v[0]) if v and 1 <= v[0] <= 8 else "none"

    def ref(tag, pos, neg):
        f = first(rec, "G", tag)
        if not f or f[2] != 2:
            return None
        s = ascii0(f[4])
        return 1.0 if s in pos else (-1.0 if s in neg else None)

    def dms(tag):
        f = first(rec, "G", tag)
        if not f or f[2] != 5:
            return None
        r = rats(f[4])
        if len(r) < 3 or any(d == 0 for _, d in r[:3]):
            return None
        return (r[0][0] / r[0][1]) + (r[1][0] / r[1][1]) / 60.0 + (r[2][0] / r[2][1]) / 3600.0

    ls, la, os_, lo = ref(1, (b"N", b"n"), (b"S", b"s")), dms(2), ref(3, (b"E", b"e"), (b"W", b"w")), dms(4)
    if None in (ls, la, os_, lo) or la > 90.0 or lo > 180.0:
        acc["gps"] = "none"
    else:
        acc["gps"] = dbits(la * ls) + "," + dbits(lo * os_)
    f = first(rec, "G", 6)
    alt = None
    if f and f[2] == 5 and rats(f[4]) and rats(f[4])[0][1] != 0:
        n, d = rats(f[4])[0]
        alt = n / d
        r = first(rec, "G", 5)
        if r is not None:
            rv = ints(r[4]) if r[2] in INT_TYPES else []
            if rv[:1] == [0]:
                pass
            elif rv[:1] == [1]:
                alt = -alt
            else:
                alt = None
    acc["alt"] = "none" if alt is None else dbits(alt)
    f = first(rec, "E", 0xA001)  # primary ExifIFD only (kamadak names the thumbnail's ExifIFD "E1")
    v = ints(f[4]) if f and f[2] in INT_TYPES else []
    acc["cs"] = str(v[0]) if v and -2147483648 <= v[0] <= 2147483647 else "none"
    return acc


# ------------------------------------------------------------------------------------------------
# checks
# ------------------------------------------------------------------------------------------------

def field_diff(p, o):
    pn, on = p.norm(), o.norm()
    out = []
    for ifd in sorted(set(pn) | set(on)):
        a, b = pn.get(ifd, []), on.get(ifd, [])
        if a != b:
            out.append("%s: pion=%s kamadak=%s" % (ifd, a[:6], b[:6]))
    return out


def cmd_diff(pp, op):
    P, order = load(pp)
    O, _ = load(op)
    bad = 0
    for f in order:
        p, o = P[f], O[f]
        name = os.path.basename(f)
        probs = []
        if p.crashed():
            probs.append("pion " + p.short())
        elif p.kind != o.kind:
            probs.append("verdict pion=%s kamadak=%s" % (p.short(), o.short()))
        elif p.kind == "OK":
            if p.bo != o.bo:
                probs.append("byte order")
            probs += field_diff(p, o)
            exp = expected_acc(o)
            for k in ("ori", "gps", "alt", "cs"):
                if p.acc.get(k) != exp[k]:
                    probs.append("accessor %s pion=%s expected=%s" % (k, p.acc.get(k), exp[k]))
        if probs:
            bad += 1
            print("  FAIL %-40s %s" % (name, " | ".join(probs)[:600]))
        else:
            print("  ok   %-40s %s" % (name, p.short()))
    print("  diff: %d/%d identical to kamadak-exif 0.6.2 (fields + accessors)" % (len(order) - bad, len(order)))
    return 1 if bad else 0


def cmd_adv(mp, pp, op):
    man = {m["file"]: m for m in json.load(open(mp)) if m["group"] == "adv"}
    P, order = load(pp)
    O, _ = load(op)
    p0 = 0
    open_findings = {}
    for f in order:
        m, p, o = man[f], P[f], O[f]
        exp = m["expect"]
        probs = []
        if p.crashed():
            probs.append("P0 " + p.short())
            p0 += 1
        v = exp.get("verdict", "ANY")
        if not p.crashed() and v != "ANY":
            if v == "OK" and p.kind != "OK":
                probs.append("want OK, got " + p.short())
            elif v.startswith("ERR") and p.kind != "ERR":
                probs.append("want %s, got %s" % (v, p.short()))
            elif v.startswith("ERR:") and p.kind == "ERR" and p.err != v[4:]:
                probs.append("want %s, got %s" % (v, p.short()))
        if p.kind == "OK":
            for k in ("ori",):
                if k in exp:
                    want = "none" if exp[k] is None else str(exp[k])
                    if p.acc["ori"] != want:
                        probs.append("ori=%s want %s" % (p.acc["ori"], want))
            for k in ("gps", "alt"):
                if k in exp:
                    if exp[k] is None:
                        want = "none"
                    elif k == "gps":
                        want = dbits(exp[k][0]) + "," + dbits(exp[k][1])
                    else:
                        want = dbits(exp[k])
                    if p.acc[k] != want:
                        probs.append("%s=%s want %s" % (k, p.acc[k], want))
            if "colorspace" in exp:
                want = "none" if exp["colorspace"] is None else str(exp["colorspace"])
                if p.acc["cs"] != want:
                    probs.append("color_space()=%s want %s (thumbnail ExifIFD leaks into primary)" % (p.acc["cs"], want))
        fid = exp.get("finding")
        tag = "FAIL" if probs else "ok  "
        if probs and fid:
            tag = "OPEN"
            open_findings.setdefault(fid, []).append(os.path.basename(f))
        elif probs and not any(x.startswith("P0") for x in probs):
            open_findings.setdefault("unclassified", []).append(os.path.basename(f))
        print("  %s %-44s pion: %-58s kamadak: %s%s" % (tag, os.path.basename(f), p.short()[:58], o.short()[:60],
                                                       ("  <- " + "; ".join(probs)) if probs else ""))
    for k, v in sorted(open_findings.items()):
        print("  open %s: %d case(s)" % (k, len(v)))
    if p0:
        return 1
    if "unclassified" in open_findings:
        return 1
    return 3 if open_findings else 0


def classify(p, o):
    """Why Pion and kamadak differ on one mutant (None = identical)."""
    if p.kind == o.kind == "ERR":
        return None
    if p.kind == "ERR" and o.kind == "OK":
        if "unsupported TIFF type" in p.msg or "unknown TIFF field type" in p.msg:
            return "pion_err_unknown_type (P1-1)"
        if "expected 0xFF JPEG marker" in p.msg:
            return "pion_err_jpeg_no_resync (P2-2)"
        if "IFD0 offset out of bounds" in p.msg and o.fields == []:
            return "pion_err_ifd0_offset (kamadak: 0 fields for IFD0 offset 0; pion stricter)"
        if "truncated PNG chunk" in p.msg:
            return "pion_err_png_needs_crc (pion requires the eXIf CRC bytes; stricter)"
        if "out of bounds" in p.msg or "truncated IFD" in p.msg:
            return "pion_err_subifd_bounds (P2-5)"
        return "pion_err_other: " + p.err + " " + p.msg[:40]
    if p.kind == "OK" and o.kind == "ERR":
        if "Unexpected next IFD" in o.msg:
            return "kamadak_err_subifd_next (pion lenient)"
        if "Broken" in o.msg or "Not a" in o.msg or "overflowing" in o.msg:
            return "kamadak_err_container (pion lenient)"
        if any(x in o.msg for x in ("Invalid pointer", "Truncated IFD", "Already visited", "Truncated field value")):
            return "kamadak_err_pointer (pion skips zero / count!=1 / non-LONG pointers; lenient)"
        return "kamadak_err_other: " + o.msg[:40]
    # both OK
    if p.bo != o.bo:
        return "VALUE_byte_order"
    pn, on = p.norm(), o.norm()
    if pn == on:
        return None
    # normalise documented structural divergences, then demand identical values
    on2 = {}
    for ifd, v in on.items():
        k = ifd[0] if ifd[0] in "EGI" else ifd
        on2.setdefault(k, []).extend(v)
    pn2 = {k: v for k, v in pn.items()}
    for d in (pn2, on2):
        for k in list(d):
            # drop pointer tags the two libraries consume differently; drop UNKNOWN-typed (kamadak-only) fields
            # and type-13 (TIFF TN1 "IFD") fields: Pion decodes them as LONG, kamadak keeps them Unknown
            d[k] = [x for x in d[k] if x[0] not in (0x8769, 0x8825, 0xA005) and x[3] != "UNKNOWN" and x[1] != 13]
            if not d[k]:
                del d[k]
    common = set(pn2) & set(on2)
    if all(sorted(pn2[k]) == sorted(on2[k]) for k in common):
        if set(pn2) != set(on2):
            return "subifd_set (pointer typing / IFD1 sub-IFD / Interop-in-IFD0: P2-1, P2-6)"
        return "type13_or_pointer_typing (P2-6, values identical)"
    return "VALUE"


def cmd_fuzz(pp, op, label):
    P, order = load(pp)
    O, _ = load(op)
    crash = [f for f in order if P[f].crashed()]
    cls = {}
    ex = {}
    for f in order:
        if P[f].crashed():
            continue
        c = classify(P[f], O[f])
        key = c or ("identical_ok" if P[f].kind == "OK" else "both_err")
        cls[key] = cls.get(key, 0) + 1
        ex.setdefault(key, f)
    print("  %s: %d inputs, %d crash/timeout" % (label, len(order), len(crash)))
    for f in crash[:10]:
        print("    CRASH %s: %s" % (f, P[f].short()))
    for k in sorted(cls):
        print("    %-70s %6d   e.g. %s" % (k, cls[k], os.path.basename(ex[k])))
    vals = [f for f in order if not P[f].crashed() and (classify(P[f], O[f]) or "").startswith("VALUE")]
    for f in vals[:5]:
        print("    VALUE %s" % f)
        for d in field_diff(P[f], O[f])[:3]:
            print("      " + d[:300])
    return 1 if crash or vals else 0


def cmd_same(a, b):
    A, order = load(a)
    B, _ = load(b)
    bad = [f for f in order if A[f].lines != B[f].lines and not (A[f].crashed() and B[f].crashed())]
    for f in bad[:5]:
        print("    DIFF %s: %s | %s" % (f, A[f].short(), B[f].short()))
    print("  %s == %s on %d/%d records" % (os.path.basename(a), os.path.basename(b), len(order) - len(bad), len(order)))
    return 1 if bad else 0


def main():
    cmd = sys.argv[1]
    a = sys.argv[2:]
    if cmd == "run":
        cmd_run(a[0], a[1], a[2:])
        return 0
    if cmd == "diff":
        return cmd_diff(a[0], a[1])
    if cmd == "adv":
        return cmd_adv(a[0], a[1], a[2])
    if cmd == "fuzz":
        return cmd_fuzz(a[0], a[1], a[2])
    if cmd == "same":
        return cmd_same(a[0], a[1])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
