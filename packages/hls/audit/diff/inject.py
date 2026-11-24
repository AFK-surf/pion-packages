#!/usr/bin/env python3
"""Bug-injection gate: copy packages/hls to <out>/mut_<n>/hls, apply one mutation to its src/, and re-point a
copy of the audit package at it. The mutations are real bug classes; each must make a control case fail.

usage: inject.py <pkg_dir> <audit_dir> <out_dir>    prints `<n> <dir>|SKIP <reason> <description>` per mutation

A mutation whose target text is not found (e.g. the code was rewritten by a fix) is reported as SKIP instead of
failing: nothing here asserts the exact pre-fix source.
"""
import os
import re
import shutil
import sys

MUTATIONS = [
    ("attrs.pion", r"if attrs\[k\]\.key == key \{", "if false {", "duplicate AttributeName check removed (§4.2)"),
    ("parser.pion", r"if pu != uri \{", "if false {", "implicit BYTERANGE: same-URI requirement removed (§4.4.4.2)"),
    ("utils.pion", r"if b == 34 \|\| b == 10 \|\| b == 13 \|\| b == 0 \{", "if b == 10 || b == 13 || b == 0 {",
     "formatter quoted-string guard lets '\"' through (attribute injection)"),
    ("decimal.pion", r"\|\| year % 400 == 0", "|| year % 400 == 1", "Gregorian 400-year leap rule broken"),
    ("utils.pion", r"codecs_str\.code_unit_at\(start \+ pn\) == 46", "true",
     "select_variant codec prefix matches without a '.' boundary (avc matches avc1)"),
]


def main():
    pkg, audit, out = sys.argv[1:4]
    for n, (f, pat, rep, desc) in enumerate(MUTATIONS, 1):
        d = os.path.join(out, "mut_%d" % n)
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(os.path.join(pkg, "src"), os.path.join(d, "hls", "src"))
        shutil.copy(os.path.join(pkg, "pion.toml"), os.path.join(d, "hls", "pion.toml"))
        p = os.path.join(d, "hls", "src", f)
        s = open(p).read()
        s2, k = re.subn(pat, rep, s, count=1)
        if k == 0:
            print("%d SKIP target-not-found %s" % (n, desc))
            continue
        open(p, "w").write(s2)
        a = os.path.join(d, "audit")
        shutil.copytree(os.path.join(audit, "src"), os.path.join(a, "src"))
        toml = open(os.path.join(audit, "pion.toml")).read()
        toml = re.sub(r'hls = \{ path = "[^"]*" \}', 'hls = { path = "%s" }' % os.path.join(d, "hls"), toml)
        open(os.path.join(a, "pion.toml"), "w").write(toml)
        print("%d %s %s" % (n, a, desc))


if __name__ == "__main__":
    main()
