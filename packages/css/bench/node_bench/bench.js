#!/usr/bin/env node
"use strict";

const fs = require("fs");
const csstree = require("css-tree");

const [, , mode, filePath, itersArg] = process.argv;
if (!mode || !filePath || !itersArg) {
  console.error("usage: bench.js <tokenize|parse|minify> <file> <iters>");
  process.exit(1);
}
const iters = parseInt(itersArg, 10) || 1;
const src = fs.readFileSync(filePath, "utf8");

if (mode === "tokenize") {
  let total = 0;
  const WS = csstree.tokenTypes.WhiteSpace;
  const COMMENT = csstree.tokenTypes.Comment;
  for (let r = 0; r < iters; r++) {
    let c = 0;
    csstree.tokenize(src, (type) => {
      if (type !== WS && type !== COMMENT) {
        c++;
      }
    });
    total += c;
  }
  console.log("mode=tokenize");
  console.log("iters=" + iters);
  console.log("non_ws_tokens=" + total);
} else if (mode === "parse") {
  let qRules = 0;
  let atRules = 0;
  let decls = 0;
  let imps = 0;
  for (let r = 0; r < iters; r++) {
    const ast = csstree.parse(src);
    csstree.walk(ast, (node) => {
      if (node.type === "Rule") {
        qRules++;
      } else if (node.type === "Atrule") {
        atRules++;
      } else if (node.type === "Declaration") {
        decls++;
        if (node.important) {
          imps++;
        }
      }
    });
  }
  console.log("mode=parse");
  console.log("iters=" + iters);
  console.log("qualified_rules=" + qRules);
  console.log("at_rules=" + atRules);
  console.log("declarations=" + decls);
  console.log("important=" + imps);
} else if (mode === "minify") {
  let totalBytes = 0;
  let lastOut = "";
  for (let r = 0; r < iters; r++) {
    const ast = csstree.parse(src);
    const out = csstree.generate(ast);
    totalBytes += Buffer.byteLength(out, "utf8");
    lastOut = out;
  }
  console.log("mode=minify");
  console.log("iters=" + iters);
  console.log("total_bytes=" + totalBytes);
  console.log("sample_head=" + lastOut.slice(0, 120));
} else {
  console.error("unknown mode: " + mode);
  process.exit(1);
}
