import fs from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const katexPath = process.env.KATEX_PATH || "katex";
const katex = require(katexPath);

const corpusPath = process.argv[2];
const iters = parseInt(process.argv[3] || "20", 10);
if (!corpusPath) {
  console.error("usage: node katex_bench.mjs <corpus_path> <iters>");
  process.exit(1);
}

const raw = fs.readFileSync(corpusPath, "utf8");
const lines = raw.split("\n");
const formulas = [];
for (const line of lines) {
  if (line.length >= 2) {
    formulas.push([line.charCodeAt(0) === 68, line.slice(2)]);
  }
}

const n = formulas.length;
let totalBytes = 0;
const firstPass = [];

for (let iter = 0; iter < iters; iter++) {
  for (let j = 0; j < n; j++) {
    const [dm, tex] = formulas[j];
    const mml = katex.renderToString(tex, { output: "mathml", displayMode: dm });
    totalBytes += Buffer.byteLength(mml, "utf8");
    if (iter === 0) {
      firstPass.push(mml);
    }
  }
}

firstPass.push(`COUNT=${n * iters} BYTES=${totalBytes}`);
process.stdout.write(firstPass.join("\n") + "\n");
