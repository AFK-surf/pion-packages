"""Static validation differential: Pion `validate_executable` vs graphql-js@16.10.0 schema-free executable rules.

graphql-js rules used (the ones that need no schema): ExecutableDefinitions, UniqueOperationNames,
LoneAnonymousOperation, UniqueFragmentNames, KnownFragmentNames, NoUnusedFragments, NoFragmentCycles,
UniqueVariableNames, NoUndefinedVariables, NoUnusedVariables, UniqueArgumentNames, UniqueInputFieldNames,
UniqueDirectivesPerLocation. Both sides print the sorted set of error kinds (rule names mapped to Pion's).
A Pion-only kind (MaxDepth/MaxAliases/MaxFields) is a Pion extension, not a diff.
Usage: valid_diff.py [--n N] [--seed S] [--json out.json] [--show K]
"""
import argparse, collections, json, random
from common import run, is_err, short
import gen

PION_ONLY = {"MaxDepthExceeded", "MaxAliasesExceeded", "MaxFieldsExceeded"}

HAND = [
    ("unused fragment", "{ a } fragment F on T { a }"),
    ("unused fragment in cycle", "{ a } fragment A on T { ...B } fragment B on T { ...A }"),
    ("self cycle", "{ ...A } fragment A on T { ...A }"),
    ("cycle via inline fragment", "{ ...A } fragment A on T { ... on T { ...B } } fragment B on T { ...A }"),
    ("3-cycle", "{ ...A } fragment A on T { ...B } fragment B on T { ...C } fragment C on T { ...A }"),
    ("undefined variable", "query Q { a(x: $v) }"),
    ("undefined variable via fragment", "query Q { ...F } fragment F on T { a(x: $v) }"),
    ("undefined variable in directive", "query Q { a @skip(if: $v) }"),
    ("unused variable", "query Q($v: Int) { a }"),
    ("variable used only in fragment", "query Q($v: Int) { ...F } fragment F on T { a(x: $v) }"),
    ("duplicate variable", "query Q($v: Int, $v: Int) { a(x: $v) }"),
    ("SDL in executable document", "type T { a: Int } { a }"),
    ("schema def in executable document", "schema { query: Q } { a }"),
    ("directive def in executable document", "directive @d on FIELD { a }"),
    ("extension in executable document", "extend scalar S @d { a }"),
    ("duplicate @skip", "{ a @skip(if: true) @skip(if: false) }"),
    ("duplicate @include on spread", "{ ...F @include(if: true) @include(if: true) } fragment F on T { a }"),
    ("duplicate argument", "{ a(x: 1, x: 2) }"),
    ("duplicate argument in directive", "{ a @d(x: 1, x: 2) }"),
    ("duplicate input field nested list", "{ a(x: [{y: 1, y: 2}]) }"),
    ("duplicate input field deep", "{ a(x: {b: {c: [[{d: 1, d: 2}]]}}) }"),
    ("duplicate input field in var default", "query Q($v: I = {a: 1, a: 2}) { b(x: $v) }"),
    ("duplicate input field in directive arg", "{ a @d(x: {y: 1, y: 2}) }"),
    ("duplicate operation name", "query Q { a } query Q { b }"),
    ("duplicate op name across kinds", "query Q { a } mutation Q { b }"),
    ("lone anonymous + named", "{ a } query Q { b }"),
    ("two anonymous", "{ a } { b }"),
    ("duplicate fragment", "{ ...F } fragment F on T { a } fragment F on T { b }"),
    ("unknown fragment", "{ ...Nope }"),
    ("valid control", "query Q($v: Int) { a(x: $v) ...F } fragment F on T { b }"),
    ("valid: variable in nested fragment", "query Q($v: Int) { ...F } fragment F on T { ...G } fragment G on T { a(x: $v) }"),
    ("valid: two ops share fragment", "query A { ...F } query B { ...F } fragment F on T { a }"),
    ("undefined var in one op of two", "query A($v: Int) { ...F } query B { ...F } fragment F on T { a(x: $v) }"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=4000)
    ap.add_argument("--seed", type=int, default=5)
    ap.add_argument("--json")
    ap.add_argument("--show", type=int, default=3)
    a = ap.parse_args()
    r = random.Random(a.seed)
    docs = [h[1] for h in HAND] + [gen.gexec(r) for _ in range(a.n)]
    p = run("pion", "valid", docs)
    n = run("node", "valid", docs)
    hand_rows = []
    print("valid_diff: hand cases (pion vs graphql-js)")
    for (name, src), x, y in zip(HAND, p, n):
        xs = set() if x == "OK" else set(x.split(","))
        ys = set() if y == "OK" else set(y.split(","))
        xs -= PION_ONLY
        st = "same" if xs == ys else "DIFF"
        hand_rows.append(dict(name=name, src=src, pion=x, node=y, status=st))
        print(f"  [{st:4s}] {name:40s} pion={x:40s} node={y}")
    missing = collections.Counter()
    extra = collections.Counter()
    ex = collections.defaultdict(list)
    agree = parsed = 0
    for src, x, y in zip(docs[len(HAND):], p[len(HAND):], n[len(HAND):]):
        if is_err(x) or is_err(y):
            continue
        parsed += 1
        xs = (set() if x == "OK" else set(x.split(","))) - PION_ONLY
        ys = set() if y == "OK" else set(y.split(","))
        if xs == ys:
            agree += 1
        for k in ys - xs:
            missing[k] += 1
            ex[k].append(src)
        for k in xs - ys:
            extra["pion-only " + k] += 1
            ex["pion-only " + k].append(src)
    print(f"valid_diff: fuzz {parsed} parsed executable docs, identical error-kind sets on {agree} ({100.0 * agree / max(1, parsed):.1f}%)")
    for k, c in missing.most_common():
        print(f"  {c:5d} x graphql-js reports {k}, Pion does not   e.g. {short(min(ex[k], key=len), 120)}")
    for k, c in extra.most_common():
        print(f"  {c:5d} x {k}   e.g. {short(min(ex[k], key=len), 120)}")
    if a.json:
        json.dump(dict(hand=hand_rows, parsed=parsed, agree=agree, missing=missing, extra=extra), open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
