// Official yjs side of the red-team workloads (see bench/pion_bench/src/main.pion for the spec).
import { createRequire } from 'module';
import fs from 'fs';
const require = createRequire(import.meta.url);
const Y = require(process.env.YJS_MODULE || 'yjs');
class Rng { constructor(s) { this.s = s >>> 0; } next() { this.s = (Math.imul(this.s, 1664525) + 1013904223) >>> 0; return this.s >>> 1; } }
const L = 'abcdefghijklmnopqrstuvwxyz';
const newT = (id) => { const d = new Y.Doc(); d.clientID = id; return [d, d.getText('text')]; };
function wText(ops) {
  const rng = new Rng(123456789); const [, t] = newT(1);
  const words = ['a', 'the ', 'pion ', 'crdt ', 'x', 'yjs ', 'fast ', 'sync '];
  let cursor = 0;
  for (let i = 0; i < ops; i++) {
    const r = rng.next(); const cur = t.length; const mode = r % 20;
    if (mode < 12 || cur === 0) { if (cursor > cur) cursor = cur; const w = words[(r >> 4) % 8]; t.insert(cursor, w); cursor += w.length; }
    else if (mode < 17) { const pos = (r >> 5) % (cur + 1); const w = words[(r >> 12) % 8]; t.insert(pos, w); cursor = pos + w.length; }
    else { const pos = (r >> 5) % cur; const maxD = cur - pos; const d = 1 + ((r >> 12) % 4); t.delete(pos, d > maxD ? maxD : d); cursor = pos; }
  }
  return t.toString();
}
function wAppend(n) { const [, t] = newT(1); for (let i = 0; i < n; i++) t.insert(i, L[i % 26]); return t.toString(); }
function wTomb(n) {
  const rng = new Rng(987654321); const [, t] = newT(1);
  for (let i = 0; i < n; i++) t.insert(i, L[i % 26]);
  for (let p = n - 1; p >= 0; p--) if (p % 2 === 1) t.delete(p, 1);
  for (let k = 0; k < Math.floor(n / 5); k++) { const pos = rng.next() % (t.length + 1); t.insert(pos, 'X'); }
  return t.toString();
}
function loadTrace(f) {
  return fs.readFileSync(f, 'utf8').split('\n').filter(Boolean).map(l => { const [p, d, h] = l.split(' '); return [+p, +d, Buffer.from(h || '', 'hex').toString('utf8')]; });
}
function replay(ops) { const [d, t] = newT(1); for (const [p, del, ins] of ops) { if (del > 0) t.delete(p, del); if (ins.length) t.insert(p, ins); } return d; }
const [, , mode, nS, itS, trace] = process.argv; const n = +nS, iters = +itS;
let out = '';
if (mode === 'trace' || mode === 'remote') {
  if (mode === 'remote') { const u = new Uint8Array(Buffer.from(fs.readFileSync(trace, 'utf8').trim(), 'hex')); for (let k = 0; k < iters; k++) { const [r] = newT(2); Y.applyUpdate(r, u); out = r.getText('text').toString(); } }
  else { const ops = loadTrace(trace);
  if (mode === 'trace') for (let k = 0; k < iters; k++) out = replay(ops).getText('text').toString();
  else { const u = Y.encodeStateAsUpdate(replay(ops)); for (let k = 0; k < iters; k++) { const [r] = newT(2); Y.applyUpdate(r, u); out = r.getText('text').toString(); } } }
} else for (let k = 0; k < iters; k++) out = mode === 'text' ? wText(n) : mode === 'append' ? wAppend(n) : wTomb(n);
process.stdout.write(`${mode} len=${Buffer.byteLength(out)}\n${out}\n`);
