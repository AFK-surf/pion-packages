// V8 oracle: node v8_validate.mjs <dir> <start> <end>  ->  "<i>\tOK|ERR"
import { readFileSync, existsSync } from "node:fs";
const [dir, s, e] = process.argv.slice(2);
const out = [];
for (let i = Number(s); i < Number(e); i++) {
  const p = `${dir}/${i}.wasm`;
  if (!existsSync(p)) continue;
  let ok = false;
  try { ok = WebAssembly.validate(readFileSync(p)); } catch { ok = false; }
  out.push(`${i}\t${ok ? "OK" : "ERR"}`);
}
process.stdout.write(out.join("\n") + (out.length ? "\n" : ""));
