#!/usr/bin/env python3
"""Compare pion / miekg/dns / hickory-proto differential outputs.

Usage: python3 compare.py <out_dir> <cases_dir>
Reads <out_dir>/{pion_native,pion_wasm,go,rust}_<mode>.txt, prints a Markdown
summary to stdout (also written to <out_dir>/summary.md).
"""
import collections
import os
import sys


def load(path):
    d = {}
    if not os.path.exists(path):
        return d
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        parts = line.split("\t")
        if len(parts) >= 2:
            d[parts[0]] = parts[1:]
    return d


def verdict(v):
    return v[0] if v else "MISSING"


def kind(v):
    s = verdict(v)
    return s.split(" ", 1)[0]


def main():
    out, cases = sys.argv[1], sys.argv[2]
    lines = []
    w = lines.append
    # ---------------- native vs wasm32
    w("## Native vs Wasm32 (pion)\n")
    w("| mode | cases | identical | diffs | native traps/panics |")
    w("| --- | ---: | ---: | ---: | ---: |")
    for m in ("msg", "name", "ip6", "tcp", "doh"):
        n = load(os.path.join(out, f"pion_native_{m}.txt"))
        x = load(os.path.join(out, f"pion_wasm_{m}.txt"))
        total = sum(1 for _ in open(os.path.join(cases, f"{m}.tsv")))
        same = sum(1 for k in n if x.get(k) == n[k])
        w(f"| {m} | {total} | {same} | {total - same} | {total - len(n)} |")
    w("")
    # ---------------- msg differential
    P = load(os.path.join(out, "pion_native_msg.txt"))
    G = load(os.path.join(out, "go_msg.txt"))
    R = load(os.path.join(out, "rust_msg.txt"))
    ids = [l.split("\t", 1)[0] for l in open(os.path.join(cases, "msg.tsv"))]
    pat = collections.Counter()
    examples = collections.defaultdict(list)
    content_mismatch = collections.Counter()
    cm_examples = collections.defaultdict(list)
    for i in ids:
        p, g, r = kind(P.get(i)), kind(G.get(i)), kind(R.get(i))
        key = f"pion={p} miekg={g} hickory={r}"
        pat[key] += 1
        examples[key].append(i)
        if p == g == "OK" and verdict(P[i]) != verdict(G[i]):
            content_mismatch["pion!=miekg"] += 1
            cm_examples["pion!=miekg"].append(i)
        if p == r == "OK" and verdict(P[i]) != verdict(R[i]):
            content_mismatch["pion!=hickory"] += 1
            cm_examples["pion!=hickory"].append(i)
        if g == r == "OK" and verdict(G[i]) != verdict(R[i]):
            content_mismatch["miekg!=hickory"] += 1
            cm_examples["miekg!=hickory"].append(i)
    w(f"## Message decode differential ({len(ids)} cases)\n")
    w("| verdict pattern | cases | hand-crafted cases (all) / first mutants |")
    w("| --- | ---: | --- |")
    for key, n in pat.most_common():
        ex = examples[key]
        hand = [e[5:] for e in ex if e.startswith("hand_")]
        muts = [e for e in ex if not e.startswith("hand_")][:3]
        w(f"| `{key}` | {n} | {', '.join('`'+h+'`' for h in hand)}{' … ' if hand and muts else ''}{', '.join(muts)} |")
    w("")
    w("Decoded-content mismatches when both sides accept (owner/type/class/TTL/A/AAAA/NS/CNAME/PTR/MX):\n")
    for k in ("pion!=miekg", "pion!=hickory", "miekg!=hickory"):
        ex = cm_examples[k]
        w(f"- {k}: {content_mismatch[k]} (e.g. {', '.join(ex[:5])})")
    w("")
    # ---------------- own re-encode consistency
    w("## Re-encode self-consistency (decode -> encode -> own decode)\n")
    w("| impl | decoded OK | encode ERR | re-decode ERR |")
    w("| --- | ---: | ---: | ---: |")
    sizes = {}
    for name, D in (("pion", P), ("miekg", G), ("hickory", R)):
        ok = [i for i in ids if kind(D.get(i)) == "OK"]
        enc_err = [i for i in ok if len(D[i]) > 1 and D[i][1].startswith("enc=ERR")]
        rt_err = [i for i in ok if len(D[i]) > 1 and "rt=ERR" in D[i][1]]
        w(f"| {name} | {len(ok)} | {len(enc_err)} | {len(rt_err)} {('(' + ', '.join(rt_err[:4]) + ')') if rt_err else ''} |")
        sizes[name] = {i: int(D[i][1].split()[0][4:]) for i in ok if len(D[i]) > 1 and not D[i][1].startswith("enc=ERR")}
    common = [i for i in ids if all(i in sizes[n] for n in sizes)]
    if common:
        tot = {n: sum(sizes[n][i] for i in common) for n in sizes}
        bigger = {n: sum(1 for i in common if sizes[n][i] > min(sizes[m][i] for m in sizes)) for n in sizes}
        w("")
        w(f"Compressed re-encode size over {len(common)} messages all three accept: " + ", ".join(f"{n}={tot[n]} B (larger than best in {bigger[n]} msgs)" for n in sizes))
    w("")
    # ---------------- name / ip6
    for m, label in (("name", "Name::parse vs dns.IsDomainName+PackDomainName vs hickory Name::from_ascii (wire only)"), ("ip6", "Ipv6Addr::parse/to_string vs Go netip vs Rust std::net::Ipv6Addr")):
        P2 = load(os.path.join(out, f"pion_native_{m}.txt"))
        G2 = load(os.path.join(out, f"go_{m}.txt"))
        R2 = load(os.path.join(out, f"rust_{m}.txt"))
        cases_raw = {l.split("\t")[0]: bytes.fromhex(l.rstrip("\n").split("\t")[1]).decode("utf-8", "replace") for l in open(os.path.join(cases, f"{m}.tsv"))}
        def norm(v):
            if not v:
                return "MISSING"
            s = v[0]
            if m == "name" and s.startswith("OK "):
                return "OK " + s.split(" ")[1].lower()  # compare lowered wire only
            return s
        cnt = collections.Counter()
        ex = collections.defaultdict(list)
        for i in cases_raw:
            p, g, r = norm(P2.get(i)), norm(G2.get(i)), norm(R2.get(i))
            key = ("pion==go" if p == g else "pion!=go") + ", " + ("pion==rust" if p == r else "pion!=rust")
            cnt[key] += 1
            if p != g or p != r:
                ex[key].append((cases_raw[i], p, g, r))
        w(f"## {label}\n")
        for key, n in cnt.most_common():
            w(f"- `{key}`: {n}")
        w("")
        shown = 0
        w("| input | pion | Go | Rust |")
        w("| --- | --- | --- | --- |")
        for key in ex:
            for inp, p, g, r in ex[key][:12 if m == "ip6" else 8]:
                esc = lambda s: s.replace("|", "\\|").replace("\n", "\\n")[:70]
                w(f"| `{esc(repr(inp))}` | `{esc(p)}` | `{esc(g)}` | `{esc(r)}` |")
                shown += 1
        w("")
    text = "\n".join(lines)
    open(os.path.join(out, "summary.md"), "w").write(text)
    print(text)


if __name__ == "__main__":
    main()
