"""Lexer differential: Pion `tokenize` vs graphql-js Lexer (kinds + decoded values), and `tokenize_bytes` on raw bytes
vs graphql-js after strict UTF-8 decoding. apollo-parser is reported for accept/reject only.

Usage: tok_diff.py [--n N] [--seed S] [--json out.json] [--show K] [--skip-ctrl]
--skip-ctrl drops inputs containing C0 controls / DEL so the known P1-1 does not swamp other buckets.
"""
import argparse, collections, json, random, re
from common import run, is_err, short

ALPHA = list('{}()[]!$&:=@|.,"\\#- \t\n\r0123456789eE+_aZon') + ['...', '"""', '\\u', '\\u{', 'é', '﻿', '\U0001F600',
                                                              '\\"""', '\x07', '\x7f', '\x00', '\x0b']
CTRL = re.compile('[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]')


def gen(r):
    return "".join(r.choice(ALPHA) for _ in range(r.randint(1, 14)))


def bucket(msg):
    msg = re.sub(r"at \d+:\d+ \(offset \d+\)", "", msg)
    msg = re.sub(r'"[^"]*"', '"…"', msg)
    return msg[:80]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--json")
    ap.add_argument("--show", type=int, default=3)
    ap.add_argument("--skip-ctrl", action="store_true")
    a = ap.parse_args()
    r = random.Random(a.seed)
    srcs = []
    while len(srcs) < a.n:
        s = gen(r)
        if a.skip_ctrl and CTRL.search(s):
            continue
        srcs.append(s)
    raw = [bytes(r.randrange(256) for _ in range(r.randint(1, 12))) for _ in range(a.n // 4)]
    raw += [s.encode()[:max(1, len(s.encode()) - 1)] for s in srcs[: a.n // 4]]  # truncated multibyte tails
    res = {}
    for mode, recs in (("tok", srcs), ("tokb", raw)):
        p = run("pion", mode, recs)
        n = run("node", mode, recs)
        ru = run("rust", "tok", recs)
        buckets = collections.OrderedDict()
        agree = 0
        for src, x, y, z in zip(recs, p, n, ru):
            if is_err(x) != is_err(y):
                st = "pion-accepts-node-rejects" if not is_err(x) else "pion-rejects-node-accepts"
            elif not is_err(x) and x != y:
                st = "TOKEN-DIFF"
            else:
                agree += 1
                continue
            key = (st, bucket(x if is_err(x) else "OK"), bucket(y if is_err(y) else "OK"))
            buckets.setdefault(key, []).append(dict(src=src if isinstance(src, str) else src.hex(), pion=x, node=y, rust=z))
        print(f"tok_diff[{mode}]: {len(recs)} inputs, agree with graphql-js on {agree} ({100.0 * agree / len(recs):.2f}%)")
        for (st, bp, bn), xs in sorted(buckets.items(), key=lambda kv: -len(kv[1])):
            print(f"  {len(xs):5d} x [{st}] pion={bp!r} node={bn!r}")
            for x in sorted(xs, key=lambda e: len(e["src"]))[:a.show]:
                print(f"        src : {short(x['src'])}   pion: {short(x['pion'], 60)}   node: {short(x['node'], 60)}   rust: {short(x['rust'], 50)}")
        res[mode] = dict(total=len(recs), agree=agree,
                         buckets=[dict(status=k[0], pion=k[1], node=k[2], count=len(v), examples=v[:5]) for k, v in buckets.items()])
    if a.json:
        json.dump(res, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
