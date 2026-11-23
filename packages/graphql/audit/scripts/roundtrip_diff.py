"""Printer + minifier semantic-preservation audit.

For every document Pion accepts (hand corpus + grammar fuzz):
  P1  parse(print(parse(x)))   == parse(x)          (Pion AST dump, Pion re-parse)
  P2  gjs.parse(pion_print(x)) == gjs.parse(x)      (graphql-js AST dump: the printed text means the same thing)
  P3  print(parse(print(parse(x)))) == print(parse(x))   (idempotency)
  M1  gjs.parse(pion_minify(x)) == gjs.parse(x)     (minify keeps meaning, judged by graphql-js)
  M2  pion_minify(x) == gjs.stripIgnoredCharacters(x)  (byte equality; informational)
  M3  len(pion_minify(x)) vs len(stripIgnoredCharacters(x))
Usage: roundtrip_diff.py [--n N] [--seed S] [--json out.json] [--show K]
"""
import argparse, collections, json, random, re
from common import run, is_err, short
import gen, spec_diff

HAND = [c[2] for c in spec_diff.CASES] + [
    '"""  leading spaces"""\ntype T { a: Int }',
    'type T { f("""  indented single line""" a: Int): Int }',
    'type T { f(\n  "arg description"\n  a: Int\n): Int }',
    'directive @d(\n  "described arg"\n  a: Int\n) on FIELD',
    '{ f(x: """\tleading tab""") }',
    '{ f(x: """  two\n  lines""") }',
    '{ f(x: """a"""") }',
    '{ f(x: "\\u0007 bell") }',
    '{ f(x: "\\u007F del") }',
    '{ f(x: "\\u{1F600} \\uD83D\\uDE00") }',
    '"""\n  multi\n    line\n  description\n"""\ntype T { a: Int }',
    'type T {\n  """\n  field doc\n  """\n  a: Int\n}',
    '{ a(x: 1.5e10, y: -0, z: [1 2 3], w: {a: {b: [true null ENUM]}}) }',
    'query Q($a: [Int!]! = [1, 2], $b: In = {x: "y"}) @dir(a: 1) { ...F ... on T @skip(if: true) { b } }',
    'fragment F on T @d { a }',
]


def cause(before, after):
    """Attribute an AST change to a root cause (first differing byte of the canonical dumps)."""
    j = next((i for i in range(min(len(before), len(after))) if before[i] != after[i]), min(len(before), len(after)))
    if before[max(0, j - 4):j] == "(iv " and after[j] == "-":
        return "argument/input-value description dropped by print_document (P0-2)"
    if re.search(r"B\d*$", before[:j]):
        return "block string leading whitespace lost by print_document (P0-1)"
    return "other"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=4000)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--json")
    ap.add_argument("--show", type=int, default=4)
    a = ap.parse_args()
    r = random.Random(a.seed)
    docs = HAND + [gen.gdoc(r) for _ in range(a.n)]
    pp = run("pion", "parse", docs)
    docs = [d for d, x in zip(docs, pp) if not is_err(x)]
    p_ast = run("pion", "parse", docs)
    n_ast = run("node", "parse", docs)
    printed = run("pion", "print", docs)
    p_ast2 = run("pion", "parse", printed)
    n_ast2 = run("node", "parse", printed)
    printed2 = run("pion", "print", printed)
    mins = run("pion", "min", docs)
    n_min_ast = run("node", "parse", mins)
    strip = run("node", "min", docs)
    fails = collections.OrderedDict((k, []) for k in ["P1", "P2", "P3", "M1"])
    m2_equal = 0
    pion_bytes = node_bytes = 0
    for i, d in enumerate(docs):
        if p_ast2[i] != p_ast[i]:
            fails["P1"].append(dict(src=d, printed=printed[i], before=p_ast[i], after=p_ast2[i]))
        if not is_err(n_ast[i]) and n_ast2[i] != n_ast[i]:
            fails["P2"].append(dict(src=d, printed=printed[i], before=n_ast[i], after=n_ast2[i]))
        if printed2[i] != printed[i]:
            fails["P3"].append(dict(src=d, printed=printed[i], printed2=printed2[i]))
        if not is_err(n_ast[i]) and n_min_ast[i] != n_ast[i]:
            fails["M1"].append(dict(src=d, minified=mins[i], before=n_ast[i], after=n_min_ast[i]))
        if not is_err(strip[i]):
            m2_equal += mins[i] == strip[i]
            pion_bytes += len(mins[i].encode())
            node_bytes += len(strip[i].encode())
    n = len(docs)
    print(f"roundtrip_diff: {n} documents accepted by Pion")
    names = dict(P1="parse(print(x)) == parse(x) [Pion]", P2="graphql-js meaning of Pion print kept",
                 P3="print idempotent", M1="graphql-js meaning of Pion minify kept")
    for k, xs in fails.items():
        print(f"  {k} {names[k]:45s}: {n - len(xs)}/{n} ok, {len(xs)} FAIL")
        for x in sorted(xs, key=lambda e: len(e["src"]))[:a.show]:
            print(f"      src    : {short(x['src'], 140)}")
            if "printed" in x:
                print(f"      printed: {short(x['printed'], 140)}")
            if "minified" in x:
                print(f"      minified: {short(x['minified'], 140)}")
            if "before" in x:
                b, c = x["before"], x["after"]
                j = next((i for i in range(min(len(b), len(c))) if b[i] != c[i]), min(len(b), len(c)))
                print(f"      before : …{short(b[max(0, j - 30):j + 50])}")
                print(f"      after  : …{short(c[max(0, j - 30):j + 50])}")
    for k in ("P1", "P2"):
        c = collections.Counter(cause(x["before"], x["after"]) for x in fails[k])
        for why, cnt in c.most_common():
            print(f"  {k} root cause: {cnt:4d} x {why}")
    print(f"  M2 byte-identical to stripIgnoredCharacters: {m2_equal}/{n}; total bytes pion={pion_bytes} graphql-js={node_bytes} "
          f"({100.0 * (pion_bytes - node_bytes) / max(1, node_bytes):+.2f}%)")
    if a.json:
        json.dump(dict(n=n, fails={k: dict(count=len(v), examples=v[:8]) for k, v in fails.items()},
                       m2_equal=m2_equal, pion_bytes=pion_bytes, node_bytes=node_bytes), open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
