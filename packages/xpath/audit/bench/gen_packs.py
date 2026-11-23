#!/usr/bin/env python3
"""Blind-spot workloads for the packages/xpath benchmark fairness review (RT-xpath).

usage: gen_packs.py OUTDIR W1_XML
Writes OUTDIR/<name>.pack in the runner PACK format (tools/pion_runner): the document once,
then the query list repeated ROUNDS times (each Q is compiled + evaluated, by every impl).
All queries return integers / booleans so pion, sxd-xpath and libxml2 print identical bytes.
Also writes OUTDIR/parse_only_w1.pack (document + one trivial query) to price XML parsing.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "diff"))
import packlib  # noqa: E402

ROUNDS = 5

W1_QUERIES = {
    # string-value heavy (element string-values, not attribute/leaf text)
    "b1_string_values": [
        "count(//book[. = 'x'])",
        "count(//section[contains(., 'volume 2999')])",
        "count(//book[string-length(.) > 100])",
        "count(//book[normalize-space(.) = ''])",
    ],
    # reverse axes and preceding/ancestor (not in the shipped W1/W3 except one ancestor::)
    "b2_reverse_axes": [
        "count(//tag[preceding-sibling::tag = 'wasm'])",
        "count(//section[last()]/book[last()]/preceding::book)",
        "count(//title/ancestor::section)",
        "count(//book[ancestor-or-self::*[@name='ml']])",
        "count(//price/preceding-sibling::*[1][self::author])",
    ],
    # `//` followed by a non-child step (no //child fusion fast path)
    "b3_general_descendant": [
        "count(//@id)",
        "count(//text())",
        "count(//self::book)",
        "count(//node())",
        "count(/descendant-or-self::node()/attribute::lang)",
    ],
    # node-set = node-set and node-set = string over many nodes
}

# node-set = node-set over two disjoint 8,000-node sets (all pairs differ): O(n*m) vs hashing
AB_DOC = "<r>" + "".join("<a>a%d</a>" % i for i in range(8000)) + "".join("<b>b%d</b>" % i for i in range(8000)) + "</r>"
AB_QUERIES = ["//a = //b", "//a = //zz", "count(//a[. = 'b1'])"]


def ns_doc(n):
    out = ['<c:catalog xmlns:c="urn:cat" xmlns:m="urn:meta">']
    for i in range(n):
        out.append('<c:item m:k="%d" c:z="%d"><m:v>%d</m:v><c:name>n%d</c:name></c:item>' % (i, i % 7, i % 13, i))
    out.append("</c:catalog>")
    return "".join(out)


NS_QUERIES = [
    "count(//c:item[@m:k > 100])",
    "count(//m:*)",
    "sum(//c:item/m:v)",
    "count(//c:item[@c:z = 3]/c:name)",
    "count(//*[namespace-uri() = 'urn:meta'])",
]


def main():
    out, w1 = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    xml = open(w1, encoding="utf-8").read()
    for name, qs in W1_QUERIES.items():
        pack, _ = packlib.build([(xml, [], qs * ROUNDS)])
        open(os.path.join(out, name + ".pack"), "wb").write(pack)
    pack, _ = packlib.build([(AB_DOC, [], AB_QUERIES * ROUNDS)])
    open(os.path.join(out, "b4_nodeset_compare.pack"), "wb").write(pack)
    pack, _ = packlib.build([(ns_doc(20000), [["c", "urn:cat"], ["m", "urn:meta"]], NS_QUERIES * ROUNDS)])
    open(os.path.join(out, "b5_namespaces.pack"), "wb").write(pack)
    pack, _ = packlib.build([(xml, [], ["1"])])
    open(os.path.join(out, "parse_only_w1.pack"), "wb").write(pack)
    print("packs written to", out)


if __name__ == "__main__":
    main()
