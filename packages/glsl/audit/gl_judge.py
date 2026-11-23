#!/usr/bin/env python3
"""OpenGL 4.1 Core ground-truth judge: ES corpus (corpus.py) -> Pion translator -> CGL compile + link.

Usage: python3 -I gl_judge.py            (expects $AUDIT_OUT/bin/{drv,gl41_oracle}, built by run_audit.sh)
Prints one line per case and exits non-zero when any valid WebGL shader is mistranslated.
"""
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import corpus as C  # noqa: E402

OUT = os.environ.get("AUDIT_OUT", "/private/tmp/pion-glsl-audit")
BIN = os.path.join(OUT, "bin")
WORK = os.path.join(OUT, "judge")
os.makedirs(WORK, exist_ok=True)


def translate(name, stage, src):
    es = os.path.join(WORK, f"{name}.{stage}.es")
    out = os.path.join(WORK, f"{name}.{stage}.410")
    with open(es, "w", encoding="utf-8") as f:
        f.write(src)
    if os.path.exists(out):
        os.remove(out)
    r = subprocess.run([os.path.join(BIN, "drv"), "tr", stage, es, out], capture_output=True, text=True, timeout=30)
    line = r.stdout.strip().splitlines()[0] if r.stdout.strip() else "CRASH " + r.stderr.strip()[:200]
    return (out if line.startswith("OK") else None), line


VARYING_RE = re.compile(r"^\s*(?:invariant\s+)?varying\s+(?:(?:lowp|mediump|highp)\s+)?(\w+)\s+(\w+)\s*;", re.M)


def partner_vs100(fs):
    """ES 1.00 vertex partner that writes every varying the fragment shader reads (so linking is meaningful)."""
    decls = VARYING_RE.findall(fs)
    body = "".join(f"  {n} = {t}(0.0);\n" for t, n in decls)
    return ("attribute vec4 aPos;\n" + "".join(f"varying {t} {n};\n" for t, n in decls)
            + "void main() {\n" + body + "  gl_Position = aPos;\n}\n")


def main():
    rows, manifest = [], []
    for name, vs, fs, tags in C.CASES:
        vs_src = vs if vs is not None else (C.VS300 if fs and fs.lstrip("\ufeff").lstrip().startswith("#version 300") else partner_vs100(fs or ""))
        fs_src = fs if fs is not None else (C.FS300 if vs and "#version 300" in vs else C.FS100)
        vo, vl = translate(name, "vert", vs_src)
        fo, fl = translate(name, "frag", fs_src)
        rows.append([name, tags, vl, fl, None])
        if vo and fo:
            manifest.append(f"{name}\t{vo}\t{fo}")
    mpath = os.path.join(WORK, "manifest.tsv")
    with open(mpath, "w") as f:
        f.write("\n".join(manifest) + "\n")
    gl = subprocess.run([os.path.join(BIN, "gl41_oracle"), mpath], capture_output=True, text=True, timeout=120)
    print(gl.stderr.strip())
    verdicts = {ln.split(" ", 1)[0]: ln for ln in gl.stdout.splitlines()}
    bad = 0
    for name, tags, vl, fl, _ in rows:
        if "reject" in tags:
            ok = not vl.startswith("OK") or not fl.startswith("OK")
            status, detail = ("PASS", "rejected as expected") if ok else ("ACCEPTED-INVALID", "")
        elif not vl.startswith("OK") or not fl.startswith("OK"):
            why = vl if not vl.startswith("OK") else fl
            status, detail = "TRANSLATOR-REJECT", why[:150]
        else:
            g = verdicts.get(name, "")
            if "LINK=ok" in g:
                loc = int(g.split("fragcolor_loc=")[1].split()[0])
                if "loc0" in tags and loc != 0:
                    status, detail = "WRONG-OUTPUT-LOC", f"_fv_gl_FragColor bound to location {loc}"
                else:
                    status, detail = "PASS", ""
            else:
                status, detail = "GL41-FAIL", g.split(" ", 1)[1][:200] if g else "no oracle verdict"
        bad += status != "PASS"
        print(f"{status:18} {name:52} {detail}")
    print(f"== {len(rows) - bad}/{len(rows)} cases correct (valid WebGL pairs translate + compile + link on OpenGL 4.1 Core; invalid ones rejected)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
