#!/usr/bin/env python3
"""Mutational differential fuzzer: Pion vs Rust toml 0.8 (TOML 1.0) vs Go BurntSushi.

Seeds = official toml-test files (TOML 1.0.0 list). Each case = seed + k random edits drawn from
TOML-significant tokens. A case is reported only when Pion disagrees with BOTH references while the
two references agree with each other (accept/reject + decoded data) -- i.e. no 1.0-vs-1.1 noise.
usage: fuzz_diff.py <toml-test checkout> <n_cases> <seed> <out_dir>
"""
import os, random, sys, json
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(__file__))
from difflib_toml import run, compare

TOKENS = [b"[", b"]", b"[[", b"]]", b"{", b"}", b"=", b",", b".", b"\n", b"\r\n", b" ", b"\t", b"#", b'"', b"'", b'"""', b"'''",
          b"\\", b"\\u", b"\\U", b"0", b"1", b"9", b"_", b"e", b"E", b"+", b"-", b"x", b"o", b"b", b"inf", b"nan", b"true",
          b"T", b"Z", b":", b"1979-05-27", b"07:32:00", b".5", b"a", b"a.b", b"\xc3\xa9", b"\x7f", b"\x00", b"\xef\xbb\xbf"]


def mutate(r, data):
    data = bytearray(data)
    for _ in range(r.randint(1, 4)):
        op = r.random()
        pos = r.randint(0, len(data)) if data else 0
        if op < 0.4:
            data[pos:pos] = r.choice(TOKENS)
        elif op < 0.7 and data:
            del data[pos:pos + r.randint(1, 3)]
        elif data:
            data[pos:pos + 1] = r.choice(TOKENS)
    return bytes(data)


def one(args):
    case_id, data = args
    pi, r8, go = run("pion", data), run("rust_toml_0.8", data), run("go_burntsushi", data)
    if compare(r8, go) != "agree":
        return None
    c = compare(pi, r8)
    if c == "agree" and pi[0] not in ("crash", "timeout"):
        return None
    return {"id": case_id, "why": c, "pion": pi[0], "ref": r8[0], "input": data.decode("latin-1")}


def main():
    root, n, seed, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    os.makedirs(out, exist_ok=True)
    files = [l.strip() for l in open(os.path.join(root, "tests/files-toml-1.0.0")) if l.strip().endswith(".toml")]
    seeds = [open(os.path.join(root, "tests", f), "rb").read() for f in files]
    r = random.Random(seed)
    cases = [(i, mutate(r, r.choice(seeds))) for i in range(n)]
    found = []
    with ThreadPoolExecutor(max_workers=8) as ex:
        for res in ex.map(one, cases, chunksize=16):
            if res:
                found.append(res)
    buckets = {}
    for f in found:
        buckets.setdefault(f["why"].split(":")[0] if f["why"] != "agree" else f["pion"], []).append(f)
    print(f"{n} mutated cases, {len(found)} where Pion disagrees with BOTH agreeing references")
    for k, v in sorted(buckets.items(), key=lambda kv: -len(kv[1])):
        print(f"  [{len(v):4d}] {k}   e.g. {v[0]['input'][:90]!r}")
    json.dump(found, open(os.path.join(out, f"fuzz_{seed}.json"), "w"), indent=1)


main()
