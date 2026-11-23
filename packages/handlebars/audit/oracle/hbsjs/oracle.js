// Handlebars.js 4.7.8 (the reference implementation) oracle for the packages/handlebars red-team audit.
// usage: node oracle.js <node_modules dir containing handlebars@4.7.8> <cases.jsonl>
// Same JSONL protocol as audit/probe. Mustache-only syntax Handlebars.js lacks (`{{=<% %>=}}`) simply errors.
'use strict';
const fs = require('fs');
const path = require('path');
const H = require(path.join(process.argv[2], 'handlebars'));
if (H.VERSION !== '4.7.8') throw new Error('need handlebars@4.7.8, got ' + H.VERSION);
const out = [];
for (const line of fs.readFileSync(process.argv[3], 'utf8').split('\n')) {
  if (!line) continue;
  const c = JSON.parse(line);
  let r;
  try {
    const hb = H.create();
    hb.registerHelper('wrap', function (opts) { return '<b>' + opts.fn(this) + '</b>'; });
    hb.registerHelper('echo', function (v) { return v; });
    hb.registerHelper('safe', function (v) { return new hb.SafeString(typeof v === 'string' ? v : ''); });
    for (const [k, v] of Object.entries(c.partials || {})) hb.registerPartial(k, v);
    const t = hb.compile(c.tmpl, { strict: !!c.strict, noEscape: !!c.no_escape });
    r = { id: c.id, ok: true, out: t(JSON.parse(c.data || '{}')) };
  } catch (e) {
    r = { id: c.id, ok: false, kind: 'Error', msg: String(e && e.message || e).split('\n')[0] };
  }
  out.push(JSON.stringify(r));
}
process.stdout.write(out.join('\n') + '\n');
