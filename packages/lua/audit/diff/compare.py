#!/usr/bin/env python3
"""Differential runner: Pion lua (native dbg/rel, wasm32 dbg/rel) vs PUC-Rio Lua 5.4.7.
usage: compare.py <cases_module_dir> <bin_dir> <lua_bin> <out_dir> [--modes rel,dbg,wdbg,wrel] [--only name,...]
Writes <out_dir>/cases/*.lua, <out_dir>/results.json and prints a summary.
Verdicts per case: SAME (stdout + OK/ERR identical), DIFF (output differs), CRASH (non-zero exit/signal/timeout)."""
import json, os, subprocess, sys, concurrent.futures as cf
sys.dont_write_bytecode = True

import re
POS = re.compile(r"(?:\[string \"[^\"]*\"\]|[\w./-]+\.lua|[\w./-]+):\d+: ")
ADDR = re.compile(r"(table|function): (0x[0-9a-f]+|builtin#\d+)")

def norm(text, loose=False):
    out = []
    for line in text.splitlines():
        if line.startswith("#msg") or line.startswith("#stats") or line.startswith("## "):
            continue
        if line.startswith("=> ERR"):
            line = "=> ERR"
        if loose:
            line = ADDR.sub(r"\1: ADDR", POS.sub("", line))
        out.append(line)
    return "\n".join(out)

def run(cmd, timeout):
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.decode("latin-1"), p.stderr.decode("latin-1")[-400:]
    except subprocess.TimeoutExpired:
        return "TIMEOUT", "", ""

def main():
    a = sys.argv[1:]
    mod_dir, bin_dir, lua_bin, out_dir = a[:4]
    modes = ["rel", "dbg", "wdbg", "wrel"]
    only = None
    timeout = 30
    i = 4
    while i < len(a):
        if a[i] == "--modes": modes = a[i + 1].split(","); i += 2
        elif a[i] == "--only": only = set(a[i + 1].split(",")); i += 2
        elif a[i] == "--timeout": timeout = int(a[i + 1]); i += 2
        else: i += 1
    sys.path.insert(0, mod_dir)
    import cases
    cdir = os.path.join(out_dir, "cases"); os.makedirs(cdir, exist_ok=True)
    names = [n for n in cases.C if only is None or n in only]
    for n in names:
        with open(os.path.join(cdir, n + ".lua"), "w", encoding="utf-8") as f:
            f.write(cases.C[n])
    rt = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
    cmds = {
        "rel": lambda p: [os.path.join(bin_dir, "drv_rel"), "run", p],
        "dbg": lambda p: [os.path.join(bin_dir, "drv_dbg"), "run", p],
        "wdbg": lambda p: ["node", "--stack-size=984", rt, os.path.join(bin_dir, "drv_dbg.wasm"), "run", p],
        "wrel": lambda p: ["node", "--stack-size=984", rt, os.path.join(bin_dir, "drv_rel.wasm"), "run", p],
    }
    jobs = {}
    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        for n in names:
            p = os.path.join(cdir, n + ".lua")
            jobs[(n, "lua")] = ex.submit(run, [lua_bin, os.path.join(mod_dir, "oracle.lua"), p], timeout)
            for m in modes:
                jobs[(n, m)] = ex.submit(run, cmds[m](p), timeout)
    results = {}
    counts = {"SAME": 0, "DIFF_POS": 0, "DIFF": 0, "CRASH": 0, "MODE_SPLIT": 0}
    for n in names:
        lrc, lout, _ = jobs[(n, "lua")].result()
        r = {"lua": lout, "lua_norm": norm(lout)}
        verdict = "SAME"
        pion_norms = set()
        for m in modes:
            rc, out, err = jobs[(n, m)].result()
            r[m] = {"rc": rc, "out": out, "stderr": err}
            if rc != 0:
                verdict = "CRASH"
            pion_norms.add(norm(out) if rc == 0 else "CRASH:%s" % rc)
        if verdict != "CRASH":
            if len(pion_norms) > 1:
                verdict = "MODE_SPLIT"
            elif pion_norms.pop() != r["lua_norm"]:
                # DIFF_POS: identical once chunk:line: prefixes and addresses are stripped
                verdict = "DIFF_POS" if norm(jobs[(n, modes[0])].result()[1], True) == norm(lout, True) else "DIFF"
        r["verdict"] = verdict
        counts[verdict] += 1
        results[n] = r
    with open(os.path.join(out_dir, "results.json"), "w") as f:
        json.dump(results, f, indent=1)
    print("cases=%d %s" % (len(names), " ".join("%s=%d" % kv for kv in counts.items())))
    print("DIFF_POS (only error position prefix / addresses differ): " + " ".join(n for n in names if results[n]["verdict"] == "DIFF_POS"))
    for n in names:
        r = results[n]
        if r["verdict"] in ("SAME", "DIFF_POS"): continue
        print("\n[%s] %s" % (r["verdict"], n))
        print("  lua : " + r["lua_norm"].replace("\n", "\n        "))
        for m in modes:
            x = r[m]
            body = norm(x["out"]) if x["rc"] == 0 else "rc=%s %s" % (x["rc"], x["stderr"].strip().replace("\n", " | ")[-200:])
            msgs = [l for l in x["out"].splitlines() if l.startswith("#msg")]
            print("  %-4s: %s%s" % (m, body.replace("\n", "\n        "), ("\n        " + msgs[0]) if msgs else ""))
            if r["verdict"] in ("DIFF",) : break

main()
