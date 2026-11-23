"""Grammar + mutation fuzz differential: Pion `parse` vs graphql-js `parse` (AST) vs apollo-parser (accept/reject).

Usage: fuzz_diff.py [--n N] [--seed S] [--json out.json] [--show K]
Diffs are bucketed by (status, Pion error message, graphql-js error message) so one root cause shows once.
"""
import argparse, collections, json, random, re
from common import run, is_err, short
import gen


def bucket(msg):
    msg = re.sub(r"at \d+:\d+ \(offset \d+\)", "", msg)
    msg = re.sub(r'"[^"]*"', '"…"', msg)
    return msg[:90]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=5000)
    ap.add_argument("--seed", type=int, default=2021)
    ap.add_argument("--json")
    ap.add_argument("--show", type=int, default=3)
    a = ap.parse_args()
    r = random.Random(a.seed)
    docs = []
    for i in range(a.n):
        d = gen.gdoc(r)
        docs.append(gen.mutate(r, d) if i % 3 == 2 else d)
    p = run("pion", "parse", docs)
    n = run("node", "parse", docs)
    ru = run("rust", "parse", docs)
    buckets = collections.OrderedDict()
    stats = collections.Counter()
    for src, x, y, z in zip(docs, p, n, ru):
        ap_, an, ar = not is_err(x), not is_err(y), not is_err(z)
        stats["pion_accept"] += ap_
        stats["node_accept"] += an
        stats["rust_accept"] += ar
        if ap_ != an:
            st = "pion-accepts-node-rejects" if ap_ else "pion-rejects-node-accepts"
        elif ap_ and x != y:
            st = "AST-DIFF"
        else:
            stats["agree"] += 1
            continue
        key = (st, bucket(x if is_err(x) else "OK"), bucket(y if is_err(y) else "OK"))
        buckets.setdefault(key, []).append(dict(src=src, pion=x, node=y, rust=z))
    total = len(docs)
    print(f"fuzz_diff: {total} docs (seed {a.seed}); agree with graphql-js on {stats['agree']} "
          f"({100.0 * stats['agree'] / total:.2f}%); accept rates pion={stats['pion_accept']} node={stats['node_accept']} rust={stats['rust_accept']}")
    for (st, bp, bn), xs in sorted(buckets.items(), key=lambda kv: -len(kv[1])):
        print(f"  {len(xs):5d} x [{st}] pion={bp!r} node={bn!r}")
        for x in sorted(xs, key=lambda e: len(e["src"]))[:a.show]:
            print(f"        src : {short(x['src'], 160)}")
            if st == "AST-DIFF":
                pa, na = x["pion"], x["node"]
                k = next((i for i in range(min(len(pa), len(na))) if pa[i] != na[i]), 0)
                print(f"        pion: …{short(pa[max(0, k - 40):k + 60])}")
                print(f"        node: …{short(na[max(0, k - 40):k + 60])}")
            print(f"        rust: {short(x['rust'])}")
    if a.json:
        json.dump(dict(stats=stats, buckets=[dict(status=k[0], pion=k[1], node=k[2], count=len(v), examples=v[:5]) for k, v in buckets.items()]),
                  open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
