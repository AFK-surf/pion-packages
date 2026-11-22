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

function applyClientBatch(doc, rng, tag, cid, count) {
  const t = doc.getText('doc');
  const a = doc.getArray('arr');
  const m = doc.getMap('meta');
  for (let i = 0; i < count; i++) {
    const r = rng.next();
    const kind = r % 10;
    if (kind < 6) {
      const curLen = t.length;
      if (((r >> 4) % 4) !== 0 || curLen === 0) {
        const pos = (r >> 7) % (curLen + 1);
        t.insert(pos, tag);
      } else {
        const pos = (r >> 7) % curLen;
        const dlen = 1 + ((r >> 13) % 3);
        const maxD = curLen - pos;
        t.delete(pos, dlen > maxD ? maxD : dlen);
      }
    } else if (kind < 8) {
      const curLen = a.length;
      if (((r >> 4) % 4) !== 0 || curLen === 0) {
        const pos = (r >> 7) % (curLen + 1);
        a.insert(pos, [cid * 10000 + i]);
      } else {
        const pos = (r >> 7) % curLen;
        a.delete(pos, 1);
      }
    } else {
      const k = 'k' + ((r >> 4) % 32);
      if (((r >> 10) % 5) !== 0) {
        m.set(k, cid * 10000 + i);
      } else {
        m.delete(k);
      }
    }
  }
}

function runOnce(opsPerClient) {
  const d1 = new Y.Doc();
  d1.clientID = 100;
  const d2 = new Y.Doc();
  d2.clientID = 200;
  const rng1 = new Rng(111111);
  const rng2 = new Rng(222222);

  const rounds = 5;
  const batch = Math.floor(opsPerClient / rounds);
  for (let r = 0; r < rounds; r++) {
    applyClientBatch(d1, rng1, 'A', 1, batch);
    applyClientBatch(d2, rng2, 'B', 2, batch);
    const sv1 = Y.encodeStateVector(d1);
    const sv2 = Y.encodeStateVector(d2);
    const u1 = Y.encodeStateAsUpdate(d1, sv2);
    const u2 = Y.encodeStateAsUpdate(d2, sv1);
    Y.applyUpdate(d1, u2);
    Y.applyUpdate(d2, u1);
  }

  const s1 = d1.getText('doc').toString();
  const s2 = d2.getText('doc').toString();
  const a1 = d1.getArray('arr').toArray();
  const m1 = d1.getMap('meta');
  const ks = Array.from(m1.keys()).sort();

  const eq = s1 === s2 ? '1' : '0';
  const arrStr = a1.join(',');
  const mapStr = ks.map(k => `${k}=${m1.get(k)}`).join(',');
  return `eq=${eq} text_len=${s1.length} arr_len=${a1.length} map_len=${ks.length}\n${s1}\nARR:${arrStr}\nMAP:${mapStr}`;
}

const ops = process.argv[2] ? parseInt(process.argv[2], 10) : 5000;
const iters = process.argv[3] ? parseInt(process.argv[3], 10) : 10;

let out = '';
for (let k = 0; k < iters; k++) {
  out = runOnce(ops);
}
process.stdout.write(out + '\n');
