// Shared differential check: run a script through official yjs and the Pion harness.
import { createRequire } from 'module';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { execFileSync } from 'child_process';
import { run, dumpDoc } from './interp.mjs';
const require = createRequire(import.meta.url);
const Y = require(process.env.YJS_MODULE || 'yjs');

let tmpN = 0;
export function check(BIN, script, file) {
  const f = file || path.join(os.tmpdir(), `crdt-check-${process.pid}-${tmpN++}.txt`);
  fs.writeFileSync(f, script);
  const shuffle = script.includes('# expect ');
  const yo = run(script, []);
  let po; let crash = null;
  try { po = execFileSync(BIN, [f], { encoding: 'utf8', maxBuffer: 1 << 28, timeout: 60000, stdio: ['ignore', 'pipe', 'pipe'] }).split('\n').filter(Boolean); }
  catch (e) { crash = `exit=${e.status} signal=${e.signal}`; po = (e.stdout || '').split('\n').filter(Boolean); }
  if (!file) fs.unlinkSync(f);
  const problems = [];
  if (crash) problems.push('PION_CRASH ' + crash);
  const yd = yo.filter(l => l.startsWith('D ')), pd = po.filter(l => l.startsWith('D '));
  const ye = yo.filter(l => l.startsWith('E ')), pe = po.filter(l => l.startsWith('E '));
  if (pe.length !== ye.length) problems.push(`ERRORS yjs=${ye.length} pion=${pe.length} (${pe[0] || ye[0]})`);
  const pBodies = new Set(pd.map(l => l.slice(l.indexOf(' ', 2) + 1)));
  if (!shuffle && pBodies.size > 1) problems.push(`PION_NOT_CONVERGED replicas=${pBodies.size}\n   ` + pd.join('\n   '));
  for (let k = 0; k < Math.max(yd.length, pd.length); k++) if (yd[k] !== pd[k]) { problems.push(`STATE_DIVERGES_FROM_YJS\n   yjs : ${yd[k]}\n   pion: ${pd[k]}`); break; }
  for (const l of po.filter(l => l.startsWith('U '))) {
    const [, id, h] = l.split(' ');
    try {
      const d = new Y.Doc(); Y.applyUpdate(d, new Uint8Array(Buffer.from(h, 'hex')));
      const yd2 = yd.find(x => x.startsWith(`D ${id} `));
      const got = `D ${id} ${dumpDoc(d)}`;
      if (yd2 && got !== yd2) { problems.push(`YJS_DECODES_PION_UPDATE_DIFFERENTLY doc=${id}\n   yjs-native : ${yd2}\n   yjs(pion-u): ${got}`); break; }
      if (d.store.pendingStructs || d.store.pendingDs) { problems.push(`YJS_PENDING_AFTER_PION_UPDATE doc=${id}`); break; }
    } catch (e) { problems.push(`YJS_REJECTS_PION_UPDATE doc=${id}: ${e.message}`); break; }
  }
  if (shuffle) {
    const exp = script.split('\n').find(l => l.startsWith('# expect ')).slice(9);
    if (pd[0] !== `D 99 ${exp}`) problems.push(`SHUFFLED_DELIVERY_DIVERGES\n   yjs : D 99 ${exp}\n   pion: ${pd[0]}`);
  }
  return problems;
}
