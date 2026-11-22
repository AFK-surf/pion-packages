// Red-team differential driver (reference side): real npm `katex`.
// Usage: KATEX_PATH=/path/to/node_modules/katex node katex_diff.mjs <cases_path>
import fs from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const katex = require(process.env.KATEX_PATH || "katex");
const out = [];
for (const line of fs.readFileSync(process.argv[2], "utf8").split("\n")) {
  if (line.length < 2) continue;
  const dm = line.charCodeAt(0) === 68;
  const tex = line.slice(2);
  try {
    out.push("OK " + katex.renderToString(tex, { output: "mathml", displayMode: dm }));
  } catch (e) {
    out.push("ERR " + String(e.message).replace(/\n/g, " "));
  }
}
process.stdout.write(out.join("\n") + "\n");
