// Generates official-yjs wire fixtures (hex) + expected yjs results used by tests/redteam_test.pion.
// usage: node gen_fixtures.mjs   -> prints JSON {name: {hex, expect...}}
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const Y = require(process.env.YJS_MODULE || 'yjs');
const H = (u) => Buffer.from(u).toString('hex');
const doc = (id, gc = true) => { const d = new Y.Doc({ gc }); d.clientID = id; return d; };
const fx = {};

// 1. surrogate pair split by a concurrent insert (client 2 types inside "😀")
{
  const a = doc(1); a.getText('t').insert(0, '😀');
  const b = doc(2); Y.applyUpdate(b, Y.encodeStateAsUpdate(a));
  const sv = Y.encodeStateVector(b); b.getText('t').insert(1, 'x');
  fx.surrogate_base = H(Y.encodeStateAsUpdate(a));
  fx.surrogate_insert = H(Y.encodeStateAsUpdate(b, sv));
  fx.surrogate_expect = b.getText('t').toString();
}
// 2. XmlFragment with XmlElement('p') + XmlText (what y-prosemirror / tiptap send)
{
  const a = doc(5); const frag = a.getXmlFragment('t');
  const p = new Y.XmlElement('paragraph'); p.setAttribute('align', 'left');
  const tx = new Y.XmlText(); tx.insert(0, 'hello');
  p.insert(0, [tx]); frag.insert(0, [p]);
  fx.xml_update = H(Y.encodeStateAsUpdate(a));
  fx.xml_expect = frag.toString();
}
// 2b. nested XmlText only inside a YMap (type ref 6, no nodeName) -> re-encode must keep ref 6
{
  const a = doc(6); a.getMap('m').set('k', new Y.XmlText('hi'));
  fx.xmltext_update = H(Y.encodeStateAsUpdate(a));
}
// 3. subdocument (ContentDoc, ref 9)
{
  const a = doc(7); const sub = new Y.Doc({ guid: 'sub-guid' });
  a.getMap('m').set('sub', sub);
  fx.subdoc_update = H(Y.encodeStateAsUpdate(a));
}
// 4. deleted secret: what yjs ships after insert+delete (gc=true default)
{
  const a = doc(8); const t = a.getText('t');
  t.insert(0, 'public '); t.insert(7, 'SECRET-PASSWORD-123'); t.delete(7, 19);
  fx.secret_yjs_update_len = Y.encodeStateAsUpdate(a).length;
  fx.secret_yjs_contains = Buffer.from(Y.encodeStateAsUpdate(a)).includes(Buffer.from('SECRET'));
}
// 5. rich text: format() semantics
{
  const a = doc(9); const t = a.getText('t');
  t.insert(0, 'abcdef'); t.format(0, 6, { bold: true }); t.format(2, 2, { bold: true });
  fx.format_overlap_delta = JSON.stringify(t.toDelta());
  const b = doc(10); const tb = b.getText('t');
  tb.insert(0, 'abc'); tb.format(0, 3, { bold: true }); tb.insert(3, 'X');
  fx.format_append_delta = JSON.stringify(tb.toDelta());
  const c = doc(11); const tc = c.getText('t');
  tc.insert(0, 'abcdef'); tc.format(0, 6, { color: '"red"' }); tc.format(2, 2, { color: '"blue"' });
  fx.format_nested_delta = JSON.stringify(tc.toDelta());
  const e = doc(12); const te = e.getText('t');
  te.insert(0, 'hi', { bold: true }); te.insertEmbed(2, { image: 'x.png' });
  fx.richinsert_update = H(Y.encodeStateAsUpdate(e));
  fx.richinsert_delta = JSON.stringify(te.toDelta());
}
// 6. client id at the u53 boundary (Number.MAX_SAFE_INTEGER) and a huge clock
{
  const a = doc(2 ** 53 - 1); a.getText('t').insert(0, 'max');
  fx.bigclient_update = H(Y.encodeStateAsUpdate(a));
  fx.bigclient_sv = H(Y.encodeStateVector(a));
}
// 7. any-object key order (lib0 writes insertion order)
{
  const a = doc(13); a.getArray('a').insert(0, [{ zeta: 1, alpha: 2, mid: 3 }]);
  fx.objorder_update = H(Y.encodeStateAsUpdate(a));
  fx.objorder_keys = Object.keys(a.getArray('a').get(0)).join(',');
}
// 8. update v2 of a trivial doc (feature gap)
{
  const a = doc(14); a.getText('t').insert(0, 'v2');
  fx.v2_update = H(Y.encodeStateAsUpdateV2(a));
}
// 9. empty update
fx.empty_update = H(Y.encodeStateAsUpdate(new Y.Doc()));
// 10. UndoManager-free deleted nested type: yjs GCs the children of a deleted YMap
{
  const a = doc(15); const arr = a.getArray('a'); const m = new Y.Map(); arr.insert(0, [m]);
  for (let i = 0; i < 50; i++) m.set('key' + i, 'value-' + i + '-xxxxxxxxxxxxxxxx');
  arr.delete(0, 1);
  fx.deleted_nested_yjs_len = Y.encodeStateAsUpdate(a).length;
}
console.log(JSON.stringify(fx, null, 1));
