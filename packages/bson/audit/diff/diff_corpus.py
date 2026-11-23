"""Run the official MongoDB BSON Corpus (specifications/source/bson-corpus/tests) through
Pion / Rust bson 2.15.0 / Go mongo-driver v2 and grade each against the spec runner rules
(bson-corpus.md "Testing validity"), then list every Pion-vs-oracle disagreement.

usage: diff_corpus.py <corpus_tests_dir> <out_dir> <pion_probe> <rust_oracle> <go_oracle>
"""
import glob
import json
import os
import sys

from runner import run_impl, write_requests, status, json_equal

tests_dir, out_dir, pion, rust, go = sys.argv[1:6]
os.makedirs(out_dir, exist_ok=True)

reqs = []   # (op, payload)
checks = [] # (file, desc, kind, req_index, expected)


def add(op, payload):
    reqs.append((op, payload))
    return len(reqs) - 1


for path in sorted(glob.glob(os.path.join(tests_dir, "*.json"))):
    f = os.path.basename(path)
    spec = json.load(open(path))
    key = spec.get("test_key")
    is_dec = spec.get("bson_type") == "0x13"
    for v in spec.get("valid", []):
        d = v["description"]
        cb = v["canonical_bson"].lower()
        i = add("B", bytes.fromhex(cb))
        checks.append((f, d, "decode(cB)->encode==cB", i, ("bson", cb)))
        checks.append((f, d, "decode(cB)->canonicalEJ==cEJ", i, ("cej", v["canonical_extjson"])))
        if "relaxed_extjson" in v:
            checks.append((f, d, "decode(cB)->relaxedEJ==rEJ", i, ("rej", v["relaxed_extjson"])))
        if "degenerate_bson" in v:
            j = add("B", bytes.fromhex(v["degenerate_bson"]))
            checks.append((f, d, "decode(dB)->encode==cB", j, ("bson", cb)))
        if not v.get("lossy"):
            j = add("J", v["canonical_extjson"])
            checks.append((f, d, "parse(cEJ)->encode==cB", j, ("bson", cb)))
            if "degenerate_extjson" in v:
                j = add("J", v["degenerate_extjson"])
                checks.append((f, d, "parse(dEJ)->encode==cB", j, ("bson", cb)))
            if "relaxed_extjson" in v:
                j = add("J", v["relaxed_extjson"])
                checks.append((f, d, "parse(rEJ)->ok", j, ("ok", None)))
    for v in spec.get("decodeErrors", []):
        i = add("B", bytes.fromhex(v["bson"]))
        checks.append((f, v["description"], "decodeError", i, ("err", None)))
    for v in spec.get("parseErrors", []):
        if is_dec:
            i = add("D", v["string"])
        else:
            i = add("J", v["string"])
        checks.append((f, v["description"], "parseError", i, ("err", None)))

req_path = os.path.join(out_dir, "corpus_requests.tsv")
write_requests(req_path, reqs)
res = {
    "pion": run_impl([pion, "diff"], req_path, len(reqs), crash_restart=True),
    "rust": run_impl([rust], req_path, len(reqs)),
    "go": run_impl([go], req_path, len(reqs)),
}


def grade(line, exp):
    kind, val = exp
    st = status(line)
    parts = line.split("\t")
    if kind == "err":
        return st == "ERR"
    if st != "OK":
        return False
    if kind == "ok":
        return True
    if kind == "bson":
        return parts[1].lower() == val
    if kind == "cej":
        return json_equal(parts[2], val)
    if kind == "rej":
        return json_equal(parts[3], val)
    return False


summary = {k: {"pass": 0, "fail": 0, "crash": 0} for k in res}
fails = {k: [] for k in res}
for (f, d, kind, i, exp) in checks:
    for impl, lines in res.items():
        ok = grade(lines[i], exp)
        summary[impl]["pass" if ok else "fail"] += 1
        if status(lines[i]) == "CRASH":
            summary[impl]["crash"] += 1
        if not ok:
            fails[impl].append({"file": f, "desc": d, "check": kind, "got": lines[i][:300],
                                "req": reqs[i][0] + " " + (reqs[i][1].hex() if isinstance(reqs[i][1], bytes) else reqs[i][1])[:200]})

print("BSON corpus: %d requests, %d spec assertions" % (len(reqs), len(checks)))
for impl in res:
    s = summary[impl]
    print("  %-5s pass=%d fail=%d crash=%d" % (impl, s["pass"], s["fail"], s["crash"]))
print("\nPion spec failures that Rust AND Go pass (hard evidence):")
rust_fail = {(x["file"], x["desc"], x["check"]) for x in fails["rust"]}
go_fail = {(x["file"], x["desc"], x["check"]) for x in fails["go"]}
hard = [x for x in fails["pion"] if (x["file"], x["desc"], x["check"]) not in rust_fail | go_fail]
for x in hard:
    print("  [%s] %s :: %s\n      req: %s\n      pion: %s" % (x["file"], x["desc"], x["check"], x["req"], x["got"]))
print("\nPion spec failures shared with an oracle:")
for x in fails["pion"]:
    k = (x["file"], x["desc"], x["check"])
    if k in rust_fail | go_fail:
        print("  [%s] %s :: %s (rust %s, go %s)" % (x["file"], x["desc"], x["check"],
              "fails" if k in rust_fail else "ok", "fails" if k in go_fail else "ok"))
json.dump({"summary": summary, "fails": fails, "hard": hard}, open(os.path.join(out_dir, "corpus_result.json"), "w"), indent=1)
