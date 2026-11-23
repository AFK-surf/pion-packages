#!/usr/bin/env python3
"""Structure-aware fuzzing of packages/glsl: Pion native --release vs Pion wasm32 --release (node).

Seeds: every shader of corpus.py plus the packaged bench corpora.  Mutators: byte flip / random bytes, GLSL token
insertion (keywords, builtins, directives, brackets, line continuations, NUL/CR/UTF-8), line delete / duplicate /
swap, cross-seed splice, truncation.  Each case runs parse_and_reflect + translate_to_glsl410 for BOTH stages.

Checks: 0 crash / trap / hang, native == wasm32 verdict line (error kind + message hash, output hash, reflection
hash), and parse_and_reflect(src) == translate(src).reflection.
Usage: python3 -I fuzz.py [N] [seed]
"""
import os
import random
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import corpus as C  # noqa: E402

OUT = os.environ.get("AUDIT_OUT", "/private/tmp/pion-glsl-audit")
BIN = os.path.join(OUT, "bin")
RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
FZ = os.path.join(OUT, "fuzz")
CHUNK = 500
TOKS = [b"texture2D(", b"gl_FragColor", b"gl_FragData[", b"]", b"[", b"(", b")", b"{", b"}", b";", b",", b".",
        b"#define X ", b"#define gl_FragColor c\n", b"#ifdef A\n", b"#if 1\n", b"#else\n", b"#endif\n", b"#undef X\n",
        b"#version 300 es\n", b"#version 100\n", b"#extension GL_EXT_draw_buffers : enable\n", b"#extension all:warn\n",
        b"#line 4294967296\n", b"#pragma x\n", b"\\\n", b"\\\r\n", b"\r", b"\n", b"\0", b"\xff", b"\xc3\xa9", b"/*",
        b"*/", b"//", b"attribute ", b"varying ", b"uniform ", b"in ", b"out ", b"layout(location=", b"precision ",
        b"highp ", b"struct S{float x;}", b"vec4 ", b"=", b"0x", b"1e", b"99999999999999", b"2147483648", b"1.0",
        b"gl_Position", b"discard", b"void main(){", b"textureCube(", b"invariant ", b"flat ", b"centroid ",
        b"_fv_gl_FragColor", b"#", b"##", b"sample", b"texture", b"\t", b" "]


def seeds():
    out = []
    for _, vs, fs, _ in C.CASES:
        for s in (vs, fs):
            if s:
                out.append(s.encode())
    out += [C.VS100.encode(), C.FS100.encode(), C.VS300.encode(), C.FS300.encode()]
    bench = os.path.join(OUT, "bench_corpus")
    if os.path.isdir(bench):
        for f in sorted(os.listdir(bench)):
            if f.endswith((".vert", ".frag")):
                out.append(open(os.path.join(bench, f), "rb").read())
    return out


def mutate(rng, src, pool):
    b = bytearray(src)
    for _ in range(rng.choice([1, 1, 2, 3, 5, 8])):
        op = rng.randrange(9)
        p = rng.randrange(len(b) + 1) if b else 0
        if op == 0 and b:
            b[min(p, len(b) - 1)] = rng.randrange(256)
        elif op in (1, 2, 3):
            b[p:p] = rng.choice(TOKS)
        elif op == 4 and b:
            del b[p:p + rng.randrange(1, 40)]
        elif op == 5:
            lines = bytes(b).split(b"\n")
            i, j = rng.randrange(len(lines)), rng.randrange(len(lines))
            r = rng.randrange(3)
            if r == 0:
                lines.insert(j, lines[i])
            elif r == 1:
                lines[i], lines[j] = lines[j], lines[i]
            else:
                del lines[i]
            b = bytearray(b"\n".join(lines))
        elif op == 6:
            o = rng.choice(pool)
            q = rng.randrange(len(o) + 1)
            b = b[:p] + bytearray(o[q:q + rng.randrange(1, 400)]) + b[p:]
        elif op == 7:
            b = b[:p]
        else:
            b[p:p] = bytes(rng.randrange(256) for _ in range(rng.randrange(1, 16)))
    return bytes(b)


def run(cmd, timeout):
    t0 = time.time()
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=timeout)
        return r.returncode, r.stderr.decode("utf-8", "replace"), time.time() - t0
    except subprocess.TimeoutExpired:
        return "TIMEOUT", "", time.time() - t0


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 12000
    rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 20261123)
    os.makedirs(FZ, exist_ok=True)
    pool = seeds()
    paths = []
    for i in range(n):
        p = os.path.join(FZ, f"c{i:06d}.glsl")
        r = rng.random()
        if r < 0.05:
            data = bytes(rng.randrange(256) for _ in range(rng.randrange(1, 300)))
        elif r < 0.10:
            data = b"".join(rng.choice(TOKS) for _ in range(rng.randrange(1, 200)))
        else:
            data = mutate(rng, rng.choice(pool), pool)
        with open(p, "wb") as f:
            f.write(data)
        paths.append(p)
    bad, crashes, hangs, mism, refl_mism, ok_tr = 0, 0, 0, 0, 0, 0
    tn = tw = 0.0
    for c in range(0, n, CHUNK):
        part = paths[c:c + CHUNK]
        lst = os.path.join(FZ, f"list{c}.txt")
        with open(lst, "w") as f:
            f.write("\n".join(part) + "\n")
        res = {}
        for impl, cmd in (("native", [os.path.join(BIN, "drv")]), ("wasm", ["node", RT, os.path.join(BIN, "drv.wasm")])):
            o = os.path.join(FZ, f"{impl}{c}.txt")
            if os.path.exists(o):
                os.remove(o)
            rc, err, dt = run(cmd + ["batch", lst, o], 300)
            if impl == "native":
                tn += dt
            else:
                tw += dt
            if rc != 0 or not os.path.exists(o):
                kind = "HANG" if rc == "TIMEOUT" else "CRASH"
                print(f"  {kind} {impl} chunk {c}: rc={rc} {err.strip()[:300]}")
                crashes += kind == "CRASH"
                hangs += kind == "HANG"
                res[impl] = None
                continue
            res[impl] = open(o, encoding="latin-1").read().splitlines()
        if res.get("native") is None or res.get("wasm") is None:
            bad += 1
            continue
        for a, w in zip(res["native"], res["wasm"]):
            if a != w:
                mism += 1
                if mism <= 5:
                    print(f"  NATIVE!=WASM {a}\n               {w}")
            f = a.split(" ")
            # <path> V <reflect> <translate> F <reflect> <translate>
            for r_, t_ in ((f[2], f[3]), (f[5], f[6])):
                if r_.startswith("OK") != t_.startswith("OK") or (r_.startswith("OK") and r_.split(":")[1] != t_.split(":")[2]):
                    refl_mism += 1
                    if refl_mism <= 5:
                        print(f"  REFLECT!=TRANSLATE {a}")
                ok_tr += t_.startswith("OK")
        if len(res["native"]) != len(part) or len(res["wasm"]) != len(part):
            print(f"  SHORT OUTPUT chunk {c}")
            bad += 1
    print(f"== fuzz: {n} cases x 2 stages x 2 APIs: native {tn:.1f}s, wasm32 {tw:.1f}s; translate OK {ok_tr}/{2 * n}; "
          f"crash {crashes}, hang {hangs}, native!=wasm {mism}, reflect!=translate {refl_mism}")
    return 1 if (bad or mism or refl_mism or crashes or hangs) else 0


if __name__ == "__main__":
    sys.exit(main())
