#!/usr/bin/env python3
"""Mutation-differential fuzz: 00b956c (optimized) vs its parent 09ca291 on mutated
yaml-test-suite inputs. Any output difference (value, type, accept/reject) is a
regression candidate introduced by the perf commit. Error *positions/messages* are
compared too but reported separately.

usage: regress_fuzz.py <yts_dir> <pion_cur> <pion_prev> [iterations_per_case=20] [seed=7]
"""
import os, random, subprocess, sys

root, cur, prev = sys.argv[1:4]
iters = int(sys.argv[4]) if len(sys.argv) > 4 else 20
R = random.Random(int(sys.argv[5]) if len(sys.argv) > 5 else 7)
TOK = [b': ', b':', b'#', b' #', b' ', b'  ', b'\t', b'\n', b'\r\n', b'- ', b'[', b']', b'{', b'}', b',', b'? ', b'&a ', b'*a', b'!!str ', b'"', b"'", b'|', b'>', b'---\n', b'...\n', b'\\', b'%', b'<<: ', b'\xc3\xa9']
files = []
for dp, dn, fn in os.walk(root):
    if 'in.yaml' in fn:
        files.append(os.path.join(dp, 'in.yaml'))
files.sort()
tmp = os.path.join(os.environ.get('TMPDIR', '/tmp'), 'pion_regress_fuzz.yaml')

def run(d):
    p = subprocess.run([d, 'typed', tmp], capture_output=True, timeout=10)
    o = p.stdout.decode('utf-8', 'replace')
    return ('ERR' if o.startswith('ERR') else 'OK'), o

n = val_diff = err_diff = 0
for f in files:
    base = open(f, 'rb').read()
    for _ in range(iters):
        b = bytearray(base)
        for _ in range(R.randint(1, 3)):
            pos = R.randint(0, len(b))
            op = R.random()
            if op < 0.5:
                b[pos:pos] = R.choice(TOK)
            elif op < 0.8 and len(b) > 0:
                del b[pos:pos + R.randint(1, 3)]
            else:
                b[pos:pos + 1] = R.choice(TOK)
        open(tmp, 'wb').write(bytes(b))
        n += 1
        (sa, oa), (sb_, ob) = run(cur), run(prev)
        if sa != sb_ or (sa == 'OK' and oa != ob):
            val_diff += 1
            print('VALUE/ACCEPT DIFF from', f, repr(bytes(b))[:200])
            print('   cur :', oa.strip()[:200])
            print('   prev:', ob.strip()[:200])
        elif oa != ob:
            err_diff += 1
print(f'mutants={n} value_or_accept_diffs={val_diff} error_position_or_message_diffs={err_diff}')
