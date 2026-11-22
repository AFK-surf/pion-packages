#!/usr/bin/env python3
"""Mutation-fuzz differential: Pion packages/cbor vs Go fxamacker/cbor/v2 (vs Rust ciborium).

usage: fuzz_diff.py <pion_probe> <go_probe> <rust_probe> <workdir> [count] [seed]

* Seeds = gen_vectors.py vectors + 200 WebAuthn/Telemetry records from bench/gen_corpus.py.
* Mutations: bit flips, byte replace with CBOR-significant values, insert/delete, truncation,
  splice of two seeds. Deterministic (seeded).
* Reports: crashes (non-zero exit / missing output lines), accept/reject disagreements
  (Pion vs Go, default + dup-rejection modes), and value disagreements on inputs both accept
  (Core Deterministic re-encoding compared byte for byte).
"""
import collections
import importlib.util
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


INTERESTING = [0x00, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1f, 0x20, 0x3b, 0x40, 0x58, 0x5b, 0x5f,
               0x60, 0x7b, 0x7f, 0x80, 0x9b, 0x9f, 0xa0, 0xbb, 0xbf, 0xc0, 0xc2, 0xd8, 0xdb, 0xf4,
               0xf7, 0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xff, 0xc3, 0xed, 0xf4, 0x7e]


def mutate(rnd, seeds):
    b = bytearray(rnd.choice(seeds))
    for _ in range(rnd.randint(1, 4)):
        op = rnd.randrange(6)
        if not b:
            b.append(rnd.choice(INTERESTING))
            continue
        i = rnd.randrange(len(b))
        if op == 0:
            b[i] ^= 1 << rnd.randrange(8)
        elif op == 1:
            b[i] = rnd.choice(INTERESTING)
        elif op == 2:
            b.insert(i, rnd.choice(INTERESTING))
        elif op == 3:
            del b[i]
        elif op == 4:
            del b[i:]
        else:
            o = rnd.choice(seeds)
            if o:
                j = rnd.randrange(len(o))
                b[i:] = o[j:]
    return bytes(b)


def run(probe, mode, path, n):
    # bytes mode: Go error messages may quote raw key bytes (\r), which text mode would split.
    p = subprocess.run([probe, mode, path], capture_output=True)
    lines = [l.decode("utf-8", "replace") for l in p.stdout.split(b"\n") if l]
    return p.returncode, lines[:n] if len(lines) >= n else lines


def find_crash(probe, mode, cases, work):
    """Bisect to the first input that crashes the probe."""
    lo, hi = 0, len(cases)
    while hi - lo > 1:
        mid = (lo + hi) // 2
        path = os.path.join(work, "bisect.hex")
        open(path, "w").write("\n".join(c.hex() for c in cases[lo:mid]) + "\n")
        rc, _ = run(probe, mode, path, mid - lo)
        if rc != 0:
            hi = mid
        else:
            lo = mid
    return cases[lo]


def main():
    pion, go, rust, work = sys.argv[1:5]
    count = int(sys.argv[5]) if len(sys.argv) > 5 else 10000
    seed = int(sys.argv[6]) if len(sys.argv) > 6 else 8949
    os.makedirs(work, exist_ok=True)
    gv = load(os.path.join(HERE, "gen_vectors.py"), "gen_vectors")
    gc = load(os.path.join(HERE, "..", "bench", "gen_corpus.py"), "gen_corpus")
    seeds = [bytes.fromhex(h) for _, h in gv.V if h] + [gc.make_record(i) for i in range(200)]
    rnd = random.Random(seed)
    cases = [mutate(rnd, seeds) for _ in range(count)]
    cases = [c for c in cases if c]
    path = os.path.join(work, "fuzz.hex")
    open(path, "w").write("\n".join(c.hex() for c in cases) + "\n")
    print("fuzz: %d mutated inputs (seed %d, %d seeds)" % (len(cases), seed, len(seeds)))
    problems = 0
    for mode in ("dec", "dup", "enc_det"):
        res = {}
        for name, probe in (("pion", pion), ("go", go), ("rust", rust)):
            if name == "rust" and mode == "dup":
                continue
            rc, lines = run(probe, mode, path, len(cases))
            if rc != 0 or len(lines) != len(cases):
                bad = find_crash(probe, mode, cases, work)
                print("  CRASH %s mode=%s rc=%d first crashing input: %s" % (name, mode, rc, bad.hex()))
                problems += 1
                continue
            res[name] = lines
        if "pion" not in res or "go" not in res:
            continue
        verdict = collections.Counter()
        examples = collections.defaultdict(list)
        for i, c in enumerate(cases):
            p, g = res["pion"][i], res["go"][i]
            pv, gv_ = p.split(" ")[0], g.split(" ")[0]
            if mode == "enc_det":
                if pv == "OK" and gv_ == "OK" and p != g:
                    key = "value: both accept, Core Deterministic re-encoding differs"
                else:
                    continue
            elif pv == gv_ or (pv.startswith("OK") and gv_.startswith("OK")):
                continue
            else:
                gmsg = g.split(":", 1)[-1].strip()[:60] if gv_ == "ERR" else ""
                key = "pion %s / go %s  [%s]" % (pv, gv_, gmsg)
            verdict[key] += 1
            if len(examples[key]) < 3:
                examples[key].append((c.hex()[:80], p[:70], g[:90]))
        print("== mode %s: %d disagreements" % (mode, sum(verdict.values())))
        for k, n in verdict.most_common():
            print("  %5d  %s" % (n, k))
            for ex in examples[k]:
                print("         in=%s\n           pion=%s\n           go  =%s" % ex)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
