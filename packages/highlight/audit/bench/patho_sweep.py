#!/usr/bin/env python3
"""Adversarial 1 MiB sweep, end-to-end HTML, single run each: pion probe vs prismjs vs shiki (timeout per run).
Reports wall ms, peak RSS and whether the decoded text hash matches the source. usage:
REF_NODE_MODULES=... patho_sweep.py <probe-bin> <ref_html.mjs> <dir> [timeout_s]"""
import os, resource, subprocess, sys, time

probe, ref, d = sys.argv[1:4]
timeout = float(sys.argv[4]) if len(sys.argv) > 4 else 20

def fnv(b):
    h = 0x811C9DC5
    for x in b:
        h = ((h ^ x) * 16777619) & 0xFFFFFFFF
    return "%08x" % h

def run(cmd):
    t = time.time()
    # measure child RSS via /usr/bin/time -l (macOS) or -v (GNU)
    flag = "-l" if sys.platform == "darwin" else "-v"
    try:
        r = subprocess.run(["/usr/bin/time", flag] + cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, None, "TIMEOUT>%ds" % timeout
    ms = (time.time() - t) * 1000
    rss = None
    for line in r.stderr.splitlines():
        if "maximum resident set size" in line:
            v = int(line.split()[0]); rss = v / 1048576 if sys.platform == "darwin" else v / 1024
        if "Maximum resident set size" in line:
            rss = int(line.split()[-1]) / 1024
    return ms, rss, r.stdout.strip()

print("| input (1 MiB) | pion ms | pion RSS MiB | prism ms | prism RSS MiB | shiki ms | shiki RSS MiB | lossless (all) |")
print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
for name in sorted(os.listdir(d)):
    lang = name.split(".")[0]
    data = open(os.path.join(d, name), "rb").read()
    want = "TEXT_FNV=" + fnv(data)
    res = [run([probe, "bench-html-text", lang, os.path.join(d, name), "1"])]
    for eng in ("prism", "shiki"):
        res.append(run(["node", ref, eng, lang, os.path.join(d, name), "1"]))
    cells, ok = [], True
    for ms, rss, out in res:
        if ms is None:
            cells += [out, "-"]
        else:
            cells += ["%.0f" % ms, "%.1f" % rss if rss else "?"]
            ok = ok and want in out
    print(f"| {name} | " + " | ".join(cells) + f" | {'yes' if ok else 'NO'} |", flush=True)
