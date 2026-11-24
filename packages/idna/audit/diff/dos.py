"""DoS bomb set for packages/idna: each bomb runs once per runner (native --release, wasm32 --release) in a
fresh process; wall time and peak RSS are measured and compared with a budget, and the one-line result must be
identical across runners.

  dos.py <outdir> --list-only                 write the bombs, list them
  dos.py <outdir> <native_bin> <wasm_cmd>     write + run; prints a table, `OPENIDS ...` for budget overruns
                                              explained by open findings; exit 1 on crash / divergence / an
                                              unexplained overrun

Bomb file format (read by `idna_audit bomb`): `<op>\n<limits>\n<hex payload>`.
"""
import os
import resource
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model  # noqa: E402

DEF = "default"
BIG = "1000000 1000000 1000 2000"  # a caller that raises the byte/label limits but keeps per-label bounds


def bombs():
    P = model.puny_encode
    desc_1000 = [0x4E00 + 999 - i for i in range(1000)]  # every insertion lands at index 0 (max shifting)
    alt = "̖́"  # ccc 230 / 220 alternating: worst case for the canonical-ordering insertion sort
    B = []
    # (id, op, limits, payload, native_budget_s, wasm_budget_s, finding id if over budget)
    B.append(("b01", "puny_dec", DEF, "z" * 2000, 1, 5, None))
    B.append(("b02", "puny_dec", DEF, "9" * 2000, 1, 5, None))
    B.append(("b03", "puny_dec", DEF, P(desc_1000), 1, 5, None))
    B.append(("b04", "unicode_url", DEF, "xn--" + P(desc_1000) + ".com", 1, 5, None))
    B.append(("b05", "puny_dec", DEF, "a-" + "z" * 1997, 1, 5, None))
    B.append(("b06", "puny_enc", DEF, "".join(map(chr, desc_1000)), 1, 5, None))
    B.append(("b07", "unicode", DEF, "a" + alt * 1023 + ".com", 1, 5, None))
    B.append(("b08", "ascii_url", DEF, "ﷺ" * 1365, 1, 5, None))
    B.append(("b09", "ascii", DEF, "a." * 5000 + "com", 1, 5, None))
    B.append(("b10", "ascii", "10000000 1000000 1000 2000", "a." * 200000 + "com", 2, 10, None))
    B.append(("b11", "unicode", "10000000 1000000 1000 2000", ("ü." * 150000) + "com", 2, 10, None))
    B.append(("b12", "display", DEF, ".".join(["pаypal"] * 300)[:4000], 1, 5, None))
    B.append(("b13", "unicode", DEF, "ب" + ("ً" * 30 + "‌") * 30 + "ب", 1, 5, None))
    B.append(("b14", "unicode", DEF, ".".join(["א١"] * 120), 1, 5, None))
    B.append(("b15", "unicode", DEF, "각" * 450, 1, 5, None))
    B.append(("b16", "scripts", DEF, "".join(chr(c) for c in range(0x10000, 0x10000 + 1)) +
              "aаαאا中あア가ก" * 50000, 2, 10, None))
    B.append(("b17", "unicode", BIG, "a" + alt * 20000 + ".com", 1, 5, "P2-9"))
    B.append(("b18", "skeleton", DEF, "a" + alt * 50000, 1, 5, "P1-6"))
    B.append(("b19", "confusable", DEF, "a" + alt * 30000, 1, 5, "P1-6"))
    B.append(("b20", "skeleton", DEF, "a" * 1000000, 2, 10, None))
    return B


def write(outdir):
    os.makedirs(outdir, exist_ok=True)
    out = []
    for b in bombs():
        path = os.path.join(outdir, b[0] + ".bomb")
        with open(path, "w") as f:
            f.write("%s\n%s\n%s\n" % (b[1], b[2], b[3].encode("utf-8").hex()))
        out.append((b, path))
    return out


RUNNER = r"""
import resource, subprocess, sys, time
t0 = time.perf_counter()
try:
    r = subprocess.run(sys.argv[2:], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=float(sys.argv[1]))
    dt = time.perf_counter() - t0
    rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    if sys.platform != "darwin":
        rss *= 1024
    out = r.stdout.decode(errors="replace").strip().split("\n")[-1] if r.stdout else ""
    print("%d\t%.3f\t%d\t%s\t%s" % (r.returncode, dt, rss, out, r.stderr.decode(errors="replace").strip()[:120]))
except subprocess.TimeoutExpired:
    print("TIMEOUT\t%.3f\t0\t\t" % (time.perf_counter() - t0))
"""


def run_one(cmd, timeout):
    r = subprocess.run([sys.executable, "-I", "-c", RUNNER, str(timeout)] + cmd, stdout=subprocess.PIPE)
    f = r.stdout.decode().rstrip("\n").split("\t")
    return f[0], float(f[1]), int(f[2]), f[3] if len(f) > 3 else "", f[4] if len(f) > 4 else ""


def main():
    outdir = sys.argv[1]
    items = write(outdir)
    if sys.argv[2] == "--list-only":
        print("  dos: %d bombs written to %s" % (len(items), outdir))
        return 0
    native = [sys.argv[2]]
    wasm = sys.argv[3].split()
    rc = 0
    openids = set()
    rss_budget = 512 * 1024 * 1024
    print("  %-4s %-11s %-10s %-24s %-24s %s" % ("id", "op", "bytes", "native rel (s / MiB)", "wasm32 rel (s / MiB)",
                                               "result"))
    for b, path in items:
        bid, op, lim, payload, nb, wb, fid = b
        res = []
        for cmd, budget in ((native, nb), (wasm, wb)):
            res.append(run_one(cmd + ["bomb", path], max(60, budget * 20)))
        (nrc, nt, nr, nout, nerr), (wrc, wt, wr, wout, werr) = res
        status = []
        if nrc != "0" or wrc != "0":
            status.append("CRASH/TIMEOUT native=%s wasm=%s %s %s" % (nrc, wrc, nerr, werr))
            if fid and (nrc == "TIMEOUT" or wrc == "TIMEOUT"):
                openids.add(fid)
            else:
                rc = 1
        elif nout != wout:
            status.append("DIVERGE native=%r wasm=%r" % (nout, wout))
            rc = 1
        over = nt > nb or wt > wb or nr > rss_budget or wr > rss_budget
        if over:
            if fid:
                openids.add(fid)
                status.append("OVER BUDGET (%s)" % fid)
            else:
                status.append("OVER BUDGET")
                rc = 1
        print("  %-4s %-11s %-10d %6.3f / %-15.1f %6.3f / %-15.1f %s %s" % (
            bid, op, len(payload.encode()), nt, nr / 1048576.0, wt, wr / 1048576.0, nout[:70], " ".join(status)))
    if openids:
        print("OPENIDS " + " ".join(sorted(openids)))
    return rc


if __name__ == "__main__":
    sys.exit(main())
