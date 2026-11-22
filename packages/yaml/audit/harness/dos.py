#!/usr/bin/env python3
"""DoS / pathological-input probes with wall time and peak RSS.

usage: dos.py <pion_driver> <rust_driver> <go_driver> <work_dir>
yaml-rust2 is skipped on alias bombs (it has no alias limit: the 9x9 seq bomb reached
22 GiB RSS before a 60 s timeout during this audit; we don't re-run that on a shared host).
"""
import os, platform, re, subprocess, sys, time

def gen(work):
    g = {}
    L = ['a0: &a0 ["lol","lol","lol","lol","lol","lol","lol","lol","lol"]']
    for i in range(1, 10):
        L.append(f'a{i}: &a{i} [' + ','.join([f'*a{i-1}'] * 9) + ']')
    g['bomb_seq_9x9'] = ('\n'.join(L) + '\n', 'bomb')
    L = ['m0: &m0 {a: lol, b: lol, c: lol, d: lol, e: lol, f: lol, g: lol, h: lol, i: lol}']
    for i in range(1, 10):
        L.append(f'm{i}: &m{i} {{' + ','.join(f'k{j}: *m{i-1}' for j in range(9)) + '}')
    g['bomb_map_9x9'] = ('\n'.join(L) + '\n', 'bomb')
    L = ['m0: &m0 {a: lol}']
    for i in range(1, 30):
        L.append(f'm{i}: &m{i} {{<<: [*m{i-1}], k{i}: [*m{i-1}, *m{i-1}]}}')
    g['bomb_merge_2x30'] = ('\n'.join(L) + '\n', 'bomb')
    L = ['k0: &k0 [lol, lol, lol, lol, lol, lol, lol, lol, lol]']
    for i in range(1, 10):
        L.append(f'k{i}: &k{i} {{' + ','.join(f'? [*k{i-1}, {j}] : x' for j in range(9)) + '}')
    g['bomb_alias_as_keys'] = ('\n'.join(L) + '\n', 'bomb')
    g['bytes_amplify_256KiBx4096'] = ('s: &s "' + 'x' * 262144 + '"\nl: [' + ','.join(['*s'] * 4096) + ']\n', 'bomb')
    g['deep_flow_1M_brackets'] = ('[' * 1000000 + ']' * 1000000 + '\n', 'all')
    g['deep_flow_unclosed_1M'] = ('[' * 1000000 + '\n', 'all')
    n = 40000
    g['merge_quadratic_40k_keys'] = ('base: &b {' + ', '.join('k%d: %d' % (i, i) for i in range(n)) + '}\nx:\n  <<: *b\n', 'all')
    s = 'base: &b {' + ', '.join('b%d: %d' % (i, i) for i in range(10000)) + '}\nx:\n  <<: *b\n' + ''.join('  e%d: %d\n' % (i, i) for i in range(100000))
    g['merge_10k_into_100k_explicit'] = (s, 'all')
    docs = []
    for i in range(1500):
        docs.append('defaults: &d\n' + ''.join(f'  opt{j}: v{j}\n' for j in range(20)) + f'svc{i}a:\n  <<: *d\n  name: a{i}\nsvc{i}b:\n  <<: *d\n  name: b{i}\n')
    g['valid_multidoc_1500_small_anchors'] = ('---\n'.join(docs), 'all')
    g['valid_120k_scalar_aliases'] = ('common: &img registry.example.com/app:1.2.3\njobs:\n' + ''.join(f'  - name: job{i}\n    image: *img\n' for i in range(120000)), 'all')
    L = ['l0: &l0 x']
    for k in range(1, 29):
        L.append(f'l{k}: &l{k} ' + '[' * 250 + f'*l{k-1}' + ']' * 250)
    g['emit_alias_depth_28x250'] = ('\n'.join(L) + '\n', 'emit')
    for name, (txt, _) in g.items():
        open(os.path.join(work, name + '.yaml'), 'w').write(txt)
    return g

def timed(cmd):
    sysname = platform.system()
    tcmd = ['/usr/bin/time', '-l'] + cmd if sysname == 'Darwin' else ['/usr/bin/time', '-v'] + cmd
    t0 = time.perf_counter()
    try:
        p = subprocess.run(tcmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    except subprocess.TimeoutExpired:
        return 'TIMEOUT>120s', None, 0, b''
    dt = time.perf_counter() - t0
    err = p.stderr.decode('utf-8', 'replace')
    m = re.search(r'(\d+)\s+maximum resident set size', err) or re.search(r'Maximum resident set size \(kbytes\): (\d+)', err)
    rss = None
    if m:
        rss = int(m.group(1)) if sysname == 'Darwin' else int(m.group(1)) * 1024
    return '%.2fs' % dt, rss, len(p.stdout), p.stdout[:80]

def main():
    pion, rust, go, work = sys.argv[1:5]
    os.makedirs(work, exist_ok=True)
    g = gen(work)
    print('| input | size | impl | mode | wall | peak RSS | stdout bytes | head |')
    print('|---|---:|---|---|---:|---:|---:|---|')
    for name, (_, kind) in g.items():
        f = os.path.join(work, name + '.yaml')
        size = os.path.getsize(f)
        impls = [('pion', pion), ('go', go)] + ([] if kind == 'bomb' else [('rust', rust)])
        mode = 'rtjson' if kind == 'emit' else 'json'
        for tag, drv in impls:
            if kind == 'emit' and tag == 'pion':
                w, rss, nout, head = timed([drv, 'emit', f])
                m = 'emit'
            else:
                w, rss, nout, head = timed([drv, mode, f])
                m = mode
            h = head.decode('utf-8', 'replace').split('\n')[0][:60].replace('|', '\\|')
            print(f'| {name} | {size} | {tag} | {m} | {w} | {"%.1f MiB" % (rss / 1048576) if rss else "-"} | {nout} | `{h}` |')
        if kind == 'bomb':
            print(f'| {name} | {size} | rust | json | skipped (no alias limit; 9x9 bomb hit 22 GiB) | | | |')

main()
