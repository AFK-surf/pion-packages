import fs from 'node:fs';
import { optimize } from 'svgo';

const file = process.argv[2];
if (!file) {
  console.error('usage: node bench.mjs <icons_file>');
  process.exit(1);
}
const src = fs.readFileSync(file, 'utf8');
const icons = src.split('\n---SVG---\n').filter(Boolean);
let totalIn = 0;
let totalOut = 0;
for (const icon of icons) {
  totalIn += Buffer.byteLength(icon, 'utf8');
  const res = optimize(icon, { multipass: false, floatPrecision: 3 });
  totalOut += Buffer.byteLength(res.data, 'utf8');
}
console.log(`mode=w3_svgo`);
console.log(`icons=${icons.length}`);
console.log(`in_bytes=${totalIn}`);
console.log(`out_bytes=${totalOut}`);
