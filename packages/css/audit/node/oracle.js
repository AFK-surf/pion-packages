#!/usr/bin/env node
// Node css-tree@3.1.0 oracle for the packages/css red-team audit.
//   tok <in> <out>          : token dump in the shared `KIND len:value` format (comments dropped)
//   one <file> tokcount|parse|gen [reps] : timing modes
"use strict";
const fs = require("fs");
const csstree = require("css-tree");
const T = csstree.tokenTypes;

function readRecords(b) {
  const out = [];
  let i = 0;
  while (i < b.length) {
    const j = b.indexOf(10, i);
    const n = parseInt(b.slice(i, j).toString("latin1"), 10);
    out.push(b.slice(j + 1, j + 1 + n).toString("utf8"));
    i = j + 1 + n;
  }
  return out;
}

function item(parts, kind, v) {
  parts.push(Buffer.from(kind + " " + Buffer.byteLength(v, "utf8") + ":" + v, "utf8"));
}

const NUM_RE = /^[+-]?(\d*\.\d+|\d+)([eE][+-]?\d+)?/;
function numParts(text) {
  const m = NUM_RE.exec(text);
  const n = m[0];
  const sign = n[0] === "+" || n[0] === "-" ? "1" : "0";
  const isInt = /[.eE]/.test(n) ? "0" : "1";
  return [sign + isInt, Number(n), text.slice(n.length)];
}

function fmt(v) {
  // shortest round-trip like Pion/Rust; f32 normalisation happens in the comparer
  return Object.is(v, -0) ? "-0" : String(v);
}

function tokDump(src) {
  const parts = [];
  csstree.tokenize(src, (type, start, end) => {
    const t = src.slice(start, end);
    switch (type) {
      case T.Ident: return item(parts, "IDENT", csstree.ident.decode(t));
      case T.Function: return item(parts, "FUNC", csstree.ident.decode(t.slice(0, -1)));
      case T.AtKeyword: return item(parts, "AT", csstree.ident.decode(t.slice(1)));
      case T.Hash: return item(parts, "HASH", csstree.ident.decode(t.slice(1)));
      case T.String: return item(parts, "STR", csstree.string.decode(t));
      case T.BadString: return item(parts, "BADSTR", "");
      case T.Url: return item(parts, "URL", csstree.url.decode(t));
      case T.BadUrl: return item(parts, "BADURL", "");
      case T.Delim: return item(parts, "DELIM", t);
      case T.Number: { const [f, v] = numParts(t); return item(parts, "NUM", f + " " + fmt(v)); }
      case T.Percentage: { const [f, v] = numParts(t); return item(parts, "PCT", f + " " + fmt(v)); }
      case T.Dimension: { const [f, v, u] = numParts(t); return item(parts, "DIM", f + " " + fmt(v) + " " + csstree.ident.decode(u)); }
      case T.WhiteSpace: return item(parts, "WS", "");
      case T.CDO: return item(parts, "CDO", "");
      case T.CDC: return item(parts, "CDC", "");
      case T.Colon: return item(parts, "COLON", "");
      case T.Semicolon: return item(parts, "SEMI", "");
      case T.Comma: return item(parts, "COMMA", "");
      case T.LeftSquareBracket: return item(parts, "LSQ", "");
      case T.RightSquareBracket: return item(parts, "RSQ", "");
      case T.LeftParenthesis: return item(parts, "LPAR", "");
      case T.RightParenthesis: return item(parts, "RPAR", "");
      case T.LeftCurlyBracket: return item(parts, "LCUR", "");
      case T.RightCurlyBracket: return item(parts, "RCUR", "");
      case T.Comment: return undefined;
      default: return item(parts, "UNKNOWN" + type, t);
    }
  });
  return Buffer.concat(parts);
}

const [, , mode, inPath, arg3, arg4] = process.argv;
const data = fs.readFileSync(inPath);
if (mode === "one") {
  const src = data.toString("utf8");
  const reps = parseInt(arg4 || "1", 10);
  let total = 0;
  for (let r = 0; r < reps; r++) {
    if (arg3 === "tokcount") {
      csstree.tokenize(src, (type) => { if (type !== T.WhiteSpace && type !== T.Comment) total++; });
    } else if (arg3 === "parse") {
      const ast = csstree.parse(src, { parseValue: true, parseRulePrelude: true, parseAtrulePrelude: true });
      total += ast.children.size;
    } else if (arg3 === "gen") {
      total += csstree.generate(csstree.parse(src)).length;
    } else if (arg3 === "tok") {
      total += tokDump(src).length;
    }
  }
  console.log("ok " + total);
} else if (mode === "tok") {
  const out = [];
  for (const rec of readRecords(data)) {
    let r;
    try { r = tokDump(rec); } catch (e) { r = Buffer.from("ERR " + e.message, "utf8"); }
    out.push(Buffer.from(r.length + "\n", "latin1"), r);
  }
  fs.writeFileSync(arg3, Buffer.concat(out));
} else {
  console.error("usage: oracle.js tok <in> <out> | one <file> tokcount|parse|gen|tok [reps]");
  process.exit(2);
}
