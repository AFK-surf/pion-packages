#!/usr/bin/env node
// Reference extractor: official `mermaid` (via linkedom) -> the same normalized topology the
// Pion probe prints (`probe parse`), so the two can be diffed case by case.
// Usage: MERMAID_REF_DIR=<dir with node_modules/mermaid> node mermaid_ref.mjs <corpus.mmd>
// Output: one line per case: name \t OK|ERR \t json|message
import fs from "node:fs";
import { createRequire } from "node:module";

const out = (s) => process.stdout.write(s + "\n");
const refDir = process.env.MERMAID_REF_DIR;
if (!refDir) {
  process.stderr.write("MERMAID_REF_DIR is required\n");
  process.exit(1);
}
const require = createRequire(refDir + "/package.json");
const { parseHTML } = require("linkedom");
const { window, document } = parseHTML("<!doctype html><html><body></body></html>");
globalThis.window = window;
globalThis.document = document;
// linkedom lacks HTMLOptionElement; mermaid's sequence `box <color>` uses `new Option().style`
// to validate CSS colors. Minimal shim so `box` parses as in a browser.
if (!globalThis.Option) globalThis.Option = class { constructor() { this.style = {}; } };
const mermaid = (await import(refDir + "/node_modules/mermaid/dist/mermaid.esm.min.mjs")).default;
mermaid.initialize({ startOnLoad: false, securityLevel: "strict", maxEdges: 100000, maxTextSize: 10000000 });

// mermaid encodes `#quot;`-style entity codes into placeholders at parse time and decodes them
// (then lets the DOM resolve the HTML entity) at render time; do the same here so labels compare
// as the user finally sees them.
const entityEl = document.createElement("div");
function decodeLabel(s) {
  if (s == null) return "";
  s = String(s);
  if (!s.includes("\uFB02\u00B0") && !s.includes("\u00B6\u00DF")) return s;
  const html = s.replace(/\uFB02\u00B0\u00B0/g, "&#").replace(/\uFB02\u00B0/g, "&").replace(/\u00B6\u00DF/g, ";");
  entityEl.innerHTML = html;
  return entityEl.textContent;
}
// mermaid gives anonymous concurrency regions random ids (`id-8jc54szin7p-1`); make them stable.
const stableId = (id) => String(id).replace(/^id-[a-z0-9]+-(\d+)/, "region-anon-$1");
const node = (id, label, parent, group) =>
  JSON.stringify({ id: stableId(id), label: stableId(decodeLabel(label)), parent: parent == null ? null : stableId(parent), group: !!group });
const edge = (s, e, l) => JSON.stringify({ s: stableId(s), e: stableId(e), l: decodeLabel(l) });
const sorted = (a) => "[" + a.sort().join(",") + "]";

// mermaid sequence LINETYPE values that are real messages (not notes / block markers)
const SEQ_MSG_TYPES = new Set([0, 1, 3, 4, 5, 6, 24, 25, 33, 34]);
const SEQ_NOTE = 2;

function normalize(diag) {
  const t = diag.type;
  const db = diag.db;
  const nodes = [], edges = [], notes = [];
  let kind = t;
  if (t === "flowchart-v2" || t === "flowchart" || t === "flowchart-elk") {
    kind = "flowchart";
    const data = db.getData();
    for (const n of data.nodes) nodes.push(node(n.id, n.isGroup ? n.label : n.label, n.parentId, n.isGroup));
    for (const e of data.edges) edges.push(edge(e.start, e.end, e.label ?? e.text));
  } else if (t === "sequence") {
    kind = "sequence";
    const actors = db.getActors();
    const entries = actors instanceof Map ? [...actors.entries()] : Object.entries(actors);
    for (const [id, a] of entries) nodes.push(node(id, a.description ?? id, null, false));
    for (const m of db.getMessages()) {
      if (m.type === SEQ_NOTE) notes.push(edge([m.from, m.to].filter((x, i, arr) => x && arr.indexOf(x) === i).join(","), "", m.message));
      else if (SEQ_MSG_TYPES.has(m.type) && m.from && m.to) edges.push(edge(m.from, m.to, m.message));
    }
  } else if (t === "stateDiagram" || t === "state") {
    kind = "state";
    const data = db.getData();
    for (const n of data.nodes) {
      if (n.shape === "note" || n.shape === "noteGroup" || n.id.includes("----")) continue;
      nodes.push(node(n.id, n.id, n.parentId, n.isGroup));
    }
    for (const e of data.edges) {
      if (String(e.id).includes("note")) continue;
      edges.push(edge(e.start, e.end, e.label));
    }
  } else if (t === "classDiagram" || t === "class") {
    kind = "class";
    const data = db.getData();
    for (const n of data.nodes) {
      if (n.shape === "note") continue;
      nodes.push(node(n.id, n.label, n.parentId, n.isGroup));
    }
    for (const e of data.edges) {
      if (String(e.id).startsWith("edgeNote")) continue;
      edges.push(edge(e.start, e.end, e.label));
    }
  } else if (t === "er") {
    kind = "er";
    const ents = db.getEntities();
    const idToName = new Map();
    for (const [name, e] of ents.entries()) {
      idToName.set(e.id, name);
      nodes.push(node(name, e.alias || name, null, false));
    }
    for (const r of db.getRelationships()) edges.push(edge(idToName.get(r.entityA) ?? r.entityA, idToName.get(r.entityB) ?? r.entityB, r.roleA));
  }
  return `{"kind":${JSON.stringify(kind)},"nodes":${sorted(nodes)},"edges":${sorted(edges)},"notes":${sorted(notes)}}`;
}

function splitCorpus(text) {
  const cases = [];
  let cur = null;
  for (const ln of text.split("\n")) {
    if (ln.startsWith("%%CASE ")) {
      cur = { name: ln.slice(7).trim(), body: [] };
      cases.push(cur);
    } else if (cur) cur.body.push(ln);
  }
  return cases.map((c) => ({ name: c.name, src: c.body.join("\n") + "\n" }));
}

for (const c of splitCorpus(fs.readFileSync(process.argv[2], "utf8"))) {
  try {
    const diag = await mermaid.mermaidAPI.getDiagramFromText(c.src);
    out(`${c.name}\tOK\t${normalize(diag)}`);
  } catch (e) {
    out(`${c.name}\tERR\t${String(e && e.message ? e.message : e).replace(/[\n\t]+/g, " ").slice(0, 300)}`);
  }
}
process.exit(0);
