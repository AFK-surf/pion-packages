"""Score Pion / Rust html5ever (scraper) / Go x/net/html on html5lib-tests tree-construction.

Usage: html5lib_suite.py <html5lib-tests/tree-construction dir> [--show N]
Only scripting-on (default) tests; document tests use Document::parse, fragment tests whose
context is plain `body` use parse_fragment. Expected = html5lib `#document` block verbatim.
"""
import glob, os, sys, json, collections
sys.path.insert(0, os.path.dirname(__file__))
from common import run, PION, RUST, GO


def parse_dat(path):
    tests, cur, sec = [], None, None
    for line in open(path, encoding="utf-8").read().split("\n"):
        if line == "#data":
            if cur: tests.append(cur)
            cur, sec = {"data": [], "document": [], "frag": None, "script": None}, "data"; continue
        if cur is None: continue
        if line.startswith("#") and line.split(" ")[0] in ("#errors", "#new-errors", "#document", "#document-fragment", "#script-off", "#script-on"):
            sec = line[1:].split(" ")[0]
            if sec in ("script-off", "script-on"): cur["script"] = sec
            continue
        if sec == "data": cur["data"].append(line)
        elif sec == "document": cur["document"].append(line)
        elif sec == "document-fragment": cur["frag"] = line.strip()
    if cur: tests.append(cur)
    out = []
    for t in tests:
        doc = "\n".join(t["document"]).rstrip("\n")
        out.append({"data": "\n".join(t["data"]), "expect": doc + "\n" if doc else "", "frag": t["frag"], "script": t["script"]})
    return out


def main():
    d = sys.argv[1]
    show = int(sys.argv[sys.argv.index("--show") + 1]) if "--show" in sys.argv else 0
    cases = []
    for f in sorted(glob.glob(os.path.join(d, "*.dat"))):
        for i, t in enumerate(parse_dat(f)):
            if t["script"] == "script-off": continue
            if t["frag"] not in (None, "body"): continue
            t["file"] = os.path.basename(f); t["idx"] = i
            cases.append(t)
    res = {}
    for impl, binary in (("pion", PION), ("rust_html5ever", RUST), ("go_x_net_html", GO)):
        got = [None] * len(cases)
        for mode in ("doc", "frag"):
            ids = [i for i, c in enumerate(cases) if (c["frag"] is None) == (mode == "doc")]
            outs = run(binary, "tree", [cases[i]["data"] for i in ids], mode)
            for i, o in zip(ids, outs): got[i] = o
        res[impl] = got
    summary = {}
    per_file = collections.defaultdict(lambda: collections.Counter())
    for impl, got in res.items():
        ok = sum(1 for c, g in zip(cases, got) if g == c["expect"])
        summary[impl] = {"passed": ok, "total": len(cases), "rate": round(100.0 * ok / len(cases), 2)}
        for c, g in zip(cases, got):
            per_file[c["file"]][impl] += (g == c["expect"])
            per_file[c["file"]]["total_" + impl] += 1
    print(json.dumps(summary, indent=1))
    print("per-file pass (pion / html5ever / go / total):")
    for f in sorted(per_file):
        p = per_file[f]
        print(f"  {f:44s} {p['pion']:4d} {p['rust_html5ever']:4d} {p['go_x_net_html']:4d} {p['total_pion']:4d}")
    shown = 0
    for c, g, r in zip(cases, res["pion"], res["rust_html5ever"]):
        if shown >= show: break
        if g != c["expect"] and r == c["expect"]:
            shown += 1
            print(f"--- {c['file']}#{c['idx']} input={c['data']!r}\n  expected:\n{c['expect']}  pion:\n{g}")


if __name__ == "__main__":
    main()
