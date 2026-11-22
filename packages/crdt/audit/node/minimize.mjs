// Delta-debugging minimizer: shrink a failing script while the first problem kind persists.
// usage: node minimize.mjs <harness-bin> <script> [kind]
import fs from 'fs';
import { check } from './check.mjs';
const [, , BIN, FILE, KIND0] = process.argv;
let lines = fs.readFileSync(FILE, 'utf8').split('\n').filter(Boolean);
const kindOf = (p) => p.length ? p[0].split(/[ \n]/)[0] : null;
const KIND = KIND0 || kindOf(check(BIN, lines.join('\n') + '\n'));
const fails = (ls) => { const p = check(BIN, ls.join('\n') + '\n'); return !p.some(x => x.startsWith('ERRORS')) && p.some(x => x.startsWith(KIND)); };
const meshAt = lines.indexOf('# mesh');
const isFixed = lines.map((l, j) => l.startsWith('doc ') || l.startsWith('opt ') || l.startsWith('dump ') || l.startsWith('# expect') || (meshAt >= 0 && j >= meshAt));
const fixedSet = new Set(lines.filter((l, j) => isFixed[j]));
const fixed = (l) => fixedSet.has(l);
let chunk = Math.max(1, lines.length >> 1);
while (chunk >= 1) {
  let changed = false;
  for (let i = 0; i < lines.length;) {
    const cand = lines.filter((l, j) => j < i || j >= i + chunk || fixed(l));
    if (cand.length < lines.length && fails(cand)) { lines = cand; changed = true; } else i += chunk;
  }
  if (!changed) chunk >>= 1;
}
// drop upd lines unless needed
const out = lines.join('\n') + '\n';
process.stdout.write(out);
console.error(check(BIN, out).join('\n'));
