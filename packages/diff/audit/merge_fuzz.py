#!/usr/bin/env python3
"""merge3 differential: Pion `diff::merge3` vs `git merge-file -p` (imara-diff 0.2.0 has no
3-way merge, so git's xdiff merge is the reference). Labels are aligned to Pion's defaults.

usage: merge_fuzz.py --runner BIN [--cases N] [--seed S] [--out DIR]
"""
import argparse, collections, os, random, subprocess, tempfile, json

def gen(r):
    alpha = ["a\n", "b\n", "c\n", "d\n", "\n", "}\n"]
    base = [r.choice(alpha) for _ in range(r.randint(0, 12))]
    def edit(src):
        out = list(src)
        for _ in range(r.randint(0, 3)):
            p = r.randint(0, len(out))
            op = r.random()
            if op < 0.4: out.insert(p, r.choice(alpha + ["X\n", "Y\n"]))
            elif op < 0.7 and out: del out[min(p, len(out) - 1)]
            elif out: out[min(p, len(out) - 1)] = r.choice(["X\n", "Y\n", "Z\n"])
        return out
    return "".join(base), "".join(edit(base)), "".join(edit(base))

def git_merge(tmp, b, o, t):
    paths = []
    for name, txt in (("ours", o), ("base", b), ("theirs", t)):
        p = os.path.join(tmp, name); open(p, "w").write(txt); paths.append(p)
    pr = subprocess.run(["git", "merge-file", "-p", "-L", "ours", "-L", "base", "-L", "theirs", *paths], capture_output=True)
    return pr.returncode != 0, pr.stdout

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runner", required=True); ap.add_argument("--cases", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=20261123); ap.add_argument("--out", default="/tmp/diff-redteam")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    r = random.Random(a.seed)
    cases = [gen(r) for _ in range(a.cases)]
    binp = os.path.join(a.out, "merge_cases.bin")
    with open(binp, "wb") as f:
        for b, o, t in cases:
            bb, ob, tb = b.encode(), o.encode(), t.encode()
            f.write(f"{len(bb)} {len(ob)} {len(tb)}\n".encode() + bb + ob + tb)
    buf = subprocess.run([a.runner, "merge", binp], check=True, capture_output=True).stdout
    pion, p = [], 0
    while p < len(buf):
        nl = buf.index(b"\n", p); hdr = buf[p:nl].decode().split(); p = nl + 1
        n = int(hdr[2]); pion.append((hdr[1] == "C", buf[p:p + n])); p += n
    cnt = collections.Counter(); samples = collections.defaultdict(list)
    with tempfile.TemporaryDirectory() as tmp:
        for i, (b, o, t) in enumerate(cases):
            gc, gtxt = git_merge(tmp, b, o, t)
            pc, ptxt = pion[i]
            if gc == pc and gtxt == ptxt: k = "identical"
            elif not gc and not pc: k = "both-clean-but-different-text"
            elif gc and not pc: k = "pion-clean-git-conflict"
            elif pc and not gc: k = "pion-conflict-git-clean"
            else: k = "both-conflict-different-text"
            cnt[k] += 1
            if k != "identical" and len(samples[k]) < 3:
                samples[k].append(dict(base=b, ours=o, theirs=t, git=gtxt.decode(), pion=ptxt.decode()))
    print(dict(cnt.most_common()))
    json.dump(dict(counts=cnt, samples=samples), open(os.path.join(a.out, "merge_summary.json"), "w"), indent=1)

if __name__ == "__main__":
    main()
