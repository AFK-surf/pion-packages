"""Official Unicode 16.0.0 IdnaTestV2.txt conformance of packages/idna (from an `idna_audit dump` of
idnatest.cases, profile N = uts46_non_transitional for toUnicode / toAsciiN, profile T for toAsciiT;
these are exactly the flags the file is generated with).

  idnatest.py <pion_dump> [--json out.json]

Prints per-column pass counts and every failing line, grouped by the finding that explains it
(`explained_by`), and exits 1 if a failure is not explained by an open finding id.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen import idnatest_lines  # noqa: E402


def blocks(path):
    d = {}
    cur = None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("="):
            cur = line[1:]
            d[cur] = {}
        elif cur is not None:
            f = line.split(" ")
            key = f[0] + " " + f[1] if f[0] in ("A", "U") else f[0]
            d[cur][key] = f
    return d


def unhex(x):
    return "" if x == "-" else bytes.fromhex(x).decode("utf-8", "replace")


def status(s):
    s = s.strip()
    if not s or s == "[]":
        return []
    return [x.strip() for x in s.strip("[]").split(",") if x.strip()]


def main():
    P = blocks(sys.argv[1])
    res = {"toUnicode": [0, 0], "toUnicode_string_on_error": [0, 0], "toAsciiN": [0, 0], "toAsciiT": [0, 0]}
    fails = []
    valid_all = [0, 0]
    for no, c in idnatest_lines():
        name = "t%05d" % no
        src = "" if c[0] == '""' else c[0]
        tu = src if c[1] == "" else ("" if c[1] == '""' else c[1])
        su = status(c[2])
        tn = tu if c[3] == "" else ("" if c[3] == '""' else c[3])
        sn = su if c[4] == "" else status(c[4])
        tt = tn if c[5] == "" else ("" if c[5] == '""' else c[5])
        st = sn if c[6] == "" else status(c[6])
        if any(0xD800 <= ord(ch) <= 0xDFFF for ch in src):
            continue  # ill-formed strings: skipped as the file allows ("A3")
        b = P[name]
        # toUnicode
        u = b["U N"]
        ok_valid = (u[2] == "1") == (not su)
        out = unhex(u[5])
        res["toUnicode"][1] += 1
        if ok_valid and (su or out == tu):
            res["toUnicode"][0] += 1
        else:
            fails.append((name, "toUnicode", src, "valid=%s out=%r" % (u[2], out), "%s %r" % (su, tu)))
        if su:
            res["toUnicode_string_on_error"][1] += 1
            if out == tu or (len(out) == len(tu) and all(a == e or a == "�" for a, e in zip(out, tu))):
                res["toUnicode_string_on_error"][0] += 1
        for col, prof, want, sts in (("toAsciiN", "A N", tn, sn), ("toAsciiT", "A T", tt, st)):
            a = b[prof]
            res[col][1] += 1
            got_ok = a[2] == "OK"
            if got_ok == (not sts) and (not got_ok or unhex(a[3]) == want):
                res[col][0] += 1
            else:
                fails.append((name, col, src, " ".join(a[2:]) if not got_ok else "OK " + unhex(a[3]),
                              "%s %r" % (sts, want)))
        if not su and not sn and not st:
            valid_all[1] += 1
            if all(not (f[0] == name) for f in fails):
                valid_all[0] += 1
    explained = {}
    unexplained = []
    for f in fails:
        fid = None
        if f[1] == "toAsciiT" and "ẞ" in f[2]:
            fid = "P2-4"  # transitional deviation reached through a mapping (ẞ -> ß -> ss)
        elif f[1].startswith("toAscii") and f[4].startswith("['A4_2']") and f[3].startswith("OK ") and \
                f[3].endswith("."):
            fid = "INFO-6"  # documented: verify_dns_length accepts one trailing root dot (= Rust VerifyAllowRootDot)
        elif f[1] == "toUnicode" and f[4].startswith("['X4_2']") and f[3].startswith("valid=1"):
            fid = "INFO-7"  # X4_2: test-file-only empty-label toUnicode status (no UTS #46 16.0 processing step)
        if fid:
            explained.setdefault(fid, []).append(f)
        else:
            unexplained.append(f)
    total = sum(v[1] for k, v in res.items() if k != "toUnicode_string_on_error")
    passed = sum(v[0] for k, v in res.items() if k != "toUnicode_string_on_error")
    for k, v in res.items():
        print("  %-26s %d/%d" % (k, v[0], v[1]))
    print("  all-valid lines (no status in any column): %d/%d" % tuple(valid_all))
    print("  total checks: %d/%d pass, %d explained (open findings or documented INFO deviations), %d unexplained" %
          (passed, total, sum(len(v) for v in explained.values()), len(unexplained)))
    for fid, lst in sorted(explained.items()):
        f = lst[0]
        print("  [%s] %d checks, e.g. %s %s src=%r got=%s want=%s" % (fid, len(lst), f[0], f[1], f[2][:60], f[3][:70],
                                                                     f[4][:70]))
    for f in unexplained:
        print("  [UNEXPLAINED] %s %s src=%r got=%s want=%s" % (f[0], f[1], f[2], f[3][:200], f[4][:200]))
    print("FINDINGS " + " ".join(sorted(k for k in explained if k.startswith("P"))))
    print("VALID_ALL %d %d" % tuple(valid_all))
    if len(sys.argv) > 3 and sys.argv[2] == "--json":
        json.dump({"res": res, "valid_all": valid_all, "explained": {k: len(v) for k, v in explained.items()},
                   "unexplained": len(unexplained)}, open(sys.argv[3], "w"))
    sys.exit(1 if unexplained else 0)


if __name__ == "__main__":
    main()
