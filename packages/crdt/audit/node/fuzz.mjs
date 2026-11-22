// Differential fuzzer: random multi-client scripts executed by official yjs (node/interp.mjs)
// and by Pion (harness binary). Any divergence in stdout or cross-decoding is reported.
// usage: node fuzz.mjs <harness-bin> <mode> <seeds> [outdir]
//   mode: ops-ascii | ops-unicode | ops-emoji | shuffle | shuffle-emoji | format
import { createRequire } from 'module';
import fs from 'fs';
import path from 'path';
import { run, newDoc, dumpDoc } from './interp.mjs';
import { check } from './check.mjs';
const require = createRequire(import.meta.url);
const Y = require(process.env.YJS_MODULE || 'yjs');

const [, , BIN, MODE0 = 'ops-ascii', SEEDS = '50', OUT = '/tmp/crdt-fuzz'] = process.argv;
// suffix '+nm' => harness drops search markers before each local op (isolates bugs other than P0-1)
const NM = MODE0.endsWith('+nm'); const MODE = MODE0.replace('+nm', '');
fs.mkdirSync(OUT, { recursive: true });

class Rng { constructor(s) { this.s = (s * 2654435761) >>> 0 || 1; } next() { this.s ^= this.s << 13; this.s >>>= 0; this.s ^= this.s >>> 17; this.s ^= this.s << 5; this.s >>>= 0; return this.s; } int(n) { return this.next() % n; } pick(a) { return a[this.int(a.length)]; } }
const hx = (s) => Buffer.from(s, 'utf8').toString('hex');
const ALPHA = {
  'ops-ascii': ['a', 'b', 'c', 'hello', 'xy', ' '],
  'ops-unicode': ['a', 'é', '中文', 'ß', 'x', 'Ω'],
  'ops-emoji': ['a', '😀', 'b👍🏽', '中', '🏳️‍🌈', 'z'],
  'format': ['a', 'bc', 'def', 'g'],
};

function lenOf(t) { return t.length; }
function genOps(rng, mode, nDocs, nOps) {
  const alpha = ALPHA[mode.replace('shuffle-emoji', 'ops-emoji').replace('shuffle', 'ops-ascii')] || ALPHA['ops-ascii'];
  const lines = NM ? ['opt nomarkers'] : [];
  const docs = [];
  for (let i = 0; i < nDocs; i++) {
    const client = mode.includes('big') ? 2 ** 53 - 1 - i : (i + 1) * 7 + rng.int(5);
    lines.push(`doc ${i} ${client}`);
    docs.push(newDoc(client));
  }
  const ups = [];
  docs.forEach(d => d.on('update', u => ups.push(u)));
  // keep a yjs mirror in lockstep via direct API calls
  for (let k = 0; k < nOps; k++) {
    const i = rng.int(nDocs); const d = docs[i];
    const r = rng.int(100);
    const t = d.getText('t'), a = d.getArray('a'), m = d.getMap('m');
    if (r < 30) {
      const s = rng.pick(alpha); const idx = rng.int(t.length + 1);
      lines.push(`ti ${i} t ${idx} ${hx(s)}`); t.insert(idx, s);
    } else if (r < 42 && t.length > 0) {
      const idx = rng.int(t.length); const l = 1 + rng.int(Math.min(4, t.length - idx));
      lines.push(`td ${i} t ${idx} ${l}`); t.delete(idx, l);
    } else if (r < 50 && mode === 'format' && t.length > 0) {
      const idx = rng.int(t.length); const l = 1 + rng.int(t.length - idx);
      const key = rng.pick(['bold', 'italic']); const v = rng.pick(['true', 'null', '"x"']);
      lines.push(`tf ${i} t ${idx} ${l} ${key} ${hx(v)}`); t.format(idx, l, { [key]: JSON.parse(v) });
    } else if (r < 60) {
      const idx = rng.int(a.length + 1); const v = rng.int(1000);
      lines.push(`ai ${i} a ${idx} i:${v}`); a.insert(idx, [v]);
    } else if (r < 64) {
      const idx = rng.int(a.length + 1); const kind = rng.pick(['text', 'array', 'map']);
      lines.push(`ait ${i} a ${idx} ${kind}`); a.insert(idx, [kind === 'text' ? new Y.Text() : kind === 'array' ? new Y.Array() : new Y.Map()]);
    } else if (r < 70 && a.length > 0) {
      const idx = rng.int(a.length); const l = 1 + rng.int(Math.min(3, a.length - idx));
      lines.push(`ad ${i} a ${idx} ${l}`); a.delete(idx, l);
    } else if (r < 78) {
      const key = rng.pick(['k1', 'k2', 'k3']);
      if (rng.int(4) === 0) { const kind = rng.pick(['text', 'array', 'map']); lines.push(`mst ${i} m ${key} ${kind}`); m.set(key, kind === 'text' ? new Y.Text() : kind === 'array' ? new Y.Array() : new Y.Map()); }
      else { const v = rng.int(100); lines.push(`ms ${i} m ${key} i:${v}`); m.set(key, v); }
    } else if (r < 81) {
      const key = rng.pick(['k1', 'k2', 'k3']); lines.push(`md ${i} m ${key}`); m.delete(key);
    } else if (r < 88) {
      // nested op
      const cand = [];
      a.forEach((v, j) => { if (v instanceof Y.AbstractType) cand.push([`a/${j}`, v]); });
      m.forEach((v, key) => { if (v instanceof Y.AbstractType) cand.push([`m/${key}`, v]); });
      if (!cand.length) continue;
      const [p, ty] = rng.pick(cand);
      if (ty instanceof Y.Text) { const s = rng.pick(alpha); const idx = rng.int(ty.length + 1); lines.push(`ti ${i} ${p} ${idx} ${hx(s)}`); ty.insert(idx, s); }
      else if (ty instanceof Y.Array) { const idx = rng.int(ty.length + 1); const v = rng.int(50); lines.push(`ai ${i} ${p} ${idx} i:${v}`); ty.insert(idx, [v]); }
      else { const key = rng.pick(['x', 'y']); const v = rng.int(50); lines.push(`ms ${i} ${p} ${key} i:${v}`); ty.set(key, v); }
    } else if (!mode.startsWith('shuffle')) {
      const j = rng.int(nDocs); if (j === i) continue;
      lines.push(`sync ${i} ${j}`); Y.applyUpdate(docs[j], Y.encodeStateAsUpdate(d, Y.encodeStateVector(docs[j])));
    }
  }
  return { lines, docs, ups };
}

function makeScript(seed) {
  const rng = new Rng(seed);
  const nDocs = 3 + rng.int(3);
  const nOps = 40 + rng.int(120);
  const { lines, docs, ups } = genOps(rng, MODE, nDocs, nOps);
  if (MODE.startsWith('shuffle')) {
    // Out-of-order delivery of every individual update into a fresh observer doc (Pion & yjs both).
    const order = ups.map((u, k) => k);
    for (let k = order.length - 1; k > 0; k--) { const j = rng.int(k + 1); [order[k], order[j]] = [order[j], order[k]]; }
    lines.push('doc 99 4242');
    for (const k of order) lines.push(`apply 99 ${Buffer.from(ups[k]).toString('hex')}`);
    lines.push('dump 99');
    // expected: all docs fully synced
    for (const a of docs) for (const b of docs) if (a !== b) Y.applyUpdate(b, Y.encodeStateAsUpdate(a));
    lines.push('# expect ' + dumpDoc(docs[0]));
  } else {
    // full mesh sync, then dump every replica
    lines.push('# mesh');
    for (let r = 0; r < 2; r++) for (let i = 0; i < nDocs; i++) for (let j = 0; j < nDocs; j++) if (i !== j) lines.push(`sync ${i} ${j}`);
    for (let i = 0; i < nDocs; i++) lines.push(`dump ${i}`);
    for (let i = 0; i < nDocs; i++) lines.push(`upd ${i}`);
  }
  return lines.join('\n') + '\n';
}

let fails = 0; const kinds = {};
for (let seed = 1; seed <= +SEEDS; seed++) {
  const script = makeScript(seed);
  const f = path.join(OUT, `${MODE0}-${seed}.txt`);
  const problems = check(BIN, script, f);
  if (problems.length) {
    fails++;
    const k = problems[0].split(/[ \n]/)[0]; kinds[k] = (kinds[k] || 0) + 1;
    if (fails <= 3) console.log(`seed=${seed} script=${f}\n  ` + problems.join('\n  '));
  }
}
console.log(`MODE=${MODE0} seeds=${SEEDS} failures=${fails} ${JSON.stringify(kinds)}`);
process.exitCode = fails ? 1 : 0;
