#!/usr/bin/env python3
"""Geometric defect audit for laid-out scenes (Pion `probe scene` or `dagre_ref.mjs`).

Input: TSV lines `name \t OK|ERR \t scene-json` (schema: nodes[id,x,y,w,h,group,shape],
groups[id,x,y,w,h,parent], edges[id,s,e,l,pts], labels[text,owner,x,y,w,h]); node/label x,y are
centres, group x,y is the top-left corner.

Usage: geom_check.py scenes.tsv [--json out.json]
Prints one row per case with defect counts and examples; exit code = number of cases with defects.
"""
import json
import math
import sys

EPS = 0.5  # px of tolerance for every containment / overlap test


def box_node(n):
    return (n["x"] - n["w"] / 2, n["y"] - n["h"] / 2, n["x"] + n["w"] / 2, n["y"] + n["h"] / 2)


def box_group(g):
    return (g["x"], g["y"], g["x"] + g["w"], g["y"] + g["h"])


def inter(a, b, eps=EPS):
    return min(a[2], b[2]) - max(a[0], b[0]) > eps and min(a[3], b[3]) - max(a[1], b[1]) > eps


def inside(inner, outer, eps=EPS):
    return inner[0] >= outer[0] - eps and inner[1] >= outer[1] - eps and inner[2] <= outer[2] + eps and inner[3] <= outer[3] + eps


def shrink(b, d):
    return (b[0] + d, b[1] + d, b[2] - d, b[3] - d)


def seg_hits_box(p, q, b):
    """Liang-Barsky: does segment pq pass through the open box b?"""
    if b[2] <= b[0] or b[3] <= b[1]:
        return False
    x0, y0 = p
    dx, dy = q[0] - p[0], q[1] - p[1]
    t0, t1 = 0.0, 1.0
    for pk, qk in ((-dx, x0 - b[0]), (dx, b[2] - x0), (-dy, y0 - b[1]), (dy, b[3] - y0)):
        if abs(pk) < 1e-12:
            if qk <= 0:
                return False
        else:
            t = qk / pk
            if pk < 0:
                t0 = max(t0, t)
            else:
                t1 = min(t1, t)
            if t0 >= t1:
                return False
    return t1 - t0 > 1e-6


def num_ok(v):
    return isinstance(v, (int, float)) and math.isfinite(v)


def audit(scene):
    d = {k: [] for k in (
        "non_finite", "node_overlap", "group_misses_member", "group_contains_foreign_node",
        "sibling_group_overlap", "edge_through_node", "label_overlaps_node", "label_overlaps_label",
        "out_of_canvas", "dangling_edge", "coincident_parallel_edges", "edge_detached_from_node",
    )}
    nodes = [n for n in scene["nodes"] if n.get("shape") != "dummy"]
    byid = {n["id"]: n for n in nodes}
    groups = scene.get("groups", [])
    gby = {g["id"]: g for g in groups}

    def ancestors(gid):
        out = []
        seen = set()
        while gid is not None and gid in gby and gid not in seen:
            seen.add(gid)
            out.append(gid)
            gid = gby[gid].get("parent")
        return out

    # 0. finiteness
    for n in nodes:
        if not all(num_ok(n[k]) for k in ("x", "y", "w", "h")):
            d["non_finite"].append(n["id"])
    for e in scene["edges"]:
        for p in e["pts"]:
            if not all(num_ok(c) for c in p):
                d["non_finite"].append(e["id"])
                break
    if d["non_finite"]:
        return d
    W, H = scene["width"], scene["height"]
    canvas = (0, 0, W, H)
    # 1. node-node overlap
    boxes = [(n["id"], box_node(n)) for n in nodes]
    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            if inter(boxes[i][1], boxes[j][1]):
                d["node_overlap"].append(f"{boxes[i][0]}~{boxes[j][0]}")
    # 2/3. cluster containment & intrusion
    member_of = {}
    for n in nodes:
        member_of[n["id"]] = set(ancestors(n.get("group")))
    for g in groups:
        if g.get("kind", "subgraph") not in ("subgraph", None):
            continue
        gb = box_group(g)
        for n in nodes:
            nb = box_node(n)
            if g["id"] in member_of[n["id"]]:
                if not inside(nb, gb):
                    d["group_misses_member"].append(f"{g['id']}!>{n['id']}")
            elif inter(nb, gb):
                d["group_contains_foreign_node"].append(f"{g['id']}<-{n['id']}")
    sg = [g for g in groups if g.get("kind", "subgraph") == "subgraph"]
    for i in range(len(sg)):
        for j in range(i + 1, len(sg)):
            a, b = sg[i], sg[j]
            if a["id"] in ancestors(b.get("parent")) or b["id"] in ancestors(a.get("parent")):
                continue
            if inter(box_group(a), box_group(b)):
                d["sibling_group_overlap"].append(f"{a['id']}~{b['id']}")
    # 4. edges
    seen_geom = {}
    for e in scene["edges"]:
        if e["s"] not in byid or e["e"] not in byid:
            d["dangling_edge"].append(f"{e['id']}:{e['s']}->{e['e']}")
            continue
        pts = e["pts"]
        if len(pts) < 2:
            d["dangling_edge"].append(f"{e['id']}:no-points")
            continue
        for n in nodes:
            if n["id"] in (e["s"], e["e"]):
                continue
            nb = shrink(box_node(n), 1.0)
            if any(seg_hits_box(pts[k], pts[k + 1], nb) for k in range(len(pts) - 1)):
                d["edge_through_node"].append(f"{e['id']}({e['s']}->{e['e']})x{n['id']}")
        if e["s"] != e["e"]:
            # endpoints must touch (be within 3px of) the boxes of their own nodes
            def dist_to_box(p, b):
                dx = max(b[0] - p[0], 0, p[0] - b[2])
                dy = max(b[1] - p[1], 0, p[1] - b[3])
                return math.hypot(dx, dy)

            ends = {dist_to_box(pts[0], box_node(byid[e["s"]])), dist_to_box(pts[-1], box_node(byid[e["e"]]))}
            if max(ends) > 3.0:
                d["edge_detached_from_node"].append(f"{e['id']}({e['s']}->{e['e']}) gap={max(ends):.1f}")
            key = (min(e["s"], e["e"]), max(e["s"], e["e"]))
            geom = tuple(sorted((round(p[0]), round(p[1])) for p in pts))
            if key in seen_geom and seen_geom[key] == geom:
                d["coincident_parallel_edges"].append(f"{e['s']}<->{e['e']}")
            seen_geom.setdefault(key, geom)
        for p in pts:
            if not (-EPS <= p[0] <= W + EPS and -EPS <= p[1] <= H + EPS):
                d["out_of_canvas"].append(f"edge {e['id']}")
                break
    for nid, nb in boxes:
        if not inside(nb, canvas):
            d["out_of_canvas"].append(f"node {nid}")
    for g in groups:
        if not inside(box_group(g), canvas):
            d["out_of_canvas"].append(f"group {g['id']}")
    # 5. labels
    labels = scene.get("labels", [])
    lboxes = [(l["text"], (l["x"] - l["w"] / 2, l["y"] - l["h"] / 2, l["x"] + l["w"] / 2, l["y"] + l["h"] / 2)) for l in labels]
    for t, lb in lboxes:
        for nid, nb in boxes:
            if inter(lb, nb):
                d["label_overlaps_node"].append(f"'{t}'x{nid}")
        if not inside(lb, canvas):
            d["out_of_canvas"].append(f"label '{t}'")
    for i in range(len(lboxes)):
        for j in range(i + 1, len(lboxes)):
            if inter(lboxes[i][1], lboxes[j][1]):
                d["label_overlaps_label"].append(f"'{lboxes[i][0]}'~'{lboxes[j][0]}'")
    return d


def main():
    rows = []
    for ln in open(sys.argv[1], encoding="utf-8"):
        ln = ln.rstrip("\n")
        if not ln:
            continue
        name, status, payload = (ln.split("\t", 2) + ["", ""])[:3]
        if status != "OK":
            rows.append((name, None, payload))
            continue
        rows.append((name, audit(json.loads(payload)), None))
    bad = 0
    result = {}
    for name, d, err in rows:
        if d is None:
            print(f"{name:42} PARSE-ERR {err[:80]}")
            result[name] = {"error": err}
            continue
        total = {k: len(v) for k, v in d.items() if v}
        result[name] = {k: v for k, v in d.items() if v}
        if total:
            bad += 1
            print(f"{name:42} DEFECTS {total}")
            for k, v in d.items():
                if v:
                    print(f"    {k}: {v[:4]}{' ...' if len(v) > 4 else ''}")
        else:
            print(f"{name:42} clean")
    if "--json" in sys.argv:
        with open(sys.argv[sys.argv.index("--json") + 1], "w", encoding="utf-8") as f:
            json.dump(result, f, indent=1, ensure_ascii=False)
    sys.exit(min(bad, 100))


if __name__ == "__main__":
    main()
