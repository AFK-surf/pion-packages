#!/usr/bin/env python3
"""Mutation-differential fuzz: Pion vs yaml-rust2 (whose scanner/parser Pion mirrors) on mutated
yaml-test-suite inputs, comparing accept/reject and canonical JSON. Prints each disagreement once
per (pion_status, rust_status) signature plus totals.

usage: fuzz_vs_rust.py <yts_dir> <pion_driver> <rust_driver> [iterations_per_case=10] [seed=11]
"""
import os, random, subprocess, sys
root, pion, rust = sys.argv[1:4]
iters = int(sys.argv[4]) if len(sys.argv) > 4 else 10
R = random.Random(int(sys.argv[5]) if len(sys.argv) > 5 else 11)
TOK = [b': ', b':', b'#', b' #', b' ', b'  ', b'\t', b'\n', b'- ', b'[', b']', b'{', b'}', b',', b'? ', b'&a ', b'*a', b'"', b"'", b'|', b'>', b'---\n', b'...\n', b'\\']
files = sorted(os.path.join(dp, 'in.yaml') for dp, dn, fn in os.walk(root) if 'in.yaml' in fn)
tmp = os.path.join(os.environ.get('TMPDIR', '/tmp'), 'pion_fuzz_rust.yaml')
def run(d):
    p = subprocess.run([d, 'json', tmp], capture_output=True, timeout=10)
    o = p.stdout.decode('utf-8', 'replace')
    if p.returncode < 0: return 'CRASH', o
    return ('ERR' if o.startswith('ERR') else 'OK'), o
n = 0; diffs = {}
for f in files:
    base = open(f, 'rb').read()
    for _ in range(iters):
        b = bytearray(base)
        for _ in range(R.randint(1, 3)):
            pos = R.randint(0, len(b))
            if R.random() < 0.6: b[pos:pos] = R.choice(TOK)
            elif len(b): del b[pos:pos + R.randint(1, 3)]
        data = bytes(b)
        try: data.decode('utf-8')
        except UnicodeDecodeError: continue
        open(tmp, 'wb').write(data); n += 1
        (sp, op), (sr, orr) = run(pion), run(rust)
        if sp == 'CRASH' or (sp, op) != (sr, orr) and not (sp == sr == 'ERR') and '<BadValue>' not in orr:
            key = (sp, sr)
            diffs.setdefault(key, []).append((data, op.strip(), orr.strip()))
print(f'mutants={n}')
for k, v in diffs.items():
    print(f'== pion={k[0]} rust={k[1]}: {len(v)} cases; first 3:')
    for data, op, orr in v[:3]:
        print('   input:', repr(data)[:160]); print('   pion :', op[:160]); print('   rust :', orr[:160])
