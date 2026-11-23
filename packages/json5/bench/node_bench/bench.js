#!/usr/bin/env node
'use strict';

const fs = require('fs');
const JSON5 = require('json5');
const jsonpatch = require('fast-json-patch');

const MOD = 1000000007n;

function polyHash(s) {
  const buf = Buffer.from(s, 'utf8');
  let h = 17n;
  for (let i = 0; i < buf.length; i++) {
    h = (h * 131n + BigInt(buf[i])) % MOD;
  }
  return h;
}

function walkVal(st, v) {
  if (v === null) {
    st.nulls += 1n;
  } else if (typeof v === 'boolean') {
    st.bools += 1n;
    if (v) st.bool_true += 1n;
  } else if (typeof v === 'number') {
    st.numbers += 1n;
  } else if (typeof v === 'string') {
    st.strings += 1n;
    st.str_bytes += BigInt(Buffer.byteLength(v, 'utf8'));
    st.str_hash = (st.str_hash + polyHash(v)) % MOD;
  } else if (Array.isArray(v)) {
    st.arrays += 1n;
    for (let i = 0; i < v.length; i++) {
      walkVal(st, v[i]);
    }
  } else if (typeof v === 'object') {
    st.objects += 1n;
    const keys = Object.keys(v);
    st.keys += BigInt(keys.length);
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      st.key_hash = (st.key_hash + polyHash(k)) % MOD;
      walkVal(st, v[k]);
    }
  }
}

const args = process.argv.slice(2);
const mode = args[0];

if (mode === 'parse') {
  const content = fs.readFileSync(args[1], 'utf8');
  const iters = parseInt(args[2], 10);
  const st = {
    objects: 0n,
    arrays: 0n,
    keys: 0n,
    strings: 0n,
    numbers: 0n,
    bools: 0n,
    bool_true: 0n,
    nulls: 0n,
    str_bytes: 0n,
    key_hash: 0n,
    str_hash: 0n,
  };
  for (let i = 0; i < iters; i++) {
    const parsed = JSON5.parse(content);
    walkVal(st, parsed);
  }
  console.log('mode=parse');
  console.log('iters=' + iters);
  console.log('objects=' + st.objects);
  console.log('arrays=' + st.arrays);
  console.log('keys=' + st.keys);
  console.log('strings=' + st.strings);
  console.log('numbers=' + st.numbers);
  console.log('bools=' + st.bools);
  console.log('bool_true=' + st.bool_true);
  console.log('nulls=' + st.nulls);
  console.log('str_bytes=' + st.str_bytes);
  console.log('key_hash=' + st.key_hash);
  console.log('str_hash=' + st.str_hash);
} else if (mode === 'roundtrip') {
  const content = fs.readFileSync(args[1], 'utf8');
  const iters = parseInt(args[2], 10);
  let totalBytes = 0n;
  let outHash = 0n;
  for (let i = 0; i < iters; i++) {
    const parsed = JSON5.parse(content);
    const encoded = JSON.stringify(parsed);
    totalBytes += BigInt(Buffer.byteLength(encoded, 'utf8'));
    outHash = (outHash + polyHash(encoded)) % MOD;
  }
  console.log('mode=roundtrip');
  console.log('iters=' + iters);
  console.log('total_bytes=' + totalBytes);
  console.log('out_hash=' + outHash);
} else if (mode === 'patch') {
  const doc = JSON.parse(fs.readFileSync(args[1], 'utf8'));
  const patch = JSON.parse(fs.readFileSync(args[2], 'utf8'));
  const opsEach = parseInt(args[3], 10);
  const ptrs = [
    '/service',
    '/a~1b/m~0n',
    '/config/host',
    '/config/port',
    '/config/tags/2',
    '/config/limits/max_conn',
    '/routes/1/path',
    '/routes/2/enabled',
  ];
  let ptrHits = 0n;
  let ptrHash = 0n;
  for (let i = 0; i < opsEach; i++) {
    const v = jsonpatch.getValueByPointer(doc, ptrs[i % 8]);
    if (v !== undefined) {
      ptrHits += 1n;
      if (typeof v === 'string') {
        ptrHash = (ptrHash + polyHash(v)) % MOD;
      } else if (typeof v === 'number') {
        ptrHash = (ptrHash + BigInt(Math.trunc(v))) % MOD;
      } else if (typeof v === 'boolean') {
        ptrHash = (ptrHash + (v ? 1n : 0n)) % MOD;
      }
    }
  }
  let patchOk = 0n;
  let patchHash = 0n;
  for (let j = 0; j < opsEach; j++) {
    const res = jsonpatch.applyPatch(doc, patch, false, false).newDocument;
    patchOk += 1n;
    const v = jsonpatch.getValueByPointer(res, '/copied_label');
    if (typeof v === 'string') {
      patchHash = (patchHash + polyHash(v)) % MOD;
    }
  }
  console.log('mode=patch');
  console.log('ops_each=' + opsEach);
  console.log('ptr_hits=' + ptrHits);
  console.log('ptr_hash=' + ptrHash);
  console.log('patch_ok=' + patchOk);
  console.log('patch_hash=' + patchHash);
} else {
  console.error('unknown mode:', mode);
  process.exit(1);
}
