// Malformed / adversarial Yjs v1 input fuzzer. Each case is applied by Pion (harness), official yjs
// (node/interp.mjs) and Rust yrs (yrs_interp). A crash (signal / abort), hang (>TIMEOUT s) or
// >1 GiB RSS on the Pion side is a finding; yjs / yrs behaviour is recorded for comparison.
// usage: node fuzz_malformed.mjs <pion-harness> <yrs_interp> <n-random> [outdir]
import { createRequire } from 'module';
import fs from 'fs';
import path from 'path';
import { spawnSync } from 'child_process';
import { fileURLToPath } from 'url';
const require = createRequire(import.meta.url);
const Y = require(process.env.YJS_MODULE || 'yjs');
const HERE = path.dirname(fileURLToPath(import.meta.url));
const [, , PION, YRS, NRAND = '300', OUT = '/tmp/crdt-fuzz/malformed'] = process.argv;
fs.mkdirSync(OUT, { recursive: true });
const TIMEOUT = 20;
const vu = (n) => { n = BigInt(n); const o = []; do { let b = Number(n & 0x7fn); n >>= 7n; if (n) b |= 0x80; o.push(b); } while (n); return o; };
const H = (a) => Buffer.from(a).toString('hex');
const str = (s) => { const b = [...Buffer.from(s, 'utf8')]; return [...vu(b.length), ...b]; };

const cases = [];
// --- handcrafted adversarial updates ---------------------------------------------------------
{ // 1. deeply nested lib0 Any array: [[[[...]]]] depth 200k (400 KB)
  const D = 200000; const any = []; for (let i = 0; i < D; i++) any.push(117, 1); any.push(126);
  cases.push(['deep_any_200k', [1, 1, 1, 0, 8, 1, ...str('a'), 1, ...any, 0]]);
}
{ // 2. deeply nested shared types (Y.Array in Y.Array ... depth 20k) and then delete the root element
  const d = new Y.Doc({ gc: false }); d.clientID = 1; const root = d.getArray('a');
  let cur = new Y.Array(); root.insert(0, [cur]);
  for (let i = 0; i < 20000; i++) { const nx = new Y.Array(); cur.insert(0, [nx]); cur = nx; }
  const u1 = Y.encodeStateAsUpdate(d); const u2 = [0, 1, 1, 1, 0, 1]; // delete set: client 1, clock 0, len 1 (the root element)
  cases.push(['deep_types_20k_then_delete_root', [...u1], [...u2]]);
}
// 3. GC struct of length 2^53-1 followed by an insert at the end of it
cases.push(['gc_len_2p53', [1, 2, 5, 0, 0, ...vu(2 ** 53 - 1), 4, 1, ...str('t'), ...str('x'), 0]]);
// 4. struct count 2^32 with only one real struct
cases.push(['struct_count_2p32', [1, ...vu(2 ** 32), 5, 0, 4, 1, ...str('t'), ...str('x'), 0]]);
// 5. client count 2^62
cases.push(['client_count_2p62', [...vu(2n ** 62n), 1, 5, 0, 4, 1, ...str('t'), ...str('x'), 0]]);
// 6. string length 2^31-1 (claims 2 GiB, buffer is tiny)
cases.push(['str_len_2p31', [1, 1, 5, 0, 4, 1, ...str('t'), ...vu(2 ** 31 - 1), 65, 0]]);
// 7. ContentAny element count 2^40 (each element 1 byte: undefined)
cases.push(['any_count_2p40', [1, 1, 5, 0, 8, 1, ...str('a'), ...vu(2 ** 40), 127, 127, 0]]);
// 8. ContentDeleted len 2^53-1
cases.push(['deleted_len_2p53', [1, 1, 5, 0, 1, 1, ...str('t'), ...vu(2 ** 53 - 1), 0]]);
// 9. delete set covering 2^53 clocks of an existing client
cases.push(['ds_len_2p53', [1, 1, 5, 0, 4, 1, ...str('t'), ...str('hello'), 1, 5, 1, 0, ...vu(2 ** 53 - 1)]]);
// 10. delete set with 10^6 one-clock ranges (3 MB) on an existing 1-char item
{ const r = []; for (let i = 0; i < 1000000; i++) r.push(...vu(i * 2), 1); cases.push(['ds_1M_ranges', [1, 1, 5, 0, 4, 1, ...str('t'), ...str('x'), 1, 5, ...vu(1000000), ...r]]); }
// 11. origin pointing at its own id (self loop) and right-origin loop
cases.push(['origin_self_loop', [1, 1, 5, 0, 0xc4, 5, 0, 5, 0, ...str('x'), 0]]);
// 12. parent = its own item (type whose parent is itself)
cases.push(['parent_self', [1, 1, 5, 0, 7, 0, 5, 0, 0, 0]]);
// 13. invalid UTF-8 inside ContentString followed by a dependent struct
cases.push(['invalid_utf8', [1, 2, 1, 0, 4, 1, ...str('t'), 2, 0xc3, 0x41, 0x84, 1, 1, ...str('Z'), 0]]);
// 14. pending flood: the same out-of-order update (missing clock 0) applied 5000 times
{ const fut = [1, 1, 9, 5, 4, 1, ...str('t'), ...str('x'), 0]; cases.push(['pending_flood_5000', ...Array(5000).fill(fut)]); }
// 15. truncated header / empty
cases.push(['empty_bytes', []]);
cases.push(['only_zero', [0]]);

// --- random mutations of valid updates -------------------------------------------------------
class Rng { constructor(s) { this.s = s >>> 0 || 1; } next() { this.s ^= this.s << 13; this.s >>>= 0; this.s ^= this.s >>> 17; this.s ^= this.s << 5; this.s >>>= 0; return this.s; } int(n) { return this.next() % n; } }
const rng = new Rng(1337);
const seeds = [];
{
  const d = new Y.Doc(); d.clientID = 3; d.getText('t').insert(0, 'héllo 😀 world'); d.getText('t').delete(2, 3);
  d.getMap('m').set('k', { a: [1, 2.5, 'x', null, true], b: new Uint8Array([1, 2]) }); d.getArray('a').insert(0, [1, 'two', new Y.Map()]);
  d.getText('t').format(0, 3, { bold: true }); seeds.push(Y.encodeStateAsUpdate(d));
  const e = new Y.Doc(); e.clientID = 2 ** 40; Y.applyUpdate(e, seeds[0]); e.getText('t').insert(1, 'Q'); seeds.push(Y.encodeStateAsUpdate(e));
}
for (let i = 0; i < +NRAND; i++) {
  const s = [...seeds[rng.int(seeds.length)]];
  const k = rng.int(5);
  if (k === 0) { const n = 1 + rng.int(4); for (let j = 0; j < n; j++) s[rng.int(s.length)] ^= 1 << rng.int(8); }
  else if (k === 1) s.length = rng.int(s.length);
  else if (k === 2) { const p = rng.int(s.length); s.splice(p, 0, 0xff, 0xff, 0xff, 0xff, 0x0f); }
  else if (k === 3) { const p = rng.int(s.length); s[p] = rng.int(256); s[(p + 1) % s.length] = rng.int(256); }
  else { const p = rng.int(s.length); s.splice(p, 1 + rng.int(4)); }
  cases.push([`mut_${i}`, s]);
}

function runOne(bin, args, script) {
  const f = path.join(OUT, 'case.txt'); fs.writeFileSync(f, script);
  const t0 = Date.now();
  const r = spawnSync('/usr/bin/time', ['-l', ...bin, ...args, f], { encoding: 'utf8', timeout: TIMEOUT * 1000, maxBuffer: 1 << 28 });
  const ms = Date.now() - t0;
  const rss = +(/(\d+)\s+maximum resident set size/.exec(r.stderr || '') || [0, 0])[1];
  const out = (r.stdout || '').split('\n').filter(Boolean);
  let status = 'ok';
  if (r.error && r.error.code === 'ETIMEDOUT') status = 'HANG';
  else if (r.signal) status = 'SIGNAL_' + r.signal;
  else if (/Command terminated abnormally|signal/i.test(r.stderr || '') && r.status !== 0) status = 'CRASH';
  else if (r.status !== 0) status = 'EXIT_' + r.status;
  const err = out.find(l => l.startsWith('E ')) || '';
  return { status, ms, rssMiB: Math.round(rss / 1048576), err: err.slice(0, 60), dump: out.find(l => l.startsWith('D ')) || '', stderr: (r.stderr || '').split('\n').filter(l => !/^\s+\d+\s/.test(l) && l.trim()).slice(0, 2).join(' | ').slice(0, 160) };
}
const findings = []; let n = 0;
const report = [];
for (const [name, ...ups] of cases) {
  const script = 'doc 1 77\n' + ups.map(u => `apply 1 ${H(u)}`).join('\n') + '\ndump 1\npending 1\n';
  const p = runOne([PION], [], script);
  const full = !name.startsWith('mut_');
  const y = full ? runOne(['node'], [path.join(HERE, 'interp.mjs')], script) : null;
  const r = full ? runOne([YRS], [], script) : null;
  const bad = p.status !== 'ok' || p.rssMiB > 1024 || p.ms > 5000;
  if (bad) findings.push(name);
  if (full || bad) report.push(`${bad ? '!!' : '  '} ${name.padEnd(32)} pion=${p.status}/${p.ms}ms/${p.rssMiB}MiB ${p.err}${p.stderr && p.status !== 'ok' ? ' [' + p.stderr + ']' : ''}` +
    (y ? `\n     ${''.padEnd(32)} yjs=${y.status}/${y.ms}ms/${y.rssMiB}MiB ${y.err}` : '') + (r ? `\n     ${''.padEnd(32)} yrs=${r.status}/${r.ms}ms/${r.rssMiB}MiB ${r.err}` : ''));
  if (bad) fs.writeFileSync(path.join(OUT, `${name}.txt`), script);
  n++;
}
console.log(report.join('\n'));
console.log(`MALFORMED cases=${n} pion_findings=${findings.length} ${JSON.stringify(findings.slice(0, 20))}`);
process.exitCode = findings.length ? 1 : 0;
