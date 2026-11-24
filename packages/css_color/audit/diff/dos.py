#!/usr/bin/env python3
"""DoS / adversarial-input budgets for packages/css_color (parse + to_rgba8 per input).
  python3 -I dos.py <out dir> <audit binary> [wasm runner words...]
Builds the bombs, runs `<binary> time <file> <iters>` (one process for all inputs, timeouts per process), checks:
  P0: a crash / trap / timeout (60 s), a wrong verdict (a bomb that must be rejected is accepted or vice versa),
      or any input over 1 s;
  P1: an input <= 16 KiB that takes > 20 ms, or super-linear growth (time per byte of the largest member of a family
      > 8x the smallest member's).
Exit 0 = within budget, 1 = P0, 3 = P1. Prints one line per bomb."""
import os
import subprocess
import sys


def bombs():
    out = []  # (name, input, expectation: "OK" | "ERR" | "ERR <Variant>" | "*")

    def nest_mix(d):
        return "color-mix(in srgb, " * d + "red" + ", blue)" * d

    for d in (1, 16, 31, 32, 33, 64, 600, 1000):
        s = nest_mix(d)
        out.append(("color-mix nested depth %d" % d, s,
                    "ERR InputTooLong" if len(s) > 16384 else ("OK" if d <= 32 else "ERR MaxDepthExceeded")))

    def tree(k):
        return "red" if k == 0 else "color-mix(in oklch, %s, %s)" % (tree(k - 1), tree(k - 1))
    for k in range(1, 15):
        s = tree(k)
        if len(s) > 16384:
            out.append(("color-mix full binary tree depth %d (%d B > limit)" % (k, len(s)), s, "ERR InputTooLong"))
            break
        out.append(("color-mix full binary tree depth %d (%d leaves, %d B)" % (k, 2 ** k, len(s)), s, "OK"))
    # widest tree that fits: depth-14 tree pruned to <= 16384 bytes via short leaves
    def tree2(k):
        return "red" if k == 0 else "color-mix(in lab,%s,%s)" % (tree2(k - 1), tree2(k - 1))
    for k in (8, 9):
        out.append(("color-mix compact tree depth %d (%d B)" % (k, len(tree2(k))), tree2(k), "OK" if len(tree2(k)) <= 16384 else "ERR InputTooLong"))
    for d in (8, 31, 32, 33, 1000, 2700, 5000):
        out.append(("calc() paren depth %d" % d, "rgb(calc(" + "(" * d + "1" + ")" * d + ") 0 0)",
                    "OK" if d <= 30 else ("ERR MaxDepthExceeded" if d > 32 else "*")))
        s = "rgb(" + "calc(" * d + "1" + ")" * d + " 0 0)"
        out.append(("calc() nested calc() depth %d" % d, s,
                    "ERR InputTooLong" if len(s) > 16384 else ("OK" if d <= 30 else ("ERR MaxDepthExceeded" if d > 32 else "*"))))
        out.append(("calc() unary + chain %d" % d, "rgb(calc(" + "+" * d + "1) 0 0)", "*"))
        out.append(("calc() unary -( chain %d" % d, "rgb(calc(" + "-(" * d + "1" + ")" * d + ") 0 0)", "*"))
    for d in (1, 31, 32, 33, 300):
        out.append(("relative from chain depth %d" % d, "rgb(from " * d + "red" + " r g b)" * d,
                    "OK" if d <= 32 else "ERR MaxDepthExceeded"))
        out.append(("relative/mix alternating depth %d" % d,
                    ("oklch(from color-mix(in oklch, " * d) + "red" + (", blue) l c h)" * d), "*"))
    out.append(("calc() 4000 terms", "rgb(calc(" + " + ".join(["1"] * 4000) + ") 0 0)", "OK"))
    out.append(("calc() 4000 factors", "rgb(calc(" + " * ".join(["1"] * 4000) + ") 0 0)", "OK"))
    out.append(("10000 x '9' number", "rgb(" + "9" * 10000 + " 0 0)", "*"))
    out.append(("16000 x '9' number", "rgb(" + "9" * 16000 + " 0 0)", "*"))
    out.append(("0.(10000 zeros)1", "rgb(0." + "0" * 10000 + "1 0 0)", "*"))
    out.append(("1e9999", "rgb(1e9999 0 0)", "*"))
    out.append(("1e-9999", "rgb(1e-9999 0 0)", "OK"))
    out.append(("exponent 1e(5000 digits)", "rgb(1e" + "9" * 5000 + " 0 0)", "*"))
    out.append(("16380 spaces + red", " " * 16380 + "red", "OK"))
    out.append(("16384 bytes exactly", " " * (16384 - 3) + "red", "OK"))
    out.append(("16385 bytes", " " * (16385 - 3) + "red", "ERR InputTooLong"))
    out.append(("1 MiB input", "a" * (1 << 20), "ERR InputTooLong"))
    out.append(("8000 components", "rgb(" + "1 " * 8000 + ")", "ERR"))
    out.append(("8000 commas in color-mix", "color-mix(in srgb, red" + ", blue" * 2700 + ")", "ERR"))
    out.append(("5000 x 'none'", "rgb(" + "none " * 3000 + ")", "ERR"))
    out.append(("hex 16000 digits", "#" + "f" * 16000, "ERR"))
    out.append(("ident 16000 chars", "r" * 16000, "ERR"))
    out.append(("gamut: oklch chroma 1e300", "oklch(0.5 1e300 30)", "OK"))
    out.append(("gamut: lab a=1e300", "lab(50 1e300 0)", "OK"))
    out.append(("gamut: xyz 1e300", "color(xyz 1e300 -1e300 1e300)", "OK"))
    out.append(("huge angle 1e300turn", "hsl(1e300turn 50% 50%)", "OK"))
    out.append(("NUL inside", "rgb(255\x000 0)", "ERR"))
    out.append(("invalid UTF-8 lead", "hex:" + b"rgb(255 \xff 0)".hex(), "ERR"))
    out.append(("lone surrogate bytes", "hex:" + b"red\xed\xa0\x80".hex(), "ERR"))
    out.append(("overlong NUL", "hex:" + b"\xc0\x80red".hex(), "ERR"))
    full = "oklch(from color-mix(in oklch longer hue, rgb(from #3b82f6 r calc(g * 0.8) b / 0.5) 30%, hsl(120 50% 50%)) calc(l + 0.05) c calc(h + 15) / alpha)"
    for i in range(len(full)):
        out.append(("prefix %d of a nested expression" % i, full[:i], "*"))
    return out


def enc(s):
    if s.startswith("hex:"):
        return s
    b = s.encode("utf-8", "surrogateescape")
    if all(0x20 <= x < 0x7F for x in b):
        return s
    return "hex:" + b.hex()


def run(cmd, path, iters):
    try:
        p = subprocess.run(cmd + ["time", path, str(iters)], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return None, "timeout"
    if p.returncode != 0:
        return None, "exit %d: %s" % (p.returncode, (p.stderr or p.stdout).strip().split("\n")[-1][:200])
    return p.stdout.rstrip("\n").split("\n"), ""


def main():
    if len(sys.argv) > 2 and sys.argv[2] == "--list-only":  # just write <dir>/dos.cases (determinism section)
        os.makedirs(sys.argv[1], exist_ok=True)
        with open(os.path.join(sys.argv[1], "dos.cases"), "w", encoding="utf-8") as f:
            for _, s, _ in bombs():
                f.write(enc(s) + "\n")
        return 0
    d, binary = sys.argv[1], sys.argv[2]
    cmd = sys.argv[3:] if len(sys.argv) > 3 else [binary]
    os.makedirs(d, exist_ok=True)
    bs = bombs()
    path = os.path.join(d, "dos.cases")
    with open(path, "w", encoding="utf-8") as f:
        for _, s, _ in bs:
            f.write(enc(s) + "\n")
    iters = 3
    res, err = run(cmd, path, iters)
    rc = 0
    if res is None or len(res) != len(bs):
        print("  P0: audit binary failed on the bomb file (%s)" % (err or "%d results for %d inputs" % (len(res), len(bs))))
        # find the culprit one by one
        for name, s, _ in bs:
            one = os.path.join(d, "one.cases")
            with open(one, "w", encoding="utf-8") as f:
                f.write(enc(s) + "\n")
            r, e = run(cmd, one, 1)
            if r is None:
                print("    crash/timeout on: %s (%s)" % (name, e))
        return 1
    fam = {}
    worst = (0.0, "")
    prefixes = 0
    for (name, s, want), line in zip(bs, res):
        us, nbytes, verdict = line.split(" ", 2)
        ms = int(us) / 1000.0 / iters
        if ms > worst[0]:
            worst = (ms, name)
        ok = want == "*" or verdict.startswith(want)
        flag = ""
        if not ok:
            flag, rc = "  P0: verdict should be %s" % want, 1
        if ms > 1000:
            flag, rc = "  P0: > 1 s", 1
        elif ms > 20 and int(nbytes) <= 16384:
            flag, rc = "  P1: > 20 ms", max(rc, 3) if rc != 1 else 1
        fk = name.split(" depth")[0].split(" chain")[0] if "tree" in name or "nested" in name else None
        if fk:
            fam.setdefault(fk, []).append((int(nbytes), ms))
        if name.startswith("prefix "):
            prefixes += 1
            if flag:
                print("  %-58s %9.3f ms %7s B  %s%s" % (name, ms, nbytes, verdict[:40], flag))
            continue
        print("  %-58s %9.3f ms %7s B  %s%s" % (name, ms, nbytes, verdict[:40], flag))
    print("  %d prefixes of a nested expression: no crash, all within budget" % prefixes)
    for k, v in fam.items():
        v = [x for x in v if x[0] > 200]
        if len(v) >= 2:
            small, big = min(v), max(v)
            r1, r2 = small[1] / small[0], big[1] / big[0]
            ratio = r2 / r1 if r1 > 0 else 0
            print("  scaling %-40s %6d B -> %6d B: time/byte x%.2f" % (k, small[0], big[0], ratio))
            if ratio > 8 and big[1] > 1.0:
                rc = max(rc, 3) if rc != 1 else 1
                print("    P1: super-linear")
    print("  worst input: %.3f ms (%s)" % worst)
    return rc


if __name__ == "__main__":
    sys.exit(main())
