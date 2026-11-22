// Reference layout extractor: KaTeX's own TeX box height/depth (em) of the rendered HTML tree.
// Usage: KATEX_PATH=/path/to/node_modules/katex node katex_layout.mjs <cases_path>
import fs from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const katex = require(process.env.KATEX_PATH || "katex");
const f3 = (v) => {
  const s = Math.round(Math.abs(v) * 1000);
  return (v < 0 && s > 0 ? "-" : "") + Math.floor(s / 1000) + "." + String(s % 1000).padStart(3, "0");
};
const out = [];
for (const line of fs.readFileSync(process.argv[2], "utf8").split("\n")) {
  if (line.length < 2) continue;
  try {
    const tree = katex.__renderToHTMLTree(line.slice(2), { displayMode: line.charCodeAt(0) === 68 });
    // tree = span.katex > span.katex-html > base spans; KaTeX sets height/depth on the root.
    let h = tree.height, d = tree.depth;
    const html = tree.children.find((c) => c.classes && c.classes.includes("katex-html")) || tree;
    for (const b of html.children || []) { h = Math.max(h, b.height); d = Math.max(d, b.depth); }
    out.push("OK " + f3(h) + " " + f3(d));
  } catch (e) {
    out.push("ERR " + String(e.message).replace(/\n/g, " "));
  }
}
process.stdout.write(out.join("\n") + "\n");
