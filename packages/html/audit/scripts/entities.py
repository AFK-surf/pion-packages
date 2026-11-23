"""WHATWG named character reference coverage: all 2,231 entries of html5ever's table
(markup5ever 0.14.1 entities.rs == WHATWG entities.json), in text and in attribute values,
plus legacy no-semicolon edge cases. Pion vs expected vs html5ever.
Usage: entities.py <markup5ever-0.14.1/entities.rs> [--json out.json]
"""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import run, PION, RUST


def main():
    src = open(sys.argv[1], encoding="utf-8").read()
    ents = [(m.group(1), int(m.group(2)), int(m.group(3))) for m in re.finditer(r'\("(&[A-Za-z0-9]+;?)", (\d+), (\d+)\)', src)]
    assert len(ents) == 2231, len(ents)
    def expect(c1, c2):
        return chr(c1) + (chr(c2) if c2 else "")
    text_in = [f"[{n} ]" for n, _, _ in ents]
    attr_in = [f'<a title="[{n} ]"></a>' for n, _, _ in ents]
    res = {}
    for label, inputs in (("text", text_in), ("attr", attr_in)):
        p = run(PION, "tree", inputs, "frag")
        r = run(RUST, "tree", inputs, "frag")
        bad = []
        for (n, c1, c2), a, b in zip(ents, p, r):
            want = expect(c1, c2)
            if label == "attr" and not n.endswith(";"):
                want = want  # legacy entity followed by ' ' is decoded in attributes too
            ok = (f"[{want} ]" in a)
            if not ok:
                bad.append((n, want, a.strip().splitlines()[-1] if a.strip() else a, f"[{want} ]" in b))
        res[label] = {"total": len(ents), "pion_wrong": len(bad), "examples": bad[:25],
                      "html5ever_wrong": sum(1 for x in bad if not x[3])}
        print(f"[{label}] entities={len(ents)} pion_wrong={len(bad)} ({100*len(bad)/len(ents):.1f}%)  "
              f"html5ever_wrong_on_same={res[label]['html5ever_wrong']}")
        print("   e.g.", ", ".join(x[0] for x in bad[:30]))
    # legacy / edge vectors, compared directly against html5ever
    edge = ["&copy=1", "&copy;=1", "&copyx", "&notin;", "&notit;", "&not", "&amp", "&ampx", "&AMP;", "&Amp;",
            "&#x110000;", "&#xD800;", "&#0;", "&#128;", "&#x80;", "&#x8D;", "&#xFDD0;", "&#x1F600;", "&#12345678901234567890;",
            "&#x;", "&#;", "&#", "&", "&;", "&zzzz;", "&lt", "&LT", "&gt=", "&frac12", "&frac123", "&NotEqualTilde;",
            "&nbsp", "&nbspx", "&ThickSpace;", "&bne;", "&fjlig;"]
    ein = [f"<p>[{e}]</p><a title=\"[{e}]\" href=\"?a=1[{e}]\"></a>" for e in edge]
    p = run(PION, "tree", ein, "frag"); r = run(RUST, "tree", ein, "frag")
    ed = [(e, a, b) for e, a, b in zip(edge, p, r) if a != b]
    res["edge_diffs"] = ed
    print(f"[edge] {len(edge)} legacy/numeric edge vectors, differing from html5ever: {len(ed)}")
    for e, a, b in ed:
        print(f"   {e!r}\n     pion    : {a!r}\n     html5ever: {b!r}")
    if "--json" in sys.argv:
        json.dump(res, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
