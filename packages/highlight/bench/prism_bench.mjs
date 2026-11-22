#!/usr/bin/env node
// Head-to-head Node.js benchmark driver using official `prismjs`.
import fs from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const prismSpec = process.env.PRISM_PATH || "prismjs";
const Prism = require(prismSpec);
const loadLanguages = require(`${prismSpec}/components/`);

loadLanguages([
  "rust",
  "typescript",
  "go",
  "python",
  "json",
  "yaml",
  "c",
  "css",
  "markup",
]);

const LANG_MAP = {
  rust: "rust",
  typescript: "typescript",
  go: "go",
  python: "python",
  json: "json",
  yaml: "yaml",
  c: "c",
  css: "css",
  html: "markup",
};

function fnv1aUpdateBuf(h, buf) {
  for (let i = 0; i < buf.length; i++) {
    h = Math.imul(h ^ buf[i], 16777619) >>> 0;
  }
  return h;
}

function hex8(v) {
  return (v >>> 0).toString(16).padStart(8, "0");
}

function parseCorpus(raw) {
  const entries = [];
  const lines = raw.split("\n");
  let curName = "";
  let curLines = [];
  let hasCur = false;
  for (const line of lines) {
    if (line.length > 11 && line.startsWith("===LANG:") && line.endsWith("===")) {
      if (hasCur) {
        entries.push({ name: curName, src: curLines.join("\n") });
      }
      curName = line.slice(8, -3);
      curLines = [];
      hasCur = true;
    } else if (hasCur) {
      curLines.push(line);
    }
  }
  if (hasCur) {
    entries.push({ name: curName, src: curLines.join("\n") });
  }
  return entries;
}

function walkTokens(tokens, state) {
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (typeof t === "string") {
      const buf = Buffer.from(t, "utf8");
      state.len += buf.length;
      state.langHash = fnv1aUpdateBuf(state.langHash, buf);
      state.totalHash = fnv1aUpdateBuf(state.totalHash, buf);
      state.leaves += 1;
    } else if (t && typeof t === "object") {
      state.typed += 1;
      if (typeof t.content === "string") {
        const buf = Buffer.from(t.content, "utf8");
        state.len += buf.length;
        state.langHash = fnv1aUpdateBuf(state.langHash, buf);
        state.totalHash = fnv1aUpdateBuf(state.totalHash, buf);
        state.leaves += 1;
      } else if (Array.isArray(t.content)) {
        walkTokens(t.content, state);
      }
    }
  }
}

const args = process.argv.slice(2);
if (args.length < 2) {
  console.error("usage: prism_bench.mjs <corpus_path> <iters> [--stats]");
  process.exit(1);
}
const corpusPath = args[0];
const iters = parseInt(args[1], 10) || 100;
const showStats = args[2] === "--stats";

const raw = fs.readFileSync(corpusPath, "utf8");
const entries = parseCorpus(raw);
const n = entries.length;
const srcByteLens = entries.map((e) => Buffer.byteLength(e.src, "utf8"));
const langHashes = new Array(n).fill(0x811c9dc5);
const langBytes = new Array(n).fill(0);
const langTokens = new Array(n).fill(0);

let totalBytes = 0;
let totalFiles = 0;
let totalValid = 0;
let totalHash = 0x811c9dc5;
let totalTyped = 0;
let totalLeaves = 0;

for (let iter = 0; iter < iters; iter++) {
  for (let j = 0; j < n; j++) {
    const { name, src } = entries[j];
    const grammar = Prism.languages[LANG_MAP[name]];
    const tokens = Prism.tokenize(src, grammar);
    const st = {
      len: 0,
      langHash: langHashes[j],
      totalHash,
      leaves: 0,
      typed: 0,
    };
    walkTokens(tokens, st);
    if (st.len === srcByteLens[j]) {
      totalValid += 1;
    }
    langHashes[j] = st.langHash;
    totalHash = st.totalHash;
    langBytes[j] += srcByteLens[j];
    if (iter === 0) {
      langTokens[j] = st.leaves;
    }
    totalTyped += st.typed;
    totalLeaves += st.leaves;
    totalBytes += srcByteLens[j];
    totalFiles += 1;
  }
}

let out = "";
for (let j = 0; j < n; j++) {
  out += `LANG=${entries[j].name} BYTES=${langBytes[j]} CHECKSUM=${hex8(langHashes[j])}\n`;
}
out += `FILES=${totalFiles} BYTES=${totalBytes} VALID=${totalValid} CHECKSUM=${hex8(totalHash)}\n`;
if (showStats) {
  out += `STATS total_leaves=${totalLeaves} typed_tokens=${totalTyped}\n`;
  for (let j = 0; j < n; j++) {
    out += `  ${entries[j].name}: leaves_per_file=${langTokens[j]}\n`;
  }
}
process.stdout.write(out);
