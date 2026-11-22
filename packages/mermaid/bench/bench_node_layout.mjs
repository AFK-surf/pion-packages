#!/usr/bin/env node
// Node.js official `@dagrejs/dagre` benchmark on 50 / 200 / 500 node graphs.

import fs from "node:fs";
import { createRequire } from "node:module";

const nodeModulesDir = process.env.MERMAID_BENCH_NODE_DIR || "/tmp/mermaid-bench-node";
const require = createRequire(nodeModulesDir + "/package.json");
const dagre = require("@dagrejs/dagre");

const graphsPath = process.argv[2];
const showMetrics = process.argv[3] === "--metrics";
if (!graphsPath) {
  console.error("usage: bench_node_layout.mjs <graphs_file> [--metrics]");
  process.exit(1);
}

const lines = fs.readFileSync(graphsPath, "utf8").split("\n");
const specs = [];
let cur = null;
for (const raw of lines) {
  const line = raw.trim();
  if (!line) continue;
  const toks = line.split(" ");
  if (toks[0] === "GRAPH") {
    cur = { name: toks[1], nodes: [], edges: [] };
    specs.push(cur);
  } else if (toks[0] === "N" && cur) {
    cur.nodes.push({ id: toks[1], width: Number(toks[2]), height: Number(toks[3]) });
  } else if (toks[0] === "E" && cur) {
    cur.edges.push({ from: toks[1], to: toks[2] });
  }
}

function orient2d(a, b, c) {
  return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

function segsIntersect(a, b, c, d) {
  const eps = 1e-6;
  const o1 = orient2d(a, b, c);
  const o2 = orient2d(a, b, d);
  const o3 = orient2d(c, d, a);
  const o4 = orient2d(c, d, b);
  return ((o1 > eps && o2 < -eps) || (o1 < -eps && o2 > eps)) &&
         ((o3 > eps && o4 < -eps) || (o3 < -eps && o4 > eps));
}

const out = [];
for (const spec of specs) {
  const g = new dagre.graphlib.Graph({ multigraph: true });
  g.setGraph({ rankdir: "TB", nodesep: 40, ranksep: 50, edgesep: 20, marginx: 20, marginy: 20 });
  g.setDefaultEdgeLabel(() => ({}));
  for (const n of spec.nodes) {
    g.setNode(n.id, { width: n.width, height: n.height });
  }
  spec.edges.forEach((e, idx) => {
    g.setEdge(e.from, e.to, {}, "e" + idx);
  });
  dagre.layout(g);

  const placed = g.nodes().map((id) => ({ id, ...g.node(id) }));
  let overlaps = 0;
  for (let i = 0; i < placed.length; i++) {
    const a = placed[i];
    const ax0 = a.x - a.width / 2, ax1 = a.x + a.width / 2;
    const ay0 = a.y - a.height / 2, ay1 = a.y + a.height / 2;
    for (let j = i + 1; j < placed.length; j++) {
      const b = placed[j];
      const bx0 = b.x - b.width / 2, bx1 = b.x + b.width / 2;
      const by0 = b.y - b.height / 2, by1 = b.y + b.height / 2;
      const ox = Math.min(ax1, bx1) - Math.max(ax0, bx0);
      const oy = Math.min(ay1, by1) - Math.max(ay0, by0);
      if (ox > 1e-6 && oy > 1e-6) overlaps++;
    }
  }
  const gw = g.graph().width || 0;
  const gh = g.graph().height || 0;
  const finiteOk = Number.isFinite(gw) && Number.isFinite(gh) && gw > 0 && gh > 0;
  let line = `${spec.name} nodes=${placed.length} edges=${g.edges().length} overlaps=${overlaps} rank_ok=true finite=${finiteOk}`;

  if (showMetrics) {
    const segs = [];
    let totalLen = 0;
    const allEdges = g.edges();
    allEdges.forEach((e, ei) => {
      const pts = g.edge(e).points || [];
      for (let k = 0; k + 1 < pts.length; k++) {
        const dx = pts[k + 1].x - pts[k].x;
        const dy = pts[k + 1].y - pts[k].y;
        totalLen += Math.hypot(dx, dy);
        segs.push([pts[k], pts[k + 1], ei]);
      }
    });
    let crossings = 0;
    for (let i = 0; i < segs.length; i++) {
      for (let j = i + 1; j < segs.length; j++) {
        if (segs[i][2] === segs[j][2]) continue;
        if (segsIntersect(segs[i][0], segs[i][1], segs[j][0], segs[j][1])) crossings++;
      }
    }
    line += ` crossings=${crossings} edge_len=${Math.round(totalLen)} area=${Math.round(gw * gh)}`;
  }
  out.push(line);
}

process.stdout.write(out.join("\n") + "\n");
