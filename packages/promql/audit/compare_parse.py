#!/usr/bin/env python3
"""Compare Pion probe vs Go oracle parse outputs.

usage: compare_parse.py <corpus.tsv> <pion.out> <go.out> <label> [--details FILE]

Pion line: <id> OK <type> <hex format_expr> <rt> <pr> <hex prettify_expr> | <id> ERR
Go line:   <id> OK <type> <hex String()> <go_rt> <hex Prettify()>       | <id> ERR

Counted categories (each must be 0 for the check to PASS):
  over_accept   Pion OK, Go ERR                 (invalid PromQL accepted)
  over_reject   Pion ERR, Go OK                 (valid PromQL rejected)
  type          both OK, different static value type
  format        both OK, format_expr != Go String(), where Go's String() re-parses to itself
  roundtrip     Pion: parse(format_expr(e)) does not re-format to the same string
  pretty_rt     Pion: parse(prettify_expr(e)) does not re-format to format_expr(e)
  pretty_go     format_expr == Go String() but prettify_expr != Go parser.Prettify()
Informational (not counted): format_go_quirk = format differs but Go's own String()
does not survive ParseExpr (upstream formatter bug, e.g. `on (a.b)` for UTF-8 names).
Prints "<label> <category> <count>" lines, then up to 5 examples per category.
"""
import sys

COUNTED = ("over_accept", "over_reject", "type", "format", "roundtrip", "pretty_rt", "pretty_go")
FINDING = {
    "over_accept": ("F11", "P2", "parser accepts PromQL that Go rejects"),
    "over_reject": ("F12", "P2", "parser rejects PromQL that Go accepts"),
    "type": ("PARSE-TYPE", "-", "static value type matches Go (control)"),
    "format": ("F13", "P2", "format_expr == Go Expr.String()"),
    "roundtrip": ("F10", "P1", "parse(format_expr(e)) is a fixed point"),
    "pretty_rt": ("F10b", "P1", "parse(prettify_expr(e)) re-formats to format_expr(e)"),
    "pretty_go": ("F14", "P2", "prettify_expr == Go parser.Prettify()"),
}


def load(path):
    d = {}
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if line:
            c = line.split("\t")
            d[c[0]] = c[1:]
    return d


def unhex(h):
    return bytes.fromhex(h).decode("utf-8", "replace")


def main():
    corpus = []
    for line in open(sys.argv[1], encoding="utf-8"):
        i, h = line.rstrip("\n").split("\t")
        corpus.append((i, unhex(h)))
    pion, go, label = load(sys.argv[2]), load(sys.argv[3]), sys.argv[4]
    details = None
    if "--details" in sys.argv:
        details = open(sys.argv[sys.argv.index("--details") + 1], "a", encoding="utf-8")
    cats = {k: [] for k in COUNTED + ("format_go_quirk",)}
    for i, q in corpus:
        p, g = pion.get(i, ["MISSING"]), go.get(i, ["MISSING"])
        p_ok, g_ok = p[0] == "OK", g[0] == "OK"
        if p_ok and not g_ok:
            cats["over_accept"].append((i, q, "pion=%r" % unhex(p[2])))
        elif g_ok and not p_ok:
            cats["over_reject"].append((i, q, "go=%r" % unhex(g[2])))
        elif p_ok and g_ok:
            if p[1] != g[1]:
                cats["type"].append((i, q, "pion=%s go=%s" % (p[1], g[1])))
            if p[2] != g[2]:
                k = "format" if g[3] == "1" else "format_go_quirk"
                cats[k].append((i, q, "pion=%r go=%r" % (unhex(p[2]), unhex(g[2]))))
            elif p[5] != g[4]:
                cats["pretty_go"].append((i, q, "pion=%r go=%r" % (unhex(p[5]), unhex(g[4]))))
        if p_ok:
            if p[3] != "1":
                cats["roundtrip"].append((i, q, "fmt=%r" % unhex(p[2])))
            if p[4] != "1":
                cats["pretty_rt"].append((i, q, "pretty=%r" % unhex(p[5])))
    for k in COUNTED:
        fid, sev, desc = FINDING[k]
        n = len(cats[k])
        print("CHECK %s %s %s %d %s %s" % ("PASS" if n == 0 else "FAIL", fid, sev, n, k, desc))
    print("%s format_go_quirk(info) %d" % (label, len(cats["format_go_quirk"])))
    for k, v in cats.items():
        for i, q, info in v[:5]:
            print("    [%s] %s %r -> %s" % (k, i, q, info[:160]))
        if details:
            for i, q, info in v:
                details.write("%s\t%s\t%s\t%r\t%s\n" % (label, k, i, q, info))


if __name__ == "__main__":
    main()
