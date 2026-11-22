// Replays a trace with official yjs and writes the resulting v1 update as hex (input of the `remote` workload).
import { createRequire } from 'module';
import fs from 'fs';
const require = createRequire(import.meta.url);
const Y = require(process.env.YJS_MODULE || 'yjs');
const [, , trace, out] = process.argv;
const d = new Y.Doc(); d.clientID = 1; const t = d.getText('text');
for (const l of fs.readFileSync(trace, 'utf8').split('\n')) { if (!l) continue; const [p, del, h] = l.split(' '); if (+del) t.delete(+p, +del); if (h) t.insert(+p, Buffer.from(h, 'hex').toString('utf8')); }
fs.writeFileSync(out, Buffer.from(Y.encodeStateAsUpdate(d)).toString('hex'));
