#!/usr/bin/env python3
"""Run the packages/xml differential matrix and summarise mismatches.

usage: python3 -I run_diff.py BIN_DIR CORPUS_DIR LOG_DIR

Comparisons (each over every *.pack in CORPUS_DIR):
  A  pion dom      vs roxmltree dom       (default options: DTD disabled)
  B  pion dom_dtd  vs roxmltree dom_dtd   (allow_dtd = true)
  C  pion raw      vs pion rd             (DOM vs streaming Reader, same document)
  D  pion raw_dtd  vs pion rd_dtd
  W  W3C expectations vs pion dom_dtd / roxmltree dom_dtd

Writes LOG_DIR/<cmp>.txt with every mismatch (inputs shown escaped) and prints a summary.
Exit status is 0: this is an evidence collector; the asserting tests live in ../*_test.pion.
"""
import os
import subprocess
import sys

BIN, CORPUS, LOG = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(LOG, exist_ok=True)


def run(tool, mode, pack):
    out = subprocess.run([os.path.join(BIN, tool), mode, pack], capture_output=True, check=True).stdout
    res = {}
    cur = None
    buf = []
    for line in out.split(b"\n"):
        if line.startswith(b"=== "):
            if cur is not None:
                res[cur] = b"\n".join(buf)
            cur = line[4:].decode()
            buf = []
        elif cur is not None and line:
            buf.append(line)
    if cur is not None:
        res[cur] = b"\n".join(buf)
    return res


def load_inputs(pack):
    data = open(pack, "rb").read()
    res = {}
    pos = 0
    while pos < len(data):
        eol = data.index(b"\n", pos)
        hdr = data[pos:eol].decode()
        sp = hdr.rindex(" ")
        name, n = hdr[7:sp], int(hdr[sp + 1:])
        res[name] = data[eol + 1:eol + 1 + n]
        pos = eol + 1 + n + 1
    return res


def show(b, limit=300):
    s = repr(b[:limit])[2:-1]
    return s + ("...(%d bytes)" % len(b) if len(b) > limit else "")


def status(r):
    return "OK" if r.startswith(b"OK") else "ERR"


summary = []
packs = sorted(f for f in os.listdir(CORPUS) if f.endswith(".pack"))
for cmp_name, (ta, ma), (tb, mb), label_a, label_b in [
    ("A_dom", ("pion_dump", "dom"), ("rust_dump", "dom"), "pion", "roxmltree"),
    ("B_dom_dtd", ("pion_dump", "dom_dtd"), ("rust_dump", "dom_dtd"), "pion", "roxmltree"),
    ("C_dom_vs_reader", ("pion_dump", "raw"), ("pion_dump", "rd"), "pion-DOM", "pion-Reader"),
    ("D_dom_vs_reader_dtd", ("pion_dump", "raw_dtd"), ("pion_dump", "rd_dtd"), "pion-DOM", "pion-Reader"),
]:
    lines = []
    tot = {"cases": 0, "same": 0, "a_accepts_only": 0, "b_accepts_only": 0, "tree_diff": 0}
    for p in packs:
        path = os.path.join(CORPUS, p)
        inputs = load_inputs(path)
        ra = run(ta, ma, path)
        rb = run(tb, mb, path)
        for name in inputs:
            a, b = ra.get(name, b"<missing>"), rb.get(name, b"<missing>")
            tot["cases"] += 1
            sa, sb = status(a), status(b)
            if sa == sb == "ERR" or a == b:
                tot["same"] += 1
                continue
            if sa == "OK" and sb == "ERR":
                kind = "a_accepts_only"
            elif sa == "ERR" and sb == "OK":
                kind = "b_accepts_only"
            else:
                kind = "tree_diff"
            tot[kind] += 1
            lines.append("### [%s] %s  (%s)" % (kind.replace("a_", label_a + "_").replace("b_", label_b + "_"), name, p))
            lines.append("input: " + show(inputs[name]))
            lines.append("%s: %s" % (label_a, show(a, 600)))
            lines.append("%s: %s" % (label_b, show(b, 600)))
            lines.append("")
    with open(os.path.join(LOG, cmp_name + ".txt"), "w") as f:
        f.write("\n".join(lines))
    summary.append("%-22s cases=%-5d same=%-5d %s_accepts_only=%-4d %s_accepts_only=%-4d tree_diff=%-4d -> %s" % (
        cmp_name, tot["cases"], tot["same"], label_a, tot["a_accepts_only"], label_b, tot["b_accepts_only"],
        tot["tree_diff"], os.path.join(LOG, cmp_name + ".txt")))

# W3C conformance scoring
exp_path = os.path.join(CORPUS, "w3c.expect")
if os.path.exists(exp_path):
    expect = {}
    for line in open(exp_path):
        parts = line.split()
        if parts:
            expect[parts[0]] = (parts[1], parts[2] if len(parts) > 2 else "")
    pack = os.path.join(CORPUS, "w3c.pack")
    inputs = load_inputs(pack)
    rp = run("pion_dump", "dom_dtd", pack)
    rr = run("rust_dump", "dom_dtd", pack)
    score = {"pion": [0, 0, 0, 0], "roxmltree": [0, 0, 0, 0]}  # wf-ok, wf-fail, notwf-ok, notwf-fail
    lines = []
    for name, (want, sections) in expect.items():
        row = []
        for label, res in (("pion", rp), ("roxmltree", rr)):
            got = status(res.get(name, b"ERR"))
            if want == "wf":
                score[label][0 if got == "OK" else 1] += 1
                row.append(got == "OK")
            else:
                score[label][2 if got == "ERR" else 3] += 1
                row.append(got == "ERR")
        if not row[0]:
            tag = "pion-only-fail" if row[1] else "both-fail"
            lines.append("### [%s] %s want=%s sections=%s" % (tag, name, want, sections))
            lines.append("input: " + show(inputs[name]))
            lines.append("pion: " + show(rp.get(name, b""), 300))
            lines.append("roxmltree: " + show(rr.get(name, b""), 300))
            lines.append("")
        elif not row[1]:
            lines.append("### [roxmltree-only-fail] %s want=%s sections=%s" % (name, want, sections))
            lines.append("")
    with open(os.path.join(LOG, "W_w3c.txt"), "w") as f:
        f.write("\n".join(lines))
    for label, s in score.items():
        total = sum(s)
        summary.append("W3C %-10s wf accepted %d/%d, not-wf rejected %d/%d, total %d/%d (%.1f%%)" % (
            label, s[0], s[0] + s[1], s[2], s[2] + s[3], s[0] + s[2], total, 100.0 * (s[0] + s[2]) / max(total, 1)))
    pion_only = sum(1 for l in lines if l.startswith("### [pion-only-fail]"))
    rox_only = sum(1 for l in lines if l.startswith("### [roxmltree-only-fail]"))
    summary.append("W3C cases pion gets wrong but roxmltree right: %d; roxmltree wrong but pion right: %d -> %s" % (
        pion_only, rox_only, os.path.join(LOG, "W_w3c.txt")))

print("\n".join(summary))
with open(os.path.join(LOG, "summary.txt"), "w") as f:
    f.write("\n".join(summary) + "\n")
