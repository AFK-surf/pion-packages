#!/usr/bin/env python3
"""DoS scaling probe for parse_data_url: time n vs 4n (median of 3) through a driver
that reads one hex-encoded URL per line. Usage: dos_scaling.py DRIVER [REPORT]"""
import statistics, subprocess, sys, time

DRIVER = sys.argv[1]

SHAPES = {
    "distinct params ;aN=1": lambda n: "data:text/plain" + "".join(";a%d=1" % i for i in range(n)) + ",x",
    "duplicate params ;a=1": lambda n: "data:text/plain" + ";a=1" * n + ",x",
    "bare semicolons ;": lambda n: "data:text/plain" + ";" * n + ",x",
    "quotes ;a=\"\"\"": lambda n: "data:text/plain;a=" + '"' * n + ",x",
    "backslashes in quoted": lambda n: 'data:text/plain;a="' + "\\" * n + '",x',
    "commas in body": lambda n: "data:," + "," * n,
    "percent body %41": lambda n: "data:," + "%41" * n,
    "broken percent %%": lambda n: "data:," + "%" * n,
    "base64 body": lambda n: "data:;base64," + "QUFB" * n,
    "base64 pct body %51": lambda n: "data:;base64," + "%51%55%46%42" * n,
    "base64 whitespace": lambda n: "data:;base64," + " " * n + "QQ==",
    "header whitespace": lambda n: "data:" + " " * n + ";base64,QQ==",
    "fragment hashes": lambda n: "data:,a" + "#" * n,
}


def run(url):
    line = url.encode().hex() + "\n"
    best = []
    for _ in range(3):
        t = time.perf_counter()
        p = subprocess.run([DRIVER], input=line.encode(), capture_output=True, timeout=600)
        best.append(time.perf_counter() - t)
        if p.returncode != 0:
            return None, p.returncode
    return statistics.median(best), 0


rows = ["| shape | n | t(n) ms | t(4n) ms | ratio | verdict |", "|---|---|---|---|---|---|"]
for name, gen in SHAPES.items():
    n = 25000
    a, rc1 = run(gen(n))
    b, rc2 = run(gen(4 * n))
    if a is None or b is None:
        rows.append("| %s | %d | crash rc=%s | crash rc=%s | - | **CRASH** |" % (name, n, rc1, rc2))
        continue
    # subtract nothing: process startup is ~ms and makes linear ratios look < 4
    ratio = b / a if a > 0 else 0
    verdict = "QUADRATIC" if ratio > 8 else "linear"
    rows.append("| %s | %d | %.1f | %.1f | %.1f | %s |" % (name, n, a * 1e3, b * 1e3, ratio, verdict))
    print(rows[-1], flush=True)
if len(sys.argv) > 2:
    open(sys.argv[2], "w").write("\n".join(rows) + "\n")
