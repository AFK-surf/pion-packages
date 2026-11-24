#!/usr/bin/env python3
"""Bug injection: 5 realistic bug classes, each applied to a fresh copy of packages/dash/src.

inject.py <pkg_dir> <audit_dir> <out_dir>   prints '<n> <mutant_audit_dir|SKIP> <description>' per mutant.
The copy of the audit package points at the mutated package copy (and at the original packages/url). When the
target text is no longer in the sources (a fix rewrote it), the mutant is reported as SKIP, not as a failure.
"""
import os
import shutil
import sys

MUTANTS = [
    ("src/xml_lexer.pion", '"<!DOCTYPE")', '"<!DOCTYPX")', 2,
     "security: <!DOCTYPE no longer classified as SecurityRejected (falls through to InvalidXml)"),
    ("src/resolve.pion", "entry.r + 1L", "entry.r", 1, "timeline: S@r repeat count off by one"),
    ("src/format.pion", 'sb.write_string("&quot;")', 'sb.write_string("\\"")', 1,
     "format_mpd: '\"' no longer escaped in attribute values (attribute / element injection)"),
    ("src/time.pion", "((year % 100 != 0) || (year % 400 == 0))", "true", 1, "calendar: century leap-year rule dropped"),
    ("src/abr.pion", "bw <= max_bandwidth && bw > best_fit_bw", "bw < max_bandwidth && bw > best_fit_bw", 1,
     "ABR: a Representation exactly at the budget is no longer eligible"),
]


def main():
    pkg, audit, out = (os.path.abspath(x) for x in sys.argv[1:4])
    url_pkg = os.path.abspath(os.path.join(pkg, "..", "url"))
    for n, (rel, old, new, count, desc) in enumerate(MUTANTS, 1):
        src = open(os.path.join(pkg, rel), encoding="utf-8").read()
        if src.count(old) < 1:
            print("%d SKIP %s" % (n, desc))
            continue
        root = os.path.join(out, "m%d" % n)
        shutil.rmtree(root, ignore_errors=True)
        dash = os.path.join(root, "dash")
        os.makedirs(dash)
        shutil.copytree(os.path.join(pkg, "src"), os.path.join(dash, "src"))
        shutil.copy(os.path.join(pkg, "pion.toml"), dash)
        a = os.path.join(dash, "audit")
        os.makedirs(a)
        shutil.copytree(os.path.join(audit, "src"), os.path.join(a, "src"))
        toml = open(os.path.join(audit, "pion.toml"), encoding="utf-8").read()
        toml = toml.replace('path = "../../url"', 'path = "%s"' % url_pkg)
        open(os.path.join(a, "pion.toml"), "w", encoding="utf-8").write(toml)
        p = os.path.join(dash, rel)
        open(p, "w", encoding="utf-8").write(src.replace(old, new))
        print("%d %s %s" % (n, a, desc))


if __name__ == "__main__":
    main()
