#!/usr/bin/env python3
"""Run the full official yaml-test-suite (data branch) through Pion / yaml-rust2 / yaml.v3 drivers.

usage: yts_run.py <yts_data_dir> <pion_driver> <rust_driver> <go_driver> <out_json>
Ground truth: `error` file => must be rejected; `in.json` => must match (JSON value equality);
valid without in.json => must at least be accepted (compared to Rust/Go for information).
"""
import json, os, subprocess, sys

def jstream(text):
    dec = json.JSONDecoder()
    i, out = 0, []
    text = text.strip()
    while i < len(text):
        while i < len(text) and text[i] in ' \t\r\n':
            i += 1
        if i >= len(text):
            break
        v, j = dec.raw_decode(text, i)
        out.append(v)
        i = j
    return out

def norm(v):
    if isinstance(v, bool) or v is None or isinstance(v, str):
        return v
    if isinstance(v, (int, float)):
        return ('num', float(v))
    if isinstance(v, list):
        return [norm(x) for x in v]
    if isinstance(v, dict):
        return {k: norm(x) for k, x in v.items()}
    return v

def run(drv, path):
    try:
        p = subprocess.run([drv, 'json', path], capture_output=True, timeout=20)
    except subprocess.TimeoutExpired:
        return ('TIMEOUT', None)
    out = p.stdout.decode('utf-8', 'replace')
    if p.returncode < 0:
        return ('CRASH', 'signal %d' % -p.returncode)
    if out.startswith('ERR') or p.returncode != 0:
        return ('ERR', out.strip()[:200])
    try:
        return ('OK', [json.loads(l) for l in out.splitlines() if l.strip()])
    except Exception as e:
        return ('BADJSON', out[:200])

def main():
    root, pion, rust, go, outp = sys.argv[1:6]
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
                if os.path.isdir(sd) and os.path.exists(os.path.join(sd, 'in.yaml')):
                    cases.append((top + '_' + sub, sd))
    res = []
    for cid, d in cases:
        kind = 'error' if os.path.exists(os.path.join(d, 'error')) else ('json' if os.path.exists(os.path.join(d, 'in.json')) else 'event-only')
        name = open(os.path.join(d, '===')).read().strip() if os.path.exists(os.path.join(d, '===')) else ''
        y = os.path.join(d, 'in.yaml')
        r = {'id': cid, 'kind': kind, 'name': name}
        for tag, drv in (('pion', pion), ('rust', rust), ('go', go)):
            st, val = run(drv, y)
            ok = None
            if kind == 'error':
                ok = st == 'ERR'
            elif kind == 'json':
                if st == 'OK':
                    exp = jstream(open(os.path.join(d, 'in.json')).read())
                    ok = norm(val) == norm(exp)
                else:
                    ok = False
            else:
                ok = st == 'OK'
            r[tag] = {'status': st, 'pass': ok, 'detail': val if st != 'OK' else json.dumps(val, ensure_ascii=False)[:300]}
        res.append(r)
    json.dump(res, open(outp, 'w'), indent=1, ensure_ascii=False)
    summ = {}
    for r in res:
        for tag in ('pion', 'rust', 'go'):
            k = (tag, r['kind'])
            a = summ.setdefault(k, [0, 0])
            a[1] += 1
            a[0] += 1 if r[tag]['pass'] else 0
    print('| impl | error cases rejected | in.json cases matched | event-only cases accepted | total |')
    print('|---|---:|---:|---:|---:|')
    for tag in ('pion', 'rust', 'go'):
        e, j, v = summ[(tag, 'error')], summ[(tag, 'json')], summ[(tag, 'event-only')]
        print(f'| {tag} | {e[0]}/{e[1]} | {j[0]}/{j[1]} | {v[0]}/{v[1]} | {e[0]+j[0]+v[0]}/{e[1]+j[1]+v[1]} |')
    print()
    print('Pion failures:')
    for r in res:
        if not r['pion']['pass']:
            print(f"  {r['id']:10s} [{r['kind']}] {r['name'][:50]!r}: pion={r['pion']['status']} {str(r['pion']['detail'])[:120]} | rust={'pass' if r['rust']['pass'] else 'FAIL'} go={'pass' if r['go']['pass'] else 'FAIL'}")

main()
