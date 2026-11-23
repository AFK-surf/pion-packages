// Independent, zero-dependency reference for the red-team differential of packages/csp.
//
// URL / origin parsing: Node's built-in WHATWG URL parser (what a browser hands to CSP and Fetch).
// Matching: a direct transcription of W3C CSP3 §6.7.2 ("Does url match source list in origin",
// scheme-part / host-part / port-part / path-part matching, 'self', '*'), written from the spec
// text, NOT from packages/csp or its Rust bench mirror. Where the spec text is ambiguous or engines
// disagree, the reference takes the MORE PERMISSIVE answer, so every "pion allows, reference
// denies" row is a definite over-permission (bypass), never a reference artefact.
//
//   node cspref.mjs gen <out_dir> [n_mutations]   -> corpus.tsv (for `oracle eval`) + ref.tsv
//   node cspref.mjs compare <out_dir> <pion.out>  -> classified diff summary (exit 1 on bypass rows)

import fs from "node:fs";

const hex = (s) => Buffer.from(s, "utf8").toString("hex");

// ---------------------------------------------------------------------------- spec matching
const DEFAULT_PORT = { http: 80, https: 443, ws: 80, wss: 443, ftp: 21 };
const schemeOf = (u) => u.protocol.slice(0, -1);

function schemePartMatch(a, b) {
  // CSP3 §6.7.2.6
  return a === b || (a === "http" && b === "https") || (a === "ws" && ["wss", "http", "https"].includes(b)) ||
    (a === "wss" && b === "https");
}

function hostPartMatch(pattern, host) {
  // CSP3 §6.7.2.7 (IP literals compared as strings: permissive vs the spec's "not a domain" rule)
  pattern = pattern.toLowerCase();
  host = host.toLowerCase();
  if (pattern === "*") return host.length > 0;
  if (pattern.startsWith("*.")) return host.endsWith(pattern.slice(1));
  return pattern === host;
}

function portPartMatch(input, url) {
  // CSP3 §6.7.2.8, plus the http:80 -> https:443 upgrade every engine allows (permissive)
  const sch = schemeOf(url);
  if (input === "") return url.port === "";
  if (input === "*") return true;
  const n = Number(input);
  const eff = url.port === "" ? DEFAULT_PORT[sch] : Number(url.port);
  if (eff === n) return true;
  return n === 80 && (sch === "https" || sch === "wss") && eff === 443;
}

function decode(seg) {
  try { return decodeURIComponent(seg); } catch { return seg; }
}

function pathPartMatch(exprPath, urlPath) {
  // CSP3 §6.7.2.9
  if (exprPath === "") return true;
  if (exprPath === "/" && urlPath === "") return true;
  const exact = !exprPath.endsWith("/");
  const a = exprPath.split("/");
  const b = urlPath.split("/");
  if (a.length > b.length) return false;
  if (exact && a.length !== b.length) return false;
  if (!exact) a.pop();
  for (let i = 0; i < a.length; i++) if (decode(a[i]) !== decode(b[i])) return false;
  return true;
}

function parseHostSource(expr) {
  const m = /^(?:([A-Za-z][A-Za-z0-9+.-]*):\/\/)?(\*|\*\.[^:/]+|\[[0-9A-Fa-f:.]+\]|[^:/*]+)(?::(\*|[0-9]+))?(\/[^?#]*)?$/.exec(expr);
  if (!m) return null;
  return { scheme: m[1] ? m[1].toLowerCase() : null, host: m[2], port: m[3] || "", path: m[4] || "" };
}

function originTuple(page) {
  try {
    const u = new URL(page);
    if (u.origin === "null") return null;
    return { scheme: schemeOf(u), host: u.hostname, port: u.port === "" ? DEFAULT_PORT[schemeOf(u)] : Number(u.port) };
  } catch { return null; }
}

function exprMatches(expr, url, origin) {
  const sch = schemeOf(url);
  if (expr === "*") {
    // permissive: ws/wss accepted too (CSP3 drafts and engines differ)
    return ["http", "https", "ws", "wss"].includes(sch) || (origin !== null && sch === origin.scheme);
  }
  if (/^[A-Za-z][A-Za-z0-9+.-]*:$/.test(expr)) return schemePartMatch(expr.slice(0, -1).toLowerCase(), sch);
  if (expr.toLowerCase() === "'self'") {
    if (origin === null || url.hostname === "") return false;
    const up = url.port === "" ? DEFAULT_PORT[sch] : Number(url.port);
    const sameOrigin = origin.scheme === sch && origin.host === url.hostname && origin.port === up;
    if (sameOrigin) return true;
    return origin.host === url.hostname &&
      (origin.port === up || (origin.port === DEFAULT_PORT[origin.scheme] && up === DEFAULT_PORT[sch])) &&
      (sch === "https" || sch === "wss" || (origin.scheme === "http" && (sch === "http" || sch === "ws")));
  }
  if (expr.startsWith("'")) return false;
  const hs = parseHostSource(expr);
  if (hs === null) return false;
  if (url.hostname === "") return false;
  if (hs.scheme === null) {
    if (origin === null || !schemePartMatch(origin.scheme, sch)) return false;
  } else if (!schemePartMatch(hs.scheme, sch)) return false;
  if (!hostPartMatch(hs.host, url.hostname)) return false;
  if (!portPartMatch(hs.port, url)) return false;
  return pathPartMatch(hs.path, url.pathname);
}

function listMatches(list, url, origin) {
  const real = list.filter((e) => e.toLowerCase() !== "'none'");
  return real.some((e) => exprMatches(e, url, origin));
}

// ---------------------------------------------------------------------------- corpus
const EXPRS = [
  "*", "https:", "http:", "ws:", "wss:", "data:", "blob:", "'self'", "trusted.com", "https://trusted.com",
  "http://trusted.com", "*.trusted.com", "https://*.trusted.com", "https://trusted.com:8443",
  "https://trusted.com:*", "http://trusted.com:80", "https://trusted.com/safe/", "https://trusted.com/safe/file.js",
  "ws://trusted.com", "wss://trusted.com", "https://[::1]:8443", "foo://trusted.com", "trusted.com/safe/",
];
const PAGES = ["https://app.com", "http://app.com", "https://trusted.com", "http://trusted.com", "null"];
const BASE_URLS = [
  "https://trusted.com/x.js", "http://trusted.com/x.js", "https://a.trusted.com/x.js", "https://trusted.com:8443/x.js",
  "https://evil.com/x.js", "https://evil.com\\@trusted.com/x.js", "https://evil.com\\@a.trusted.com/x.js",
  "https://u@trusted.com:1@evil.com/x.js", "https://u@a.trusted.com:443@evil.com/x.js",
  "https://trusted.com:00008443/x.js", "https://trusted.com:000000443/x.js", "https://trusted.com.evil.com/x.js",
  "https://eviltrusted.com/x.js", "https://trusted.com/safe/../evil.js", "https://trusted.com/safe/%2e%2e/evil.js",
  "https://trusted.com/safe/./file.js", "https://trusted.com/safe/file.js?q#f", "https://trusted.com/safe/file.js/",
  "https://trusted.com/saf%65/file.js", "https://trusted.com/safe", "https://trusted.com/safe/sub/x.js",
  "data:text/javascript,alert(1)", "blob:https://trusted.com/uuid", "javascript:alert(1)", "about:blank",
  "filesystem:https://trusted.com/temporary/x", "wss://trusted.com/s", "ws://trusted.com/s", "http://trusted.com:443/x",
  "https://[::1]:8443/x", "HTTPS://TRUSTED.COM/X.JS", "https://trusted.com.:443/x.js", "https://TRUSTED.com./x",
  "https://trusted.com:443/x", "http://trusted.com:80/x", "foo://trusted.com:9999/x", "foo://trusted.com/x",
  "https://trusted.com\t/x.js", "https://tr\nusted.com/x.js", " https://trusted.com/x.js", "https:trusted.com/x.js",
  "https:/trusted.com/x.js", "https:///trusted.com/x.js", "https://evil.com#@trusted.com/", "https://evil.com?@trusted.com/",
  "https://trusted.com%2eevil.com/x", "https://user:pass@trusted.com/x.js", "https://trusted.com:8443:1@evil.com/x",
];
const ALPHA = ["\\", "@", ":", "/", ".", "%2e", "%2f", "?", "#", "*", "0", "00", "\t", " ", "A", "%40", "[", "]", ";"];

function rng(seed) {
  let s = BigInt(seed) * 2654435761n + 88172645463325252n;
  const M = (1n << 64n) - 1n;
  return (n) => {
    s ^= (s << 13n) & M; s ^= s >> 7n; s ^= (s << 17n) & M;
    return Number((s >> 33n) % BigInt(n));
  };
}

function gen(dir, nMut) {
  const r = rng(7);
  const urls = new Set(BASE_URLS);
  while (urls.size < BASE_URLS.length + nMut) {
    const b = BASE_URLS[r(BASE_URLS.length)];
    const p = r(b.length + 1);
    const ins = ALPHA[r(ALPHA.length)];
    const op = r(3);
    const u = op === 0 ? b.slice(0, p) + ins + b.slice(p) : op === 1 ? b.slice(0, p) + ins + b.slice(p + 1) : b.slice(0, p) + b.slice(p + 1);
    urls.add(u);
  }
  const corpus = [];
  const ref = [];
  let id = 0;
  for (const raw of urls) {
    let url;
    try { url = new URL(raw); } catch { continue; } // a browser never fetches an unparsable URL
    const variants = [["raw", raw]];
    if (url.href !== raw) variants.push(["href", url.href]);
    for (const page of PAGES) {
      const origin = originTuple(page);
      for (const e of EXPRS) {
        const want = listMatches([e], url, origin) ? 1 : 0;
        for (const [v, s] of variants) {
          if (/[\t\n\r]/.test(s) && v === "raw") {
            // the CSP header can't carry it, but the URL can: still a valid probe of check_source
          }
          const k = "s" + id++;
          corpus.push([k, "src", hex("img-src"), hex("img-src " + e), hex(page), hex(s)].join("\t"));
          ref.push([k, want, v, e, page, JSON.stringify(s), url.href].join("\t"));
        }
      }
    }
    for (const [v, s] of variants) {
      const k = "o" + id++;
      corpus.push([k, "origin", hex(s)].join("\t"));
      ref.push([k, url.origin, v, "-", "-", JSON.stringify(s), url.href].join("\t"));
    }
  }
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(dir + "/corpus.tsv", corpus.join("\n") + "\n");
  fs.writeFileSync(dir + "/ref.tsv", ref.join("\n") + "\n");
  console.log(`corpus: ${urls.size} candidate URLs, ${corpus.length} records (src x ${EXPRS.length} exprs x ${PAGES.length} pages, raw + href variants, + origin)`);
}

function compare(dir, pionOut) {
  const ref = new Map(fs.readFileSync(dir + "/ref.tsv", "utf8").trim().split("\n").map((l) => {
    const f = l.split("\t");
    return [f[0], f];
  }));
  const got = new Map(fs.readFileSync(pionOut, "utf8").trim().split("\n").map((l) => l.split("\t")));
  const buckets = {};
  const add = (key, row) => { (buckets[key] ||= []).push(row); };
  let n = 0;
  for (const [k, f] of ref) {
    const g = got.get(k);
    n++;
    if (k[0] === "s") {
      const want = f[1];
      if (g === want) { add(`agree/${f[2]}`, f); continue; }
      if (g === "1" && want === "0") add(`BYPASS(pion allows, spec denies)/${f[2]}`, f);
      else if (g === "0" && want === "1") add(`over-block(pion denies, spec allows)/${f[2]}`, f);
      else add(`other(${g})/${f[2]}`, f);
    } else {
      if (g === f[1]) add(`origin agree/${f[2]}`, f);
      else add(`ORIGIN MISMATCH/${f[2]}`, [...f, "pion=" + g]);
    }
  }
  console.log(`records compared: ${n}`);
  for (const key of Object.keys(buckets).sort()) {
    const rows = buckets[key];
    console.log(`  ${key}: ${rows.length}`);
    if (key.startsWith("agree") || key.startsWith("origin agree")) continue;
    // group by expression to keep the output short
    const seen = new Map();
    for (const f of rows) {
      const g = f[0][0] === "s" ? `expr=${f[3]} page=${f[4]}` : "origin";
      if (!seen.has(g)) seen.set(g, []);
      seen.get(g).push(f);
    }
    let shown = 0;
    for (const [g, fs_] of seen) {
      if (shown++ >= 8) { console.log(`      ... ${seen.size - 8} more groups`); break; }
      const ex = fs_.slice(0, 3).map((f) => `${f[5]}${f[0][0] === "o" ? " ref=" + f[1] + " " + f[7] : ""}`).join("  ");
      console.log(`      [${fs_.length}] ${g}: ${ex}`);
    }
  }
  const bypass = Object.keys(buckets).filter((k) => k.startsWith("BYPASS")).reduce((a, k) => a + buckets[k].length, 0);
  console.log(`bypass rows: ${bypass}`);
  process.exit(bypass > 0 ? 1 : 0);
}

const [cmd, a, b] = process.argv.slice(2);
if (cmd === "gen") gen(a, Number(b || 600));
else if (cmd === "compare") compare(a, b);
else { console.error("usage: node cspref.mjs gen <dir> [n] | compare <dir> <pion.out>"); process.exit(2); }
