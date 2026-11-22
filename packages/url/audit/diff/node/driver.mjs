// Third-party WHATWG tie-breaker oracle (Node.js `URL`, backed by Ada) for the
// `url` red-team audit. Same hex/TAB protocol as audit/diff/{pion,rust}.
// Only WHATWG-observable behaviour is reproduced; rust-url native setters
// (`set_scheme`, `set_host`, ...) have no WHATWG counterpart and yield "NA".
import { createInterface } from "node:readline";
import { domainToASCII, domainToUnicode } from "node:url";

const unhex = (s) => (s === "~" ? null : Buffer.from(s, "hex").toString("utf8"));
const hex = (s) => Buffer.from(s, "utf8").toString("hex");

function dump(u) {
  return [
    "OK", u.href, u.protocol, u.username, u.password, u.host, u.hostname, u.port,
    u.pathname, u.search, u.hash, u.origin,
    // cannot-be-a-base (opaque path): serialization after `scheme:` does not start with '/'
    u.href.slice(u.protocol.length).startsWith("/") ? "base" : "opaque",
  ];
}

const QUIRKS = new Set(["protocol", "username", "password", "host", "hostname", "port",
  "pathname", "search", "hash", "href"]);

function pctDecode(s) {
  const b = Buffer.from(s, "utf8");
  const out = [];
  for (let i = 0; i < b.length; i++) {
    const h = (c) => /[0-9a-fA-F]/.test(String.fromCharCode(c));
    if (b[i] === 0x25 && i + 2 < b.length && h(b[i + 1]) && h(b[i + 2])) {
      out.push(parseInt(String.fromCharCode(b[i + 1], b[i + 2]), 16));
      i += 2;
    } else out.push(b[i]);
  }
  return new TextDecoder("utf-8").decode(Uint8Array.from(out));
}

function run(f) {
  const op = f[0];
  const a = (i) => (i < f.length && f[i] !== null ? f[i] : "");
  switch (op) {
    case "P": {
      try { return dump(new URL(a(1))); } catch { return ["ERR"]; }
    }
    case "J": {
      let b;
      try { b = new URL(a(1)); } catch { return ["BASEERR"]; }
      try { return dump(new URL(a(2), b)); } catch { return ["ERR"]; }
    }
    case "S": {
      let u;
      try { u = new URL(a(1)); } catch { return ["BASEERR"]; }
      const out = [];
      for (let i = 2; i < f.length; i += 2) {
        const name = a(i);
        if (!QUIRKS.has(name)) return ["NA"];
        if (name === "href") {
          try { u.href = a(i + 1); out.push("SETOK"); } catch { out.push("SETERR"); }
        } else {
          u[name] = a(i + 1);
          out.push("SET?");
        }
      }
      return out.concat(dump(u));
    }
    case "R": return ["NA"];
    case "A": return [domainToASCII(a(1))];
    case "U": return [domainToUnicode(a(1))];
    case "D": return [pctDecode(a(1))];
    case "Q": {
      const p = new URLSearchParams(a(1));
      const out = [];
      let n = 0;
      for (const [k, v] of p) { out.push(k, v); n++; }
      return [String(n), ...out, p.toString()];
    }
    case "M": {
      const p = new URLSearchParams(a(1));
      const out = [];
      for (let i = 2; i < f.length;) {
        const o = a(i);
        if (o === "d") { p.delete(a(i + 1)); i += 2; }
        else if (o === "s") { p.set(a(i + 1), a(i + 2)); i += 3; }
        else if (o === "a") { p.append(a(i + 1), a(i + 2)); i += 3; }
        else if (o === "sort") { p.sort(); i += 1; }
        else if (o === "g") { const v = p.get(a(i + 1)); out.push(v === null ? "<none>" : v); i += 2; }
        else if (o === "h") { out.push(String(p.has(a(i + 1)))); i += 2; }
        else return ["UNKNOWN-M-OP"];
      }
      let n = 0;
      for (const _ of p) n++;
      return [...out, String(n), p.toString()];
    }
    default: return ["UNKNOWN-OP"];
  }
}

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
const buf = [];
for await (const line of rl) {
  if (!line) continue;
  const f = line.split("\t").map(unhex);
  buf.push(run(f).map(hex).join("\t"));
  if (buf.length >= 4096) { process.stdout.write(buf.join("\n") + "\n"); buf.length = 0; }
}
if (buf.length) process.stdout.write(buf.join("\n") + "\n");
