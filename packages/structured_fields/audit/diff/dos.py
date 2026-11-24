#!/usr/bin/env python3
"""RT-sfv DoS / complexity bombs. usage: dos.py <work_dir> <native_cmd> <wasm_cmd>
Each bomb is one field parsed + re-serialized by `sfv_audit bomb <type> <file> [limits]`; native --release and
wasm32 --release must print the same summary (minus time), finish within the budget (native 20 s / 1 GiB RSS,
wasm32 60 s) and never crash. Scaling pairs (n, 4n) must grow at most 8x in time (linear: ~4x, quadratic: 16x).
Prints OPENIDS <ids> for findings it reproduces (none are expected), exit 1 on any P0 condition."""
import os
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rss  # noqa: E402

work, native, wasm = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(work, exist_ok=True)
D = None  # default SfvLimits
BIG = ["67108864", "10000000", "10000000", "10000000", "10000000", "67108864", "268435456"]


def lim(out):
    return BIG[:6] + [str(out)]


B = []


def bomb(name, typ, data, limits, want):
    B.append((name, typ, data, limits, want))
    f = os.path.join(work, name + ".sf")
    with open(f, "wb") as o:  # written at once and dropped, so the parent stays small
        o.write(data)
    B[-1] = (name, typ, None, limits, want)


bomb("d01-sp-padding-item", "item", b" " * 65534 + b"1", D, "OK params=0 ser=1")
bomb("d02-list-1024", "list", b", ".join([b"a"] * 1024), D, "OK members=1024")
bomb("d03-list-1025", "list", b",".join([b"a"] * 1025), D, "ERR LimitExceeded")
bomb("d04-dict-dup-13k", "dictionary", b"a=1, " * 13000 + b"b", D, "OK members=2")
bomb("d05-param-dup-32k", "item", b"x" + b";a" * 32000, D, "OK params=1")
bomb("d06-empty-inner-1024", "list", b", ".join([b"()"] * 1024), D, "OK members=1024")
bomb("d07-string-16384", "item", b'"' + b"x" * 16384 + b'"', D, "OK params=0")
bomb("d08-string-16385", "item", b'"' + b"x" * 16385 + b'"', D, "ERR LimitExceeded")
bomb("d09-display-pct", "item", b'%"' + b"%c3%a9" * 10900 + b'"', D, "ERR LimitExceeded")
bomb("d10-binary-16384", "item", b":" + b"QUJD" * 5461 + b"QQ==:", D, "OK params=0")
bomb("d11-input-65537", "item", b" " * 65536 + b"1", D, "ERR LimitExceeded")
bomb("d12-dict-1024-inner-256", "dictionary", b"a=(" + b" ".join([b"1"] * 256) + b")", D, "OK members=1")
bomb("r01-dict-250k-keys", "dictionary", b", ".join(b"k%d=1" % i for i in range(250000)), BIG, "OK members=250000")
bomb("r02-dict-1m-keys", "dictionary", b", ".join(b"k%d=1" % i for i in range(1000000)), BIG, "OK members=1000000")
bomb("r03-dict-4m-dup", "dictionary", b"a=1, " * 4000000 + b"b", BIG, "OK members=2")
bomb("r04-params-250k", "item", b"x" + b"".join(b";k%d" % i for i in range(250000)), BIG, "OK params=250000")
bomb("r05-params-1m", "item", b"x" + b"".join(b";k%d" % i for i in range(1000000)), BIG, "OK params=1000000")
bomb("r06-params-4m-dup", "item", b"x" + b";a=1;b" * 2000000, BIG, "OK params=2")
bomb("r07-inner-2m", "list", b"(" + b" ".join([b"1"] * 2000000) + b")", BIG, "OK members=1")
bomb("r08-list-2m", "list", b", ".join([b"a"] * 2000000), BIG, "OK members=2000000")
bomb("r09-empty-inner-2m", "list", b", ".join([b"()"] * 2000000), BIG, "OK members=2000000")
bomb("r10-display-30m", "item", b'%"' + b"%c3%a9" * 5000000 + b'"', BIG, "OK params=0 ser=30000003")
bomb("r11-binary-30m", "item", b":" + b"QUJD" * 7500000 + b":", BIG, "OK params=0 ser=30000002")
bomb("r12-string-30m", "item", b'"' + b"\\\"" * 15000000 + b'"', BIG, "OK params=0 ser=30000002")
bomb("r13-ows-30m", "list", b"a" + b" \t" * 15000000 + b",b", BIG, "OK members=2 ser=4")
bomb("r14-token-30m", "item", b"a" * 30000000, BIG, "OK params=0 ser=30000000")
bomb("r15-numbers-1m", "list", b", ".join([b"-999999999999.999"] * 1000000), BIG, "OK members=1000000")
bomb("r16-out-limit-display", "item", b'%"' + b"%01" * 1000000 + b'"', lim(1000), "OK params=0 ser=LimitExceeded")
bomb("r17-out-limit-binary", "item", b":" + b"AAAA" * 1000000 + b":", lim(1000), "OK params=0 ser=LimitExceeded")
bomb("r18-out-limit-dict", "dictionary", b", ".join(b"k%d" % i for i in range(1000000)), lim(1000),
     "OK members=1000000 ser=LimitExceeded")
SCALE = [("r01-dict-250k-keys", "r02-dict-1m-keys"), ("r04-params-250k", "r05-params-1m")]


def run(cmd, f, typ, limits):
    out, rc, secs, peak = rss.run(shlex.split(cmd) + ["bomb", typ, f] + (limits or []))
    return out.strip(), rc, secs, peak


bad = 0
times = {}
print("  %-28s %-46s %9s %9s %9s" % ("bomb", "native --release summary", "native s", "RSS MiB", "wasm32 s"))
for name, typ, data, limits, want in B:
    f = os.path.join(work, name + ".sf")
    no, nrc, nt, nrss = run(native, f, typ, limits)
    wo, wrc, wt, _ = run(wasm, f, typ, limits)
    ns = no.rsplit(" us=", 1)[0]
    ws = wo.rsplit(" us=", 1)[0]
    times[name] = nt
    flag = ""
    if nrc != 0 or wrc != 0:
        flag = "CRASH native=%d wasm=%d (%s / %s)" % (nrc, wrc, no[-120:], wo[-120:])
    elif ns != ws:
        flag = "native / wasm32 differ: %s / %s" % (ns, ws)
    elif not ns.startswith(want):
        flag = "unexpected summary (want %s)" % want
    elif nt > 20 or wt > 60 or nrss > 1 << 30:
        flag = "over budget"
    if flag:
        bad += 1
    r = "%9.1f" % (nrss / 1048576) if nt >= 0.05 else "%9s" % "<sample"  # VmHWM sampler needs > ~1 ms of run time
    print("  %-28s %-46s %9.2f %s %9.2f %s" % (name, ns[:46], nt, r, wt, flag))
for a, b in SCALE:
    r = times[b] / max(times[a], 1e-3)
    ok = r <= 8
    if not ok:
        bad += 1
    print("  scaling %s -> %s (4x input): %.2fx time %s" % (a, b, r, "linear" if ok else "SUPERLINEAR"))
sys.exit(1 if bad else 0)
