#!/usr/bin/env python3
"""Corpus differential: packages/wgsl vs Rust naga =24.0.0, judged by real compilers.

valid corpus   (naga must ACCEPT, control): packages/wgsl must return Ok, its MSL must compile with
               `xcrun -sdk macosx metal -std=macos-metal2.4`, and its GLSL for every entry point must pass
               glslangValidator whenever naga's own GLSL for that entry passes (otherwise reported N/A).
invalid corpus (naga must REJECT, control): packages/wgsl `validate` must return Err.

usage: judge.py <pion_driver> <naga_oracle> <glslangValidator> <out_dir> <valid_dir>... -- <invalid_dir>...
Exit 1 on any FAIL or CONTROL-FAIL."""
import concurrent.futures as cf
import os
import subprocess
import sys

pion, naga, glslang, out = sys.argv[1:5]
rest = sys.argv[5:]
sep = rest.index("--")
valid_dirs, invalid_dirs = rest[:sep], rest[sep + 1:]
os.makedirs(out, exist_ok=True)


def files(dirs):
    r = []
    for d in dirs:
        r += sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith(".wgsl"))
    return r


def sh(args, timeout=60):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return -999, "TIMEOUT"


def first_error(text):
    for line in text.splitlines():
        if "error" in line.lower():
            return line.split("/")[-1][:150]
    return text.strip().splitlines()[0][:150] if text.strip() else "?"


def naga_classify(paths, tag):
    lst = os.path.join(out, tag + ".list")
    res = os.path.join(out, tag + ".naga")
    open(lst, "w").write("\n".join(paths) + "\n")
    sh([naga, "classify", lst, res])
    verdict = {}
    for line in open(res):
        p, v = line.rstrip("\n").split(" ", 1)
        verdict[p] = v
    return verdict


def glsl_ok(path):
    rc, txt = sh([glslang, path])
    return rc == 0, first_error(txt)


def judge_valid(path, nv):
    b = os.path.basename(path)[:-5]
    notes, fails = [], []
    if nv != "ACCEPT":
        return "CONTROL-FAIL", b, ["naga: " + nv]
    msl = os.path.join(out, b + ".metal")
    rc, txt = sh([pion, "msl", path, msl])
    if rc != 0:
        return "FAIL", b, ["pion rejects valid WGSL: " + txt.strip()[:150]]
    rc, txt = sh(["xcrun", "-sdk", "macosx", "metal", "-x", "metal", "-std=macos-metal2.4", "-c", msl, "-o", "/dev/null"])
    if rc != 0:
        fails.append("MSL: " + first_error(txt))
    rc, refl = sh([pion, "reflect", path])
    entries = [(l.split()[1], l.split()[2]) for l in refl.splitlines() if l.startswith("entry ")]
    for name, stage in entries:
        ext = {"vertex": "vert", "fragment": "frag", "compute": "comp"}[stage]
        pg = os.path.join(out, "%s.%s.pion.%s" % (b, name, ext))
        ng = os.path.join(out, "%s.%s.naga.%s" % (b, name, ext))
        nrc, _ = sh([naga, "glsl", path, name, ng])
        n_ok = nrc == 0 and glsl_ok(ng)[0]
        rc, txt = sh([pion, "glsl", path, name, pg])
        if rc != 0:
            p_ok, perr = False, "pion: " + txt.strip()[:120]
        else:
            p_ok, perr = glsl_ok(pg)
        if not p_ok and n_ok:
            fails.append("GLSL %s: %s" % (name, perr))
        elif not p_ok:
            notes.append("GLSL %s N/A (naga's GLSL also fails)" % name)
    return ("FAIL" if fails else "PASS"), b, fails + notes


def judge_invalid(path, nv):
    b = os.path.basename(path)[:-5]
    if not nv.startswith("REJECT"):
        return "CONTROL-FAIL", b, ["naga accepts"]
    lst = os.path.join(out, b + ".one")
    open(lst, "w").write(path + "\n")
    sh([pion, "digest", lst, lst + ".out"])
    d = open(lst + ".out").read()
    v = d.split(" V[", 1)[1].split("]", 1)[0] if " V[" in d else "CRASH"
    if v.startswith("OK"):
        return "FAIL", b, ["pion accepts invalid WGSL (naga: %s)" % nv[7:110]]
    return "PASS", b, ["pion " + v]


vf, inf = files(valid_dirs), files(invalid_dirs)
nvv, niv = naga_classify(vf, "valid"), naga_classify(inf, "invalid")
with cf.ThreadPoolExecutor(max_workers=6) as ex:
    rv = list(ex.map(lambda p: judge_valid(p, nvv.get(p, "?")), vf))
    ri = list(ex.map(lambda p: judge_invalid(p, niv.get(p, "?")), inf))
bad = 0
for title, rows in (("valid WGSL (naga accepts): Ok + Metal compile + glslang", rv),
                    ("invalid WGSL (naga rejects): packages/wgsl must reject", ri)):
    print("  -- " + title)
    for verdict, name, msgs in rows:
        bad += verdict != "PASS"
        print("  %-12s %-36s %s" % (verdict, name, "; ".join(msgs)[:300]))
    print("  %d/%d pass" % (sum(r[0] == "PASS" for r in rows), len(rows)))
sys.exit(1 if bad else 0)
