#!/usr/bin/env python3
"""Turn cases/eval_cases.txt into the hex-encoded eval script read by both probes.

usage: gen_eval.py <eval_cases.txt> <out.tsv>
"""
import re
import sys

SEL = re.compile(r'^([A-Za-z_:][A-Za-z0-9_:]*)?\{(.*)\}$')
PAIR = re.compile(r'\s*([A-Za-z_][A-Za-z0-9_]*)="((?:[^"\\]|\\.)*)"\s*(?:,|$)')


def unescape(s):
    return s.encode("utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")


def hx(s):
    return s.encode("utf-8").hex()


def main():
    out = []
    for raw in open(sys.argv[1], encoding="utf-8"):
        line = raw.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        c = line.split("\t")
        if c[0] == "clear":
            out.append("clear")
        elif c[0] == "series":
            m = SEL.match(c[1])
            labels = []
            if m.group(1):
                labels.append(("__name__", m.group(1)))
            body = m.group(2)
            pos = 0
            while pos < len(body):
                p = PAIR.match(body, pos)
                labels.append((p.group(1), unescape(p.group(2))))
                pos = p.end()
            out.append("series\t%s\t%s" % (",".join("%s=%s" % (k, hx(v)) for k, v in labels), c[2]))
        elif c[0] == "instant":
            out.append("instant\t%s\t%s\t%s" % (c[1], c[2], hx(c[3])))
        elif c[0] == "range":
            out.append("range\t%s\t%s\t%s\t%s\t%s" % (c[1], c[2], c[3], c[4], hx(c[5])))
        else:
            raise SystemExit("bad line: " + line)
    open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
