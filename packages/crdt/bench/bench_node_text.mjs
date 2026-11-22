import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const yjsPath = process.env.YJS_MODULE || '/tmp/pion-crdt-bench/node/node_modules/yjs';
const Y = require(yjsPath);

class Rng {
  constructor(seed) {
    this.s = seed >>> 0;
  }
  next() {
    this.s = (Math.imul(this.s, 1664525) + 1013904223) >>> 0;
    return this.s >>> 1;
  }
}

function runOnce(ops) {
  const rng = new Rng(123456789);
  const doc = new Y.Doc();
  doc.clientID = 1;
  const t = doc.getText('text');
  const words = ['a', 'the ', 'pion ', 'crdt ', 'x', 'yjs ', 'fast ', 'sync '];

  let cursor = 0;
  for (let i = 0; i < ops; i++) {
    const r = rng.next();
    const curLen = t.length;
    const mode = r % 20;
    if (mode < 12 || curLen === 0) {
      if (cursor > curLen) cursor = curLen;
      const w = words[(r >> 4) % 8];
      t.insert(cursor, w);
      cursor += w.length;
    } else if (mode < 17) {
      const pos = (r >> 5) % (curLen + 1);
      const w = words[(r >> 12) % 8];
      t.insert(pos, w);
      cursor = pos + w.length;
    } else {
      const pos = (r >> 5) % curLen;
      const maxD = curLen - pos;
      const dlen = 1 + ((r >> 12) % 4);
      const actualD = dlen > maxD ? maxD : dlen;
      t.delete(pos, actualD);
      cursor = pos;
    }
  }
  const upd = Y.encodeStateAsUpdate(doc);
  const finalTxt = t.toString();
  const dst = new Y.Doc();
  dst.clientID = 2;
  Y.applyUpdate(dst, upd);
  const decodedTxt = dst.getText('text').toString();
  return [finalTxt, upd.length, decodedTxt];
}

const ops = process.argv[2] ? parseInt(process.argv[2], 10) : 20000;
const iters = process.argv[3] ? parseInt(process.argv[3], 10) : 10;

let lastTxt = '';
let lastDec = '';
let lastUpdLen = 0;
for (let k = 0; k < iters; k++) {
  const [ft, ul, dt] = runOnce(ops);
  lastTxt = ft;
  lastUpdLen = ul;
  lastDec = dt;
}
const matchOk = lastTxt === lastDec ? 'ok' : 'mismatch';
process.stdout.write(
  `iters=${iters} ops=${ops} text_len=${lastTxt.length} roundtrip=${matchOk} upd_ge=${lastUpdLen > 0 ? 1 : 0}\n${lastTxt}\n`
);
