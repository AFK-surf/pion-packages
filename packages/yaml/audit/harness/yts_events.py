#!/usr/bin/env python3
"""Strict typed oracle for the official yaml-test-suite: rebuild every valid case's
value tree from its `test.event` stream (the suite's normative parse result) with
YAML 1.2.2 Core Schema resolution, and compare it to Pion's type-tagged dump
(`pion_driver typed`).  Unlike `in.json`, this keeps Int vs Float, key order,
non-string keys, and the 25+ event-only cases that the ported tests skipped.

usage: yts_events.py <yts_data_dir> <pion_driver> [--show N]
"""
import json, math, os, re, subprocess, sys

CORE = 'tag:yaml.org,2002:'
RE_INT10 = re.compile(r'[-+]?[0-9]+\Z')
RE_INT8 = re.compile(r'0o[0-7]+\Z')
RE_INT16 = re.compile(r'0x[0-9a-fA-F]+\Z')
RE_FLOAT = re.compile(r'[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?\Z')

def core_plain(s):
    if s in ('', '~', 'null', 'Null', 'NULL'):
        return None
    if s in ('true', 'True', 'TRUE'):
        return True
    if s in ('false', 'False', 'FALSE'):
        return False
    if RE_INT10.match(s):
        return ('i', int(s))
    if RE_INT8.match(s):
        return ('i', int(s[2:], 8))
    if RE_INT16.match(s):
        return ('i', int(s[2:], 16))
    if RE_FLOAT.match(s):
        return ('f', float(s))
    if s in ('.inf', '.Inf', '.INF', '+.inf', '+.Inf', '+.INF'):
        return ('f', math.inf)
    if s in ('-.inf', '-.Inf', '-.INF'):
        return ('f', -math.inf)
    if s in ('.nan', '.NaN', '.NAN'):
        return ('f', 'nan')
    return s

def unesc(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == '\\' and i + 1 < len(s):
            n = s[i + 1]
            out.append({'n': '\n', 't': '\t', 'r': '\r', 'b': '\b', '0': '\0', '\\': '\\', 'f': '\f', 'a': '\a', 'v': '\v', 'e': '\x1b'}.get(n, '\\' + n))
            i += 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)

def scalar(tag, style, text):
    if tag is None:
        return core_plain(text) if style == ':' else text
    if tag == '!':
        return text
    if tag.startswith(CORE):
        t = tag[len(CORE):]
        if t == 'str':
            return text
        if t in ('int', 'float', 'bool', 'null'):
            v = core_plain(text)
            if t == 'float' and isinstance(v, tuple) and v[0] == 'i':
                return ('f', float(v[1]))
            return v
    return core_plain(text) if style == ':' else text

TOK = re.compile(r'^(&\S+ )?(<[^>]*> )?')

def build(events):
    docs, stack, anchors = [], [], {}
    def add(v):
        if not stack:
            docs.append(v)
            return
        top = stack[-1]
        if top[0] == 'seq':
            top[1].append(v)
        else:
            if top[2] is None:
                top[2] = [v]
            else:
                top[1].append((top[2][0], v))
                top[2] = None
    for line in events:
        line = line.rstrip('\n')
        if line.startswith('+DOC'):
            anchors = {}
        if line.startswith('+MAP') or line.startswith('+SEQ'):
            rest = line[5:]
            rest = rest.replace('{} ', '').replace('[] ', '').replace('{}', '').replace('[]', '')
            m = re.findall(r'&(\S+)', rest)
            stack.append(['map' if line.startswith('+MAP') else 'seq', [], None, m[0] if m else None])
        elif line.startswith('-MAP') or line.startswith('-SEQ'):
            kind, items, _, anc = stack.pop()
            v = ('seq', items) if kind == 'seq' else ('map', items)
            if anc:
                anchors[anc] = v
            add(v)
        elif line.startswith('=VAL '):
            rest = line[5:]
            anc = tag = None
            while True:
                if rest.startswith('&'):
                    sp = rest.index(' ')
                    anc, rest = rest[1:sp], rest[sp + 1:]
                elif rest.startswith('<'):
                    e = rest.index('> ')
                    tag, rest = rest[1:e], rest[e + 2:]
                else:
                    break
            style, text = rest[0], unesc(rest[1:])
            v = scalar(tag, style, text)
            if anc:
                anchors[anc] = v
            add(v)
        elif line.startswith('=ALI '):
            add(anchors[line[6:]])
    return docs

def from_pion(j):
    if isinstance(j, dict):
        if 'i' in j:
            return ('i', int(j['i']))
        f = j['f']
        if f in ('nan', 'NaN', '-nan'):
            return ('f', 'nan')
        return ('f', float(f.replace('inf', 'inf')))
    if isinstance(j, list):
        if j[0] == 'seq':
            return ('seq', [from_pion(x) for x in j[1:]])
        return ('map', [(from_pion(k), from_pion(v)) for k, v in j[1:]])
    return j

def main():
    root, pion = sys.argv[1], sys.argv[2]
    show = int(sys.argv[sys.argv.index('--show') + 1]) if '--show' in sys.argv else 200
    cases = []
    for top in sorted(os.listdir(root)):
        d = os.path.join(root, top)
        if not os.path.isdir(d) or top.startswith('.') or top in ('name', 'tags'):
            continue
        if os.path.exists(os.path.join(d, 'in.yaml')):
            cases.append((top, d))
        else:
            for sub in sorted(os.listdir(d)):
                sd = os.path.join(d, sub)
                if os.path.exists(os.path.join(sd, 'in.yaml')):
                    cases.append((top + '_' + sub, sd))
    total = passed = 0
    fails = []
    for cid, d in cases:
        if os.path.exists(os.path.join(d, 'error')):
            continue
        total += 1
        exp = build(open(os.path.join(d, 'test.event'), encoding='utf-8').readlines())
        p = subprocess.run([pion, 'typed', os.path.join(d, 'in.yaml')], capture_output=True, timeout=20)
        out = p.stdout.decode('utf-8', 'replace')
        if p.returncode != 0:
            fails.append((cid, 'ERR ' + out.strip(), exp, None))
            continue
        got = [from_pion(json.loads(l)) for l in out.splitlines() if l.strip()]
        if got == exp:
            passed += 1
        else:
            fails.append((cid, 'MISMATCH', exp, got))
    print(f'typed event-oracle: Pion {passed}/{total} valid cases identical')
    for cid, why, exp, got in fails[:show]:
        name = open(os.path.join(root, cid.split('_')[0], '===')).read().strip() if os.path.exists(os.path.join(root, cid.split('_')[0], '===')) else ''
        print(f'  FAIL {cid} ({name}): {why}')
        print(f'     expected: {exp!r:.400}')
        print(f'     pion    : {got!r:.400}')
    return 0 if not fails else 1

sys.exit(main())
