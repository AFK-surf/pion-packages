#!/usr/bin/env python3
"""Deterministic adversarial XML inputs for the packages/xml red-team benchmarks.

usage: python3 -I gen_adversarial.py OUT_DIR [--quick]

Every file is well-formed and parsed identically (same summary line counts) by pion and by
roxmltree 0.21.2 / quick-xml 0.42.0, so bench_compare.py's stdout SHA-256 check holds.
"""
import os
import sys

OUT = sys.argv[1]
QUICK = "--quick" in sys.argv
os.makedirs(OUT, exist_ok=True)


def w(name, s):
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        f.write(s)


# 1. Text + CDATA alternation: every chunk merges into ONE DOM text node (roxmltree semantics).
#    Scaling series to expose O(n^2) re-concatenation in append_or_merge_text_slow.
for n in ([2000, 4000, 8000, 16000] if QUICK else [5000, 10000, 20000, 40000]):
    w("merge_%d.xml" % n, "<a>" + "xx<![CDATA[yy]]>" * n + "</a>")
# Same merge pattern via entity/char references splitting nothing (control: single text scan)
w("merge_control_refs.xml", "<a>" + "xx&amp;yy" * 40000 + "</a>")

# 2. 1,000 namespace prefixes declared on the root, 200k children cycling through them
#    (defeats the 1-entry prefix cache: every lookup scans the active namespace stack).
decls = " ".join('xmlns:p%d="urn:%d"' % (i, i) for i in range(1000))
kids = 50000 if QUICK else 200000
w("ns_1000_alt.xml", "<r %s>%s</r>" % (decls, "".join("<p%d:e/>" % (i % 1000) for i in range(kids))))
# control: same element count, one prefix (cache always hits)
w("ns_1000_same.xml", "<r %s>%s</r>" % (decls, "<p0:e/>" * kids))

# 3. Deep namespace scope: depth D, each level declares its own prefix, leaf elements use the
#    *outermost* prefix -> lookup walks the whole stack.
d = 2000 if QUICK else 5000
s = ['<e0 xmlns:q0="urn:0">']
for i in range(1, d):
    s.append('<e%d xmlns:q%d="urn:%d"><q0:x/>' % (i, i, i))
for i in reversed(range(1, d)):
    s.append("</e%d>" % i)
s.append("</e0>")
w("ns_deep_%d.xml" % d, "".join(s))

# 4. Wide attribute lists: duplicate detection is pairwise.
na = 1000
elems = 50 if QUICK else 200
w("attrs_%dx%d.xml" % (elems, na), "<r>" + ("<e " + " ".join('a%d="%d"' % (i, i) for i in range(na)) + "/>") * elems + "</r>")
# prefixed variant (expanded-name duplicate check)
w("attrs_ns_%dx%d.xml" % (elems, na), '<r xmlns:p="urn:p">' + ("<e " + " ".join('p:a%d="%d"' % (i, i) for i in range(na)) + "/>") * elems + "</r>")

# 5. Deep nesting and huge sibling lists
depth = 50000
w("deep_%d.xml" % depth, "<a>" * depth + "x" + "</a>" * depth)
w("siblings_100k.xml", "<r>" + "<e/>" * 100000 + "</r>")

# 6. Huge single text / CDATA nodes (16 MiB)
big = 16 * 1024 * 1024
w("text_16m.xml", "<a>" + ("abcdefghijklmnop" * (big // 16)) + "</a>")
w("cdata_16m.xml", "<a><![CDATA[" + ("abcdefghijklmnop" * (big // 16)) + "]]></a>")
w("text_16m_refs.xml", "<a>" + ("abc&lt;def&amp;gh&#x4E2D;" * (big // 24)) + "</a>")

# 7. DTD with many internal entities (allow_dtd): pairwise "first definition wins" check
#    and linear entity lookup per reference.
ne = 5000 if QUICK else 20000
ents = "".join('<!ENTITY e%d "v%d">' % (i, i) for i in range(ne))
refs = "".join("&e%d;" % (ne - 1 - (i % 50)) for i in range(20000))
w("dtd_entities_%d.xml" % ne, "<!DOCTYPE r [%s]><r>%s</r>" % (ents, refs))

print("wrote adversarial inputs to", OUT)
