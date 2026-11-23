"""Differential report: pion vs monoid-login reference (URLs) and pion vs Go httpproxy (NO_PROXY).

usage: compare.py <corpus_dir> <pion_urls> <ref_urls> <pion_np> <go_np> [--show N]
Exits 0: differences are evidence for REPORT.md, not by themselves a failure.
Secret leakage IS checked: any pion redacted() containing a password (or, for non-ssh, a
username) of its own input, or any pion error echoing `userinfo@`, is listed under LEAK.
"""
import collections
import os
import sys
from urllib.parse import unquote

d, pu, ru, pn, gn = sys.argv[1:6]
show = int(sys.argv[sys.argv.index("--show") + 1]) if "--show" in sys.argv else 6

urls = [bytes.fromhex(x).decode("utf-8", "replace") for x in open(os.path.join(d, "urls.hex")).read().split("\n") if x]
P = open(pu).read().split("\n")[:-1]
R = open(ru).read().split("\n")[:-1]
assert len(urls) == len(P) == len(R), (len(urls), len(P), len(R))

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

cats = collections.defaultdict(list)
leaks = []
for raw, p, r in zip(urls, P, R):
    pf, rf = p.split("\t"), r.split("\t")
    u, pw = userinfo(raw)
    scheme = raw.split("://", 1)[0].lower() if "://" in raw else ""
    secrets = []
    if pw and len(unquote(pw)) >= 2:
        secrets.append(pw)
    if u and len(u) >= 2 and scheme != "ssh":
        secrets.append(u)
    shown = pf[5]
    if pf[0] == "ok":
        for s in secrets:
            if s in shown or (unquote(s) in shown and len(unquote(s)) >= 2):
                leaks.append((raw, shown))
                break
    elif u is not None and "@" in shown:
        # an error message that echoes `userinfo@` verbatim
        leaks.append((raw, shown))
    if pf[0] != rf[0]:
        cats[f"pion {pf[0]} / ref {rf[0]}"].append((raw, p, r))
    elif pf[0] == "ok":
        if pf[1:3] != rf[1:3]:
            cats["both ok: host/port differ"].append((raw, p, r))
        elif pf[3:5] != rf[3:5]:
            cats["both ok: credentials differ"].append((raw, p, r))
        elif pf[5] != rf[5]:
            cats["both ok: redacted() differs"].append((raw, p, r))
        else:
            cats["agree"].append(None)
    else:
        cats["both err"].append(None)

print(f"== proxy URL: pion vs monoid-login@886d08e ({len(urls)} URLs)")
for k in sorted(cats, key=lambda k: -len(cats[k])):
    print(f"  {len(cats[k]):6d}  {k}")
for k in sorted(cats):
    if k in ("agree", "both err"):
        continue
    print(f"-- {k}: first {show}")
    for raw, p, r in cats[k][:show]:
        print(f"   {raw!r}\n      pion: {p}\n      ref : {r}")
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
