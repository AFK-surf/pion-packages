#!/usr/bin/env python3
"""Build the parse differential corpus for the packages/promql red-team audit.

usage: gen_corpus.py <parse_corpus.txt> <out_dir> [n_mutants]

Writes <out_dir>/hand.tsv (hand-written cases) and <out_dir>/mut.tsv (deterministic mutants,
fixed seed) as "<id>\t<hex query>" lines. Deterministic: same inputs -> same bytes.
"""
import random
import sys

SEED = 20261123
TOKENS = [
    "(", ")", "{", "}", "[", "]", ",", ":", "@", "+", "-", "*", "/", "%", "^", "==", "!=",
    "<", ">", "<=", ">=", "=", "=~", "!~", " and ", " or ", " unless ", " bool ", " on(a) ",
    " ignoring(a) ", " group_left ", " group_right(b) ", " offset 5m ", " offset -1m ",
    " @ 100 ", " @ start() ", " by (a) ", " without (a) ", "[5m]", "[1h:5m]", "[0s]", "5m",
    "1e3", "0x1f", "1_0", "Inf", "NaN", "-Inf", '"x"', "'y'", "`z`", "foo", "bar", "sum",
    "rate", "topk", "atan2", "le", "__name__", '{"a.b"}', '"\\x41"', "\\", "#", "\n", "\t",
    "é", "99999999999y", "1e300", "1ms", "start()", "end()",
]


def load(path):
    out = []
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        if not line or line.startswith("##"):
            continue
        if line.startswith("ESC:"):
            line = line[4:].replace("\\n", "\n").replace("\\t", "\t")
        out.append(line)
    return out


def mutate(rng, q):
    b = q
    for _ in range(rng.randint(1, 3)):
        op = rng.randrange(7)
        pos = rng.randint(0, len(b))
        if op == 0 and b:  # delete a char
            p = rng.randrange(len(b))
            b = b[:p] + b[p + 1:]
        elif op == 1:  # insert a token
            b = b[:pos] + rng.choice(TOKENS) + b[pos:]
        elif op == 2 and len(b) > 1:  # swap adjacent chars
            p = rng.randrange(len(b) - 1)
            b = b[:p] + b[p + 1] + b[p] + b[p + 2:]
        elif op == 3 and b:  # duplicate a slice
            p = rng.randrange(len(b))
            e = min(len(b), p + rng.randint(1, 8))
            b = b[:e] + b[p:e] + b[e:]
        elif op == 4:  # toggle case of a char
            if b:
                p = rng.randrange(len(b))
                b = b[:p] + b[p].swapcase() + b[p + 1:]
        elif op == 5:  # splice with another corpus entry is done by caller
            pass
        else:  # replace a digit run
            digits = [i for i, c in enumerate(b) if c.isdigit()]
            if digits:
                p = rng.choice(digits)
                b = b[:p] + rng.choice(["0", "9", "00", "1e9", "_", "x"]) + b[p + 1:]
    return b


def main():
    src, out_dir = sys.argv[1], sys.argv[2]
    n_mut = int(sys.argv[3]) if len(sys.argv) > 3 else 2000
    hand = load(src)
    rng = random.Random(SEED)
    with open(out_dir + "/hand.tsv", "w", encoding="utf-8") as f:
        for i, q in enumerate(hand):
            f.write("H%04d\t%s\n" % (i, q.encode("utf-8").hex()))
    seen = set(hand)
    muts = []
    while len(muts) < n_mut:
        q = rng.choice(hand)
        if rng.random() < 0.15:
            o = rng.choice(hand)
            q = q[: rng.randint(0, len(q))] + o[rng.randint(0, len(o)):]
        m = mutate(rng, q)
        if m and m not in seen:
            seen.add(m)
            muts.append(m)
    with open(out_dir + "/mut.tsv", "w", encoding="utf-8") as f:
        for i, q in enumerate(muts):
            f.write("M%04d\t%s\n" % (i, q.encode("utf-8").hex()))
    print("corpus: %d hand-written + %d mutants" % (len(hand), len(muts)))


if __name__ == "__main__":
    main()
