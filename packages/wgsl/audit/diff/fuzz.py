#!/usr/bin/env python3
"""Deterministic mutation fuzzing of packages/wgsl (all four build modes) with naga =24.0.0 as reference.

usage: fuzz.py <out_dir> <n> <seed> <naga_oracle> <mode>=<runner...> ... -- <seed_dir>...
  <mode>=<runner> e.g. native_rel=/path/wgsl_audit  wasm_rel="node rt.mjs /path/wgsl_audit.wasm"

Gates (exit 1): any crash (non-zero exit / missing verdict line), any batch over the time budget (hang),
or any byte difference between the verdict files of the build modes.
Information only: acceptance agreement with naga (packages/wgsl does no type checking, so it accepts many
mutants naga rejects; the inverse - packages/wgsl rejecting what naga accepts - is listed)."""
import os
import random
import re
import shlex
import subprocess
import sys
import time

out, n, seed, naga = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
rest = sys.argv[5:]
sep = rest.index("--")
modes = [(a.split("=", 1)[0], shlex.split(a.split("=", 1)[1])) for a in rest[:sep]]
seed_dirs = rest[sep + 1:]
os.makedirs(out, exist_ok=True)

seeds = []
for d in seed_dirs:
    for f in sorted(os.listdir(d)):
        if f.endswith(".wgsl"):
            seeds.append(open(os.path.join(d, f), "rb").read())

DICT = [b"<", b">", b">>", b">>=", b"<<", b"(", b")", b"[", b"]", b"{", b"}", b",", b";", b":", b".", b"@",
        b"/*", b"*/", b"//", b"\n", b"-", b"--", b"- -", b"&", b"*", b"!", b"~", b"=", b"->", b"_", b"__x",
        b"0x", b"0x1p", b"1e", b"1e+999", b"0x1.fp3", b"0xffffffffffffffffffff", b"18446744073709551616",
        b"99999999999999999999999", b"0u", b"1f", b"1h", b"-2147483648i", b".5", b"0123",
        b"fn", b"var", b"let", b"const", b"struct", b"alias", b"loop", b"continuing", b"break if", b"switch",
        b"case", b"default", b"for", b"while", b"if", b"else", b"return", b"discard", b"continue", b"break",
        b"array<", b"vec4<f32>", b"mat4x4<f32>", b"ptr<function, f32>", b"atomic<u32>", b"texture_2d<f32>",
        b"@group(0)", b"@binding(9)", b"@location(", b"@builtin(position)", b"@workgroup_size(", b"@id(",
        b"@compute", b"@vertex", b"@fragment", b"\xc3\xa9", b"\xff", b"\x00", b"\t", b"\r", b"\x0b",
        b"main", b"kernel", b"device", b"in", b"out", b"uniform", b"sample", b"half", b"M_PI_F", b"gl_Position"]
TOK = re.compile(rb"[A-Za-z_][A-Za-z0-9_]*|0[xX][0-9a-fA-F.pP+-]+|[0-9][0-9.eE+-]*[uifh]?|>>=|<<=|->|&&|\|\||\+\+|--|[<>=!+\-*/%&|^]=?|\S")


def mutate(rng, src):
    k = rng.randrange(8)
    if k == 0 and src:  # byte flip
        i = rng.randrange(len(src))
        return src[:i] + bytes([rng.randrange(256)]) + src[i + 1:]
    if k == 1:  # insert dictionary token
        i = rng.randrange(len(src) + 1)
        return src[:i] + rng.choice(DICT) + src[i:]
    if k == 2 and src:  # delete a range
        i = rng.randrange(len(src))
        return src[:i] + src[i + rng.randrange(1, 32):]
    if k == 3:  # truncate
        return src[:rng.randrange(len(src) + 1)]
    toks = TOK.findall(src)
    if not toks:
        return src + rng.choice(DICT)
    if k == 4:  # drop a token
        del toks[rng.randrange(len(toks))]
    elif k == 5:  # duplicate a token run
        i = rng.randrange(len(toks))
        toks[i:i] = toks[i:i + rng.randrange(1, 8)] * rng.randrange(1, 4)
    elif k == 6:  # swap two tokens
        i, j = rng.randrange(len(toks)), rng.randrange(len(toks))
        toks[i], toks[j] = toks[j], toks[i]
    else:  # splice a token run from another seed
        other = TOK.findall(rng.choice(seeds)) or [b";"]
        a = rng.randrange(len(other))
        i = rng.randrange(len(toks) + 1)
        toks[i:i] = other[a:a + rng.randrange(1, 24)]
    return b" ".join(toks)


rng = random.Random(seed)
paths = []
for i in range(n):
    src = rng.choice(seeds)
    for _ in range(rng.randrange(1, 4)):
        src = mutate(rng, src)
    p = os.path.join(out, "m%05d.wgsl" % i)
    open(p, "wb").write(src)
    paths.append(p)
lst = os.path.join(out, "all.list")
open(lst, "w").write("\n".join(paths) + "\n")
print("  generated %d mutants from %d seeds (seed %d)" % (n, len(seeds), seed))

BATCH = 500
BUDGET = 60.0
bad = 0
digests = {}
for mode, runner in modes:
    lines, t0 = [], time.time()
    for b in range(0, len(paths), BATCH):
        chunk = paths[b:b + BATCH]
        cl, co = os.path.join(out, "chunk.list"), os.path.join(out, "chunk.%s.out" % mode)
        open(cl, "w").write("\n".join(chunk) + "\n")
        if os.path.exists(co):
            os.remove(co)
        s = time.time()
        try:
            r = subprocess.run(runner + ["digest", cl, co], capture_output=True, timeout=BUDGET)
            rc = r.returncode
        except subprocess.TimeoutExpired:
            rc = "timeout"
        got = open(co).read().splitlines() if os.path.exists(co) else []
        if rc != 0 or len(got) != len(chunk):
            # isolate the offending inputs one by one
            got = []
            for p in chunk:
                open(cl, "w").write(p + "\n")
                try:
                    r1 = subprocess.run(runner + ["digest", cl, co], capture_output=True, timeout=10)
                    ok = r1.returncode == 0 and os.path.exists(co)
                    line = open(co).read().strip() if ok else p + " CRASH rc=%d %s" % (r1.returncode, r1.stderr[-120:])
                except subprocess.TimeoutExpired:
                    line = p + " HANG"
                if "CRASH" in line or "HANG" in line:
                    bad += 1
                    print("  %s: %s" % (mode, line.replace(out + "/", "")))
                got.append(line)
        lines += got
    digests[mode] = lines
    print("  %-10s %d mutants in %.1fs" % (mode, len(lines), time.time() - t0))
ref = modes[0][0]
for mode, _ in modes[1:]:
    diff = [(a, b) for a, b in zip(digests[ref], digests[mode]) if a != b]
    if diff or len(digests[ref]) != len(digests[mode]):
        bad += 1
        print("  DETERMINISM FAIL %s vs %s: %d lines differ, e.g. %s" % (ref, mode, len(diff), diff[:1]))
    else:
        print("  %s == %s byte-identical verdicts" % (mode, ref))

subprocess.run([naga, "classify", lst, os.path.join(out, "naga.out")], capture_output=True)
nv = dict(l.rstrip("\n").split(" ", 1) for l in open(os.path.join(out, "naga.out")))
stats = {"both_accept": 0, "both_reject": 0, "pion_accepts_naga_rejects": 0, "pion_rejects_naga_accepts": 0}
false_rejects = []
for line in digests[ref]:
    p = line.split(" ", 1)[0]
    pv = " V[OK" in line
    na = nv.get(p, "REJECT").startswith("ACCEPT")
    if pv and na:
        stats["both_accept"] += 1
    elif not pv and not na:
        stats["both_reject"] += 1
    elif pv:
        stats["pion_accepts_naga_rejects"] += 1
    else:
        stats["pion_rejects_naga_accepts"] += 1
        false_rejects.append(line.replace(out + "/", "")[:140])
print("  naga agreement (info): " + ", ".join("%s=%d" % kv for kv in stats.items()))
kinds = {}
for l in false_rejects:
    k = l.split(" V[", 1)[1].split("@", 1)[0] if " V[" in l else "?"
    kinds.setdefault(k, []).append(l.split(" ", 1)[0])
for k, v in sorted(kinds.items()):
    print("    pion rejects / naga accepts by %s: %d (e.g. %s)" % (k, len(v), ", ".join(v[:3])))
print("  fuzz: %s" % ("FAIL" if bad else "0 crash / 0 hang / modes identical"))
sys.exit(1 if bad else 0)
