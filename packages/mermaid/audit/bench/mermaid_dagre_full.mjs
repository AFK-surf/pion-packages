#!/usr/bin/env node
// Official pipeline for one flowchart file: `mermaid` parse (getDiagramFromText -> db.getData())
// + `@dagrejs/dagre` compound layout with the same node-size estimate Pion uses
// (label length * 8 + 28, min 72 x 38) and the same spacing (nodesep 40, ranksep 50, edgesep 20).
// Prints `nodes=N edges=E dummy_free_points=P parse_ms=.. layout_ms=..` so it can sit next to
// `probe time` in an adversarial benchmark.
// Usage: MERMAID_REF_DIR=<dir> node mermaid_dagre_full.mjs <file.mmd> [--count] [--default-limits] [--parse-only]
import fs from "node:fs";
import { createRequire } from "node:module";

const refDir = process.env.MERMAID_REF_DIR;
const require = createRequire(refDir + "/package.json");
const { parseHTML } = require("linkedom");
const { window, document } = parseHTML("<!doctype html><html><body></body></html>");
globalThis.window = window;
globalThis.document = document;
const dagre = require("@dagrejs/dagre");
const mermaid = (await import(refDir + "/node_modules/mermaid/dist/mermaid.esm.min.mjs")).default;
// --default-limits keeps mermaid's shipped guards (maxEdges 500, maxTextSize 50000) to show how the
// official library bounds hostile input; otherwise they are lifted so the layout itself is measured.
mermaid.initialize(
  process.argv.includes("--default-limits")
    ? { startOnLoad: false }
    : { startOnLoad: false, maxEdges: 10000000, maxTextSize: 100000000 },
);

const src = fs.readFileSync(process.argv[2], "utf8");
const t0 = performance.now();
const diag = await mermaid.mermaidAPI.getDiagramFromText(src);
if (process.argv.includes("--parse-only")) {
  // any diagram kind (e.g. sequence): stop after the official parse
  process.stdout.write(`parsed type=${diag.type} parse_ms=${(performance.now() - t0).toFixed(1)}\n`);
  process.exit(0);
}
const data = diag.db.getData();
const t1 = performance.now();
const dir = diag.db.getDirection ? diag.db.getDirection() : "TB";
const g = new dagre.graphlib.Graph({ multigraph: true, compound: true });
g.setGraph({ rankdir: dir === "TD" ? "TB" : dir, nodesep: 40, ranksep: 50, edgesep: 20, marginx: 20, marginy: 20 });
g.setDefaultEdgeLabel(() => ({}));
for (const n of data.nodes) {
  if (n.isGroup) g.setNode(n.id, {});
  else {
    const lbl = String(n.label ?? n.id);
    g.setNode(n.id, { width: Math.max(72, lbl.length * 8 + 28), height: 38 });
  }
}
for (const n of data.nodes) if (n.parentId) g.setParent(n.id, n.parentId);
data.edges.forEach((e, i) => g.setEdge(e.start, e.end, {}, "k" + i));
dagre.layout(g);
const t2 = performance.now();
if (process.argv.includes("--count")) {
  // same stdout as `probe count` so scripts/bench_compare.py can verify SHA-256 parity
  process.stdout.write(`nodes=${data.nodes.filter((n) => !n.isGroup).length} edges=${data.edges.length}\n`);
  process.exit(0);
}
let pts = 0;
for (const e of g.edges()) pts += (g.edge(e).points || []).length;
process.stdout.write(
  `nodes=${data.nodes.filter((n) => !n.isGroup).length} edges=${data.edges.length} points=${pts} ` +
    `parse_ms=${(t1 - t0).toFixed(1)} layout_ms=${(t2 - t1).toFixed(1)} width=${Math.round(g.graph().width)} height=${Math.round(g.graph().height)}\n`,
);
process.exit(0);
