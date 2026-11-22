#!/usr/bin/env python3
"""Targeted-vector differential table: Pion vs Go fxamacker vs Rust ciborium.

usage: diff_vectors.py <pion_probe> <go_probe> <rust_probe> <workdir>
Prints every vector where the accept/reject verdicts differ (modes dec and dup).
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_vectors  # noqa: E402


def run(probe, mode, path):
    out = subprocess.run([probe, mode, path], capture_output=True).stdout
    return [l.decode("utf-8", "replace") for l in out.split(b"\n") if l]


def main():
    pion, go, rust, work = sys.argv[1:5]
    os.makedirs(work, exist_ok=True)
    vec = [(l, h) for l, h in gen_vectors.V if h]
    path = os.path.join(work, "vectors.hex")
    open(path, "w").write("\n".join(h for _, h in vec) + "\n")
    print("%d targeted vectors" % len(vec))
    for mode in ("dec", "dup"):
        res = {"pion": run(pion, mode, path), "go": run(go, mode, path)}
        if mode == "dec":
            res["rust"] = run(rust, mode, path)
        names = list(res)
        print("\n== mode %s (%s): verdict disagreements" % (mode, " / ".join(names)))
        print("| vector | hex | " + " | ".join(names) + " |")
        print("|---|---|" + "---|" * len(names))
        n = 0
        for i, (lab, h) in enumerate(vec):
            vs = [res[k][i].split(" ")[0] for k in names]
            if len(set(vs)) > 1:
                n += 1
                cells = [res[k][i][:60].replace("|", "/") for k in names]
                print("| %s | `%s` | %s |" % (lab, h[:24], " | ".join(cells)))
        print("(%d disagreements)" % n)


if __name__ == "__main__":
    main()
