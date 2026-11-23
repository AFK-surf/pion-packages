"""Differential run of gen_vectors.py output: Pion vs Rust bson 2.15.0 vs Go mongo-driver v2.

usage: diff_vectors.py <vectors.tsv> <out_dir> <pion_probe> <rust_oracle> <go_oracle> [max_show_per_cat]
Verdict per vector:
  CRASH       Pion aborted (panic / trap) -- always a finding
  CONSENSUS   Rust and Go agree with each other, Pion differs (accept/reject or value) -- hard evidence
  SPLIT       the oracles disagree with each other; Pion sides with one of them -- informational
  AGREE       all three agree
"""
import collections
import json
import os
import sys

from runner import run_impl, status, json_equal

vec_path, out_dir, pion, rust, go = sys.argv[1:6]
max_show = int(sys.argv[6]) if len(sys.argv) > 6 else 6
os.makedirs(out_dir, exist_ok=True)
vecs = [l.rstrip("\n").split("\t") for l in open(vec_path) if l.strip()]
req_path = os.path.join(out_dir, "vectors_requests.tsv")
with open(req_path, "w") as f:
    for cat, op, h in vecs:
        f.write("%s\t%s\n" % (op, h))
n = len(vecs)
R = {
    "pion": run_impl([pion, "diff"], req_path, n, crash_restart=True),
    "rust": run_impl([rust], req_path, n),
    "go": run_impl([go], req_path, n),
}


def same(op, a, b):
    sa, sb = status(a), status(b)
    if sa != sb:
        return False
    if sa != "OK":
        return True
    pa, pb = a.split("\t"), b.split("\t")
    if op == "B":
        return pa[1] == pb[1] and json_equal(pa[2], pb[2]) and json_equal(pa[3], pb[3])
    if op == "J":
        return pa[1] == pb[1]
    if op == "D":
        return pa[1] == pb[1] and pa[2] == pb[2]
    if op == "X":
        return pa[1] == pb[1]
    return a == b


def show_payload(op, h):
    b = bytes.fromhex(h)
    if op in ("J", "D"):
        return b.decode("utf-8", "replace")
    return h


verdicts = collections.Counter()
bycat = collections.defaultdict(collections.Counter)
details = collections.defaultdict(list)
for idx, (cat, op, h) in enumerate(vecs):
    p, r, g = R["pion"][idx], R["rust"][idx], R["go"][idx]
    if status(p) == "CRASH":
        v = "CRASH"
    elif same(op, p, r) and same(op, p, g):
        v = "AGREE"
    elif same(op, r, g):
        v = "CONSENSUS"
    else:
        v = "SPLIT"
    verdicts[v] += 1
    bycat[cat][v] += 1
    if v != "AGREE":
        details[(v, cat)].append({"op": op, "in": show_payload(op, h)[:220], "pion": p[:260], "rust": r[:260], "go": g[:260]})

print("Adversarial differential: %d vectors (%s)" % (n, ", ".join("%s=%d" % kv for kv in sorted(verdicts.items()))))
print("%-24s %6s %6s %9s %6s" % ("category", "AGREE", "CRASH", "CONSENSUS", "SPLIT"))
for cat in sorted(bycat):
    c = bycat[cat]
    print("%-24s %6d %6d %9d %6d" % (cat, c["AGREE"], c["CRASH"], c["CONSENSUS"], c["SPLIT"]))
for v in ("CRASH", "CONSENSUS", "SPLIT"):
    for (vv, cat), items in sorted(details.items()):
        if vv != v:
            continue
        print("\n--- %s / %s (%d) ---" % (v, cat, len(items)))
        for it in items[:max_show]:
            print("  %s %s\n    pion: %s\n    rust: %s\n    go  : %s" % (it["op"], it["in"], it["pion"], it["rust"], it["go"]))
json.dump({"verdicts": verdicts, "bycat": bycat, "details": {"%s/%s" % k: v for k, v in details.items()}},
          open(os.path.join(out_dir, "vectors_result.json"), "w"), indent=1)
