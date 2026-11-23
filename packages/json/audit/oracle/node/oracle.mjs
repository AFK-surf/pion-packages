// Node.js (ECMAScript) reference for RFC 8785 JCS: JSON.parse + the RFC 8785 Appendix canonicalizer
// (keys sorted by UTF-16 code units = default JS string order, numbers by Number::toString,
// strings by JSON.stringify). Non-finite numbers (e.g. 1e400 -> Infinity) are an error, as the RFC requires.
import { readFileSync } from "node:fs";

function canon(v) {
  if (v === null || typeof v !== "object") {
    if (typeof v === "number" && !Number.isFinite(v)) throw new Error("non-finite");
    return JSON.stringify(v);
  }
  if (Array.isArray(v)) return "[" + v.map(canon).join(",") + "]";
  const ks = Object.keys(v).sort();
  return "{" + ks.map((k) => JSON.stringify(k) + ":" + canon(v[k])).join(",") + "}";
}

const [mode, path] = process.argv.slice(2);
const lines = readFileSync(path, "utf8").split("\n").filter((l) => l.length > 0);
const out = [];
if (mode === "canon") {
  for (const l of lines) {
    const text = Buffer.from(l.split("\t")[0], "hex").toString("utf8");
    let v;
    try { v = JSON.parse(text); } catch { out.push("PARSE_ERR"); continue; }
    try { out.push("OK " + Buffer.from(canon(v), "utf8").toString("hex")); } catch { out.push("ERR"); }
  }
} else if (mode === "numfmt") {
  const buf = new DataView(new ArrayBuffer(8));
  for (const l of lines) {
    buf.setBigUint64(0, BigInt("0x" + l));
    const x = buf.getFloat64(0);
    out.push(Number.isFinite(x) ? String(x) : "ERR");
  }
} else {
  throw new Error("unknown mode " + mode);
}
process.stdout.write(out.join("\n") + "\n");
