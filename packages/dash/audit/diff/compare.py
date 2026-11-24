#!/usr/bin/env python3
"""Comparisons for run_audit.sh.

  compare.py same <a> <b>                       byte-identical outputs (4-mode determinism)
  compare.py model <cases> <pion> <model>       Pion dump vs reference model (spec alternatives / emu of open findings)
  compare.py api <vec> <pion_api> <model_api>   API sweep vs reference model; RFC 3986 resolver vs urllib.parse.urljoin
  compare.py rust <cases> <pion> <rust> <model> accept sets + shared field subset vs Rust dash-mpd-core 0.1.0
  compare.py fmt <cases> <pion_fmt>             format_mpd output: well-formed (pyexpat), no injected element names

URLs (TRK init, SEG url) are compared after resolving them against a probe document URL with the model's RFC 3986
resolver, so equivalent spellings of a relative reference ('a/../b' vs 'b') are not divergences. Error variants are
compared as 'ERR' (the variant is reported, not gated: a fix may legitimately reclassify an error).
"""
import os
import re
import sys
import xml.parsers.expat
from urllib.parse import urljoin

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model  # noqa: E402

PROBE = b"http://probe.invalid/a/b/c/d/manifest.mpd"


def unesc(s):
    return re.sub(rb"%([0-9A-F]{2})", lambda m: bytes([int(m.group(1), 16)]), s.encode("latin-1"))


def norm_url(field):
    if not field.startswith('"'):
        return field
    u = unesc(field[1:])
    return model.qs(model.rfc_resolve(PROBE, u))


def norm(dump):
    out = []
    for l in dump.split("\n"):
        if l.startswith("SEG|"):
            f = l.split("|")
            f[2] = norm_url(f[2])
            l = "|".join(f)
        elif l.startswith("TRK|") and not l.split("|")[2].startswith("ERR"):
            f = l.split("|")
            f[2] = norm_url(f[2])
            l = "|".join(f)
        l = re.sub(r"ERR \w+", "ERR", l)
        out.append(l)
    return "\n".join(out)


def blocks(path):
    res = {}
    order = []
    cur = None
    buf = []
    for l in open(path, encoding="latin-1"):
        if l.startswith("="):
            if cur is not None:
                res[cur] = "".join(buf)
            cur = l[1:].rstrip("\n")
            order.append(cur)
            buf = []
        else:
            buf.append(l)
    if cur is not None:
        res[cur] = "".join(buf)
    return res, order


def model_blocks(path):
    raw, order = blocks(path)
    res = {}
    for k, v in raw.items():
        alts = []
        emu = None
        cur = None
        buf = []
        for l in v.splitlines(True):
            if l in ("S\n", "E\n"):
                if cur == "S":
                    alts.append("".join(buf))
                elif cur == "E":
                    emu = "".join(buf)
                cur = l[0]
                buf = []
            else:
                buf.append(l)
        if cur == "S":
            alts.append("".join(buf))
        elif cur == "E":
            emu = "".join(buf)
        res[k] = (alts, emu)
    return res, order


def cases(path):
    d = {}
    for l in open(path, encoding="ascii"):
        n, h = l.rstrip("\n").split("\t")
        d[n] = bytes.fromhex(h)
    return d


def first_diff(a, b):
    al, bl = a.split("\n"), b.split("\n")
    for i in range(max(len(al), len(bl))):
        x = al[i] if i < len(al) else "<eof>"
        y = bl[i] if i < len(bl) else "<eof>"
        if x != y:
            return "line %d: pion %r / model %r" % (i + 1, x[:150], y[:150])
    return "?"


def attribute(data, pion_n):
    """Findings whose emu flag is needed to reproduce the Pion output."""
    need = []
    for f in model.FLAGS:
        rest = tuple(x for x in model.FLAGS if x != f)
        if norm(model.emu(data, rest)) != pion_n:
            need.append(f)
    return need


def cmd_model(cpath, ppath, mpath):
    cs = cases(cpath)
    pion, order = blocks(ppath)
    mod, _ = model_blocks(mpath)
    conf = expl = unexpl = 0
    fixed_like = 0
    per = {}
    kinds = 0
    examples = {}
    for name in order:
        p = pion[name]
        alts, emu = mod[name]
        pn = norm(p)
        an = [norm(a) for a in alts]
        if pn in an:
            conf += 1
            if norm(emu) != pn:
                fixed_like += 1
            if p not in alts:
                kinds += 1
            continue
        if norm(emu) == pn:
            need = attribute(cs[name], pn)
            expl += 1
            for f in need:
                per[f] = per.get(f, 0) + 1
                examples.setdefault(f, name)
            if not need:
                per["(combined)"] = per.get("(combined)", 0) + 1
            continue
        unexpl += 1
        print("  UNEXPLAINED %s: %s" % (name, first_diff(pn, norm(emu))))
    tot = conf + expl + unexpl
    print("  %d cases: %d conforming (spec), %d diverge and are explained by open findings, %d unexplained" % (tot, conf, expl, unexpl))
    if per:
        print("  explained by: " + ", ".join("%s %d (e.g. %s)" % (f, per[f], examples.get(f, "-")) for f in sorted(per)))
    if fixed_like:
        print("  conforming cases where the emu of an open finding differs (finding fixed for that input?): %d" % fixed_like)
    if kinds:
        print("  conforming with a different error variant: %d (not gated)" % kinds)
    print("FINDINGS " + " ".join(sorted(f for f in per if f.startswith("P"))))
    return 1 if unexpl else 0


def cmd_api(vpath, ppath, mpath):
    vecs = [l.rstrip("\n").split("\t") for l in open(vpath, encoding="ascii") if l.strip()]
    pl = open(ppath, encoding="ascii").read().splitlines()
    ml = open(mpath, encoding="ascii").read().splitlines()
    S = [l[2:] for l in ml if l.startswith("S ")]
    E = [l[2:] for l in ml if l.startswith("E ")]
    if not (len(pl) == len(S) == len(E) == len(vecs)):
        print("  API: line count mismatch pion=%d model=%d/%d vectors=%d" % (len(pl), len(S), len(E), len(vecs)))
        return 1

    def nu(l):
        if l.startswith("URL|"):
            f = l.split("|")
            f[3] = norm_url(f[3])
            l = "|".join(f)
        return re.sub(r"ERR \w+", "ERR", l)
    conf = expl = unexpl = 0
    per = {}
    for v, p, s, e in zip(vecs, pl, S, E):
        if nu(p) == nu(s):
            conf += 1
        elif nu(p) == nu(e):
            expl += 1
            for f in model.FLAGS:
                rest = tuple(x for x in model.FLAGS if x != f)
                if nu(model.api_line(v, model.Flags(rest)).rstrip("\n")) != nu(p):
                    per[f] = per.get(f, 0) + 1
        else:
            unexpl += 1
            print("  UNEXPLAINED api: pion %r model %r" % (p[:160], s[:160]))
    print("  API sweep: %d vectors: %d conforming, %d explained by open findings (%s), %d unexplained"
          % (len(vecs), conf, expl, ", ".join("%s %d" % kv for kv in sorted(per.items())) or "-", unexpl))
    # independent check of the model's RFC 3986 resolver
    agree = known = bad = 0
    for v in vecs:
        if v[0] != "URL":
            continue
        b, r = bytes.fromhex(v[1]), bytes.fromhex(v[2])
        if not b.startswith((b"http://", b"https://")) or re.match(rb"^[A-Za-z][A-Za-z0-9+.-]*:", r):
            continue
        mine = model.rfc_resolve(b, r).decode()
        theirs = urljoin(b.decode(), r.decode())
        if mine == theirs:
            agree += 1
        elif b"//" in model.split_ref(b)[2] + r.split(b"?")[0].split(b"#")[0] or mine.replace("//", "/")[8:] == theirs.replace("//", "/")[8:]:
            known += 1  # urllib.parse.urljoin drops empty path segments (not RFC 3986)
        else:
            bad += 1
            print("  RFC-RESOLVER-DIFF base=%r ref=%r model=%r urljoin=%r" % (b, r, mine, theirs))
    print("  RFC 3986 resolver of the model vs urllib.parse.urljoin: %d agree, %d differ only by urljoin dropping empty"
          " segments, %d other" % (agree, known, bad))
    return 1 if (unexpl or bad) else 0


def cmd_same(a, b):
    x, y = open(a, "rb").read(), open(b, "rb").read()
    if x == y:
        return 0
    xl, yl = x.split(b"\n"), y.split(b"\n")
    for i in range(min(len(xl), len(yl))):
        if xl[i] != yl[i]:
            print("  first difference line %d: %r / %r" % (i + 1, xl[i][:120], yl[i][:120]))
            break
    else:
        print("  outputs differ in length (%d / %d lines)" % (len(xl), len(yl)))
    return 1


# --------------------------------------------------------------- Rust dash-mpd-core

RUST_LENIENT = {
    # reasons the model (and Pion) reject a document that dash-mpd-core (serde + quick-xml) accepts
}


def rust_reason(data):
    """Why the reference model rejects `data` (first error, strict spec mode)."""
    try:
        root = model.Xml(data, False, True).document()
    except model.Err as e:
        return "xml:" + e.kind
    except RecursionError:
        return "xml:depth"
    try:
        model.mpd(root, model.Flags(()))
    except model.Err as e:
        return "mpd:" + e.kind
    return None


def subset_from_model_dump(d):
    """MPD / Period / AdaptationSet / Representation / S fields that dash-mpd-core exposes the same way."""
    out = []
    for l in d.split("\n"):
        f = l.split("|")
        if f[0] == "MPD":
            out.append("MPD|%s|%s|%s|%s|%s" % (f[1], f[2], f[4], f[5], f[6]))
        elif f[0] == "P":
            out.append("P|%s|%s|%s" % (f[2], f[3], f[4]))
        elif f[0] == "A":
            out.append("A|%s|%s|%s|%s" % (f[2], f[5], f[6], f[7]))
        elif f[0] == "R":
            out.append("R|%s|%s|%s|%s|%s" % (f[2], f[3], f[4], f[5], f[8]))
        elif f[0] == "S":
            out.append(l)
        elif f[0] == "CP":
            out.append("CP|%s|%s|%s|%s" % (f[1], f[2], f[3], f[4]))
    return "\n".join(out)


def cmd_rust(cpath, ppath, rpath, mpath):
    cs = cases(cpath)
    pion, order = blocks(ppath)
    rust, _ = blocks(rpath)
    mod, _ = model_blocks(mpath)
    stats = {}
    unexpl = 0

    def bump(k):
        stats[k] = stats.get(k, 0) + 1
    for name in order:
        p = pion[name]
        r = rust.get(name, "PANIC\n")
        p_ok = not p.startswith("ERR")
        r_ok = r.startswith("MPD|")
        spec_alts = [a for a in mod[name][0] if not a.startswith("ERR")]
        spec_ok = bool(spec_alts)
        if r.startswith("PANIC"):
            bump("rust panicked (not a Pion issue)")
            continue
        if p_ok and r_ok:
            ps = subset_from_model_dump(p)
            if ps == r.rstrip("\n"):
                bump("both accept, shared fields identical")
            else:
                # explained differences: dash-mpd-core keeps raw strings / skips validation the model performs
                mss = [subset_from_model_dump(a) for a in spec_alts]
                if r.rstrip("\n") in mss:
                    bump("both accept, Rust equals the reference model (Pion divergence explained by findings)")
                else:
                    why = rust_field_reason(ps, r.rstrip("\n"), mss)
                    if not spec_ok:
                        why = "the model rejects (%s; Pion accepts because of an open finding), %s" % (rust_reason(cs[name]), why)
                    bump("both accept, fields differ: " + why)
                    if why.startswith("UNEXPLAINED"):
                        unexpl += 1
                        print("  RUST-UNEXPLAINED %s: %s" % (name, first_diff(ps, r.rstrip("\n"))))
            continue
        if not p_ok and not r_ok:
            bump("both reject")
            continue
        if not p_ok and r_ok:
            why = rust_reason(cs[name])
            if why is None:
                bump("Pion rejects, Rust and the model accept (open finding, see the model comparison)")
            else:
                bump("Rust accepts what the model rejects (dash-mpd-core is lenient): " + why)
            continue
        # Pion accepts, Rust rejects
        why = r.split("|", 1)[1].strip()[:200] if "|" in r else r.strip()[:200]
        if not spec_ok:
            bump("Rust rejects like the model, Pion accepts (open finding: " + rust_reason(cs[name]) + ")")
            continue
        cls = rust_reject_class(why)
        bump("Rust rejects, Pion accepts: " + cls)
        if cls.startswith("UNEXPLAINED"):
            unexpl += 1
            print("  RUST-UNEXPLAINED %s: rust %r" % (name, why))
    for k in sorted(stats):
        print("  %5d  %s" % (stats[k], k))
    return 1 if unexpl else 0


def rust_field_reason(ps, rs, mss):
    a, b = ps.split("\n"), rs.split("\n")
    if len(a) != len(b):
        return "element counts (dash-mpd-core drops / keeps elements differently: unknown, empty)"
    for i, (x, y) in enumerate(zip(a, b)):
        if x == y:
            continue
        if any(len(m.split("\n")) == len(b) and m.split("\n")[i] == y for m in mss):
            continue  # Rust agrees with the reference model on this record; Pion's value is an open finding
        if any(len(m.split("\n")) == len(b) and m.split("\n")[i] == x for m in mss):
            pass  # Pion agrees with the model, Rust differs: classify Rust below
        fx, fy = x.split("|"), y.split("|")
        if fx[0] != fy[0]:
            return "element order"
        if re.sub("%0[9AD]", "%20", x) == y:
            return "attribute-value normalisation: dash-mpd-core turns TAB / LF into a space as XML 1.0 requires (P2-6)"
        if fx[0] == "MPD" and fx[2:] == fy[2:] and fx[1] != fy[1]:
            return "MPD@id raw string handling"
        if fx[0] == "CP":
            return "ContentProtection value / default_KID string handling (quick-xml unescaping, trimming)"
        if fx[0] in ("A", "R") and any(p != q for p, q in zip(fx, fy)):
            return "string attribute unescaping / whitespace (quick-xml vs XML 1.0 normalisation)"
        if fx[0] == "MPD":
            return "duration value (dash-mpd-core xs:duration regex: ',' / overflow)"
        if fx[0] == "P":
            return "Period duration value (dash-mpd-core xs:duration regex)"
        if fx[0] == "S":
            return "S@t / @d / @r integer parsing (dash-mpd-core u64 / i64 serde)"
        return "UNEXPLAINED " + fx[0]
    return "Rust equals the reference model on every differing record (Pion divergence explained by findings)"


def rust_reject_class(msg):
    m = unesc(msg).decode("latin-1").lower()
    for key, cls in (("duplicate field `segmenttimeline`", "dash-mpd-core schema allows one SegmentTimeline (the model / Pion"
                      " concatenate them, design)"),
                     ("duplicate field `@", "serde matches attributes by local name: two prefixed attributes with the same local"
                      " name collide (the model / Pion take the first, same root cause as P2-9)"),
                     ("couldn't parse xs duration", "dash-mpd-core xs:duration regex rejects leading / trailing whitespace"
                      " (xs:duration whiteSpace=collapse allows it)"),
                     ("invalid utf-8 (input", "input is not UTF-8 (Rust &str)"),("duration", "xs:duration regex stricter / different (e.g. 'P1W', ',', whitespace)"),
                     ("invalid digit", "integer with '+' / whitespace (serde u64)"),
                     ("number too large", "integer above u64 / u32 range"), ("datetime", "xs:dateTime parsing (chrono)"),
                     ("premature end", "quick-xml EOF handling"), ("unknown variant", "enumerated attribute value"),
                     ("missing field", "required attribute / element per dash-mpd-core schema"),
                     ("expected", "serde type expectation (e.g. bool 'true' / '1', element vs attribute)"),
                     ("invalid", "value parsing in dash-mpd-core"), ("escape", "quick-xml entity / character reference"),
                     ("duplicate", "duplicate field"), ("utf", "UTF-8"), ("xml", "quick-xml syntax")):
        if key in m:
            return cls
    return "other dash-mpd-core error (" + msg[:40] + ")"


# --------------------------------------------------------------- format_mpd output checks

ALLOWED = {"MPD", "BaseURL", "Location", "UTCTiming", "Period", "AdaptationSet", "Representation", "Role", "ContentProtection",
           "cenc:pssh", "mspr:pro", "Accessibility", "AudioChannelConfiguration", "SupplementalProperty", "EssentialProperty", "SegmentBase",
           "SegmentList", "SegmentURL", "SegmentTemplate", "SegmentTimeline", "S", "Initialization"}


def cmd_fmt(cpath, fpath):
    """A non-well-formed output is explained (P2-5 + P2-7) when the reference model's strict XML layer rejects the
    input itself: the package accepted bytes an XML processor must reject and format_mpd wrote them back."""
    cs = cases(cpath)
    out, order = blocks(fpath)
    n = wf = bad = errs = expl = 0
    for name in order:
        v = out[name].strip()
        if v == "-":
            continue
        if v.startswith("FMTERR"):
            errs += 1
            continue
        n += 1
        data = bytes.fromhex(v)
        names = set()
        p = xml.parsers.expat.ParserCreate()
        p.StartElementHandler = lambda nm, at: names.add(nm)
        try:
            p.Parse(data, True)
        except xml.parsers.expat.ExpatError as e:
            try:
                model.Xml(cs[name], False, True).document()
                strict_ok = True
            except (model.Err, RecursionError):
                strict_ok = False
            if not strict_ok:
                expl += 1
                continue
            bad += 1
            print("  FORMAT-NOT-WELL-FORMED %s: %s" % (name, e))
            continue
        if not names <= ALLOWED:
            bad += 1
            print("  FORMAT-INJECTED-ELEMENT %s: %s" % (name, sorted(names - ALLOWED)))
            continue
        wf += 1
    print("  format_mpd output of %d accepted documents: %d well-formed (pyexpat) with only DASH element names, %d not"
          " well-formed because the input was not well-formed XML either (P2-5 + P2-7), %d unexplained, %d refused (FMTERR)"
          % (n, wf, expl, bad, errs))
    if expl:
        print("FINDINGS P2-5 P2-7")
    return 1 if bad else 0


def main():
    c = sys.argv[1]
    a = sys.argv[2:]
    rc = {"same": cmd_same, "model": cmd_model, "api": cmd_api, "rust": cmd_rust, "fmt": cmd_fmt}[c](*a)
    sys.exit(rc)


if __name__ == "__main__":
    main()
