// Node.js y-octo-wasm side of the red-team workloads (see bench/pion_bench/src/main.pion for the spec).
import fs from 'fs';
import { pathToFileURL } from 'url';

const wasmJsPath = process.env.YOCTO_WASM_JS;
const wasmPath = process.env.YOCTO_WASM;
if (!wasmJsPath || !wasmPath) {
  throw new Error('YOCTO_WASM_JS and YOCTO_WASM environment variables must be set');
}

const { loadYOctoWasm } = await import(pathToFileURL(wasmJsPath).href);
const api = await loadYOctoWasm(fs.readFileSync(wasmPath));
const BATCH = process.env.YOCTO_WASM_BATCH === '1';

class Rng {
  constructor(s) {
    this.s = s >>> 0;
  }
  next() {
    this.s = (Math.imul(this.s, 1664525) + 1013904223) >>> 0;
    return this.s >>> 1;
  }
}

const L = 'abcdefghijklmnopqrstuvwxyz';

function withSession(id, fn) {
  const s = new api.DocSession(id, 'bench', { gc: true, undo: 'disabled' });
  try {
    const target = { Identity: s.ensureRoot('text', 'Text') };
    return fn(s, target);
  } finally {
    s.free();
  }
}

function runOps(s, fn) {
  if (BATCH) {
    s.transact(fn);
  } else {
    fn();
  }
}

function wText(ops) {
  const rng = new Rng(123456789);
  const words = ['a', 'the ', 'pion ', 'crdt ', 'x', 'yjs ', 'fast ', 'sync '];
  return withSession(1, (s, target) => {
    runOps(s, () => {
      let cursor = 0;
      for (let i = 0; i < ops; i++) {
        const r = rng.next();
        const cur = s.readTextLen(target);
        const mode = r % 20;
        if (mode < 12 || cur === 0) {
          if (cursor > cur) cursor = cur;
          const w = words[(r >> 4) % 8];
          s.textInsert(target, cursor, w);
          cursor += w.length;
        } else if (mode < 17) {
          const pos = (r >> 5) % (cur + 1);
          const w = words[(r >> 12) % 8];
          s.textInsert(target, pos, w);
          cursor = pos + w.length;
        } else {
          const pos = (r >> 5) % cur;
          const maxD = cur - pos;
          const d = 1 + ((r >> 12) % 4);
          s.textRemove(target, pos, d > maxD ? maxD : d);
          cursor = pos;
        }
      }
    });
    return s.readTextString(target);
  });
}

function wAppend(n) {
  return withSession(1, (s, target) => {
    runOps(s, () => {
      for (let i = 0; i < n; i++) s.textInsert(target, i, L[i % 26]);
    });
    return s.readTextString(target);
  });
}

function wTomb(n) {
  const rng = new Rng(987654321);
  return withSession(1, (s, target) => {
    runOps(s, () => {
      for (let i = 0; i < n; i++) s.textInsert(target, i, L[i % 26]);
      for (let p = n - 1; p >= 0; p--) if (p % 2 === 1) s.textRemove(target, p, 1);
      for (let k = 0; k < Math.floor(n / 5); k++) {
        const pos = rng.next() % (s.readTextLen(target) + 1);
        s.textInsert(target, pos, 'X');
      }
    });
    return s.readTextString(target);
  });
}

function loadTrace(f) {
  return fs
    .readFileSync(f, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((l) => {
      const [p, d, h] = l.split(' ');
      return [+p, +d, Buffer.from(h || '', 'hex').toString('utf8')];
    });
}

function replayInto(s, target, ops) {
  runOps(s, () => {
    for (const [p, del, ins] of ops) {
      if (del > 0) s.textRemove(target, p, del);
      if (ins.length) s.textInsert(target, p, ins);
    }
  });
}

const [, , mode, nS, itS, trace] = process.argv;
if (mode === 'size') {
  const tracePath = trace || nS;
  const ops = loadTrace(tracePath);
  const len = withSession(1, (s, target) => {
    replayInto(s, target, ops);
    return s.encodeUpdateV1().length;
  });
  process.stdout.write(`${len}\n`);
  process.exit(0);
}

const n = +nS;
const iters = +itS;
let out = '';
if (mode === 'trace' || mode === 'remote') {
  if (mode === 'remote') {
    const u = new Uint8Array(Buffer.from(fs.readFileSync(trace, 'utf8').trim(), 'hex'));
    for (let k = 0; k < iters; k++) {
      out = withSession(2, (s, target) => {
        s.applyUpdateV1(u);
        return s.readTextString(target);
      });
    }
  } else {
    const ops = loadTrace(trace);
    for (let k = 0; k < iters; k++) {
      out = withSession(1, (s, target) => {
        replayInto(s, target, ops);
        return s.readTextString(target);
      });
    }
  }
} else {
  for (let k = 0; k < iters; k++) {
    out = mode === 'text' ? wText(n) : mode === 'append' ? wAppend(n) : wTomb(n);
  }
}

process.stdout.write(`${mode} len=${Buffer.byteLength(out)}\n${out}\n`);
