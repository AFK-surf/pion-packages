"""Differential run: Pion (native release) vs Rust handlebars =6.4.4 vs Handlebars.js 4.7.8 over the
hand-written adversarial corpus (cases.py) and the official Mustache Spec v1.4.2 core vectors.

Grading uses only each case's `expect` (see cases.py). Exit status 1 iff a graded case differs.
usage: diff.py <out_dir> <spec_specs_dir> <pion_cmd> <rust_cmd> [<hbsjs_cmd>]   (cmds are shell-split)"""
import json
import os
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cases as sem  # noqa: E402
import runner  # noqa: E402
import spec_cases  # noqa: E402


def graded(r, expect):
    if expect is None:
        return None
    crashed = (not r["ok"]) and r["kind"].startswith(("CRASH", "TIMEOUT"))
    if "graceful" in expect:
        return not crashed
    if "one_of" in expect:
        return any(graded(r, e) for e in expect["one_of"])
    if "out" in expect:
        return bool(r["ok"] and r["out"] == expect["out"])
    return bool((not r["ok"]) and not crashed and (not expect["err"] or r.get("kind") in expect["err"]))


def wire(c):
    return {k: v for k, v in c.items() if k in ("id", "tmpl", "data", "partials", "strict", "no_escape", "limits")}


def main():
    out_dir, spec_dir, pion, rust = sys.argv[1:5]
    hbs = sys.argv[5] if len(sys.argv) > 5 else ""
    all_cases = sem.cases() + spec_cases.load(spec_dir)
    w = [wire(c) for c in all_cases]
    engines = [("pion", pion), ("rust", rust)] + ([("hbs", hbs)] if hbs else [])
    res = {name: runner.run_engine(shlex.split(cmd), w, os.path.join(out_dir, "work-" + name)) for name, cmd in engines}
    with open(os.path.join(out_dir, "diff_results.json"), "w", encoding="utf-8") as f:
        json.dump({"cases": all_cases, "results": res}, f, ensure_ascii=False)

    fails, info = [], []
    tally = {"sem": [0, 0], "spec": [0, 0]}
    for c in all_cases:
        g = graded(res["pion"][c["id"]], c["expect"])
        group = "spec" if c["id"].startswith("spec/") else "sem"
        if g is None:
            info.append(c)
            continue
        tally[group][0] += g
        tally[group][1] += 1
        if not g:
            fails.append(c)
    spec_total = [c for c in all_cases if c["id"].startswith("spec/")]
    print("Mustache Spec v1.4.2 core (%d vectors): pion %d/%d, rust %d, hbs.js %s pass" % (
        len(spec_total), tally["spec"][0], tally["spec"][1],
        sum(graded(res["rust"][c["id"]], c["expect"]) for c in spec_total),
        sum(graded(res["hbs"][c["id"]], c["expect"]) for c in spec_total) if hbs else "n/a"))
    print("Adversarial corpus: %d graded, pion %d pass / %d FAIL; %d ungraded (documented divergences)" % (
        tally["sem"][1], tally["sem"][0], tally["sem"][1] - tally["sem"][0], len(info)))
    agree = {n: sum(1 for c in all_cases if c["expect"] is not None and graded(res[n][c["id"]], c["expect"]))
             for n, _ in engines}
    print("Expectation agreement over all graded cases: " + ", ".join("%s %d" % kv for kv in agree.items()))
    print()
    for c in fails:
        print("FAIL %-48s [%s] ref=%s" % (c["id"], c.get("finding") or "control!", c.get("ref", "spec")))
        print("     want %s" % json.dumps(c["expect"], ensure_ascii=False))
        for n, _ in engines:
            print("     %-4s %s" % (n, runner.show(res[n][c["id"]])))
    if info:
        print("\nDocumented divergences (not graded):")
        for c in info:
            print("  %-46s " % c["id"] + "  ".join("%s=%s" % (n, runner.show(res[n][c["id"]])[:60]) for n, _ in engines))
    bad_controls = [c["id"] for c in fails if not c.get("finding")]
    if bad_controls:
        print("\nUNEXPECTED: control cases failing:", bad_controls)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
