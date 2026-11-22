#!/usr/bin/env node
// Node.js official `mermaid` + `linkedom` benchmark: parse corpus and emit identical canonical JSON.

import fs from "node:fs";
import { createRequire } from "node:module";

const nodeModulesDir = process.env.MERMAID_BENCH_NODE_DIR || "/tmp/mermaid-bench-node";
const require = createRequire(nodeModulesDir + "/package.json");
const { parseHTML } = require("linkedom");

const { window, document } = parseHTML("<!doctype html><html><body></body></html>");
globalThis.window = window;
globalThis.document = document;
if (!globalThis.DOMParser) globalThis.DOMParser = window.DOMParser;

const mermaidMod = await import(nodeModulesDir + "/node_modules/mermaid/dist/mermaid.esm.min.mjs");
const mermaid = mermaidMod.default;
mermaid.initialize({ startOnLoad: false, securityLevel: "loose", maxEdges: 5000, maxTextSize: 500000 });

function canonJson(kind, direction, nodes, edges) {
  const nStrs = nodes
    .map(([id, label]) => `{"id":${JSON.stringify(id)},"label":${JSON.stringify(label)}}`)
    .sort();
  const eStrs = edges
    .map(([from, to, label]) => `{"from":${JSON.stringify(from)},"to":${JSON.stringify(to)},"label":${JSON.stringify(label)}}`)
    .sort();
  return `{"kind":${JSON.stringify(kind)},"direction":${JSON.stringify(direction)},"nodes":[${nStrs.join(",")}],"edges":[${eStrs.join(",")}]}`;
}

const corpusPath = process.argv[2];
if (!corpusPath) {
  console.error("usage: bench_node_parse.mjs <corpus_file>");
  process.exit(1);
}

const parts = fs.readFileSync(corpusPath, "utf8").split("\n===DIAGRAM===\n");
const out = [];

for (const raw of parts) {
  const src = raw.trim();
  if (!src) continue;
  const diag = await mermaid.mermaidAPI.getDiagramFromText(src);
  const type = diag.type;
  const db = diag.db;
  if (type === "flowchart-v2" || type === "flowchart" || type === "flowchart-elk") {
    const dir = db.getDirection() === "TD" ? "TB" : db.getDirection();
    const nodes = [];
    for (const [id, v] of db.getVertices().entries()) {
      nodes.push([id, v.text || id]);
    }
    const edges = db.getEdges().map((e) => [e.start, e.end, e.text || ""]);
    out.push(canonJson("flowchart", dir, nodes, edges));
  } else if (type === "sequence") {
    const nodes = [];
    const actors = db.getActors();
    const entries = actors instanceof Map ? Array.from(actors.entries()) : Object.entries(actors);
    for (const [id, a] of entries) {
      nodes.push([id, a.description || id]);
    }
    const edges = db.getMessages().map((m) => [m.from, m.to, m.message || ""]);
    out.push(canonJson("sequence", "LR", nodes, edges));
  } else if (type === "stateDiagram" || type === "state") {
    const nodes = [];
    for (const [id, st] of db.getStates().entries()) {
      nodes.push([id, id]);
    }
    const edges = db.getRelations().map((r) => [r.id1, r.id2, r.relationTitle || ""]);
    out.push(canonJson("state", "TB", nodes, edges));
  } else if (type === "classDiagram" || type === "class") {
    const nodes = [];
    for (const [id, c] of db.getClasses().entries()) {
      nodes.push([id, c.label || id]);
    }
    const edges = db.getRelations().map((r) => [r.id1, r.id2, r.title || ""]);
    out.push(canonJson("class", "TB", nodes, edges));
  } else if (type === "er") {
    const nodes = [];
    const idToName = new Map();
    for (const [name, e] of db.getEntities().entries()) {
      idToName.set(e.id, name);
      nodes.push([name, e.alias || name]);
    }
    const edges = db.getRelationships().map((r) => [
      idToName.get(r.entityA) || r.entityA,
      idToName.get(r.entityB) || r.entityB,
      r.roleA || "",
    ]);
    out.push(canonJson("er", "TB", nodes, edges));
  } else {
    throw new Error("unexpected diagram type: " + type);
  }
}

process.stdout.write(out.join("\n") + "\n");
