"use strict";
// Reference oracle: Node `ajv@8.17.1` (+ `ajv-formats@3.0.1` when fmt=true), strict:false.
// Usage: NODE_PATH=<dir>/node_modules node oracle.js <cases.jsonl>
// Output per line: id \t IS \t VAL \t ms \t nerr   (VAL mirrors IS: ajv has a single path)
const fs = require("node:fs");
const Ajv2020 = require("ajv/dist/2020").default;
const AjvDraft7 = require("ajv").default;
const addFormats = require("ajv-formats").default;

const lines = fs.readFileSync(process.argv[2], "utf8").split("\n").filter((l) => l.length > 0);
const out = [];
lines.forEach((line, li) => {
  let c;
  try { c = JSON.parse(line); } catch (e) { out.push(`line${li}\tX:${e.message}\t-\t0\t0`); return; }
  const id = c.id || `line${li}`;
  const t0 = process.hrtime.bigint();
  let res;
  try {
    const Cls = c.draft === "7" ? AjvDraft7 : Ajv2020;
    const ajv = new Cls({ strict: false, allErrors: true, validateFormats: !!c.fmt, unicodeRegExp: true });
    if (c.fmt) addFormats(ajv);
    const v = ajv.compile(c.schema);
    const ok = v(c.instance);
    const n = ok ? 0 : (v.errors || []).length;
    res = `${ok ? "V" : "I"}\t${ok ? "V" : "I"}\t#\t${n}`;
  } catch (e) {
    res = `E:${String(e.message).replace(/[\t\n]/g, " ").slice(0, 60)}\t-\t#\t0`;
  }
  const ms = Number((process.hrtime.bigint() - t0) / 1000000n);
  out.push(`${id}\t${res.replace("#", String(ms))}`);
});
process.stdout.write(out.join("\n") + "\n");
