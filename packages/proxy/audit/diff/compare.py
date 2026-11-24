"""Differential & leak-check report: pion proxy URL redaction invariants and pion vs Go httpproxy (NO_PROXY).

usage: compare.py <corpus_dir> <pion_urls> <pion_np> <go_np> [--show N]
Exits 0: differences are evidence for REPORT.md, not by themselves a failure.
Secret leakage IS checked: any pion redacted() containing a password (or, for non-ssh, a
username) of its own input, or any pion error echoing `userinfo@`, is listed under LEAK.
"""
import collections
import os
import sys
from urllib.parse import unquote

d, pu, pn, gn = sys.argv[1:5]
show = int(sys.argv[sys.argv.index("--show") + 1]) if "--show" in sys.argv else 6

urls = [bytes.fromhex(x).decode("utf-8", "replace") for x in open(os.path.join(d, "urls.hex")).read().split("\n") if x]
P = open(pu).read().split("\n")[:-1]
assert len(urls) == len(P), (len(urls), len(P))

def userinfo(raw):
    i = raw.find("://")
    rest = raw[i + 3:] if i >= 0 else raw
    for c in "/?#":
        j = rest.find(c)
        if j >= 0:
            rest = rest[:j]
    k = rest.rfind("@")
    if k < 0:
        return None, None
    ui = rest[:k]
    if ":" in ui:
        a, b = ui.split(":", 1)
        return a, b
    return ui, None

cats = collections.Counter()
leaks = []
for raw, p in zip(urls, P):
    pf = p.split("\t")
    u, pw = userinfo(raw)
    scheme = raw.split("://", 1)[0].lower() if "://" in raw else ""
    secrets = []
    if pw and len(unquote(pw)) >= 2:
        secrets.append(pw)
    if u and len(u) >= 2 and scheme != "ssh":
        secrets.append(u)
    shown = pf[5]
    if pf[0] == "ok":
        cats["ok"] += 1
        for s in secrets:
            if s in shown or (unquote(s) in shown and len(unquote(s)) >= 2):
                leaks.append((raw, shown))
                break
    else:
        cats["err"] += 1
        if u is not None and "@" in shown:
            # an error message that echoes `userinfo@` verbatim
            leaks.append((raw, shown))

print(f"== proxy URL redaction audit ({len(urls)} URLs)")
for k, v in cats.most_common():
    print(f"  {v:6d}  {k}")
print(f"LEAK (pion output contains its own password / non-ssh username): {len(leaks)}")
for raw, shown in leaks[:show]:
    print(f"   {raw!r} -> {shown}")

rows = [x.split("\t") for x in open(os.path.join(d, "noproxy.tsv")).read().split("\n") if x]
PN = open(pn).read().split()
GN = open(gn).read().split()
assert len(rows) == len(PN) == len(GN)
diff = collections.Counter()
ex = collections.defaultdict(list)
loop = 0
for (rh, th, port), p, g in zip(rows, PN, GN):
    if g == "L":
        loop += 1
        continue
    if p != g:
        key = (bytes.fromhex(rh).decode(), bytes.fromhex(th).decode())
        tag = "pion bypass, go proxy" if p == "1" else "pion proxy, go bypass"
        diff[tag] += 1
        ex[tag].append(f"{key[0]!r} vs {key[1]!r}:{port}")
print(f"\n== NO_PROXY: pion vs golang.org/x/net/http/httpproxy v0.62.0 ({len(rows)} cases, {loop} loopback/localhost set aside)")
print(f"  agree={len(rows) - loop - sum(diff.values())} " + " ".join(f"[{k}]={v}" for k, v in diff.items()))
for k in ex:
    print(f"-- {k}: first {show * 4}")
    for e in ex[k][: show * 4]:
        print("   " + e)
