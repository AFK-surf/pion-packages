#!/usr/bin/env node
// End-to-end HTML reference driver: prismjs `Prism.highlight` or shiki `codeToHtml`, N iterations,
// prints FNV-1a of the tag-stripped + entity-decoded text of the last output (must equal the source bytes).
// usage: REF_NODE_MODULES=/path/node_modules node ref_html.mjs <prism|shiki> <lang> <file> <iters>
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

// corpus mode: node ref_html.mjs <prism|shiki> corpus <corpus.txt> <iters>
const [engine, lang, file, itersArg] = process.argv.slice(2);
const iters = Number(itersArg || 1);
const nm = process.env.REF_NODE_MODULES;
if (!nm) { console.error("REF_NODE_MODULES not set"); process.exit(2); }
const require = createRequire(path.join(nm, "_"));
const src = fs.readFileSync(file, "utf8");
const PRISM = { js: "javascript", javascript: "javascript", ts: "typescript", typescript: "typescript", html: "markup", sh: "bash", shell: "bash", md: "markdown", rs: "rust", py: "python" };
const SHIKI = { sh: "bash", shell: "bash", md: "markdown", rs: "rust", py: "python", js: "javascript", ts: "typescript" };

function decode(html) {
  const text = html.replace(/<[^>]*>/g, "");
  return text.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);/g, (_, e) =>
    e === "amp" ? "&" : e === "lt" ? "<" : e === "gt" ? ">" : e === "quot" ? '"' : e === "apos" ? "'" : e === "nbsp" ? " "
    : e[1] === "x" ? String.fromCodePoint(parseInt(e.slice(2), 16)) : String.fromCodePoint(parseInt(e.slice(1), 10)));
}
function fnv(buf) { let h = 0x811c9dc5; for (const b of buf) h = Math.imul(h ^ b, 16777619) >>> 0; return h.toString(16).padStart(8, "0"); }

async function makeRenderer(l) {
  if (engine === "prism") {
    const Prism = require("prismjs");
    const pl = PRISM[l] || l;
    require("prismjs/components/")([pl]);
    return (s) => Prism.highlight(s, Prism.languages[pl], pl);
  }
  const { createHighlighter } = await import(pathToFileURL(require.resolve("shiki")).href);
  const sl = SHIKI[l] || l;
  const h = await createHighlighter({ themes: ["github-dark"], langs: [sl] });
  return (s) => h.codeToHtml(s, { lang: sl, theme: "github-dark" }).replace(/^<pre[^>]*><code>/, "").replace(/<\/code><\/pre>$/, "");
}

let entries;
if (lang === "corpus") {
  entries = [];
  let cur = null;
  for (const line of src.split("\n")) {
    if (line.length > 11 && line.startsWith("===LANG:") && line.endsWith("===")) { cur = { lang: line.slice(8, -3), lines: [] }; entries.push(cur); }
    else if (cur) cur.lines.push(line);
  }
  entries = entries.map((e) => ({ lang: e.lang, src: e.lines.join("\n") }));
} else entries = [{ lang, src }];

const bufs = [];
let bytes = 0;
for (const e of entries) {
  const render = await makeRenderer(e.lang);
  let html = "";
  for (let i = 0; i < iters; i++) html = render(e.src);
  bufs.push(Buffer.from(decode(html)));
  bytes += Buffer.byteLength(e.src);
}
const h = fnv(Buffer.concat(bufs));
console.log(lang === "corpus" ? `FILES=${entries.length} BYTES=${bytes} TEXT_FNV=${h}` : `BYTES=${bytes} TEXT_FNV=${h}`);
