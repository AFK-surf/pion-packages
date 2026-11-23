'use strict';
// graphql-js (graphql@16.10.0) oracle for the packages/graphql red-team audit.
// Same CLI and length-framed record format as probe/src/main.pion:
//   node oracle.js <tok|tokb|parse|parseb|min|print|valid> <in> <out>
//   node oracle.js one <in> <tok|parse|min|print|valid> [reps]
// The canonical AST dump below is a byte-for-byte mirror of `dump_doc` in the Pion probe.
const fs = require('fs');
const g = require('graphql');

function readRecords(buf) {
  const out = [];
  let i = 0;
  while (i < buf.length) {
    const j = buf.indexOf(10, i);
    const n = parseInt(buf.slice(i, j).toString('latin1'), 10);
    out.push(buf.slice(j + 1, j + 1 + n));
    i = j + 1 + n;
  }
  return out;
}

const W = (s) => `${Buffer.byteLength(s, 'utf8')}:${s}`;
const optName = (n) => (n ? W(n.value) : '-');

function dType(t) {
  if (t.kind === 'NamedType') return W(t.name.value);
  if (t.kind === 'ListType') return '[' + dType(t.type) + ']';
  return dType(t.type) + '!';
}

function dValue(v) {
  switch (v.kind) {
    case 'Variable': return '$' + W(v.name.value);
    case 'IntValue': return 'i' + W(v.value);
    case 'FloatValue': return 'f' + W(v.value);
    case 'StringValue': return (v.block ? 'B' : 's') + W(v.value);
    case 'BooleanValue': return v.value ? 'true' : 'false';
    case 'NullValue': return 'null';
    case 'EnumValue': return 'e' + W(v.value);
    case 'ListValue': return '[' + v.values.map((x) => dValue(x) + ' ').join('') + ']';
    case 'ObjectValue': return '{' + v.fields.map((f) => W(f.name.value) + '=' + dValue(f.value) + ' ').join('') + '}';
  }
  throw new Error('value kind ' + v.kind);
}

const dArgs = (args) => '(' + (args || []).map((a) => W(a.name.value) + '=' + dValue(a.value) + ' ').join('') + ')';
const dDirs = (ds) => '<' + (ds || []).map((d) => '@' + W(d.name.value) + dArgs(d.arguments)).join('') + '>';

function dSS(ss) {
  return '{' + ss.selections.map((s) => {
    if (s.kind === 'Field') {
      return '(F ' + optName(s.alias) + ' ' + W(s.name.value) + dArgs(s.arguments) + dDirs(s.directives) +
        (s.selectionSet ? dSS(s.selectionSet) : '-') + ')';
    }
    if (s.kind === 'FragmentSpread') return '(S ' + W(s.name.value) + dDirs(s.directives) + ')';
    return '(I ' + (s.typeCondition ? W(s.typeCondition.name.value) : '-') + dDirs(s.directives) + dSS(s.selectionSet) + ')';
  }).join('') + '}';
}

const dDesc = (d) => (d ? (d.block ? 'B' : 's') + W(d.value) : '-');
const dIvs = (ivs) => '(' + (ivs || []).map((iv) => '(iv ' + dDesc(iv.description) + ' ' + W(iv.name.value) + ' ' +
  dType(iv.type) + ' ' + (iv.defaultValue ? dValue(iv.defaultValue) : '-') + dDirs(iv.directives) + ')').join('') + ')';
const dNames = (xs) => '[' + (xs || []).map((x) => W(x.kind === 'NamedType' ? x.name.value : x.value)).join('') + ']';
const dFields = (fs) => '{' + (fs || []).map((f) => '(fd ' + dDesc(f.description) + ' ' + W(f.name.value) + dIvs(f.arguments) +
  dType(f.type) + dDirs(f.directives) + ')').join('') + '}';
const dEnumVals = (vs) => '{' + (vs || []).map((v) => '(ev ' + dDesc(v.description) + ' ' + W(v.name.value) + dDirs(v.directives) + ')').join('') + '}';
const dOpTypes = (ots) => '{' + (ots || []).map((o) => o.operation + '=' + W(o.type.name.value) + ' ').join('') + '}';

function dumpDef(d) {
  switch (d.kind) {
    case 'OperationDefinition':
      return '(op ' + d.operation + ' ' + optName(d.name) + ' (' + (d.variableDefinitions || []).map((vd) => '(var ' +
        W(vd.variable.name.value) + ' ' + dType(vd.type) + ' ' + (vd.defaultValue ? dValue(vd.defaultValue) : '-') +
        dDirs(vd.directives) + ')').join('') + ')' + dDirs(d.directives) + dSS(d.selectionSet) + ')';
    case 'FragmentDefinition':
      return '(frag ' + W(d.name.value) + ' ' + W(d.typeCondition.name.value) + dDirs(d.directives) + dSS(d.selectionSet) + ')';
    case 'SchemaDefinition':
      return '(schema ' + dDesc(d.description) + dDirs(d.directives) + dOpTypes(d.operationTypes) + ')';
    case 'SchemaExtension':
      return '(xschema ' + dDirs(d.directives) + dOpTypes(d.operationTypes) + ')';
    case 'DirectiveDefinition':
      return '(directive ' + dDesc(d.description) + ' ' + W(d.name.value) + dIvs(d.arguments) + (d.repeatable ? ' rep ' : ' - ') +
        dNames(d.locations) + ')';
    case 'ScalarTypeDefinition': return '(scalar ' + dDesc(d.description) + ' ' + W(d.name.value) + dDirs(d.directives) + ')';
    case 'ObjectTypeDefinition':
    case 'InterfaceTypeDefinition':
      return '(' + (d.kind === 'ObjectTypeDefinition' ? 'type ' : 'interface ') + dDesc(d.description) + ' ' + W(d.name.value) +
        dNames(d.interfaces) + dDirs(d.directives) + dFields(d.fields) + ')';
    case 'UnionTypeDefinition': return '(union ' + dDesc(d.description) + ' ' + W(d.name.value) + dDirs(d.directives) + dNames(d.types) + ')';
    case 'EnumTypeDefinition': return '(enum ' + dDesc(d.description) + ' ' + W(d.name.value) + dDirs(d.directives) + dEnumVals(d.values) + ')';
    case 'InputObjectTypeDefinition': return '(input ' + dDesc(d.description) + ' ' + W(d.name.value) + dDirs(d.directives) + dIvs(d.fields) + ')';
    case 'ScalarTypeExtension': return '(xscalar ' + W(d.name.value) + dDirs(d.directives) + ')';
    case 'ObjectTypeExtension':
    case 'InterfaceTypeExtension':
      return '(' + (d.kind === 'ObjectTypeExtension' ? 'xtype ' : 'xinterface ') + W(d.name.value) + dNames(d.interfaces) +
        dDirs(d.directives) + dFields(d.fields) + ')';
    case 'UnionTypeExtension': return '(xunion ' + W(d.name.value) + dDirs(d.directives) + dNames(d.types) + ')';
    case 'EnumTypeExtension': return '(xenum ' + W(d.name.value) + dDirs(d.directives) + dEnumVals(d.values) + ')';
    case 'InputObjectTypeExtension': return '(xinput ' + W(d.name.value) + dDirs(d.directives) + dIvs(d.fields) + ')';
  }
  throw new Error('def kind ' + d.kind);
}

const dumpDoc = (doc) => doc.definitions.map((d) => dumpDef(d) + '\n').join('');

const PUNCT = new Set(['!', '$', '&', '(', ')', '...', ':', '=', '@', '[', ']', '{', '|', '}']);
function dumpTokens(src) {
  const lexer = new g.Lexer(new g.Source(src));
  let out = '';
  for (;;) {
    const t = lexer.advance();
    if (t.kind === '<EOF>') break;
    if (PUNCT.has(t.kind)) out += 'P ' + W(t.kind);
    else out += t.kind + ' ' + W(t.value);
  }
  return out;
}

// Schema-free executable rules only (everything else needs a real schema).
const RULES = [
  ['ExecutableDefinitions', g.ExecutableDefinitionsRule],
  ['DuplicateOperationName', g.UniqueOperationNamesRule],
  ['LoneAnonymousOperation', g.LoneAnonymousOperationRule],
  ['DuplicateFragmentName', g.UniqueFragmentNamesRule],
  ['UndefinedFragment', g.KnownFragmentNamesRule],
  ['NoUnusedFragments', g.NoUnusedFragmentsRule],
  ['FragmentCycle', g.NoFragmentCyclesRule],
  ['DuplicateVariableName', g.UniqueVariableNamesRule],
  ['NoUndefinedVariables', g.NoUndefinedVariablesRule],
  ['NoUnusedVariables', g.NoUnusedVariablesRule],
  ['DuplicateArgumentName', g.UniqueArgumentNamesRule],
  ['DuplicateInputFieldName', g.UniqueInputFieldNamesRule],
  ['UniqueDirectivesPerLocation', g.UniqueDirectivesPerLocationRule],
];
const SCHEMA = g.buildSchema('type Query { a: Int }');

function validDump(doc) {
  const kinds = new Set();
  for (const [name, rule] of RULES) {
    if (g.validate(SCHEMA, doc, [rule]).length > 0) kinds.add(name);
  }
  return kinds.size === 0 ? 'OK' : [...kinds].sort().join(',');
}

function decodeUtf8Strict(buf) {
  return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(buf);
}

function runOne(mode, buf) {
  try {
    let src = mode === 'tokb' || mode === 'parseb' ? decodeUtf8Strict(buf) : buf.toString('utf8');
    switch (mode) {
      case 'tok': case 'tokb': return dumpTokens(src);
      case 'parse': case 'parseb': return dumpDoc(g.parse(src, { noLocation: true }));
      case 'min': return g.stripIgnoredCharacters(src);
      case 'print': return g.print(g.parse(src, { noLocation: true }));
      case 'valid': return validDump(g.parse(src, { noLocation: true }));
    }
    return 'ERR unknown mode';
  } catch (e) {
    return 'ERR ' + String(e && e.message ? e.message : e).split('\n')[0];
  }
}

const [mode, inp, out, ...rest] = process.argv.slice(2);
if (mode === 'one') {
  const src = fs.readFileSync(inp, 'utf8');
  const sub = out;
  const reps = parseInt(rest[0] || '1', 10);
  let total = 0;
  try {
    for (let r = 0; r < reps; r++) {
      if (sub === 'tok') { const lx = new g.Lexer(new g.Source(src)); while (lx.advance().kind !== '<EOF>') total++; }
      else if (sub === 'parse') total += g.parse(src, { noLocation: true }).definitions.length;
      else if (sub === 'min') total += g.stripIgnoredCharacters(src).length;
      else if (sub === 'print') total += g.print(g.parse(src, { noLocation: true })).length;
      else if (sub === 'valid') { const d = g.parse(src, { noLocation: true }); const v = validDump(d); if (r === 0) console.log('valid ' + v); total += v.length; }
      else throw new Error('unknown sub ' + sub);
    }
  } catch (e) {
    console.log('ERR ' + String(e && e.message ? e.message : e).split('\n')[0]);
    process.exit(0);
  }
  console.log('ok ' + total);
} else {
  const recs = readRecords(fs.readFileSync(inp));
  const parts = [];
  for (const r of recs) {
    const o = Buffer.from(runOne(mode, r), 'utf8');
    parts.push(Buffer.from(o.length + '\n', 'latin1'), o);
  }
  fs.writeFileSync(out, Buffer.concat(parts));
}
