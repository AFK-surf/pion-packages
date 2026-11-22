// Official yjs mirror of audit/harness (same script language, same stdout).
import { createRequire } from 'module';
import fs from 'fs';
const require = createRequire(import.meta.url);
const Y = require(process.env.YJS_MODULE || 'yjs');

const hex = (u8) => Buffer.from(u8).toString('hex');
const unhex = (h) => new Uint8Array(Buffer.from(h || '', 'hex'));
const hexStr = (h) => Buffer.from(h, 'hex').toString('utf8');

function parseVal(s) {
  if (s === 'n') return null;
  if (s === 't') return true;
  if (s === 'f') return false;
  if (s.startsWith('i:')) return parseInt(s.slice(2), 10);
  if (s.startsWith('s:')) return hexStr(s.slice(2));
  return undefined;
}
function conv(v) {
  if (v instanceof Y.Text) return v.toString();
  if (v instanceof Y.Array) return v.toArray().map(conv);
  if (v instanceof Y.Map) { const o = {}; [...v.keys()].sort().forEach(k => { o[k] = conv(v.get(k)); }); return o; }
  if (v instanceof Uint8Array) return { $bin: hex(v) };
  if (v === undefined) return null;
  if (Array.isArray(v)) return v.map(conv);
  if (v !== null && typeof v === 'object') { const o = {}; Object.keys(v).sort().forEach(k => { o[k] = conv(v[k]); }); return o; }
  if (typeof v === 'bigint') return Number(v);
  return v;
}
export function newDoc(client) {
  const d = new Y.Doc(); d.clientID = client;
  d.getText('t'); d.getArray('a'); d.getMap('m');
  return d;
}
export function dumpDoc(d) {
  return JSON.stringify({ a: conv(d.getArray('a')), m: conv(d.getMap('m')), t: conv(d.getText('t')) });
}
function resolve(d, path) {
  const segs = path.split('/');
  let cur = segs[0] === 't' ? d.getText('t') : segs[0] === 'a' ? d.getArray('a') : segs[0] === 'm' ? d.getMap('m') : null;
  for (let k = 1; k < segs.length && cur; k++) {
    let nx;
    if (cur instanceof Y.Array) { const i = parseInt(segs[k], 10); nx = i < cur.length ? cur.get(i) : null; }
    else if (cur instanceof Y.Map) nx = cur.get(segs[k]);
    else nx = null;
    cur = (nx instanceof Y.AbstractType) ? nx : null;
  }
  return cur;
}
const mk = (k) => k === 'text' ? new Y.Text() : k === 'array' ? new Y.Array() : new Y.Map();

export function run(src, out) {
  const docs = new Map();
  for (const line of src.split('\n')) {
    const t = line.trim().split(/ +/);
    if (!t[0] || t[0].startsWith('#')) continue;
    const c = t[0];
    try {
      if (c === 'opt') continue;
      if (c === 'doc') { docs.set(+t[1], newDoc(+t[2])); continue; }
      if (c === 'merge') { out.push('M ' + hex(Y.mergeUpdates(t.slice(1).map(unhex)))); continue; }
      if (c === 'diff') { out.push('F ' + hex(Y.diffUpdate(unhex(t[1]), unhex(t[2])))); continue; }
      const d = docs.get(+t[1]);
      if (!d) { out.push('X nodoc'); continue; }
      if (c === 'apply') { Y.applyUpdate(d, unhex(t[2])); continue; }
      if (c === 'sync' || c === 'full') {
        const dst = docs.get(+t[2]);
        const u = c === 'full' ? Y.encodeStateAsUpdate(d) : Y.encodeStateAsUpdate(d, Y.encodeStateVector(dst));
        Y.applyUpdate(dst, u); continue;
      }
      if (c === 'dump') { out.push('D ' + t[1] + ' ' + dumpDoc(d)); continue; }
      if (c === 'upd') { out.push('U ' + t[1] + ' ' + hex(Y.encodeStateAsUpdate(d))); continue; }
      if (c === 'sv') { out.push('S ' + t[1] + ' ' + hex(Y.encodeStateVector(d))); continue; }
      if (c === 'pending') { out.push('P ' + t[1] + ' ' + ((d.store.pendingStructs ? 1 : 0) + (d.store.pendingDs ? 1 : 0))); continue; }
      const ty = resolve(d, t[2]);
      if (!ty) { out.push('X badpath'); continue; }
      // strict index validation (the generator never violates it; minimizer must not either)
      if ((c === 'ti' && +t[3] > ty.length) || ((c === 'td' || c === 'tf' || c === 'ad') && +t[3] + +t[4] > ty.length)) { out.push('E strict-range'); continue; }
      switch (c) {
        case 'ti': ty.insert(+t[3], hexStr(t[4])); break;
        case 'td': ty.delete(+t[3], +t[4]); break;
        case 'tf': ty.format(+t[3], +t[4], { [t[5]]: JSON.parse(hexStr(t[6])) }); break;
        case 'ai': ty.insert(+t[3], [parseVal(t[4])]); break;
        case 'ait': ty.insert(+t[3], [mk(t[4])]); break;
        case 'ad': ty.delete(+t[3], +t[4]); break;
        case 'ms': ty.set(t[3], parseVal(t[4])); break;
        case 'mst': ty.set(t[3], mk(t[4])); break;
        case 'md': ty.delete(t[3]); break;
        default: out.push('X badcmd');
      }
    } catch (e) { out.push('E ' + (e && e.message ? e.message.split('\n')[0] : String(e))); }
  }
  return out;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const out = run(fs.readFileSync(process.argv[2], 'utf8'), []);
  process.stdout.write(out.map(l => l + '\n').join(''));
}
