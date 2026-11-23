"""SVG DOM (XML well-formedness, entities, namespaces, style cascade) and `optimize_svg` semantic / safety audit.
Pion `parse_svg` / `extract_render_paths` / `optimize_svg` vs Rust roxmltree 0.20.0 (+ CPython expat for the
optimizer output), with SVG 2 / CSS expectations encoded per case."""
import os, re, sys, random
import xml.dom.minidom as minidom
sys.path.insert(0, os.path.dirname(__file__))
from common import run, f64, Ledger
from geom_check import reference

W = '<svg xmlns="http://www.w3.org/2000/svg">%s</svg>'

# (name, doc, roxmltree-must-agree?) — documents probing the XML layer
XML = [
    ("plain", W % '<path d="M0 0L1 1"/>', True),
    ("cdata", W % '<style><![CDATA[ a > b { fill: red } ]]></style>', True),
    ("comment", W % '<!-- c --><path d="M0 0"/>', True),
    ("pi", '<?xml version="1.0"?><?xml-stylesheet href="a.css"?>' + W % '', True),
    ("entities-basic", W % '<text x="&lt;&gt;&amp;&quot;&apos;">&lt;a&gt; &amp; b</text>', True),
    ("charref-ascii", W % '<text>&#65;&#x42;&#x0043;</text>', True),
    ("charref-latin1", W % '<text>caf&#233; &#xE9;</text>', True),
    ("charref-nbsp", W % '<text>a&#160;b</text>', True),
    ("charref-astral", W % '<text>&#x1F600;</text>', True),
    ("charref-attr", W % '<g aria-label="&#x2713; ok"/>', True),
    ("utf8-raw", W % '<text>café ✓ 😀</text>', True),
    ("unknown-entity", W % '<text>&nbsp;</text>', True),
    ("bare-amp", W % '<text>a & b</text>', True),
    ("lt-in-attr", W % '<g id="a<b"/>', True),
    ("dup-attr", W % '<g id="a" id="b"/>', True),
    ("no-ws-between-attrs", W % '<g id="a"class="b"/>', True),
    ("unquoted-attr", W % '<g id=a/>', True),
    ("mismatch-close", W % '<g></h>', True),
    ("close-with-space", W % '<g></ g>', True),
    ("two-roots", '<svg/><svg/>', True),
    ("text-after-root", '<svg/>junk', True),
    ("ns-prefix", '<svg:svg xmlns:svg="http://www.w3.org/2000/svg"><svg:path d="M0 0L10 10"/></svg:svg>', True),
    ("undeclared-prefix", '<svg><a:b/></svg>', True),
    ("self-closing-root", '<svg/>', True),
    ("bom", '﻿<svg/>', True),
    ("lt-bang-junk", '<svg><!foo></svg>', True),
    ("comment-double-dash", '<svg><!-- a -- b --></svg>', True),
    ("doctype-plain", '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">' + W % '', False),
    ("doctype-entity", '<!DOCTYPE svg [<!ENTITY ns "http://example.com">]>' + W % '<text>&ns;</text>', False),
    ("billion-laughs", '<!DOCTYPE lolz [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">'
     '<!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;"><!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">'
     '<!ENTITY lol5 "&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;"><!ENTITY lol6 "&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;">'
     '<!ENTITY lol7 "&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;"><!ENTITY lol8 "&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;">'
     '<!ENTITY lol9 "&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;">]><svg><text>&lol9;</text></svg>', False),
    ("xxe", '<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg><text>&x;</text></svg>', False),
]

# Optimizer semantic / safety cases: (name, doc)
OPT = [
    ("text-word-spaces", W % '<text x="0" y="10">Hello <tspan fill="red">World</tspan> again</text>'),
    ("tspan-ws-only-between", W % '<text><tspan>a</tspan> <tspan>b</tspan></text>'),
    ("xml-space-preserve", W % '<text xml:space="preserve">  two  spaces  </text>'),
    ("charref-text", W % '<text>caf&#233; &#160;&#x2713;</text>'),
    ("charref-attr", W % '<g aria-label="&#x2713; done"><path d="M0 0L1 1"/></g>'),
    ("switch-g", W % '<switch><g><rect width="5" height="5"/><circle r="3"/></g><g><rect width="9" height="9"/></g></switch>'),
    ("g-id", W % '<g id="keep"><path d="M0 0L1 1"/></g><use href="#keep"/>'),
    ("g-transform", W % '<g transform="translate(5 5)"><path d="M0 0L1 1"/></g>'),
    ("g-class", W % '<style>.c path{fill:red}</style><g class="c"><path d="M0 0L1 1"/></g>'),
    ("g-filter-empty", W % '<defs><filter id="f"><feFlood flood-color="red"/></filter></defs><g filter="url(#f)"/>'),
    ("g-clip", W % '<g clip-path="url(#c)"><path d="M0 0L1 1"/></g>'),
    ("xml-stylesheet-pi", '<?xml-stylesheet type="text/css" href="theme.css"?>' + W % '<path d="M0 0L1 1"/>'),
    ("attr-quotes", W % '<path d="M0 0L1 1" title=\'say "hi" &amp; &lt;bye&gt;\'/>'),
    ("attr-newline-tab", W % '<path d="M0 0L1 1" data-x="a&#10;b&#9;c"/>'),
    ("g-animate", W % '<g><animateTransform attributeName="transform" type="rotate" to="90"/><rect width="5" height="5"/></g>'),
    ("script-cdata", W % '<script><![CDATA[ if (a < b && c) { alert(1) } ]]></script>'),
    ("style-cdata", W % '<style><![CDATA[ a > b { fill: red } ]]></style>'),
    ("xss-attr", W % '<a href="javascript:alert(1)"><path d="M0 0" onclick="alert(&quot;x&quot;)"/></a>'),
    ("rel-drift", W % ('<path d="M0 0' + 'l.0004 0' * 1000 + '"/>')),
    ("rel-drift-curve", W % ('<path d="M0 0' + 'c.0004 .0004 .0004 .0004 .0004 .0004' * 500 + '"/>')),
    ("huge-coord", W % '<path d="M0 0L1e306 1e306"/>'),
    ("exp-coord", W % '<path d="M0 0L1.5e10 2e-7"/>'),
    ("color-alpha", W % '<path d="M0 0" fill="rgba(255,0,0,0.5)" stroke="hsla(120,100%,50%,0.25)"/>'),
    ("color-fallback", W % '<path d="M0 0" fill="url(#g) red"/>'),
    ("color-important", W % '<path d="M0 0" fill="red !important"/>'),
    ("shape-convert-rect", W % '<rect x="1" y="2" width="10" height="5" rx="1" fill="red"/>'),
    ("empty-text", W % '<text></text>'),
    ("metadata", W % '<metadata><rdf/></metadata><path d="M0 0L1 1"/>'),
    ("nested-empty-g", W % '<g><g><g></g></g></g><path d="M0 0L1 1"/>'),
    ("comment-in-text", W % '<text>a<!-- x -->b</text>'),
]


def xml_ok(s):
    try:
        minidom.parseString(s.encode("utf-8"))
        return True
    except Exception:
        return False


def text_content(s):
    """Rendered text per <text> element under SVG default white-space handling (collapse runs)."""
    doc = minidom.parseString(s.encode("utf-8"))
    out = []
    for t in doc.getElementsByTagName("text"):
        acc = []
        def walk(n):
            for c in n.childNodes:
                if c.nodeType in (c.TEXT_NODE, c.CDATA_SECTION_NODE):
                    acc.append(c.data)
                elif c.nodeType == c.ELEMENT_NODE:
                    walk(c)
        walk(t)
        txt = "".join(acc)
        if t.getAttribute("xml:space") != "preserve":
            txt = re.sub(r"[ \t\r\n]+", " ", txt).strip()
        out.append(txt)
    return out


def attrs_of(s, skip=("d", "fill", "stroke", "color", "stop-color", "flood-color", "lighting-color")):
    doc = minidom.parseString(s.encode("utf-8"))
    res = []
    for e in doc.getElementsByTagName("*"):
        for k, v in sorted(e.attributes.items()):
            if k not in skip:
                res.append((e.tagName, k, v))
    return res


def abs_points(d):
    pts = []
    for r in reference(d):
        if r[0] == "A":
            pts.append((r[1]["x2"], r[1]["y2"]))
        elif r[0] != "Z":
            pts.append((r[-2], r[-1]))
    return pts


def main():
    L = Ledger("dom")
    # ---------------- 1. XML layer vs roxmltree
    docs = [d for _, d, _ in XML]
    P = run("pion", "xml", docs)
    R = run("rust", "xml", docs)
    acc_diff, val_diff = [], []
    for (name, d, cmp_), p, r in zip(XML, P, R):
        pe, re_ = p.startswith("ERR"), r.startswith("ERR")
        print(f"    {name:22s} pion={'ERR' if pe else 'OK '} roxmltree={'ERR ' + r[4:60] if re_ else 'OK'}")
        if cmp_ and pe != re_:
            acc_diff.append(name)
        if not pe and not re_:
            pt = [l for l in p.split("\n")[1:] if l.startswith("T ")]
            rt = [l for l in r.split("\n")[1:] if l.startswith("T ") and l.strip() != "T 0:" and l[2:].split(":", 1)[1].strip()]
            ptv = [l.split(":", 1)[1] for l in pt]
            rtv = [l.split(":", 1)[1] for l in rt]
            pa = re.findall(r" ([\w:-]+)=(\d+):", p)
            if [v.strip() for v in ptv] != [v.strip() for v in rtv]:
                val_diff.append((name, ptv, rtv))
            # attribute values
            pav = {m.group(1): m.group(3) for m in re.finditer(r" ([\w:.-]+)=(\d+):([^\n]*?)(?= [\w:.-]+=\d+:|$)", p, re.M)}
            rav = {m.group(1): m.group(3) for m in re.finditer(r" ([\w:.-]+)=(\d+):([^\n]*?)(?= [\w:.-]+=\d+:|$)", r, re.M)}
            for k in rav:
                if k in pav and pav[k] != rav[k]:
                    val_diff.append((name + "@" + k, pav[k], rav[k]))
    val_diff = [v for v in val_diff if v[0] != "bom"]  # Pion keeps U+FEFF as a document-level text node: harmless
    for v in val_diff:
        print(f"    VALUE {v}")
    ents = [v for v in val_diff if v[0].startswith("charref")]
    L.check("entities: numeric character references >= U+0080 decoded like roxmltree (&#233; &#160; &#x2713; &#x1F600;)",
            not ents, "P1", f"{[(v[0], v[1], v[2]) for v in ents][:3]}")
    L.check("entities: other decoded text/attribute values equal roxmltree", not [v for v in val_diff if not v[0].startswith("charref")],
            "P2", str([v for v in val_diff if not v[0].startswith("charref")][:3]))
    print(f"    well-formedness disagreements (Pion accepts, roxmltree rejects): {acc_diff}")
    L.check("XML well-formedness: rejects what roxmltree rejects (dup attrs, '<' in attr, bare '&', unknown entity, 2 roots, "
            "trailing text, no-ws attrs, undeclared prefix, '<!foo>')", not acc_diff, "P2", ", ".join(acc_diff))
    bl = dict(zip([n for n, _, _ in XML], P))
    L.check("XXE / billion laughs: DTD entities never expanded, no external fetch (parse returns quickly)",
            "lol" * 10 not in bl["billion-laughs"] and "root:" not in bl["xxe"], "ctl")
    # namespace-prefixed SVG renders nothing
    E = run("pion", "extract", [d for _, d, _ in XML if _ is not None])
    ex = dict(zip([n for n, _, _ in XML], E))
    L.check("namespaces: <svg:svg xmlns:svg=SVG><svg:path/> yields the path (roxmltree resolves the prefix)",
            ex["ns-prefix"].startswith("OK 1"), "P2", ex["ns-prefix"][:80])
    # ---------------- 2. optimize_svg semantics & safety
    docs = [d for _, d in OPT]
    O = run("pion", "opt", docs)
    OC = run("pion", "optc", docs)
    EXB = run("pion", "extract", docs)
    EXA = run("pion", "extract", [o[3:] if o.startswith("OK ") else "<svg/>" for o in O])
    res = {}
    for (name, d), o, oc in zip(OPT, O, OC):
        out = o[3:] if o.startswith("OK ") else None
        res[name] = (d, out, oc[3:] if oc.startswith("OK ") else None)
        print(f"    OPT {name:22s} -> {(out or 'ERR')[:150]!r}")
    invalid = [n for n, (d, o, oc) in res.items() if o is None or not xml_ok(o) or (oc is not None and not xml_ok(oc))]
    L.check("optimize_svg output is well-formed XML for every case (attribute/text escaping of < > & \")", not invalid, "P0", str(invalid))
    tx_bad = []
    for n, (d, o, _) in res.items():
        if o and xml_ok(o) and text_content(d) != text_content(o):
            tx_bad.append((n, text_content(d), text_content(o)))
    for t in tx_bad:
        print(f"    TEXT {t}")
    L.check("optimize_svg preserves rendered <text> content (inter-word spaces between tspans, xml:space)",
            not [t for t in tx_bad if not t[0].startswith("charref")], "P1",
            str([t for t in tx_bad if not t[0].startswith("charref")][:2]))
    L.check("optimize_svg preserves non-ASCII character references (no '&amp;#233;' double escaping)",
            not [t for t in tx_bad if t[0].startswith("charref")] and "&amp;#" not in (res["charref-attr"][1] or ""), "P1",
            str([t for t in tx_bad if t[0].startswith("charref")][:1]) + " " + (res["charref-attr"][1] or "")[40:120])
    at_bad = []
    for n, (d, o, _) in res.items():
        if o and xml_ok(o) and n not in ("charref-attr", "g-filter-empty", "g-animate", "switch-g"):
            a0 = [a for a in attrs_of(d) if a[0] != "metadata"]
            a1 = attrs_of(o)
            if sorted(a0) != sorted(a1):
                at_bad.append((n, sorted(set(a0) ^ set(a1))[:3]))
    L.check("optimize_svg attribute escaping: quotes / & / < / > round-trip exactly", not [a for a in at_bad if a[0] != "attr-newline-tab"],
            "P0", str(at_bad[:3]))
    L.check("optimize_svg re-escapes &#10; / &#9; / &#13; in attributes (raw TAB/LF are normalised to spaces by every XML parser)",
            not [a for a in at_bad if a[0] == "attr-newline-tab"], "P2", str([a for a in at_bad if a[0] == "attr-newline-tab"]))
    sw = res["switch-g"][1] or ""
    L.check("optimize_svg does not unwrap <g> children of <switch> (switch renders only its first valid child)",
            sw.count("<g") == 2, "P1", sw[40:200])
    ga = res["g-animate"][1] or ""
    L.check("optimize_svg does not unwrap an attribute-less <g> whose child is an animation element (it animates the <g>)",
            "<g>" in ga, "P1", ga[40:200])
    L.check("optimize_svg keeps <g> carrying id/transform/class/clip-path (only attribute-less groups collapse)",
            all(k in (res[n][1] or "") for n, k in [("g-id", 'id="keep"'), ("g-transform", "translate"), ("g-class", 'class="c"'),
                                                    ("g-clip", "clip-path")]), "ctl")
    L.check("optimize_svg keeps an empty <g filter=...> (a filter renders even with no children, e.g. feFlood)",
            "filter=" in (res["g-filter-empty"][1] or "").split("</defs>")[-1], "P2", (res["g-filter-empty"][1] or "")[-80:])
    L.check("optimize_svg keeps <?xml-stylesheet?> (it is a stylesheet link, not the XML declaration)",
            "xml-stylesheet" in (res["xml-stylesheet-pi"][1] or ""), "P2", (res["xml-stylesheet-pi"][1] or "")[:80])
    # geometry: absolute endpoints of every path within the rounding budget
    geo_bad = []
    for n in ("rel-drift", "rel-drift-curve", "huge-coord", "exp-coord"):
        d, o, _ = res[n]
        din = re.search(r' d="([^"]*)"', d).group(1)
        m = re.search(r' d="([^"]*)"', o or "")
        if not m:
            geo_bad.append((n, "no d"))
            continue
        try:
            a, b = abs_points(din), abs_points(m.group(1))
        except Exception as e:
            geo_bad.append((n, f"optimized d is not valid path data: {m.group(1)[:60]!r}"))
            continue
        if len(a) != len(b):
            geo_bad.append((n, f"{len(a)} vs {len(b)} points"))
            continue
        worst = max(max(abs(x0 - x1), abs(y0 - y1)) / max(1.0, abs(x0), abs(y0)) for (x0, y0), (x1, y1) in zip(a, b))
        if worst > 1e-3:
            geo_bad.append((n, f"absolute endpoint drift {worst:.4g} (float_precision=3 budget is 5e-4)"))
    for g in geo_bad:
        print(f"    GEOM {g}")
    L.check("optimize_svg path geometry: relative commands do not accumulate rounding drift (<= 1e-3 absolute)",
            not [g for g in geo_bad if g[0].startswith("rel")], "P2", str([g for g in geo_bad if g[0].startswith("rel")]))
    L.check("optimize_svg / format_path never emits 'inf'/'nan' or a different number for |v| >= ~1.8e305 or exponents",
            not [g for g in geo_bad if not g[0].startswith("rel")], "P1", str([g for g in geo_bad if not g[0].startswith("rel")]))
    col = res["color-alpha"][1] or ""
    L.check("minify_colors keeps colors with alpha in SVG 1.1-compatible form (no #rrggbbaa / #rgba, like svgo convertColors)",
            not re.search(r'="#[0-9a-f]{4}"|="#[0-9a-f]{8}"', col), "P2", col[40:140])
    # render-path equivalence before/after optimize (Pion vs Pion, structural)
    eq_bad = []
    for (n, _), a, b in zip(OPT, EXB, EXA):
        if a.startswith("OK") and b.startswith("OK") and a.split("\n")[0] != b.split("\n")[0]:
            eq_bad.append((n, a.split("\n")[0], b.split("\n")[0]))
    L.check("extract_render_paths count identical before/after optimize_svg", not eq_bad, "P1", str(eq_bad[:3]))
    # bench-style icon corpus (packages/svg/bench/gen_data.py): validity + render-path equivalence
    from wasm4 import icons
    ic = icons(500)
    OI = run("pion", "opt", ic)
    outs = [o[3:] if o.startswith("OK ") else "<svg/>" for o in OI]
    bad_xml = [i for i, o in enumerate(outs) if not xml_ok(o)]
    B = run("pion", "extract", ic)
    A = run("pion", "extract", outs)
    neq = []
    for i, (b, a) in enumerate(zip(B, A)):
        bl, al = b.split("\n"), a.split("\n")
        if bl[0] != al[0]:
            neq.append((i, bl[0], al[0])); continue
        for x, y in zip(bl[1:], al[1:]):
            xs, ys = x.split(" d=")[0], y.split(" d=")[0]
            if xs != ys:
                neq.append((i, xs[:120], ys[:120])); break
            pa, pb = abs_points(x.split(" d=")[1]), abs_points(y.split(" d=")[1])
            if len(pa) != len(pb) or max((max(abs(p[0] - q[0]), abs(p[1] - q[1])) for p, q in zip(pa, pb)), default=0) > 2e-3:
                neq.append((i, x[-80:], y[-80:])); break
    print(f"  bench icons: {len(ic)} optimized, {len(bad_xml)} invalid XML, {len(neq)} render-path differences")
    for x in neq[:3]:
        print(f"    ICON {x}")
    L.check("optimize_svg on 500 bench icons: well-formed output, identical render paths (style, transform, geometry <= 2e-3)",
            not bad_xml and not neq, "P1", str((bad_xml[:3], neq[:2])))
    # ---------------- 3. style cascade / extract_render_paths semantics
    ST = [
        ("style-overrides-attr", W % '<path d="M0 0L1 1" fill="blue" style="fill:red"/>', "fill=COL 255 0 0 255"),
        ("css-comment", W % '<path d="M0 0L1 1" style="/*x*/fill:red"/>', "fill=COL 255 0 0 255"),
        ("important", W % '<path d="M0 0L1 1" style="fill:red !important"/>', "fill=COL 255 0 0 255"),
        ("opacity-attr-and-style", W % '<path d="M0 0L1 1" opacity="0.5" style="opacity:0.5"/>', " op 4602678819172646912"),
        ("fill-opacity-pct", W % '<path d="M0 0L1 1" fill-opacity="50%"/>', " fop 4602678819172646912"),
        ("opacity-clamp", W % '<path d="M0 0L1 1" opacity="2"/>', " op 4607182418800017408"),
        ("inherit-fill", W % '<g fill="red"><path d="M0 0L1 1"/></g>', "fill=COL 255 0 0 255"),
        ("display-none", W % '<g style="display:none"><path d="M0 0L1 1"/></g>', None),
        ("defs-skip", W % '<defs><path d="M0 0L1 1"/></defs>', None),
        ("marker-skip", W % '<marker id="m"><path d="M0 0L1 1"/></marker>', None),
        ("nested-g-transform-order", W % '<g transform="translate(10 0)"><g transform="scale(2)"><path d="M1 1L2 2"/></g></g>',
         "tf 4611686018427387904 0 0 4611686018427387904 4621819117588971520 0"),
        ("bad-transform-keeps-doc", W % '<path d="M0 0L1 1"/><path d="M0 0L2 2" transform="rotate(oops)"/>', "OK 2"),
        ("bad-path-keeps-doc", W % '<path d="M0 0L1 1"/><path d="M0 0L2 2 X"/>', "OK 2"),
        ("odd-polyline", W % '<polyline points="0 0 10 10 20"/>', "OK 1"),
        ("rect-rx-auto", W % '<rect width="20" height="20" rx="auto" ry="5"/>', "A5 5 0"),
        ("rect-rx-neg", W % '<rect width="20" height="20" rx="-3" ry="5"/>', "A5 5 0"),
        ("rect-rx-clamp", W % '<rect width="10" height="40" rx="30"/>', "A5 20 0"),
        ("nested-svg-viewport", W % '<svg x="10" y="10" width="10" height="10" viewBox="0 0 1 1"><path d="M0 0L1 1"/></svg>',
         "tf 4621819117588971520 0 0 4621819117588971520 4621819117588971520 4621819117588971520"),
    ]
    S = run("pion", "extract", [d for _, d, _ in ST])
    for (n, d, want), out in zip(ST, S):
        if want is None:
            ok = out.startswith("OK 0")
        else:
            ok = want in out
        sev = "ctl" if n in ("style-overrides-attr", "inherit-fill", "display-none", "defs-skip", "nested-g-transform-order",
                             "rect-rx-clamp") else "P2"
        L.check(f"style/extract: {n}", ok, sev, out[:220].replace("\n", " | "))
    sys.exit(L.save())


if __name__ == "__main__":
    main()
