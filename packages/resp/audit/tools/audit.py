#!/usr/bin/env python3
"""Runner and judge for the `packages/resp` red-team audit (zero third-party dependencies).

  audit.py run   --out DIR --mode NAME [--full] -- <probe command prefix...>
  audit.py judge --cases CASES_DIR --out OUT_DIR --modes m1,m2,... [--oracle ORACLE_DIR]

`run` executes every probe mode for one build mode (native/wasm x debug/release), one process per DoS
case, recording exit status, wall time and peak RSS. `judge` checks all outputs against the immutable
expectations under cases/, cross-checks the Rust oracle and an independent CRC16/keyHashSlot model,
verifies the four build modes are byte-identical, prints PASS/FAIL per check and exits 1 on any FAIL.
"""
import argparse
import ast
import hashlib
import os
import re
import struct
import subprocess
import sys
import time

DET_MODES = ["decode", "inline", "keys", "redirect", "slots"]
FUZZ_SMALL = ("1", "20000")
FUZZ_FULL = [("1", "300000"), ("7", "300000"), ("424242", "300000")]


def unescape(s):
    return ast.literal_eval("b'" + s.replace("'", "\\'") + "'")


def rows(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line and not line.startswith("#"):
                yield line.split("\t")


def exec_child(cmd, timeout):
    """Run cmd; return (rc, stdout, stderr, ms, maxrss_bytes). rc < 0 = signal, 124 = timeout."""
    t0 = time.monotonic()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
        return 124, out, err, int((time.monotonic() - t0) * 1000), 0
    return p.returncode, out, err, int((time.monotonic() - t0) * 1000), 0


def exec_rss(cmd, timeout):
    """Run cmd with wait4() to capture the child's own peak RSS (bytes)."""
    t0 = time.monotonic()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out = p.stdout.read()
    err = p.stderr.read()
    _, status, ru = os.wait4(p.pid, 0)
    p.returncode = os.waitstatus_to_exitcode(status)
    ms = int((time.monotonic() - t0) * 1000)
    rss = ru.ru_maxrss if sys.platform == "darwin" else ru.ru_maxrss * 1024
    return p.returncode, out, err, ms, rss


def cmd_run(a):
    os.makedirs(a.out, exist_ok=True)
    probe = a.probe
    hexdir = a.hexdir

    def save(name, data):
        with open(os.path.join(a.out, name), "wb") as f:
            f.write(data)

    for m in DET_MODES:
        rc, out, err, _, _ = exec_child(probe + [m, os.path.join(hexdir, m + ".hex.tsv")], 600)
        save(m + ".out", out)
        save(m + ".rc", b"%d\n%s" % (rc, err[:2000]))
    rk = os.path.join(hexdir, "keys_random.hex.tsv")
    if os.path.exists(rk):
        rc, out, err, _, _ = exec_child(probe + ["keys", rk], 600)
        save("keys_random.out", out)
    rc, out, err, _, _ = exec_child(probe + ["builtin"], 600)
    save("builtin.out", out)
    save("builtin.rc", b"%d\n%s" % (rc, err[:2000]))
    rc, out, err, _, _ = exec_child(probe + ["dos-list"], 60)
    ids = [x for x in out.decode().split("\n") if x]
    lines = []
    for i in ids:
        rc, out, err, ms, rss = exec_rss(probe + ["dos", i], 120)
        res = out.decode("utf-8", "replace").strip().split("\t", 1)
        res = res[1] if len(res) == 2 else ""
        first_err = err.decode("utf-8", "replace").strip().split("\n")[0] if err else ""
        lines.append("\t".join([i, str(rc), str(ms), str(rss), res, first_err]))
        print("    dos %-30s rc=%-4d %6d ms  %s" % (i, rc, ms, (res or first_err)[:70]), flush=True)
    save("dos.out", ("\n".join(lines) + "\n").encode())
    fuzz = FUZZ_FULL if a.full else [FUZZ_SMALL]
    flines = []
    for seed, iters in fuzz:
        rc, out, err, ms, _ = exec_child(probe + ["fuzz", os.path.join(hexdir, "decode.hex.tsv"), seed, iters], 1200)
        flines.append("%d\t%s\t%s" % (rc, out.decode("utf-8", "replace").strip().replace("\n", " || "),
                                       err.decode("utf-8", "replace").strip().split("\n")[0] if err else ""))
    save("fuzz.out", ("\n".join(flines) + "\n").encode())
    if a.full:
        cl = []
        for row in rows(os.path.join(a.cases, "complexity.tsv")):
            rc, out, err, ms, _ = exec_child(probe + ["cx", row[0]], 900)
            cl.append("%s\t%d\t%s" % (row[0], rc, out.decode().strip().split("\t", 1)[-1]))
            print("    cx  %-12s %s" % (row[0], cl[-1].split("\t", 2)[-1]), flush=True)
        save("cx.out", ("\n".join(cl) + "\n").encode())
        sl = []
        for n in ("100000", "1000000"):
            rc, out, err, ms, rss = exec_rss(probe + ["stress", n], 900)
            sl.append("%s\t%d\t%d\t%d\t%s" % (n, rc, ms, rss, out.decode().strip()))
            print("    stress %-8s rc=%d %d ms rss=%.2f MiB %s" % (n, rc, ms, rss / 1048576, out.decode().strip()), flush=True)
        save("stress.out", ("\n".join(sl) + "\n").encode())


# ---------------------------------------------------------------- judge helpers

def crc16_xmodem(data):
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def key_hash_slot(key):
    """Redis src/cluster.c keyHashSlot()."""
    s = key.find(b"{")
    if s != -1:
        e = key.find(b"}", s + 1)
        if e != -1 and e != s + 1:
            return crc16_xmodem(key[s + 1:e]) & 16383
    return crc16_xmodem(key) & 16383


def f_canon(m):
    v = float(m.group(1))
    if v != v:
        return "nan"
    return "0x%016x" % struct.unpack(">Q", struct.pack(">d", v))[0]


def norm_expect(e):
    return re.sub(r"F\(([^)]*)\)", f_canon, e)


def match_class(expect, got):
    """Decode/inline/redirect/slots expectation grammar."""
    expect = norm_expect(expect)
    if expect == "ERR|INC":
        return got == "INC" or got.startswith("ERR")
    if expect == "ERR":
        return got.startswith("ERR")
    if expect == "INC":
        return got == "INC"
    if expect == "OK":
        return got.startswith("OK")
    return got == expect


def match_pat(expect, got):
    if expect.startswith("="):
        return got == expect[1:]
    if expect.startswith("~"):
        return re.search(expect[1:], got) is not None
    return got == expect


def klass(r):
    return "OK" if r.startswith("OK") else ("INC" if r == "INC" else ("ERR" if r.startswith("ERR") else r))


class Judge:
    def __init__(self):
        self.results = []  # (section, id, finding, ok, detail)

    def add(self, section, cid, finding, ok, detail):
        self.results.append((section, cid, finding, ok, detail))


def read_out(path):
    d = {}
    if not os.path.exists(path):
        return d
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if "\t" in line:
                k, v = line.split("\t", 1)
                d[k] = v
    return d


def cmd_judge(a):
    J = Judge()
    modes = a.modes.split(",")
    primary = modes[0]
    P = lambda m, n: os.path.join(a.out, m, n)  # noqa: E731

    # ---- per-mode process health (every mode)
    for m in modes:
        for n in DET_MODES + ["builtin"]:
            rcp = P(m, n + ".rc")
            rc = open(rcp).read().split("\n", 1) if os.path.exists(rcp) else ["missing", ""]
            J.add("health", "%s:%s" % (m, n), "-", rc[0] == "0", "exit=%s %s" % (rc[0], rc[1][:160].strip()))

    # ---- decode differential (primary mode values; split consistency in every mode)
    oracle = read_out(os.path.join(a.oracle, "decode.oracle")) if a.oracle else {}
    pd = read_out(P(primary, "decode.out"))
    diverge = []
    for r in rows(os.path.join(a.cases, "decode.tsv")):
        cid, finding, _inp, expect = r[0], r[1], r[2], r[3]
        got = pd.get(cid, "MISSING\tMISSING\tMISSING").split("\t")
        ok = match_class(expect, got[0])
        J.add("decode", cid, finding, ok, "expect=%s got=%s" % (norm_expect(expect), got[0]))
        for m in modes:
            g = read_out(P(m, "decode.out")).get(cid, "\t\tMISSING").split("\t")
            J.add("split", "%s:%s" % (m, cid), "-", len(g) > 2 and g[2] == "ok", g[2] if len(g) > 2 else "MISSING")
        if oracle:
            o = oracle.get(cid, "MISSING")
            pk, ok_ = klass(got[1]), klass(o)
            same = (pk == ok_) and (pk != "OK" or got[1] == o)
            if not same:
                diverge.append((cid, got[1], o))

    # ---- inline (sdssplitargs)
    pi = read_out(P(primary, "inline.out"))
    for r in rows(os.path.join(a.cases, "inline.tsv")):
        got = pi.get(r[0], "MISSING")
        J.add("inline", r[0], r[1], match_class(r[3], got), "expect=%s got=%s" % (r[3], got))

    # ---- key_slot: Pion vs independent model vs Rust redis_keyslot
    pk = read_out(P(primary, "keys.out"))
    ok_keys = read_out(os.path.join(a.oracle, "keys.oracle")) if a.oracle else {}
    for r in rows(os.path.join(a.cases, "keys.tsv")):
        key = unescape(r[1] if len(r) > 1 else "")
        model = str(key_hash_slot(key))
        got = pk.get(r[0], "MISSING")
        rust = ok_keys.get(r[0], "n/a")
        ok = got == model and (rust in ("n/a", model))
        J.add("key_slot", r[0], "-", ok, "pion=%s model=%s rust=%s" % (got, model, rust))
    # bulk random keys (deterministic): Pion vs model
    rk = read_out(P(primary, "keys_random.out"))
    if rk:
        bad = 0
        for r in rows(os.path.join(a.hexdir, "keys_random.hex.tsv")):
            if rk.get(r[0]) != str(key_hash_slot(bytes.fromhex(r[1]))):
                bad += 1
        rr = read_out(os.path.join(a.oracle, "keys_random.oracle")) if a.oracle else {}
        bad_r = sum(1 for k, v in rk.items() if rr and rr.get(k) != v)
        J.add("key_slot", "random_%d_keys" % len(rk), "-", bad == 0 and bad_r == 0,
              "mismatch_vs_model=%d mismatch_vs_rust=%d" % (bad, bad_r))

    # ---- redirect / slots
    for sec, fname in (("redirect", "redirect"), ("cluster_slots", "slots")):
        po = read_out(P(primary, fname + ".out"))
        for r in rows(os.path.join(a.cases, fname + ".tsv")):
            got = po.get(r[0], "MISSING")
            if sec == "cluster_slots" and r[3] == "ERR":
                ok = got.startswith("ERR")
            else:
                ok = got == r[3]
            J.add(sec, r[0], r[1], ok, "expect=%s got=%s" % (r[3][:90], got[:160]))

    # ---- builtin
    pb = read_out(P(primary, "builtin.out"))
    for r in rows(os.path.join(a.cases, "builtin.tsv")):
        got = pb.get(r[0], "MISSING")
        J.add("builtin", r[0], r[1], match_pat(r[2], got), "expect=%s got=%s" % (r[2][:100], got[:160]))

    # ---- DoS (every mode: exit status + result; time budget on native release only)
    dexp = {r[0]: r for r in rows(os.path.join(a.cases, "dos.tsv"))}
    for m in modes:
        seen = set()
        path = P(m, "dos.out")
        lines = open(path).read().strip().split("\n") if os.path.exists(path) else []
        for line in lines:
            f = line.split("\t")
            while len(f) < 6:
                f.append("")
            cid, rc, ms, rss, res, err = f[:6]
            seen.add(cid)
            e = dexp.get(cid)
            if e is None:
                J.add("dos", "%s:%s" % (m, cid), "-", False, "no expectation")
                continue
            ok = rc == "0" and match_pat(e[2], res)
            budget = ""
            if m == "native_rel" and ok and int(ms) > int(e[3]):
                ok = False
                budget = " over budget %sms" % e[3]
            J.add("dos", "%s:%s" % (m, cid), e[1], ok,
                  "exit=%s %sms rss=%.1fMiB got=%s%s" % (rc, ms, int(rss or 0) / 1048576, (res or err)[:110], budget))
        for cid in dexp:
            if cid not in seen:
                J.add("dos", "%s:%s" % (m, cid), dexp[cid][1], False, "case not run")

    # ---- fuzz
    for m in modes:
        path = P(m, "fuzz.out")
        for line in (open(path).read().strip().split("\n") if os.path.exists(path) else ["missing"]):
            f = line.split("\t")
            ok = f[0] == "0" and "split_mismatch=0" in line
            J.add("fuzz", m, "-", ok, line[:200])

    # ---- complexity + stress (native release, full run)
    cxp = P(primary, "cx.out")
    if os.path.exists(cxp):
        cexp = {r[0]: r for r in rows(os.path.join(a.cases, "complexity.tsv"))}
        for line in open(cxp).read().strip().split("\n"):
            cid, rc, rest = line.split("\t", 2)
            mw = re.search(r"whole_ms=(\d+) chunk_ms=(\d+)", rest)
            e = cexp[cid]
            if rc != "0" or not mw:
                J.add("complexity", cid, e[1], False, "exit=%s %s" % (rc, rest))
                continue
            w, c = int(mw.group(1)), int(mw.group(2))
            lim = int(e[2]) * w + int(e[3])
            J.add("complexity", cid, e[1], c <= lim,
                  "whole=%dms chunked(1KiB)=%dms limit=%dms ratio=%.0fx" % (w, c, lim, c / max(w, 1)))
    stp = P(primary, "stress.out")
    if os.path.exists(stp):
        st = [l.split("\t") for l in open(stp).read().strip().split("\n")]
        rss = {}
        for n, rc, ms, r, out in st:
            m1 = re.search(r"frames=(\d+)/(\d+) mismatched=(\d+).*maxcap=(\d+)", out)
            ok = rc == "0" and m1 and m1.group(1) == m1.group(2) and m1.group(3) == "0" and int(m1.group(4)) <= 1 << 20
            rss[n] = int(r)
            J.add("stream_rss", "stress_%s" % n, "-", bool(ok),
                  "%sms peak_rss=%.2fMiB %s" % (ms, int(r) / 1048576, out))
        if "100000" in rss and "1000000" in rss:
            grow = rss["1000000"] - rss["100000"]
            J.add("stream_rss", "rss_growth_100k_to_1m", "-", grow <= 4 << 20,
                  "delta=%.2fMiB (limit 4MiB)" % (grow / 1048576))

    # ---- 4-mode byte-identical outputs
    for n in DET_MODES + ["builtin"]:
        hs = {}
        for m in modes:
            p = P(m, n + ".out")
            hs[m] = hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else "missing"
        J.add("4mode", n, "-", len(set(hs.values())) == 1 and "missing" not in hs.values(),
              " ".join("%s=%s" % (m, h[:12]) for m, h in hs.items()))
    dh = {}
    for m in modes:
        p = P(m, "dos.out")
        if os.path.exists(p):
            # compare id, exit status and result only (timings / RSS / messages legitimately differ)
            norm = "\n".join("\t".join([f.split("\t")[0], "0" if f.split("\t")[1] == "0" else "crash", f.split("\t")[4]])
                             for f in open(p).read().strip().split("\n"))
            dh[m] = hashlib.sha256(norm.encode()).hexdigest()
    J.add("4mode", "dos", "-", len(set(dh.values())) == 1 and len(dh) == len(modes),
          " ".join("%s=%s" % (m, h[:12]) for m, h in dh.items()))

    # ---- report
    sections = []
    for r in J.results:
        if r[0] not in sections:
            sections.append(r[0])
    fails = 0
    by_finding = {}
    for sec in sections:
        rs = [r for r in J.results if r[0] == sec]
        nf = sum(1 for r in rs if not r[3])
        print("\n== %s: %d checks, %d PASS, %d FAIL" % (sec, len(rs), len(rs) - nf, nf))
        for r in rs:
            if not r[3]:
                fails += 1
                by_finding.setdefault(r[2], []).append("%s/%s" % (sec, r[1]))
            if not r[3] or a.verbose:
                print("  %s  %-44s [%s] %s" % ("PASS" if r[3] else "FAIL", r[1], r[2], r[4]))
    if diverge:
        print("\n== oracle (redis-protocol 6.0.0) divergences: %d of decode cases (informational, see REPORT.md)" % len(diverge))
        for cid, p_, o in diverge:
            print("  INFO  %-24s pion=%-40s rust=%s" % (cid, p_[:40], o[:60]))
    print("\n== SUMMARY: %d checks, %d PASS, %d FAIL" % (len(J.results), len(J.results) - fails, fails))
    for fid in sorted(by_finding):
        print("  %-6s %3d failing check(s): %s" % (fid, len(by_finding[fid]), ", ".join(by_finding[fid][:6]) +
                                                  (" ..." if len(by_finding[fid]) > 6 else "")))
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--out", required=True)
    r.add_argument("--hexdir", required=True)
    r.add_argument("--cases", required=True)
    r.add_argument("--full", action="store_true")
    r.add_argument("probe", nargs=argparse.REMAINDER)
    j = sub.add_parser("judge")
    j.add_argument("--cases", required=True)
    j.add_argument("--out", required=True)
    j.add_argument("--modes", required=True)
    j.add_argument("--oracle", default="")
    j.add_argument("--hexdir", required=True)
    j.add_argument("--verbose", action="store_true")
    a = ap.parse_args()
    if a.cmd == "run":
        a.probe = [x for x in a.probe if x != "--"]
        cmd_run(a)
        return 0
    return cmd_judge(a)


if __name__ == "__main__":
    sys.exit(main())
