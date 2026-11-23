// Node reference oracle: json5@2.2.3 (JSON5 v2.0 reference implementation) + fast-json-patch@3.1.1.
// Same CLI and line format as `audit/driver` (Pion). Run with NODE_PATH pointing at a node_modules
// that has both packages (run_audit.sh installs them under $OUT/node).
//
//   node oracle.mjs parse <file> <j5|j5inf|json>   (json = JSON.parse, the strict RFC 8259 reference)
//   node oracle.mjs idscan
//   node oracle.mjs numfmt <file>
//   node oracle.mjs patch <file>
//   node oracle.mjs diffcheck <cases file> <pion diffrt output>
import { createRequire } from 'node:module';
import fs from 'node:fs';
const require = createRequire(process.cwd() + '/');
const JSON5 = require('json5');
const jsonpatch = require('fast-json-patch');

const f64 = new Float64Array(1);
const u64 = new BigUint64Array(f64.buffer);
function num(x) {
  if (Number.isNaN(x)) return 'dNaN';
  f64[0] = x;
  return 'd' + u64[0].toString(16).padStart(16, '0');
}
const hexStr = (s) => Buffer.from(s, 'utf8').toString('hex');
function canon(v) {
  if (v === null) return 'n';
  if (v === true) return 't';
  if (v === false) return 'f';
  if (typeof v === 'number') return num(v);
  if (typeof v === 'string') return 's' + hexStr(v) + ';';
  if (Array.isArray(v)) return '[' + v.map(canon).join(',') + ']';
  return '{' + Object.keys(v).map((k) => hexStr(k) + ':' + canon(v[k])).join(',') + '}';
}
const deepEq = (x, y) => JSON.stringify(sortKeys(x)) === JSON.stringify(sortKeys(y));
const sortKeys = (v) => Array.isArray(v) ? v.map(sortKeys) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys(v[k])])) : v;
const unhex = (h) => Buffer.from(h, 'hex').toString('utf8');
const lines = (p) => {
  const t = fs.readFileSync(p, 'utf8');
  const ls = t.split('\n');
  if (ls.length && ls[ls.length - 1] === '') ls.pop();
  return ls;
};
const out = [];
const [mode, a1, a2] = process.argv.slice(2);

if (mode === 'parse') {
  for (const l of lines(a1)) {
    try {
      const src = unhex(l);
      const v = a2 === 'json' ? JSON.parse(src) : JSON5.parse(src);
      out.push('OK ' + canon(v));
    } catch {
      out.push('ERR');
    }
  }
} else if (mode === 'idscan') {
  const ok = (s) => {
    try { JSON5.parse(s); return true; } catch { return false; }
  };
  let row = '';
  for (let cp = 0x80; cp <= 0x10ffff; cp++) {
    if (cp >= 0xd800 && cp <= 0xdfff) { cp = 0xdfff; continue; }
    const x = String.fromCodePoint(cp);
    let m = 0;
    if (ok('{' + x + ':1}')) m |= 1;
    if (ok('{a' + x + ':1}')) m |= 2;
    if (ok('[' + x + '1]')) m |= 4;
    if (cp < 0x10000) {
      const e = '\\u' + cp.toString(16).padStart(4, '0');
      if (ok('{' + e + ':1}')) m |= 8;
      if (ok('{a' + e + ':1}')) m |= 16;
    }
    row += String.fromCharCode(65 + m);
    if (row.length === 256) { out.push(row); row = ''; }
  }
  out.push(row);
} else if (mode === 'numfmt') {
  for (const l of lines(a1)) {
    u64[0] = BigInt('0x' + l);
    const x = f64[0];
    if (!Number.isFinite(x)) { out.push('ERR'); continue; }
    const s = JSON.stringify(x);
    out.push(s + ' ' + num(JSON5.parse(s)));
  }
} else if (mode === 'patch') {
  for (const l of lines(a1)) {
    const [dh, ph] = l.split(' ');
    let doc;
    try { doc = JSON5.parse(unhex(dh)); } catch { out.push('BADDOC'); continue; }
    try {
      const ops = JSON5.parse(unhex(ph));
      const r = jsonpatch.applyPatch(doc, ops, true, true, false).newDocument;
      out.push('OK ' + canon(r));
    } catch {
      out.push('ERR');
    }
  }
} else if (mode === 'diffcheck') {
  // Apply Pion's diff() output with fast-json-patch and check it really produces b;
  // also report fast-json-patch's own compare() op count for size comparison.
  const cases = lines(a1);
  const pion = lines(a2);
  cases.forEach((l, i) => {
    const [ah, bh] = l.split(' ');
    const a = JSON.parse(unhex(ah));
    const b = JSON.parse(unhex(bh));
    let fjp;
    try { fjp = jsonpatch.compare(a, b).length; } catch { fjp = -1; } // fast-json-patch crashes on some null-vs-object pairs
    const [, , ph] = pion[i].split(' ');
    let verdict;
    try {
      const r = jsonpatch.applyPatch(jsonpatch.deepClone(a), JSON.parse(unhex(ph)), true, true).newDocument;
      verdict = JSON.stringify(canon(r)) === JSON.stringify(canon(b)) || deepEq(r, b) ? 'NODE_OK' : 'NODE_MISMATCH';
    } catch (e) {
      verdict = 'NODE_REJECT:' + (e.name || 'err');
    }
    out.push(verdict + ' ' + fjp);
  });
} else if (mode === 'adv') {
  const [, w, f1, f2] = process.argv.slice(2);
  const rd = (p) => JSON5.parse(fs.readFileSync(p, 'utf8'));
  const rj = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
  if (w === 'unikeys') {
    let keys = 0, bytes = 0;
    const walk = (v) => {
      if (Array.isArray(v)) v.forEach(walk);
      else if (v && typeof v === 'object') for (const k of Object.keys(v)) { keys++; bytes += Buffer.byteLength(k); walk(v[k]); }
    };
    walk(rd(f1));
    out.push(`keys=${keys} key_bytes=${bytes}`);
  } else if (w === 'numbers') {
    const a = rd(f1);
    let x = 0n;
    for (const d of a) { f64[0] = d; x ^= u64[0]; }
    out.push(`n=${a.length} xor=${x.toString(16).padStart(16, '0')}`);
  } else if (w === 'widetest') {
    const a = rj(f1), b = rj(f2);
    let ok = 'ok';
    try { jsonpatch.applyPatch(a, [{ op: 'test', path: '', value: b }], true, true); } catch { ok = 'fail'; }
    out.push('test=' + ok);
  } else if (w === 'diff') {
    out.push('ops=' + jsonpatch.compare(rj(f1), rj(f2)).length);
  } else if (w === 'ptrwide') {
    const a = rj(f1);
    const n = Object.keys(a).length;
    let hits = 0;
    for (let i = 0; i < n; i++) if (jsonpatch.getValueByPointer(a, '/k' + i) !== undefined) hits++;
    out.push('hits=' + hits);
  } else if (w === 'bigapply') {
    // fast-json-patch is NOT atomic; mutateDocument=true is its fastest mode (lower bound)
    const doc = rj(f1);
    const iters = Number(f2);
    for (let i = 1; i <= iters; i++) jsonpatch.applyPatch(doc, [{ op: 'replace', path: '/meta/rev', value: i }], false, true);
    out.push('rev=' + doc.meta.rev);
  } else {
    process.exit(2);
  }
} else {
  console.error('bad args');
  process.exit(1);
}
process.stdout.write(out.join('\n') + '\n');
