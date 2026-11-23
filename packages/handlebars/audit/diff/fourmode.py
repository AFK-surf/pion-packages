"""4-mode consistency: native_dbg / native_rel / wasm_dbg / wasm_rel Pion builds over the whole
differential corpus (adversarial + Mustache spec). Each mode's results are canonicalised (crash of any
kind -> "CRASH") and SHA-256'd; any per-case difference between modes is a finding. Exit 1 on difference.
usage: fourmode.py <out_dir> <spec_specs_dir> <bin_dir> <wasm_runtime.mjs>"""
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cases as sem  # noqa: E402
import runner  # noqa: E402
import spec_cases  # noqa: E402


def modes(bin_dir, rt):
    return [("native_dbg", [os.path.join(bin_dir, "probe_dbg")]),
            ("native_rel", [os.path.join(bin_dir, "probe")]),
            ("wasm_dbg", ["node", rt, os.path.join(bin_dir, "probe_dbg.wasm")]),
            ("wasm_rel", ["node", rt, os.path.join(bin_dir, "probe.wasm")])]


def canon(r):
    if r["ok"]:
        return ["ok", r["out"]]
    k = r.get("kind", "")
    return ["crash"] if k.startswith(("CRASH", "TIMEOUT")) else ["err", k]


def main():
    out_dir, spec_dir, bin_dir, rt = sys.argv[1:5]
    keep = ("id", "tmpl", "data", "partials", "strict", "no_escape", "limits")
    all_cases = [{k: v for k, v in c.items() if k in keep} for c in sem.cases() + spec_cases.load(spec_dir)]
    res = {}
    for name, cmd in modes(bin_dir, rt):
        r = runner.run_engine(cmd, all_cases, os.path.join(out_dir, "work-" + name))
        res[name] = {c["id"]: canon(r[c["id"]]) for c in all_cases}
        blob = json.dumps([res[name][c["id"]] for c in all_cases], ensure_ascii=False).encode("utf-8")
        print("%-10s %d cases  ok=%d err=%d crash=%d  sha256=%s" % (
            name, len(all_cases), sum(v[0] == "ok" for v in res[name].values()),
            sum(v[0] == "err" for v in res[name].values()), sum(v[0] == "crash" for v in res[name].values()),
            hashlib.sha256(blob).hexdigest()))
    diff = [c["id"] for c in all_cases if len({json.dumps(res[m][c["id"]]) for m in res}) > 1]
    for i in diff:
        print("MODE DIFFERENCE %s: %s" % (i, {m: res[m][i] for m in res}))
    print("4-mode identical: %s" % ("yes" if not diff else "NO (%d cases)" % len(diff)))
    sys.exit(1 if diff else 0)


if __name__ == "__main__":
    main()
