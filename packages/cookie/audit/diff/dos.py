"""DoS bombs for packages/cookie/audit (stdlib only).

    dos.py <out_dir> <runner...>     write the bombs and run each one with `<runner...> <mode> <file>`

Budgets (wall clock of one process, including start-up): a crash, trap or non-zero exit, or a run longer than
HARD_S, is a P0. A run longer than its budget is reported as P2-6 (algorithmic DoS): every bomb is at most ~1 MiB
or ~20k operations, so a linear-time implementation finishes far inside the budget.
Exit status: 0 within budgets, 3 a budget exceeded (P2-6), 1 a P0.
"""

import os
import subprocess
import sys
import time

HARD_S = 60.0


def jar_line(op, now, url, hdr=None):
    f = [op, str(now), url, "-", "1", "1", "1", "1"]
    if hdr is not None:
        f.append(hdr)
    return "\t".join(f)


def bombs():
    """-> [(name, mode, content, budget seconds)]"""
    B = []
    big = 1 << 20
    B.append(("set-cookie: 1 MiB value", "parse", "a=" + "v" * big, 1.0))
    B.append(("set-cookie: 1 MiB of ';'", "parse", "a=b" + ";" * big, 1.0))
    B.append(("set-cookie: 100k attributes", "parse", "a=b" + "; Path=/x" * 100000, 1.0))
    B.append(("set-cookie: 100k Expires attributes", "parse", "a=b" + "; Expires=Sun, 06 Nov 1994 08:49:37 GMT" * 25000,
              1.0))
    B.append(("set-cookie: 1000-dot Domain", "parse", "a=b; Domain=" + "." * 1000, 1.0))
    B.append(("set-cookie: 1 MiB of '='", "parse", "=" * big, 1.0))
    B.append(("date: 1 MiB of tokens", "date", "1 " * (big // 2), 1.0))
    B.append(("date: 1 MiB of delimiters", "date", "," * big, 1.0))
    B.append(("psl: 1000 labels", "psl", ".".join(["a"] * 1000) + ".com", 1.0))
    B.append(("psl: 32k labels (64 KiB host)", "psl", ".".join(["a"] * 32000) + ".com", 1.0))
    B.append(("psl: 128k labels (256 KiB host)", "psl", ".".join(["a"] * 128000) + ".com", 1.0))
    B.append(("psl: 1 MiB single label", "psl", "a" * big + ".com", 1.0))
    cjk = "".join(chr(0x4E00 + i) for i in range(24000))
    B.append(("psl: 24000 distinct CJK code points in one label (punycode, 72 KiB)", "psl", cjk + ".cn", 1.0))
    B.append(("psl: 255 x 4-byte code points", "psl", "\U0001F600" * 255 + ".com", 1.0))
    B.append(("url: 1 MiB URL", "match", "url\thttps://" + "a" * big + "/", 1.0))
    B.append(("cookie header: 100k pairs", "match", "chdr\t" + "; ".join("a%d=b" % i for i in range(100000)), 1.0))
    # jar
    t = 1700000000
    lines = [jar_line("set", t + i, "https://h%d.example/" % i, "c=1") for i in range(10000)]
    B.append(("jar: 10k cookies on 10k hosts (global eviction at 3000)", "jar", "\n".join(lines), 2.0))
    lines = [jar_line("set", t + i, "https://e.example/", "c%d=1" % i) for i in range(10000)]
    B.append(("jar: 10k cookies on one host (per-domain eviction at 180)", "jar", "\n".join(lines), 2.0))
    chain = ["a%d" % i for i in range(16)]
    lines = []
    n = 0
    for depth in range(1, 17):
        host = ".".join(chain[16 - depth:]) + ".example"
        for k in range(170):
            lines.append(jar_line("set", t + n, "https://%s/" % host, "c%d=1; Domain=%s" % (k, host)))
            n += 1
    deep = ".".join(chain) + ".example"
    lines += [jar_line("get", t + n + i, "https://%s/" % deep) for i in range(50)]
    B.append(("jar: 2720 cookies matching one request, 50 requests", "jar", "\n".join(lines), 2.0))
    B.append(("jar: import_text 40k cookies for one domain, then one store", "jar",
              "bulkimport\t40000\te.example\n" + jar_line("set", t, "https://e.example/", "x=1"), 2.0))
    B.append(("jar: import_text 40k cookies, clear_domain", "jar",
              "bulkimport\t40000\te.example\ncleardom\te.example", 2.0))
    return B


def main():
    out = sys.argv[1]
    runner = sys.argv[2:]
    os.makedirs(out, exist_ok=True)
    rc = 0
    worst = (0.0, "")
    for i, (name, mode, content, budget) in enumerate(bombs()):
        path = os.path.join(out, "bomb%02d.%s" % (i, mode))
        with open(path, "wb") as f:
            f.write(content.encode("utf-8"))
        if runner == ["--list-only"]:
            continue
        t0 = time.time()
        try:
            p = subprocess.run(runner + [mode, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=HARD_S)
            dt = time.time() - t0
            bad = p.returncode != 0
            note = (p.stderr.decode("utf-8", "replace").strip().splitlines() or [""])[-1][:120] if bad else ""
        except subprocess.TimeoutExpired:
            dt, bad, note = HARD_S, True, "timeout"
        if dt > worst[0]:
            worst = (dt, name)
        if bad:
            status = "P0 (%s)" % note
            rc = 1
        elif dt > budget:
            status = "OVER BUDGET %.1fs (P2-6)" % budget
            rc = max(rc, 3) if rc != 1 else 1
        else:
            status = "ok"
        print("  %-64s %8.3fs  %s" % (name, dt, status))
    if runner != ["--list-only"]:
        print("  worst input: %s (%.3fs)" % (worst[1], worst[0]))
    sys.exit(rc)


if __name__ == "__main__":
    main()
