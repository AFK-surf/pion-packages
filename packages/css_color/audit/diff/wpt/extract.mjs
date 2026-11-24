// Extract (kind, specified, expected...) vectors from WPT css/css-color/parsing/*.html without a browser:
// every inline <script> is evaluated in a vm context whose test helpers only record their arguments.
//   node extract.mjs <dir with the .html files> > vectors.tsv
// Output: one line per call: kind \t file \t specified \t expected-alternatives joined by " || " (or "-") \t epsilon
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const dir = process.argv[2];
const out = [];
const esc = (s) => String(s).replace(/\\/g, "\\\\").replace(/\t/g, "\\t").replace(/\n/g, "\\n");
const exp = (e) => (e === undefined || e === null ? "-" : Array.isArray(e) ? e.map(esc).join(" || ") : esc(e));
for (const file of fs.readdirSync(dir).filter((f) => f.endsWith(".html")).sort()) {
  const html = fs.readFileSync(path.join(dir, file), "utf8");
  const scripts = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  const rec = (kind) => (spec, expd, eps) => out.push([kind, file, esc(spec), exp(expd), eps === undefined ? "-" : String(eps)].join("\t"));
  const stub = new Proxy(function () {}, { get: (t, k) => (k === Symbol.toPrimitive ? () => "" : stub), apply: () => stub, construct: () => stub, set: () => true });
  const ctx = {
    test_computed_value: (prop, spec, expd) => out.push(["computed", file, esc(spec), exp(expd), prop === "color" ? "-" : "prop:" + prop].join("\t")),
    fuzzy_test_computed_color: rec("computed_fuzzy"),
    fuzzy_test_computed_color_property: (prop, spec, expd, eps) => rec("computed_fuzzy")(spec, expd, eps),
    test_valid_value: (prop, spec, expd) => out.push(["valid", file, esc(spec), exp(expd), "-"].join("\t")),
    fuzzy_test_valid_color: rec("valid_fuzzy"),
    test_invalid_value: (prop, spec) => out.push(["invalid", file, esc(spec), "-", "-"].join("\t")),
    test: () => {}, setup: () => {}, promise_test: () => {}, async_test: () => stub,
    document: stub, window: stub, getComputedStyle: stub, CSS: stub, console,
  };
  vm.createContext(ctx);
  for (const s of scripts) {
    try { vm.runInContext(s, ctx, { filename: file }); } catch (e) { console.error(`${file}: ${e.message}`); }
  }
}
process.stdout.write(out.join("\n") + "\n");
