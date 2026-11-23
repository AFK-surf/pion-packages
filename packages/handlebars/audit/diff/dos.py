"""DoS / stack / complexity probes (gen_dos.py), one process per case per engine.

Pion is graded in every mode the case allows (default: all four) against the case's expectation and a
wall-clock budget (native_rel: budget_s, other modes: 4x). Crash, timeout, over-budget or wrong result is a
FAIL. Rust handlebars =6.4.4 and Handlebars.js 4.7.8 run the same probe for comparison only (20 s cap).
Per case and mode the output SHA-256 is printed; modes must agree byte-for-byte. Exit 1 on any FAIL.
usage: dos.py <dos.jsonl> <bin_dir> <wasm_runtime.mjs> [<rust_cmd> [<hbs_cmd>]]"""
import hashlib
import json
import os
import platform
import re
import shlex
import subprocess
import sys
import tempfile
import time

ALL = ["native_rel", "native_dbg", "wasm_rel", "wasm_dbg"]


def mode_cmd(m, bin_dir, rt):
    return {"native_rel": [os.path.join(bin_dir, "probe")],
            "native_dbg": [os.path.join(bin_dir, "probe_dbg")],
            "wasm_rel": ["node", rt, os.path.join(bin_dir, "probe.wasm")],
            "wasm_dbg": ["node", rt, os.path.join(bin_dir, "probe_dbg.wasm")]}[m]


def run(cmd, path, timeout):
    timer = ["/usr/bin/time", "-l"] if platform.system() == "Darwin" else ["/usr/bin/time", "-v"]
    t = time.time()
    try:
        p = subprocess.run(timer + cmd + [path], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"state": "TIMEOUT", "secs": time.time() - t, "rss": 0}
    secs = time.time() - t
    err = p.stderr.decode("utf-8", "replace")
    m = re.search(r"(\d+)\s+maximum resident set size", err) or re.search(r"Maximum resident set size \(kbytes\): (\d+)", err)
    rss = int(m.group(1)) if m else 0
    if m and "kbytes" in m.group(0):
        rss *= 1024
    line = next((l for l in p.stdout.decode("utf-8", "replace").splitlines() if l.startswith("{")), None)
    if p.returncode != 0 or line is None:
        sig = re.search(r"(RangeError[^\n]*|Segmentation fault|Abort trap)", err)
        return {"state": "CRASH(rc=%s%s)" % (p.returncode, ", " + sig.group(1)[:40] if sig else ""), "secs": secs, "rss": rss}
    r = json.loads(line)
    r.update({"state": "ok" if r["ok"] else "err", "secs": secs, "rss": rss})
    return r


def verdict(c, r, budget):
    if r["state"] not in ("ok", "err"):
        return False, r["state"]
    if r["secs"] > budget:
        return False, "over budget (%.1fs > %ss)" % (r["secs"], budget)
    e = c["expect"]
    if "out_len" in e:
        return (r["ok"] and len(r["out"].encode("utf-8")) == e["out_len"]), "len %s" % (len(r["out"]) if r["ok"] else r["kind"])
    if "err" in e:
        return ((not r["ok"]) and r["kind"] in e["err"]), (r["kind"] if not r["ok"] else "rendered")
    return True, "graceful"


def describe(r):
    if r["state"] == "ok":
        return "OK %dB" % len(r["out"].encode("utf-8"))
    if r["state"] == "err":
        return "ERR " + r.get("kind", "")
    return r["state"]


def main():
    path, bin_dir, rt = sys.argv[1:4]
    rust = shlex.split(sys.argv[4]) if len(sys.argv) > 4 else None
    hbs = shlex.split(sys.argv[5]) if len(sys.argv) > 5 else None
    keep = ("id", "tmpl", "data", "partials", "strict", "no_escape", "limits")
    fails, failed_probes = [], set()
    with open(path, encoding="utf-8") as f:
        cases = [json.loads(l) for l in f if l.strip()]
    tmpdir = tempfile.mkdtemp(prefix="dos-", dir=os.path.dirname(os.path.abspath(path)))
    for c in cases:
        one = os.path.join(tmpdir, "case.jsonl")
        with open(one, "w", encoding="utf-8") as f:
            f.write(json.dumps({k: v for k, v in c.items() if k in keep}, ensure_ascii=False) + "\n")
        print("%s%s" % (c["id"], "  [%s]" % c["finding"] if c["finding"] else ""))
        shas = {}
        for m in c.get("modes") or ALL:
            budget = c["budget_s"] * (1 if m == "native_rel" else 4)
            r = run(mode_cmd(m, bin_dir, rt), one, budget + 5)
            ok, why = verdict(c, r, budget)
            if r["state"] == "ok":
                shas[m] = hashlib.sha256(r["out"].encode("utf-8")).hexdigest()
            elif r["state"] == "err":
                shas[m] = "err:" + r["kind"]
            else:
                shas[m] = "crash"
            print("   %-4s pion %-10s %-28s %7.2fs %8.1f MiB  %s" % (
                "ok" if ok else "FAIL", m, describe(r), r["secs"], r["rss"] / 1048576.0,
                shas[m][:16] if not ok or m == "native_rel" else ""))
            if not ok:
                failed_probes.add(c["id"])
                fails.append("%s [%s] %s: %s" % (c["id"], c["finding"] or "control", m, why))
        if len(set(shas.values())) > 1:
            failed_probes.add(c["id"])
            fails.append("%s: modes disagree %s" % (c["id"], shas))
            print("   FAIL modes disagree: %s" % shas)
        for name, cmd in (("rust", rust), ("hbs", hbs)):
            if cmd:
                r = run(cmd, one, 20)
                print("   info %-15s %-28s %7.2fs %8.1f MiB" % (name, describe(r), r["secs"], r["rss"] / 1048576.0))
    print("\n%d probes: %d pass, %d FAIL (%d failing mode runs / mode disagreements)" % (
        len(cases), len(cases) - len(failed_probes), len(failed_probes), len(fails)))
    for f in fails:
        print("  FAIL " + f)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
