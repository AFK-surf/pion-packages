#!/usr/bin/env python3
"""Compare `key = value` dumps (stdlib only, run with `python3 -I`).

  compare.py same <a> <b>
      exit 1 unless the two files are byte-identical (4-mode determinism)
  compare.py case <name> <policy> <pion> <ttf> <skrifa> [<pion_bin> <oracle_bin> <font> <face>]
      one line per divergence group; exit 1 on an UNEXPLAINED divergence: a key where pion differs
      from an oracle and neither the case policy nor a documented oracle quirk (QUIRKS) covers it.
      With the binaries given, glyphs whose outline hashes differ are re-dumped in full and accepted
      when every coordinate is within 1/16 unit (pion computes composite transforms in f64,
      ttf-parser in f32).

Attribution order for a divergence on key-prefix P with oracle O:
  1. the case policy: `<id>:<prefix>` entries (`*` = every prefix, `glyph` = gbox/outl/geom,
     `<prefix>~1` = only integer vectors within +-1, used for P2-2 on real variable fonts)
  2. QUIRKS[O][P]: a documented, source-checked behaviour of that oracle. It is only accepted when the
     *other* oracle agrees with pion on that key, so one oracle's quirk can never hide a pion bug.
"""
import os
import subprocess
import sys
import tempfile

VERBOSE = os.environ.get("VERBOSE") == "1"

# Oracle quirks verified against the spec and the oracle sources (REPORT.md, "Oracle notes").
QUIRKS = {
    "ttf": {
        "name": "decodes no Mac Roman records, rejects lone surrogates (String::from_utf16), ignores 3/10",
        "geom": "wraps absolute coordinates at i16; no outline for a zero-area glyph",
        "outl": "wraps absolute coordinates at i16; no outline for a zero-area glyph; lone Close for empty contours",
        "cmap": "3/10 must be format 12/13; idRangeOffset glyphs cast to i16; stops at the first broken subtable",
        "axis": "fvar Fixed stored as f32; HIDDEN_AXIS read from bit 3 instead of bit 0; max clamped",
    },
    "skrifa": {
        "cmap": "prefers Symbol and remaps U+00xx -> U+F0xx; supports only formats 4/12/13 for code points",
        "geom": "rounds transformed composite points to integer units; anchor-point matching; drops empty contours",
        "gbox": "rejects odd-length short loca",
    },
}
GROUPS = {"glyph": ("gbox", "outl", "geom")}


def load(path):
    d = {}
    unsupported = set()
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    if "panicked at" in text or "pion panic" in text or "parse = " not in text:
        bad = [ln for ln in text.splitlines() if "panic" in ln or "index out of" in ln]
        d["<crashed>"] = (bad[0] if bad else (text.strip().splitlines() or ["empty output"])[-1])[:200]
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        if line.startswith("unsupported "):
            unsupported.add(line.split(" ", 1)[1])
            continue
        if " = " not in line:
            continue
        k, v = line.split(" = ", 1)
        if k.startswith("cmap ") and v == "0":
            continue  # Some(0) == unmapped (.notdef); the inconsistency itself is red-team case P2-4
        d[k] = v
    return d, unsupported


def prefix(k):
    return k.split(" ", 1)[0]


def within_one(a, b):
    """Comma-separated integer vectors that differ by at most 1 in every component."""
    try:
        x, y = [int(v) for v in a.split(",")], [int(v) for v in b.split(",")]
    except ValueError:
        return False
    return len(x) == len(y) and all(abs(i - j) <= 1 for i, j in zip(x, y))


def policy_covers(policy, p, pv="", ov=""):
    """`id:prefix` covers every value; `id:prefix~1` only integer vectors within +-1 of the oracle."""
    if policy in ("", "same"):
        return None
    for ent in policy.split(","):
        if ":" not in ent:
            continue
        ident, pre = ent.split(":", 1)
        tol = pre.endswith("~1")
        pre = pre[:-2] if tol else pre
        if pre == "*" or p.startswith(pre) or p in GROUPS.get(pre, ()):
            if tol and not within_one(pv, ov):
                continue
            return ident
    return None


def geom_points(v):
    return " ".join(x for x in v.split() if not x.startswith("c="))


def norm_full(v):
    """Tokens of a full outline with degenerate-contour noise removed (duplicate / leading Close)."""
    t = v.split()[1:]
    out = []
    for x in t:
        if x == "Z" and (not out or out[-1] == "Z"):
            continue
        out.append(x)
    return out


def within_q4(a, b):
    if len(a) != len(b):
        return False
    for x, y in zip(a, b):
        if x == y:
            continue
        try:
            if abs(int(x) - int(y)) > 1:
                return False
        except ValueError:
            return False
    return True


def redump(bins, gids):
    """{gid: (pion_full, ttf_full)} via the `glyph <gid>` query."""
    pion_bin, oracle_bin, font, face = bins
    with tempfile.NamedTemporaryFile("w", suffix=".q", delete=False) as q:
        for g in gids:
            q.write("glyph %s\n" % g)
        qp = q.name
    try:
        a = subprocess.run(pion_bin.split() + ["dump", font, face, qp, "0"], capture_output=True, text=True, timeout=600).stdout
        b = subprocess.run([oracle_bin, "ttf", font, face, qp, "0"], capture_output=True, text=True, timeout=600).stdout
    finally:
        os.unlink(qp)
    pa = dict(ln.split(" = ", 1) for ln in a.splitlines() if ln.startswith("ofull "))
    pb = dict(ln.split(" = ", 1) for ln in b.splitlines() if ln.startswith("ofull "))
    return {g: (pa.get("ofull %s" % g, "none"), pb.get("ofull %s" % g, "none")) for g in gids}


def case(name, policy, pion_path, ttf_path, sk_path, bins=None):
    P, _ = load(pion_path)
    oracles = {"ttf": load(ttf_path), "skrifa": load(sk_path)}
    unexplained = []
    attributed = {}
    crashed = [o for o, (d, _) in oracles.items() if "<crashed>" in d]
    # glyphs whose outline differs from ttf-parser only by f32 rounding (<= 1/16 unit per coordinate)
    tolerant = set()
    T = oracles["ttf"][0]
    if bins and "ttf" not in crashed:
        gids = sorted({k.split(" ", 1)[1] for k in set(P) | set(T)
                       if prefix(k) in ("outl", "geom") and P.get(k) != T.get(k)}, key=int)[:200]
        if gids:
            for g, (a, b) in redump(bins, gids).items():
                if a != "none" and b != "none" and within_q4(norm_full(a), norm_full(b)):
                    tolerant.add(g)
    for oname, (O, unsup) in oracles.items():
        if oname in crashed:
            print("  ORACLE-CRASH %-23s %s: %s (oracle skipped for this case)" % (name, oname, O["<crashed>"]))
            continue
        other = "skrifa" if oname == "ttf" else "ttf"
        OO, ounsup = oracles[other]
        if other in crashed:
            OO = {}
        if (O.get("parse") == "err") != (P.get("parse") == "err"):
            key_set = {"parse", "ttc"}  # an oracle that cannot parse the face says nothing about its tables
        else:
            key_set = set(P) | set(O)
        for k in sorted(key_set):
            p = prefix(k)
            if p in unsup:
                continue
            pv, ov = P.get(k, "<absent>"), O.get(k, "<absent>")
            if pv == ov:
                continue
            gid = k.split(" ", 1)[1] if p in ("outl", "geom") else None
            ident = policy_covers(policy, p, pv, ov)
            if ident is None and gid in tolerant:
                ident = "f64-vs-f32-composite-rounding"
            if ident is None and p == "geom" and geom_points(pv) == geom_points(ov):
                ident = "degenerate-contour-count"
            if ident is None and p in QUIRKS.get(oname, {}) and OO.get("parse") == P.get("parse") and "parse" in OO:
                kk = ("geom " + gid) if (p == "outl" and p in ounsup) else k
                if prefix(kk) not in ounsup:
                    pk, ok = P.get(kk, "<absent>"), OO.get(kk, "<absent>")
                    if pk == ok or (prefix(kk) == "geom" and geom_points(pk) == geom_points(ok)):
                        ident = "quirk-%s-%s" % (oname, p)
            ex = "%s: %s pion=%s %s=%s" % (k, oname, pv[:90], oname, ov[:90])
            if ident is None:
                unexplained.append(ex)
            else:
                attributed.setdefault((ident, oname, p), []).append(ex)
    for (ident, oname, p), exs in sorted(attributed.items()):
        if not VERBOSE and (ident.startswith("quirk-") or ident in ("f64-vs-f32-composite-rounding", "degenerate-contour-count")):
            continue
        print("  ATTR %-28s %-30s %-6s %-5s %4d lines  e.g. %s" % (name, ident, oname, p, len(exs), exs[0][:150]))
    for ex in unexplained[:8]:
        print("  UNEXPLAINED %-24s %s" % (name, ex[:220]))
    if len(unexplained) > 8:
        print("  UNEXPLAINED %-24s ... %d more" % (name, len(unexplained) - 8))
    return 1 if unexplained else 0


def main():
    a = sys.argv[1:]
    if a[0] == "same":
        sys.exit(0 if open(a[1], "rb").read() == open(a[2], "rb").read() else 1)
    if a[0] == "case":
        bins = a[6:10] if len(a) >= 10 else None
        sys.exit(case(a[1], a[2], a[3], a[4], a[5], bins))
    sys.exit(2)


if __name__ == "__main__":
    main()
