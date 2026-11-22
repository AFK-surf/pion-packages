#!/usr/bin/env node
// Re-lay out the *same* graphs Pion laid out (same node sizes, same clusters, same edges, same
// edge-label boxes, same nodesep/ranksep/edgesep/margins) with official `@dagrejs/dagre`, the
// engine mermaid's flowchart/state/class/ER renderers use, and print scenes in the probe's schema.
// Sequence diagrams are not dagre-laid out by mermaid and are passed through as `SKIP`.
// Usage: MERMAID_REF_DIR=<dir> node dagre_ref.mjs <pion-scenes.tsv>
import fs from "node:fs";
import { createRequire } from "node:module";

const refDir = process.env.MERMAID_REF_DIR;
const require = createRequire(refDir + "/package.json");
const dagre = require("@dagrejs/dagre");

for (const ln of fs.readFileSync(process.argv[2], "utf8").split("\n")) {
  if (!ln) continue;
  const [name, status, payload] = ln.split("\t");
  if (status !== "OK") {
    process.stdout.write(`${name}\t${status}\t${payload}\n`);
    continue;
  }
  const sc = JSON.parse(payload);
  if (sc.kind === "sequence") {
    process.stdout.write(`${name}\tSKIP\tsequence diagrams are not dagre-laid-out\n`);
    continue;
  }
  const g = new dagre.graphlib.Graph({ multigraph: true, compound: true });
  g.setGraph({ rankdir: sc.dir, nodesep: 40, ranksep: 50, edgesep: 20, marginx: 20, marginy: 20 });
  g.setDefaultEdgeLabel(() => ({}));
  for (const gr of sc.groups) g.setNode(gr.id, { label: gr.title, clusterLabelPos: "top" });
  for (const gr of sc.groups) if (gr.parent) g.setParent(gr.id, gr.parent);
  for (const n of sc.nodes) {
    g.setNode(n.id, { width: n.w, height: n.h });
    if (n.group) g.setParent(n.id, n.group);
  }
  const labelOf = new Map(sc.labels.map((l) => [l.owner, l]));
  sc.edges.forEach((e, i) => {
    const l = labelOf.get(e.id);
    g.setEdge(e.s, e.e, l ? { width: l.w, height: l.h, labelpos: "c", label: e.l } : {}, "k" + i);
  });
  dagre.layout(g);
  const out = { kind: sc.kind, dir: sc.dir, width: g.graph().width, height: g.graph().height, nodes: [], groups: [], edges: [], labels: [] };
  for (const n of sc.nodes) {
    const v = g.node(n.id);
    out.nodes.push({ id: n.id, label: n.label, shape: n.shape, x: v.x, y: v.y, w: v.width, h: v.height, group: n.group });
  }
  for (const gr of sc.groups) {
    const v = g.node(gr.id);
    out.groups.push({ id: gr.id, title: gr.title, kind: gr.kind, x: v.x - v.width / 2, y: v.y - v.height / 2, w: v.width, h: v.height, parent: gr.parent });
  }
  sc.edges.forEach((e, i) => {
    const ed = g.edge({ v: e.s, w: e.e, name: "k" + i });
    out.edges.push({ id: e.id, s: e.s, e: e.e, l: e.l, pts: (ed.points || []).map((p) => [p.x, p.y]) });
    const l = labelOf.get(e.id);
    if (l && ed.x !== undefined) out.labels.push({ text: l.text, owner: e.id, x: ed.x, y: ed.y, w: l.w, h: l.h });
  });
  process.stdout.write(`${name}\tOK\t${JSON.stringify(out)}\n`);
}
