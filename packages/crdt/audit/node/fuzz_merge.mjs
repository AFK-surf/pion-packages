// Differential fuzz of mergeUpdates / diffUpdate: Pion vs official yjs.
// The merged/diffed bytes may legitimately differ, so both outputs are loaded into fresh
// yjs docs (together with the base where needed) and the resulting states are compared.
// usage: node fuzz_merge.mjs <harness-bin> <seeds> [outdir]
import { createRequire } from 'module';
import fs from 'fs';
import path from 'path';
import { execFileSync } from 'child_process';
import { newDoc, dumpDoc } from './interp.mjs';
const require = createRequire(import.meta.url);
const Y = require(process.env.YJS_MODULE || 'yjs');
const [, , BIN, SEEDS = '40', OUT = '/tmp/crdt-fuzz'] = process.argv;
fs.mkdirSync(OUT, { recursive: true });
class Rng { constructor(s) { this.s = (s * 2654435761) >>> 0 || 1; } next() { this.s ^= this.s << 13; this.s >>>= 0; this.s ^= this.s >>> 17; this.s ^= this.s << 5; this.s >>>= 0; return this.s; } int(n) { return this.next() % n; } }
const H = (u) => Buffer.from(u).toString('hex');
const U = (h) => new Uint8Array(Buffer.from(h, 'hex'));
const load = (...us) => { const d = newDoc(777); us.forEach(u => Y.applyUpdate(d, u)); return d; };
let fails = 0; const kinds = {};
for (let seed = 1; seed <= +SEEDS; seed++) {
  const rng = new Rng(seed);
  const docs = [newDoc(11), newDoc(22), newDoc(33)];
  const ups = [];
  docs.forEach(d => d.on('update', u => ups.push(u)));
  for (let k = 0; k < 60; k++) {
    const d = docs[rng.int(3)]; const t = d.getText('t'); const r = rng.int(10);
    if (r < 5) t.insert(rng.int(t.length + 1), ['ab', 'c', 'xyz'][rng.int(3)]);
    else if (r < 7 && t.length) { const i = rng.int(t.length); t.delete(i, 1 + rng.int(Math.min(3, t.length - i))); }
    else if (r < 8) d.getMap('m').set('k' + rng.int(3), rng.int(9));
    else { const j = docs[rng.int(3)]; if (j !== d) Y.applyUpdate(j, Y.encodeStateAsUpdate(d, Y.encodeStateVector(j))); }
  }
  // random subset, random order
  const sub = ups.filter(() => rng.int(3) > 0);
  for (let k = sub.length - 1; k > 0; k--) { const j = rng.int(k + 1); [sub[k], sub[j]] = [sub[j], sub[k]]; }
  const half = sub.slice(0, sub.length >> 1);
  const baseDoc = load(...half);
  const sv = Y.encodeStateVector(baseDoc);
  const full = Y.mergeUpdates(ups);
  const script = `merge ${sub.map(H).join(' ')}\ndiff ${H(full)} ${H(sv)}\n`;
  const f = path.join(OUT, `merge-${seed}.txt`); fs.writeFileSync(f, script);
  const problems = [];
  let po = [];
  try { po = execFileSync(BIN, [f], { encoding: 'utf8', maxBuffer: 1 << 28 }).split('\n').filter(Boolean); }
  catch (e) { problems.push(`PION_CRASH exit=${e.status} signal=${e.signal}`); }
  const pm = po.find(l => l.startsWith('M ')), pf = po.find(l => l.startsWith('F '));
  // merge
  const expMerge = load(...sub); const expMergeDump = dumpDoc(expMerge);
  if (!pm) problems.push('MERGE_ERROR ' + (po.find(l => l.startsWith('E ')) || ''));
  else {
    try {
      const d = load(U(pm.slice(2)));
      const got = dumpDoc(d);
      if (got !== expMergeDump) problems.push(`MERGE_STATE_DIFFERS\n   yjs : ${expMergeDump}\n   pion: ${got}`);
      const pend = !!(d.store.pendingStructs), expPend = !!(expMerge.store.pendingStructs);
      if (pend !== expPend) problems.push(`MERGE_PENDING_DIFFERS yjs=${expPend} pion=${pend}`);
    } catch (e) { problems.push('YJS_REJECTS_PION_MERGE ' + e.message); }
  }
  // diff: base + diff must equal full
  if (!pf) problems.push('DIFF_ERROR');
  else {
    try {
      const d = load(...half, U(pf.slice(2)));
      const exp = dumpDoc(load(full));
      if (dumpDoc(d) !== exp) problems.push(`DIFF_STATE_DIFFERS\n   yjs : ${exp}\n   pion: ${dumpDoc(d)}`);
      const yl = Y.diffUpdate(full, sv).length, pl = pf.length / 2 - 1;
      if (pl > yl * 1.5 + 16) problems.push(`DIFF_SIZE pion=${pl}B yjs=${yl}B`);
    } catch (e) { problems.push('YJS_REJECTS_PION_DIFF ' + e.message); }
  }
  if (problems.length) {
    fails++; const k = problems[0].split(/[ \n]/)[0]; kinds[k] = (kinds[k] || 0) + 1;
    if (fails <= 3) console.log(`seed=${seed} script=${f}\n  ` + problems.join('\n  '));
  }
}
console.log(`MODE=merge/diff seeds=${SEEDS} failures=${fails} ${JSON.stringify(kinds)}`);
process.exitCode = fails ? 1 : 0;
