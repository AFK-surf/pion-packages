#!/usr/bin/env node
// Token-classification differential: per-byte coarse class (C=comment, S=string/char/regex literal, O=other code)
// of pion `highlight` vs shiki (TextMate grammars, same as VS Code) and prismjs, on the given files.
// usage: PROBE=<probe bin> REF_NODE_MODULES=<node_modules> node token_diff.mjs [--corpus corpus.txt] <file>...
// Language is the file's basename (rust.rs -> rust). Prints per-file agreement and every disagreeing run vs shiki.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const require = createRequire(path.join(process.env.REF_NODE_MODULES, "_"));
const Prism = require("prismjs");
require("prismjs/components/")(["rust", "typescript", "jsx", "tsx", "go", "python", "c", "cpp", "json", "yaml", "toml", "sql", "bash", "css", "markup", "markdown", "diff"]);
const { createHighlighter } = await import(pathToFileURL(require.resolve("shiki")).href);
const PRISM = { javascript: "javascript", typescript: "typescript", tsx: "tsx", html: "markup", shell: "bash", markdown: "markdown" };
const SHIKI = { shell: "bash" };
const PION = { tsx: "tsx" };

let files = process.argv.slice(2);
const jobs = [];
if (files[0] === "--corpus") {
  const raw = fs.readFileSync(files[1], "utf8");
  files = files.slice(2);
  let cur = null;
  const ents = [];
  for (const line of raw.split("\n")) {
    if (line.length > 11 && line.startsWith("===LANG:") && line.endsWith("===")) { cur = { lang: line.slice(8, -3), lines: [] }; ents.push(cur); }
    else if (cur) cur.lines.push(line);
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "hl-corpus-"));
  for (const e of ents) { const f = path.join(dir, e.lang + ".txt"); fs.writeFileSync(f, e.lines.join("\n")); jobs.push({ lang: e.lang, file: f, label: "corpus/" + e.lang }); }
}
for (const f of files) jobs.push({ lang: path.basename(f).replace(/\..*$/, ""), file: f, label: path.basename(f) });

const hl = await createHighlighter({ themes: ["github-dark"], langs: [...new Set(jobs.map((j) => SHIKI[j.lang] || j.lang))] });

function pionClasses(lang, file, n) {
  const k = new Array(n).fill("O");
  const out = execFileSync(process.env.PROBE, ["spans", PION[lang] || lang, file]).toString();
  for (const l of out.split("\n")) {
    if (!l) continue;
    const [a, b, c] = l.split(" ");
    const cls = c === "comment" ? "C" : c === "string" ? "S" : "O";
    for (let i = +a; i < +b; i++) k[i] = cls;
  }
  return k;
}
function shikiScopeClass(scopes) {
  // Keys are not literals for this comparison (pion: Property, prism: property): JSON/YAML/TOML keys, YAML plain scalars.
  if (scopes.some((s) => /property-name|entity\.name\.tag\.yaml|string\.unquoted|support\.type\.property/.test(s))) return "O";
  for (let i = scopes.length - 1; i >= 0; i--) {
    const s = scopes[i];
    if (/^(meta\.embedded|meta\.template\.expression|punctuation\.definition\.template-expression|punctuation\.section\.embedded|source\.|meta\.interpolation|constant\.character\.format)/.test(s) && i > 0) return "O";
    if (s.startsWith("comment") || s.startsWith("punctuation.definition.comment")) return "C";
    if (s.startsWith("string") || s.startsWith("constant.character.escape") || s.startsWith("markup.inline.raw") || s.startsWith("markup.raw")) return "S";
  }
  return "O";
}
function shikiClasses(lang, src, buf) {
  const k = new Array(buf.length).fill("O");
  const r = hl.codeToTokens(src, { lang: SHIKI[lang] || lang, theme: "github-dark", includeExplanation: true });
  const lines = src.split("\n");
  let off = 0;
  r.tokens.forEach((line, li) => {
    let lo = off;
    for (const t of line) for (const ex of t.explanation) {
      const cls = shikiScopeClass(ex.scopes.map((s) => s.scopeName));
      const n = Buffer.byteLength(ex.content);
      for (let i = 0; i < n; i++) k[lo + i] = cls;
      lo += n;
    }
    off += Buffer.byteLength(lines[li] ?? "") + 1;
  });
  return k;
}
function prismClasses(lang, src, buf) {
  const k = new Array(buf.length).fill("O");
  let off = 0;
  const walk = (t, cls) => {
    if (typeof t === "string") { const n = Buffer.byteLength(t); for (let i = 0; i < n; i++) k[off + i] = cls; off += n; return; }
    if (Array.isArray(t)) return t.forEach((x) => walk(x, cls));
    const ty = t.type;
    let c = cls;
    if (/comment|prolog/.test(ty)) c = "C";
    else if (/^(string|char|template-string|regex|attr-value|url|raw-string|heredoc|code-block|code-snippet|byte-string)$/.test(ty)) c = "S";
    else if (/interpolation|embedded|script|style|code-language/.test(ty)) c = "O";
    walk(t.content, c);
  };
  walk(Prism.tokenize(src, Prism.languages[PRISM[lang] || lang]), "O");
  return k;
}

let worst = [];
console.log("| input | bytes | pion≡shiki | pion≡prism | prism≡shiki | C/S bytes shiki | pion missed/wrong C/S bytes |");
console.log("| --- | ---: | ---: | ---: | ---: | ---: | ---: |");
for (const j of jobs) {
  const src = fs.readFileSync(j.file, "utf8");
  const buf = Buffer.from(src);
  const p = pionClasses(j.lang, j.file, buf.length), s = shikiClasses(j.lang, src, buf), r = prismClasses(j.lang, src, buf);
  let ps = 0, pr = 0, rs = 0, n = 0, cs = 0, bad = 0;
  const runs = [];
  for (let i = 0; i < buf.length; i++) {
    if (buf[i] === 10 || buf[i] === 32 || buf[i] === 9 || buf[i] === 13) continue;
    n++;
    if (p[i] === s[i]) ps++;
    if (p[i] === r[i]) pr++;
    if (r[i] === s[i]) rs++;
    if (s[i] !== "O") cs++;
    if (p[i] !== s[i] && (s[i] !== "O" || p[i] !== "O")) {
      bad++;
      const last = runs[runs.length - 1];
      if (last && last.end >= i - 3 && last.p === p[i] && last.s === s[i]) last.end = i + 1;
      else runs.push({ start: i, end: i + 1, p: p[i], s: s[i] });
    }
  }
  const pct = (x) => (n ? ((100 * x) / n).toFixed(1) + "%" : "-");
  console.log(`| ${j.label} | ${buf.length} | ${pct(ps)} | ${pct(pr)} | ${pct(rs)} | ${cs} | ${bad} |`);
  if (!j.label.startsWith("corpus/") || process.env.SHOW_CORPUS_RUNS) for (const run of runs) worst.push({ label: j.label, ...run, text: buf.subarray(run.start, run.end).toString(), line: buf.subarray(0, run.start).toString().split("\n").length });
}
if (process.env.SHOW_RUNS !== "0") {
  console.log("\nDisagreeing runs vs shiki (pion class -> shiki class), C=comment S=string O=code:");
  for (const w of worst) console.log(`  ${w.label}:${w.line}  pion=${w.p} shiki=${w.s}  ${JSON.stringify(w.text.length > 70 ? w.text.slice(0, 70) + "…" : w.text)}`);
}
