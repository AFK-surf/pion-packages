#!/usr/bin/env python3
"""Render one case from a scenes TSV (Pion or dagre) with ONE neutral renderer, so the two layouts
can be compared visually without either side's styling getting in the way. Defects found by
geom_check are outlined in red (foreign nodes inside a cluster, overlapping labels, edges through
nodes).

Usage: scene_svg.py scenes.tsv case_name > out.svg
"""
import html
import json
import sys

from geom_check import audit


def main():
    want = sys.argv[2]
    sc = None
    for ln in open(sys.argv[1], encoding="utf-8"):
        name, status, payload = (ln.rstrip("\n").split("\t", 2) + ["", ""])[:3]
        if name == want and status == "OK":
            sc = json.loads(payload)
    if sc is None:
        sys.exit(f"case {want} not found")
    d = audit(sc)
    bad_nodes = set()
    for k in ("group_contains_foreign_node", "node_overlap", "edge_through_node", "label_overlaps_node"):
        for item in d[k]:
            for sep in ("<-", "~", "x"):
                if sep in item:
                    bad_nodes.add(item.split(sep)[-1].strip("'"))
    bad_labels = set()
    for item in d["label_overlaps_label"] + d["label_overlaps_node"]:
        for part in item.split("'"):
            bad_labels.add(part)
    W, H = sc["width"], sc["height"]
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.0f}" height="{H:.0f}" viewBox="0 0 {W:.1f} {H:.1f}">',
         f'<rect width="{W:.1f}" height="{H:.1f}" fill="#fff"/>',
         '<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M0 1L10 5L0 9z" fill="#334155"/></marker></defs>']
    for g in sc["groups"]:
        o.append(f'<rect x="{g["x"]:.1f}" y="{g["y"]:.1f}" width="{g["w"]:.1f}" height="{g["h"]:.1f}" rx="6" fill="#e0f2fe" fill-opacity="0.45" stroke="#0369a1" stroke-width="1.5"/>')
        o.append(f'<text x="{g["x"] + 6:.1f}" y="{g["y"] + 14:.1f}" font-family="sans-serif" font-size="12" fill="#0369a1">{html.escape(g["title"] or g["id"])}</text>')
    for e in sc["edges"]:
        pts = " ".join(f"{p[0]:.1f},{p[1]:.1f}" for p in e["pts"])
        o.append(f'<polyline points="{pts}" fill="none" stroke="#334155" stroke-width="1.4" marker-end="url(#a)"/>')
    for n in sc["nodes"]:
        x0, y0 = n["x"] - n["w"] / 2, n["y"] - n["h"] / 2
        bad = n["id"] in bad_nodes
        o.append(f'<rect x="{x0:.1f}" y="{y0:.1f}" width="{n["w"]:.1f}" height="{n["h"]:.1f}" rx="4" fill="{"#fee2e2" if bad else "#fff"}" stroke="{"#dc2626" if bad else "#334155"}" stroke-width="{2.5 if bad else 1.4}"/>')
        o.append(f'<text x="{n["x"]:.1f}" y="{n["y"] + 4:.1f}" text-anchor="middle" font-family="sans-serif" font-size="12">{html.escape(n["label"] or n["id"])}</text>')
    for lb in sc["labels"]:
        bad = lb["text"] in bad_labels
        o.append(f'<rect x="{lb["x"] - lb["w"] / 2:.1f}" y="{lb["y"] - lb["h"] / 2:.1f}" width="{lb["w"]:.1f}" height="{lb["h"]:.1f}" fill="{"#fef3c7" if not bad else "#fecaca"}" fill-opacity="0.85" stroke="{"#dc2626" if bad else "#d97706"}"/>')
        o.append(f'<text x="{lb["x"]:.1f}" y="{lb["y"] + 4:.1f}" text-anchor="middle" font-family="sans-serif" font-size="11">{html.escape(lb["text"])}</text>')
    o.append("</svg>")
    print("\n".join(o))


if __name__ == "__main__":
    main()
