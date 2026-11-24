"""Comparators for packages/cookie/audit/run_audit.sh (stdlib only).

    compare.py same <a> <b>                         byte-identical outputs (4-mode determinism)
    compare.py spec <mode> <cases> <pion_out>       Pion vs the reference model (spec_ref.py); mode: parse|date|psl|match|jar
    compare.py rustparse <cases> <pion> <rust>      Pion vs Rust cookie =0.18.3 (information; classified)
    compare.py rustpsl <cases> <pion> <rust>        Pion vs Rust psl =2.1.261 on lower-case ASCII inputs
    compare.py testpsl <expect> <pion_out>          Pion vs Mozilla tests/test_psl.txt
    compare.py pslfile <psl_data.pion> <dat>        embedded table == pinned official list (rules, sections, order)

Exit status: 0 clean, 3 only divergences attributed to known findings, 1 unexplained divergence (P0).
The last line of `spec` output is `FINDINGS <ids>` (attributed findings), read by run_audit.sh.
Attribution: a divergent item (line, or jar scenario block) is attributed to the smallest set of finding emulation
flags (spec_ref.FLAG_IDS) under which the model reproduces the Pion output exactly; none -> unexplained. Items
reproduced only with "OK" flags (accepted fail-closed alternatives) are conforming and counted separately.
"""

import itertools
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import spec_ref  # noqa: E402

MODE_FLAGS = {
    "parse": ["samesite_keep", "path_keep", "format_nameless_raw", "format_nameless_always", "format_nameless_err"],
    "date": [],
    "psl": ["ip_trailing", "no_uts46", "uts46_subset", "reject_all_combining", "psl_reject_noncanonical",
            "psl_reject_long"],
    "match": ["url_backslash", "url_reject_backslash"],
    "jar": ["nameless_prefix", "secure_alone", "hostonly_identity", "xsite_set", "url_backslash", "samesite_keep",
            "lax_nonhttp", "path_keep", "domain_multidot", "url_reject_backslash"],
}


def lines(path):
    with open(path, "rb") as f:
        data = f.read().decode("utf-8", "surrogateescape")
    out = data.split("\n")
    if out and out[-1] == "":
        out.pop()
    return out


def model_line(mode, raw, flags):
    if mode == "parse":
        return spec_ref.parse_line(spec_ref.decode_input(raw), flags)
    if mode == "date":
        return spec_ref.date_line(spec_ref.decode_input(raw))
    if mode == "psl":
        return spec_ref.psl_line(spec_ref.decode_input(raw), flags)
    return spec_ref.match_line([spec_ref.decode_input(x) for x in raw.split("\t")], flags)


def attribute(fn, want, cand):
    """Smallest flag set (singles, pairs, triples, all) under which fn(flags) == want. Sets made only of accepted
    alternatives ("OK") are tried first, so a conforming fail-closed output is never charged to a finding."""
    ok = [f for f in cand if spec_ref.FLAG_IDS[f] == "OK"]
    for k in (1, 2):
        for combo in itertools.combinations(ok, k):
            if fn(set(combo)) == want:
                return combo
    for k in (1, 2, 3):
        for combo in itertools.combinations(cand, k):
            if fn(set(combo)) == want:
                return combo
    if len(cand) > 2 and fn(set(cand)) == want:
        return tuple(cand)
    return None


def jar_blocks(case_lines):
    blocks, cur = [], []
    for l in case_lines:
        if l.startswith("===") and cur:
            blocks.append(cur)
            cur = []
        cur.append(l)
    if cur:
        blocks.append(cur)
    return blocks


def normalize_pion_jar(out):
    """Sort dump lines inside each dump; OK0 / ERR:* -> NO (both mean 'not stored')."""
    res, i = [], 0
    while i < len(out):
        l = out[i]
        if l.startswith("set "):
            res.append("set OK1" if l == "set OK1" else "set NO")
            i += 1
        elif l.startswith("dump "):
            n = int(l.split()[1])
            res.append(l)
            res.extend(sorted(out[i + 1:i + 1 + n]))
            i += 1 + n
        else:
            res.append(l)
            i += 1
    return res


def cmd_spec(mode, cases_path, pion_path):
    cases, pion = lines(cases_path), lines(pion_path)
    found, unexplained, shown = {}, [], 0
    if mode == "jar":
        blocks = jar_blocks(cases)
        pout = normalize_pion_jar(pion)
        pos, nblocks, ndiv = 0, len(blocks), 0
        for b in blocks:
            ref = spec_ref.run_jar_block(b)
            got = pout[pos:pos + len(ref)]
            # dump lengths may differ: re-split on the next block header
            nxt = pos + 1
            while nxt < len(pout) and not pout[nxt].startswith("==="):
                nxt += 1
            got = pout[pos:nxt]
            pos = nxt
            if got == ref:
                continue
            ndiv += 1
            combo = attribute(lambda fl: spec_ref.run_jar_block(b, fl), got, MODE_FLAGS["jar"])
            if combo is None:
                unexplained.append((b[0], got, ref))
            else:
                key = tuple(sorted({spec_ref.FLAG_IDS[f] for f in combo} - {"OK"})) or ("accepted alternative",)
                found.setdefault(key, []).append(b[0])
        print("  [jar] %d scenario blocks, %d diverge from the model" % (nblocks, ndiv))
        for key, names in sorted(found.items()):
            print("    attributed to %s: %d blocks (e.g. %s)" % ("+".join(key), len(names), names[0][4:]))
        for name, got, ref in unexplained[:3]:
            print("    UNEXPLAINED %s" % name)
            for a, bb in itertools.zip_longest(got, ref, fillvalue="<missing>"):
                if a != bb:
                    print("      pion:  %s\n      model: %s" % (a[:200], bb[:200]))
                    break
    else:
        if len(cases) != len(pion):
            print("  [%s] line count differs: %d cases, %d outputs" % (mode, len(cases), len(pion)))
            return 1
        ndiv = 0
        for raw, got in zip(cases, pion):
            if mode in ("parse", "date") and got.startswith("ERR"):
                got = "ERR"  # the error variant is the package's choice
            if mode == "parse" and " F=ERR:" in got:
                got = re.sub(r" F=ERR:\w+", " F=ERR", got)
            ref = model_line(mode, raw, set())
            if got == ref:
                continue
            ndiv += 1
            combo = attribute(lambda fl: model_line(mode, raw, fl), got, MODE_FLAGS[mode])
            if combo is None:
                unexplained.append((raw, got, ref))
            else:
                key = tuple(sorted({spec_ref.FLAG_IDS[f] for f in combo} - {"OK"})) or ("accepted alternative",)
                found.setdefault(key, []).append(raw)
        print("  [%s] %d inputs, %d diverge from the model" % (mode, len(cases), ndiv))
        for key, raws in sorted(found.items()):
            print("    attributed to %s: %d (e.g. %s)" % ("+".join(key), len(raws), raws[0][:90]))
        for raw, got, ref in unexplained[:5]:
            print("    UNEXPLAINED %s\n      pion:  %s\n      model: %s" % (raw[:120], got[:200], ref[:200]))
    ids = sorted({i for key in found for i in key if i.startswith("P")})
    print("FINDINGS " + " ".join(ids))
    if unexplained:
        print("  %d unexplained divergences (P0)" % len(unexplained))
        return 1
    return 3 if ids else 0


def cmd_same(a, b):
    la, lb = lines(a), lines(b)
    if la == lb:
        return 0
    for i, (x, y) in enumerate(itertools.zip_longest(la, lb, fillvalue="<missing>")):
        if x != y:
            print("    first difference at line %d:\n      %s\n      %s" % (i + 1, x[:200], y[:200]))
            break
    return 1


# Rust cookie 0.18.3 is not an RFC 6265bis parser; a divergence where Pion equals the model is classified here.
def rust_class(raw, pion, rust):
    b = spec_ref.decode_input(raw)
    c = spec_ref.parse_set_cookie(b)
    if any(spec_ref._ctl(x) for x in b):
        return "cookie-rs accepts CTL bytes (§5.6 step 1 rejects)"
    if rust.startswith("ERR") and pion.startswith("OK"):
        return "cookie-rs rejects nameless cookies (§5.6 step 3 allows them)"
    if pion == "ERR" and rust.startswith("OK"):
        if c is None and len(b) > 4096:
            return "cookie-rs has no 4096-octet name+value limit"
        return "cookie-rs accepts an empty name and value"
    fp = dict(x.split("=", 1) for x in pion.split()[1:11])
    fr = dict(x.split("=", 1) for x in rust.split()[1:11])
    diff = sorted(k for k in fp if fp[k] != fr.get(k))
    reasons = []
    for k in diff:
        reasons.append({
            "n": "trim: cookie-rs trims all Unicode whitespace", "v": "trim: cookie-rs trims all Unicode whitespace",
            "m": "Max-Age: cookie-rs clamps negatives to 0, accepts '' as i64::MAX, keeps '+'-less parse",
            "e": "Expires: cookie-rs parses only 4 fixed formats (not the §5.1.1 algorithm)",
            "d": "Domain: cookie-rs keeps the raw value (no leading-dot strip, no 1024 limit)",
            "p": "Path: cookie-rs keeps any value (no '/' check, no 1024 limit)",
            "ss": "SameSite: cookie-rs ignores invalid values (§5.6.7 sets Default)",
            "s": "flag attribute", "h": "flag attribute", "pt": "flag attribute",
        }[k])
    return "; ".join(sorted(set(reasons))) or "other"


def cmd_rustparse(cases_path, pion_path, rust_path):
    cases, pion, rust = lines(cases_path), lines(pion_path), lines(rust_path)
    classes, same, bad = {}, 0, 0
    for raw, p, r in zip(cases, pion, rust):
        p0 = "ERR" if p.startswith("ERR") else p.split(" F=")[0]
        if p0 == r or (p0 == "ERR" and r.startswith("ERR")):
            same += 1
            continue
        model = spec_ref.parse_line(spec_ref.decode_input(raw)).split(" F=")[0]
        if p0 != model:
            bad += 1  # a Pion-vs-model divergence; reported (and attributed) by `spec parse`
            continue
        k = rust_class(raw, p0, r)
        classes.setdefault(k, []).append(raw)
    print("  [cookie 0.18.3] %d inputs: %d identical, %d differ where Pion == model, %d covered by the spec gate" % (
        len(cases), same, sum(len(v) for v in classes.values()), bad))
    for k, v in sorted(classes.items(), key=lambda kv: -len(kv[1])):
        print("    %5d  %s  (e.g. %s)" % (len(v), k[:110], v[0][:60]))
    return 0


_WILD = None


def nested_wildcard(d):
    """True when `d` lies under a wildcard rule `*.B` that has another wildcard rule `*.A` below it (A ends with
    ".B"): psl 2.1.261's generated matcher then returns a shorter suffix (ex.futurecms.at -> at,
    ap-north-1.r.cloud.int.apple -> int.apple) than the PSL algorithm."""
    global _WILD
    if _WILD is None:
        _WILD = {k[2:] for k in spec_ref.rules() if k.startswith("*.")}
    for b in _WILD:
        if d == b or d.endswith("." + b):
            if any(a != b and a.endswith("." + b) for a in _WILD):
                return True
    return False


def cmd_rustpsl(cases_path, pion_path, rust_path, newer):
    """Pion `ps` / `rd` vs psl 2.1.261 on inputs that are lower-case ASCII with no empty label / leading dot / IP."""
    cases, pion, rust = lines(cases_path), lines(pion_path), lines(rust_path)
    newer = set(newer)
    n, agree, snap, nest, bad, longref = 0, 0, 0, [], [], 0
    for raw, p, r in zip(cases, pion, rust):
        d = raw
        if raw.startswith("hex:") or not d or d != d.lower() or d.startswith(".") or d.endswith(".") or ".." in d \
                or spec_ref.is_ip_literal(d) or not all(c.isalnum() or c in "-._*!" for c in d):
            continue
        n += 1
        f = p.split("|")
        rs, rd, typ = r.split("|")
        if (f[0], f[2]) == (rs, rd):
            agree += 1
            continue
        labels = d.split(".")
        if f[0] == "-" and (len(d) > 253 or any(len(x) > 63 for x in labels)):
            longref += 1  # RFC 1035 limits: refusing the name is an accepted fail-closed choice
            continue
        hits = [x for x in newer if any(".".join(labels[i:]) == x.lstrip("*.").lstrip("!") for i in range(len(labels)))]
        if hits:
            snap += 1
        elif nested_wildcard(d) and f[0].endswith("." + rs):
            nest.append(d)
        else:
            bad.append((d, p, r))
    print("  [psl 2.1.261] %d ASCII inputs: %d identical, %d differ only by rules newer than the crate's list (%s)" % (
        n, agree, snap, ", ".join(sorted(newer))))
    print("    %d differ where psl 2.1.261 mis-handles a wildcard nested under a wildcard (oracle bug, e.g. %s: "
          "the PSL algorithm and Pion give the full name)" % (len(nest), nest[0] if nest else "-"))
    if longref:
        print("    %d names over 253 octets / labels over 63 octets refused by Pion (accepted alternative)" % longref)
    for d, p, r in bad[:5]:
        print("    UNEXPLAINED %s pion=%s rust=%s" % (d[:120], p[:120], r[:120]))
    return 1 if bad else 0


def cmd_testpsl(expect_path, pion_path):
    exp, pion = lines(expect_path), lines(pion_path)
    bad = 0
    for e, p in zip(exp, pion):
        got = p.split("|")[2]
        want = spec_ref.esc(spec_ref.decode_input(e)) if e != "-" else "-"
        if got != want:
            bad += 1
            print("    test_psl mismatch: expected %s, got %s" % (want, got))
    print("  [test_psl.txt] %d vectors, %d mismatches" % (len(exp), bad))
    return 1 if bad else 0


def cmd_pslfile(pion_src, dat):
    src = open(pion_src, encoding="utf-8").read()
    m = re.search(r'"(.*)"', src, re.S)
    lit = m.group(1).encode("utf-8").decode("unicode_escape")
    rows = [l.rsplit("\t", 1) for l in lit.split("\n") if l]
    names = [r[0] for r in rows]
    table = {r[0]: r[1] for r in rows}
    off = spec_ref.rules()
    ok = True
    print("  embedded: %d rules (%d ICANN, %d Private), %d bytes; official @pinned: %d rules" % (
        len(rows), sum(1 for r in rows if r[1] == "I"), sum(1 for r in rows if r[1] == "P"), len(lit.encode()), len(off)))
    if [n.encode() for n in names] != sorted(n.encode() for n in names) or len(set(names)) != len(names):
        print("  table is not strictly byte-sorted / unique (binary search precondition)")
        ok = False
    miss, extra = sorted(set(off) - set(table)), sorted(set(table) - set(off))
    wrong = sorted(k for k in off if k in table and table[k] != off[k])
    for what, xs in (("missing", miss), ("extra", extra), ("wrong section", wrong)):
        if xs:
            print("  %s: %d (e.g. %s)" % (what, len(xs), ", ".join(xs[:5])))
            ok = False
    if ok:
        print("  identical to the pinned official list (rules and ICANN/Private sections)")
    return 0 if ok else 3


def cmd_pslindex(index_src, data_src):
    """A generated node-flag index (src/psl_index.pion, added by the fix) must agree with the rule table: one entry per
    PSL node with flags 1/2 = ICANN/Private rule, 4/8 = ICANN/Private wildcard child, 16 = has children,
    32 = has an exception child. Exit 0 consistent, 1 inconsistent (P0), 2 absent / unknown format (information)."""
    if not os.path.exists(index_src):
        print("  no psl_index.pion (rule table only)")
        return 2
    src = open(index_src, encoding="utf-8").read()
    try:
        def lit(name):
            m = re.search(r"fn " + name + r'\(\) -> String \{\s*"(.*?)"\s*\}', src, re.S)
            return m.group(1).encode("utf-8").decode("unicode_escape")
        cnt = int(re.search(r"fn psl_node_count\(\) -> Int \{\s*(\d+)", src).group(1))
        data, offs = lit("psl_node_data"), lit("psl_node_offsets")
        dec6 = lambda c: ord(c) - 49 if ord(c) > 92 else ord(c) - 48
        u18 = lambda s, i: (dec6(s[3 * i]) << 12) | (dec6(s[3 * i + 1]) << 6) | dec6(s[3 * i + 2])
        nodes = {}
        for i in range(cnt):
            a, b = u18(offs, i), u18(offs, i + 1)
            nodes[data[a:b - 1]] = dec6(data[b - 1])
    except (AttributeError, IndexError, ValueError):
        print("  psl_index.pion has an unknown layout: correctness rests on the end-to-end model / test_psl gates")
        return 2
    plit = re.search(r'"(.*)"', open(data_src, encoding="utf-8").read(), re.S).group(1)
    R = {l.rsplit("\t", 1)[0]: l.rsplit("\t", 1)[1] for l in plit.encode("utf-8").decode("unicode_escape").split("\n") if l}
    D = {}

    def add(n, f=0):
        D[n] = D.get(n, 0) | f
    for r, sec in R.items():
        if r.startswith("!"):
            base = r[1:]
            add(base.split(".", 1)[1], 32)
        elif r.startswith("*."):
            base = r[2:]
            add(base, 4 if sec == "I" else 8)
        else:
            base = r
            add(base, 1 if sec == "I" else 2)
        labs = base.split(".")
        for i in range(len(labs)):
            add(".".join(labs[i:]))
    for n in list(D):
        if "." in n:
            add(n.split(".", 1)[1], 16)
    bad = [k for k in set(D) | set(nodes) if D.get(k, 0) != nodes.get(k, 0)]
    srt = [k.encode() for k in nodes] == sorted(k.encode() for k in nodes)
    print("  psl_index.pion: %d nodes, %s, %d disagree with the rule table%s" % (
        len(nodes), "byte-sorted" if srt else "NOT sorted", len(bad), (" (e.g. %s)" % ", ".join(sorted(bad)[:4])) if bad else ""))
    return 0 if (not bad and srt) else 1


def main():
    a = sys.argv[1:]
    if a[0] == "same":
        sys.exit(cmd_same(a[1], a[2]))
    if a[0] == "spec":
        sys.exit(cmd_spec(a[1], a[2], a[3]))
    if a[0] == "rustparse":
        sys.exit(cmd_rustparse(a[1], a[2], a[3]))
    if a[0] == "rustpsl":
        sys.exit(cmd_rustpsl(a[1], a[2], a[3], a[4:]))
    if a[0] == "testpsl":
        sys.exit(cmd_testpsl(a[1], a[2]))
    if a[0] == "pslindex":
        sys.exit(cmd_pslindex(a[1], a[2]))
    if a[0] == "pslfile":
        sys.exit(cmd_pslfile(a[1], a[2]))
    print("bad arguments")
    sys.exit(2)


if __name__ == "__main__":
    main()
