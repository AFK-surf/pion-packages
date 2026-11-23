'use strict';
const fs = require('fs');
const { parse, print, stripIgnoredCharacters } = require('graphql');

function fnv1aUpdate(hash, str) {
  const buf = Buffer.from(str, 'utf8');
  for (let i = 0; i < buf.length; i++) {
    hash ^= buf[i];
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return hash;
}

function checkValueInputFields(val, errs) {
  const stack = [val];
  while (stack.length > 0) {
    const cur = stack.pop();
    if (cur.kind === 'ListValue') {
      for (let i = cur.values.length - 1; i >= 0; i--) {
        stack.push(cur.values[i]);
      }
    } else if (cur.kind === 'ObjectValue') {
      const seen = new Set();
      for (const f of cur.fields) {
        if (seen.has(f.name.value)) {
          errs.count++;
        } else {
          seen.add(f.name.value);
        }
        stack.push(f.value);
      }
    }
  }
}

function checkArgs(args, errs) {
  if (!args || args.length === 0) return;
  const seen = new Set();
  for (const a of args) {
    if (seen.has(a.name.value)) {
      errs.count++;
    } else {
      seen.add(a.name.value);
    }
    checkValueInputFields(a.value, errs);
  }
}

function checkDirs(dirs, errs) {
  if (!dirs) return;
  for (const d of dirs) {
    checkArgs(d.arguments, errs);
  }
}

function walkSelSet(ss, fragMap, spreads, errs) {
  const stack = [ss];
  while (stack.length > 0) {
    const cur = stack.pop();
    for (const sel of cur.selections) {
      if (sel.kind === 'Field') {
        checkArgs(sel.arguments, errs);
        checkDirs(sel.directives, errs);
        if (sel.selectionSet) stack.push(sel.selectionSet);
      } else if (sel.kind === 'FragmentSpread') {
        checkDirs(sel.directives, errs);
        const idx = fragMap.get(sel.name.value);
        if (idx === undefined) {
          errs.count++;
        } else {
          spreads.push(idx);
        }
      } else if (sel.kind === 'InlineFragment') {
        checkDirs(sel.directives, errs);
        stack.push(sel.selectionSet);
      }
    }
  }
}

function validateDocJs(doc) {
  const opNames = new Set();
  const fragMap = new Map();
  const ops = [];
  const frags = [];
  let anonOps = 0;
  const errs = { count: 0 };

  for (const def of doc.definitions) {
    if (def.kind === 'OperationDefinition') {
      ops.push(def);
      if (def.name) {
        if (opNames.has(def.name.value)) errs.count++;
        else opNames.add(def.name.value);
      } else {
        anonOps++;
      }
      if (def.variableDefinitions) {
        const vseen = new Set();
        for (const vd of def.variableDefinitions) {
          const vn = vd.variable.name.value;
          if (vseen.has(vn)) errs.count++;
          else vseen.add(vn);
          if (vd.defaultValue) checkValueInputFields(vd.defaultValue, errs);
          checkDirs(vd.directives, errs);
        }
      }
      checkDirs(def.directives, errs);
    } else if (def.kind === 'FragmentDefinition') {
      const fn = def.name.value;
      if (fragMap.has(fn)) {
        errs.count++;
      } else {
        fragMap.set(fn, frags.length);
        frags.push(def);
      }
    }
  }
  if (anonOps > 0 && ops.length > 1) errs.count++;

  const fragEdges = [];
  for (const f of frags) {
    const sp = [];
    checkDirs(f.directives, errs);
    walkSelSet(f.selectionSet, fragMap, sp, errs);
    fragEdges.push(sp);
  }
  for (const op of ops) {
    const sp = [];
    walkSelSet(op.selectionSet, fragMap, sp, errs);
  }

  const color = new Uint8Array(frags.length);
  let reported = false;
  for (let i = 0; i < frags.length; i++) {
    if (color[i] === 0) {
      color[i] = 1;
      const stack = [[i, 0]];
      while (stack.length > 0) {
        const top = stack[stack.length - 1];
        const u = top[0];
        if (top[1] < fragEdges[u].length) {
          const v = fragEdges[u][top[1]++];
          if (color[v] === 1) {
            if (!reported) {
              errs.count++;
              reported = true;
            }
          } else if (color[v] === 0) {
            color[v] = 1;
            stack.push([v, 0]);
          }
        } else {
          color[u] = 2;
          stack.pop();
        }
      }
    }
  }
  return [ops.length, frags.length, errs.count];
}

const mode = process.argv[2];
const filePath = process.argv[3];
const iters = parseInt(process.argv[4] || '1', 10);
const src = fs.readFileSync(filePath, 'utf8');

if (mode === 'sdl') {
  let totalDefs = 0;
  let totalObjs = 0;
  let totalFields = 0;
  for (let r = 0; r < iters; r++) {
    const doc = parse(src, { noLocation: true });
    totalDefs += doc.definitions.length;
    for (const def of doc.definitions) {
      if (def.kind === 'ObjectTypeDefinition') {
        totalObjs++;
        if (def.fields) totalFields += def.fields.length;
      } else if (def.kind === 'ObjectTypeExtension') {
        if (def.fields) totalFields += def.fields.length;
      }
    }
  }
  console.log(`mode=sdl\niters=${iters}\ndefinitions=${totalDefs}\nobject_types=${totalObjs}\nfields=${totalFields}`);
} else if (mode === 'queries') {
  const queries = src.split('\n###QUERY###\n');
  let totalQ = 0;
  let totalOps = 0;
  let totalFrags = 0;
  let totalErrs = 0;
  for (let r = 0; r < iters; r++) {
    for (let i = 0; i < queries.length; i++) {
      const doc = parse(queries[i], { noLocation: true });
      const [ops, frags, errs] = validateDocJs(doc);
      totalQ++;
      totalOps += ops;
      totalFrags += frags;
      totalErrs += errs;
    }
  }
  console.log(`mode=queries\niters=${iters}\nqueries=${totalQ}\nops=${totalOps}\nfrags=${totalFrags}\nval_errors=${totalErrs}`);
} else if (mode === 'roundtrip') {
  const queries = src.split('\n###QUERY###\n');
  let totalQ = 0;
  let totalMinBytes = 0;
  let minHash = 2166136261 >>> 0;
  let totalDefs = 0;
  let totalPrintedOk = 0;
  for (let r = 0; r < iters; r++) {
    for (let i = 0; i < queries.length; i++) {
      const min = stripIgnoredCharacters(queries[i]);
      totalMinBytes += Buffer.byteLength(min, 'utf8');
      minHash = fnv1aUpdate(minHash, min);
      const doc = parse(min, { noLocation: true });
      const printed = print(doc);
      if (printed.length > 0) totalPrintedOk++;
      totalDefs += doc.definitions.length;
      totalQ++;
    }
  }
  console.log(`mode=roundtrip\niters=${iters}\nqueries=${totalQ}\nmin_bytes=${totalMinBytes}\nmin_fnv1a=${minHash}\ndefs=${totalDefs}\nprinted_ok=${totalPrintedOk}`);
} else {
  console.error('unknown mode:', mode);
  process.exit(1);
}
