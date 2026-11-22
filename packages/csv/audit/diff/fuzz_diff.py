#!/usr/bin/env python3
"""Large-scale differential fuzz: Pion `csv` (3 reader variants + 2 writer variants) vs Rust `csv =1.4.0`.

  python3 fuzz_diff.py [N_READ] [N_WRITE] [SEED] [OUTDIR]

Every case runs through:
  rust_ref                       (csv =1.4.0, StringRecord, reused)
  pion_cli read-bytes            (Reader::from_bytes_with_config, reused Record)
  pion_cli read-string           (Reader::from_string_with_config, reused Record -> exercises the fast path)
  pion_cli read-fresh            (from_string + next_record)
Writer cases: pion write / write-rec vs rust.

A divergence is split into
  content : headers / fields / error kinds differ           (what the program sees)
  pos     : only Position (byte/line/record) differs
  internal: two Pion variants disagree with each other   (a Pion bug whatever Rust does)
Root causes printed at the end map to REPORT.md ids (OTHER / POS-OTHER / INTERNAL-content = unexplained).
Divergent cases are greedily minimized (batched) and grouped; one line per group goes to the summary.
"""
import collections
import json
import os
import random
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import caseio  # noqa: E402

N_READ = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
N_WRITE = int(sys.argv[2]) if len(sys.argv) > 2 else 5000
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else 4180
OUT = sys.argv[4] if len(sys.argv) > 4 else "/tmp/pion-csv-audit/fuzz"
os.makedirs(OUT, exist_ok=True)
rng = random.Random(SEED)

DELIMS = [44, 59, 9, 124]
QUOTES = [34, 39]
TERMS = [-1, -2, 10, 13, 0x1E]
UTF8 = ["é", "中", "😀", "　", " ", " ", "\u0085"]
BAD = [b"\xff", b"\xc0\xaf", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"\x80", b"\xe2\x82", b"\xf0\x9f\x98"]


def rand_cfg():
    c = caseio.cfg()
    c["delim"] = rng.choice(DELIMS)
    c["quote"] = rng.choice(QUOTES)
    c["dq"] = rng.choice([1, 1, 0])
    c["esc"] = rng.choice([-1, -1, 92])
    c["cmt"] = rng.choice([-1, -1, 35])
    c["quoting"] = rng.choice([1, 1, 1, 0])
    c["trim"] = rng.choice([0, 0, 1, 2, 3])
    c["term"] = rng.choice(TERMS)
    c["hdr"] = rng.choice([0, 1])
    c["flex"] = rng.choice([1, 1, 0])
    c["style"] = rng.choice([0, 1, 2, 3])
    if rng.random() < 0.3:  # keep a good share on the default (fast-path) config
        c.update(delim=44, quote=34, dq=1, esc=-1, cmt=-1, quoting=1, trim=0, term=-1)
    return c


def rand_input(c, allow_bad):
    specials = [bytes([c["delim"]]), bytes([c["quote"]]), b"\n", b"\r", b"\r\n", b" ", b"\t", b"\x0b", b"\x0c"]
    if c["esc"] >= 0:
        specials.append(bytes([c["esc"]]))
    if c["cmt"] >= 0:
        specials += [bytes([c["cmt"]])] * 2
    if c["term"] >= 0:
        specials += [bytes([c["term"]])] * 2
    specials += [bytes([c["quote"]]) * 2, b"\xef\xbb\xbf"]
    words = [b"a", b"bc", b"1", b"-0.5", b"x y"] + [u.encode() for u in UTF8]
    out = []
    if rng.random() < 0.1:
        out.append(b"\xef\xbb\xbf")
    for _ in range(rng.randint(0, 24)):
        r = rng.random()
        if r < 0.45:
            out.append(rng.choice(specials))
        elif r < 0.93 or not allow_bad:
            out.append(rng.choice(words))
        else:
            out.append(rng.choice(BAD))
    return b"".join(out)


def rand_field():
    r = rng.random()
    if r < 0.15:
        return b""
    if r < 0.35:
        return rng.choice([b"1", b"-0.5", b"1e5", b"NaN", b"inf", b"0x10", b" 123", b"+7", b".5", b"5.", b"1_000",
                           b"Infinity", b"-inf", b"1.5", b"1e400", b"00", b"#x", b"\\", b"\\\""])
    chars = [b"a", b",", b";", b"\t", b"|", b'"', b"'", b"\n", b"\r", b"#", b"\\", b" ", b"\x1e", "é".encode()]
    return b"".join(rng.choice(chars) for _ in range(rng.randint(1, 6)))


def strip_pos(lines):
    out = []
    for ln in lines:
        if ln.startswith("P "):
            continue
        out.append(re.sub(r" @ .*$", "", ln))
    return out


def classify(r, p):
    if r == p:
        return None
    if strip_pos(r) != strip_pos(p):
        return "content"
    return "pos"


def run_all(lines, valid):
    """valid: dict id -> whether input is valid UTF-8 (string variants only make sense then)."""
    out = {"rust": caseio.rust(lines), "read-bytes": caseio.pion("read-bytes", lines)}
    ok_lines = [ln for ln in lines if valid[ln.split(" ", 1)[0]]]
    if ok_lines:
        out["read-string"] = caseio.pion("read-string", ok_lines)
        out["read-fresh"] = caseio.pion("read-fresh", ok_lines)
    return out


def signatures(cid, res):
    sig = set()
    r = res["rust"][cid]
    for v in ("read-bytes", "read-string", "read-fresh"):
        if v in res and cid in res[v]:
            k = classify(r, res[v][cid])
            if k:
                sig.add("%s:%s" % (v, k))
    pv = [res[v][cid] for v in ("read-bytes", "read-string", "read-fresh") if v in res and cid in res[v]]
    for a in pv[1:]:
        if strip_pos(a) != strip_pos(pv[0]) or a != pv[0]:
            sig.add("internal")
    return frozenset(sig)


def _terms(c):
    if c["term"] in (-1, -2):
        return {10, 13}
    return {c["term"]}


def _skippable(c, seg):
    """True if `seg` holds only what a reader skips before a record: BOM, terminators, comment lines."""
    if seg.startswith(b"\xef\xbb\xbf"):
        seg = seg[3:]
    i = 0
    while i < len(seg):
        if seg[i] in _terms(c):
            i += 1
        elif c["cmt"] >= 0 and seg[i] == c["cmt"]:
            while i < len(seg) and seg[i] not in _terms(c) and seg[i] != 10:
                i += 1
        else:
            return False
    return True


def pion_line_oracle(d, b):
    pre = d[:b]
    return 1 + pre.count(b"\r\n") + (pre.count(b"\r") - pre.count(b"\r\n")) + (pre.count(b"\n") - pre.count(b"\r\n"))


def classify_root(c, d, r, p):
    """Map one minimized divergence to a root cause id used in REPORT.md."""
    if strip_pos(r) == strip_pos(p):
        rp = [ln for ln in r if ln.startswith("P ")]
        pp = [ln for ln in p if ln.startswith("P ")]
        sem = len(rp) == len(pp)
        for a, b in zip(rp, pp):
            rb, rl, ri = map(int, a.split()[1:])
            pb, pl, pi = map(int, b.split()[1:])
            if ri != pi or rb > pb or not _skippable(c, d[rb:pb]):
                sem = False
            if rl != d[:rb].count(b"\n") + 1:
                sem = False
            if pl != pion_line_oracle(d, pb):
                sem = False
        return "D1-position-semantics" if sem else "POS-OTHER"
    if c["hdr"] == 0 and r and r[0].startswith("HE") and p and p[0].startswith("HE"):
        if len(r) > 1 and r[1].startswith("E") and (len(p) < 2 or not p[1].startswith("E")):
            return "F1-hdr0-first-row-error-dropped"
    if c["term"] == -2:
        return "D2-terminator-LF-is-CRLF"
    if c["cmt"] >= 0 and bytes([c["cmt"]]) in d:
        return "D3-comment-termination"
    if c["trim"] > 0:
        return "F6/D4-trim-semantics"
    return "OTHER"


def minimize(cases, sig_of):
    """cases: dict id -> (cfg, data, sig). Greedy batched reduction keeping the signature."""
    active = dict(cases)
    rounds = 0
    while active and rounds < 80:
        rounds += 1
        lines, valid, owner = [], {}, {}
        for cid, (c, data, sig) in active.items():
            cands = []
            n = len(data)
            for size in sorted({max(1, n // 2), max(1, n // 4), 2, 1}, reverse=True):
                for st in range(0, n, size):
                    cands.append((c, data[:st] + data[st + size:]))
            for k in caseio.KEYS:
                if c[k] != caseio.DEFAULT[k]:
                    c2 = dict(c)
                    c2[k] = caseio.DEFAULT[k]
                    cands.append((c2, data))
            for j, (c2, d2) in enumerate(cands):
                nid = "%s_%d" % (cid, j)
                lines.append(caseio.read_line(nid, c2, d2))
                valid[nid] = is_utf8(d2)
                owner[nid] = (cid, c2, d2)
        res = run_all(lines, valid)
        progressed = {}
        for nid, (cid, c2, d2) in owner.items():
            if cid in progressed:
                continue
            if sig_of(nid, res) == active[cid][2]:
                progressed[cid] = (c2, d2, active[cid][2])
        done = [cid for cid in active if cid not in progressed]
        for cid in done:
            cases[cid] = active.pop(cid)
        for cid, v in progressed.items():
            active[cid] = v
            cases[cid] = v
    return cases


def is_utf8(b):
    try:
        b.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def main():
    # ---------------- reader ----------------
    lines, valid, meta = [], {}, {}
    for i in range(N_READ):
        c = rand_cfg()
        d = rand_input(c, allow_bad=rng.random() < 0.15)
        cid = "r%d" % i
        lines.append(caseio.read_line(cid, c, d))
        valid[cid] = is_utf8(d)
        meta[cid] = (c, d)
    res = run_all(lines, valid)
    bad = {}
    sig_count = collections.Counter()
    for cid in meta:
        s = signatures(cid, res)
        if s:
            bad[cid] = (meta[cid][0], meta[cid][1], s)
            sig_count[s] += 1
    print("reader: %d cases, %d divergent" % (N_READ, len(bad)))
    for s, n in sig_count.most_common():
        print("  %6d  %s" % (n, " ".join(sorted(s))))
    # Residual check over ALL divergent cases (not just the minimized sample): neutralize the features
    # behind the known content root causes (trim -> None, comment -> None, LF -> CRLF, has_headers -> true
    # so F1 cannot fire) and re-run. Any content divergence left is unexplained.
    nl, nvalid = [], {}
    for cid, (c, d, sg) in bad.items():
        if not any(x.endswith(":content") for x in sg):
            continue
        c2 = dict(c, trim=0, cmt=-1, hdr=1, term=(-1 if c["term"] == -2 else c["term"]))
        nl.append(caseio.read_line(cid, c2, d))
        nvalid[cid] = valid[cid]
    if nl:
        nres = run_all(nl, nvalid)
        resid = [k for k in nres["rust"] if any(
            v in nres and k in nres[v] and strip_pos(nres[v][k]) != strip_pos(nres["rust"][k])
            for v in ("read-bytes", "read-string", "read-fresh"))]
        rc = collections.Counter()
        with open(os.path.join(OUT, "residual.txt"), "w") as f:
            for k in resid:
                r2, p2 = strip_pos(nres["rust"][k]), strip_pos(nres["read-bytes"][k])
                if r2 and r2[0].startswith("HE") and p2 and p2[0].startswith("HE"):
                    why = "F9-header-error-drops-length-check"
                elif any(x.startswith("E UL") for x in r2) and any(x.startswith("E U8") for x in p2):
                    why = "D7-error-precedence-UnequalLengths-vs-InvalidUtf8"
                else:
                    why = "UNEXPLAINED"
                rc[why] += 1
                f.write("%s <%s> %r\n  rust %s\n  pion %s\n" % (k, why, bad[k][1], nres["rust"][k], nres["read-bytes"][k]))
        print("  residual content divergences after neutralizing trim/comment/LF/has_headers: %d of %d" % (len(resid), len(nl)))
        for k, n in rc.most_common():
            print("  %6d  %s" % (n, k))
    # minimize up to 400 of them, preferring short ones and spreading over signatures
    pick = {}
    per_sig = collections.defaultdict(list)
    for cid, v in bad.items():
        per_sig[v[2]].append(cid)
    for s, ids in per_sig.items():
        ids.sort(key=lambda x: len(bad[x][1]))
        for cid in ids[:60]:
            pick[cid] = bad[cid]
    mini = minimize(dict(pick), signatures)
    groups = collections.defaultdict(list)
    for cid, (c, d, s) in mini.items():
        groups[(s, caseio.describe(c), d)].append(cid)
    # final evidence for every group
    lines2, valid2, keys = [], {}, []
    for gi, (k, ids) in enumerate(sorted(groups.items(), key=lambda kv: (len(kv[0][2]), kv[0][1]))):
        s, desc, d = k
        c = mini[ids[0]][0]
        gid = "g%d" % gi
        lines2.append(caseio.read_line(gid, c, d))
        valid2[gid] = is_utf8(d)
        keys.append((gid, k, len(ids)))
    res2 = run_all(lines2, valid2) if lines2 else {}
    report = []
    roots = collections.Counter()
    with open(os.path.join(OUT, "reader_divergences.txt"), "w") as f:
        for gid, (s, desc, d), n in keys:
            c = mini[groups[(s, desc, d)][0]][0]
            pv = "read-bytes"
            root = classify_root(c, d, res2["rust"][gid], res2[pv][gid])
            if "internal" in s:
                pv = [strip_pos(res2[v][gid]) for v in ("read-bytes", "read-string", "read-fresh") if v in res2 and gid in res2[v]]
                root = "F5-line-numbers-from_string-vs-from_bytes" if all(x == pv[0] for x in pv) else "INTERNAL-content"
            roots[root] += n
            f.write("=== %s  <%s>  [%s]  cfg: %s  input: %r  (%d fuzz hits)\n" % (gid, root, " ".join(sorted(s)), desc, d, n))
            for v in ("rust", "read-bytes", "read-string", "read-fresh"):
                if v in res2 and gid in res2[v]:
                    f.write("  %-12s %s\n" % (v, " | ".join(caseio.pretty(res2[v][gid]))))
            report.append({"root": root, "sig": sorted(s), "cfg": desc, "input": d.decode("latin-1"), "hits": n})
    with open(os.path.join(OUT, "reader_divergences.json"), "w") as f:
        json.dump(report, f, indent=1)
    print("  minimized groups: %d -> %s/reader_divergences.txt" % (len(keys), OUT))
    print("  root causes of the minimized sample (fuzz hits):")
    for k, n in roots.most_common():
        print("  %6d  %s" % (n, k))

    # ---------------- writer ----------------
    wl, wmeta = [], {}
    for i in range(N_WRITE):
        c = rand_cfg()
        nf = rng.randint(1, 4)  # zero-field records are a known, separately tested divergence (W1)
        recs = []
        for _ in range(rng.randint(1, 3)):
            k = nf if (not c["flex"] or rng.random() < 0.7) else rng.randint(1, 4)
            recs.append([rand_field() for _ in range(k)])
        cid = "w%d" % i
        wl.append(caseio.write_line(cid, c, recs))
        wmeta[cid] = (c, recs)
    wr = caseio.rust(wl)
    wp = caseio.pion("write", wl)
    wq = caseio.pion("write-rec", wl)
    wbad = collections.defaultdict(list)
    rust_specials = {b"NaN", b"nan", b"inf", b"-inf", b"+inf", b"Infinity", b"-Infinity", b"infinity", b"1e400"}
    for cid, (c, recs) in wmeta.items():
        if wp[cid] != wq[cid]:
            wbad["internal(write vs write-rec)"].append(cid)
        if wr[cid] != wp[cid]:
            if c["style"] == 3 and any(r == [b""] for r in recs):
                root = "F8-never-single-empty-field"
            elif c["style"] == 2 and any(f in rust_specials for r in recs for f in r):
                root = "F7-nonnumeric-nan-inf"
            else:
                root = "OTHER(" + caseio.STYLE[c["style"]] + ")"
            wbad[root].append(cid)
    print("writer: %d cases" % N_WRITE)
    with open(os.path.join(OUT, "writer_divergences.txt"), "w") as f:
        for k, ids in sorted(wbad.items()):
            print("  %6d  %s" % (len(ids), k))
            ids.sort(key=lambda x: len(wl[int(x[1:])]))
            for cid in ids[:25]:
                c, recs = wmeta[cid]
                f.write("=== %s [%s] cfg: %s records: %r\n" % (cid, k, caseio.describe(c), recs))
                f.write("  rust      %s\n" % " | ".join(caseio.pretty(wr[cid])))
                f.write("  write     %s\n" % " | ".join(caseio.pretty(wp[cid])))
                f.write("  write-rec %s\n" % " | ".join(caseio.pretty(wq[cid])))
    print("  details -> %s/writer_divergences.txt" % OUT)

    # ---------------- round trip: write with config X, read back with config X ----------------
    # Only lossless settings: Necessary/Always, double_quote on (escape-only output is lossy in Rust too).
    rl, rmeta = [], {}
    for cid, (c, recs) in wmeta.items():
        if c["style"] not in (0, 1) or not c["dq"] or not c["quoting"]:
            continue
        rc = dict(c, hdr=0, flex=1, trim=0, esc=-1)
        for who, res in (("pion", wp), ("rust", wr)):
            out = res[cid][0]
            if not out.startswith("W "):
                continue
            nid = "%s_%s" % (cid, who)
            rl.append(caseio.read_line(nid, rc, bytes.fromhex(out[2:])))
            rmeta[nid] = recs
    if rl:
        back_p = caseio.pion("read-bytes", rl)
        back_r = caseio.rust(rl)
        fails = collections.Counter()
        examples = []
        for nid, recs in rmeta.items():
            for reader, back in (("pion-reader", back_p), ("rust-reader", back_r)):
                got = [caseio.decode_fields(ln[2:]) for ln in back[nid] if ln.startswith("R ")]
                if got != recs:
                    who = nid.rsplit("_", 1)[1]
                    fails["%s-writer -> %s" % (who, reader)] += 1
                    if len(examples) < 30:
                        examples.append((nid, reader, recs, got))
        print("round trip (Necessary/Always, double_quote): %d written outputs re-read" % len(rl))
        for k in ("pion-writer -> pion-reader", "pion-writer -> rust-reader", "rust-writer -> rust-reader",
                  "rust-writer -> pion-reader"):
            print("  %6d  lossy: %s" % (fails[k], k))
        with open(os.path.join(OUT, "roundtrip_failures.txt"), "w") as f:
            for nid, reader, recs, got in examples:
                f.write("%s via %s: wrote %r read %r\n" % (nid, reader, recs, got))

    # ---------------- wasm32 vs native (same Pion driver, same cases) ----------------
    wasm = os.path.join(caseio.BIN, "pion_cli.wasm")
    rt = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
    if os.path.exists(wasm) and os.path.exists(rt):
        ok_lines = [ln for ln in lines if valid[ln.split(" ", 1)[0]]]
        for variant, ls in (("read-bytes", lines), ("read-string", ok_lines), ("read-fresh", ok_lines),
                            ("write", wl), ("write-rec", wl)):
            if not ls:
                continue
            nat = caseio.pion(variant, ls)
            was = caseio.run(["node", rt, wasm, variant], ls)
            diff = [k for k in nat if nat[k] != was.get(k)]
            print("wasm32 %-11s %6d cases: %s" % (variant, len(ls), "identical to native" if not diff else
                                                   "%d DIFFER, e.g. %s" % (len(diff), diff[:5])))
            if diff:
                with open(os.path.join(OUT, "wasm_divergences.txt"), "a") as f:
                    for k in diff[:50]:
                        f.write("=== %s %s\n  native %s\n  wasm   %s\n" % (variant, k, nat[k], was.get(k)))
    else:
        print("wasm32: skipped (build %s first)" % wasm)


if __name__ == "__main__":
    main()
