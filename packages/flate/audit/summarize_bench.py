#!/usr/bin/env python3
"""Collect bench_compare.py JSON outputs from run_audit.sh into one Markdown matrix (MB/s and x vs miniz_oxide)."""
import glob
import json
import os
import sys

out = sys.argv[1]
rows = {}
for p in sorted(glob.glob(os.path.join(out, 'bench_*_*.json'))):
    name = os.path.basename(p)[6:-5]
    corpus, op = name.rsplit('_', 1)
    d = json.load(open(p))
    res = d.get('results') or d.get('impls') or d
    rows[(corpus, op)] = d


def pick(d):
    out = {}
    items = d.get('results', d.get('impls', []))
    if isinstance(items, dict):
        items = [dict(v, name=k) for k, v in items.items()]
    for r in items:
        out[r.get('name')] = r
    return out


ops = {'d': 'gzip decompress', '1': 'compress L1', '6': 'compress L6', '9': 'compress L9', 'crc': 'CRC-32+Adler-32'}
print('| corpus | op | pion MB/s | miniz_oxide MB/s | go MB/s | pion vs miniz | pion vs go |')
print('| --- | --- | ---: | ---: | ---: | ---: | ---: |')
for (corpus, op), d in sorted(rows.items(), key=lambda kv: (kv[0][0], ['d', '1', '6', '9', 'crc'].index(kv[0][1]))):
    r = pick(d)
    def mbs(n):
        x = r.get(n, {})
        return x.get('throughput_mb_s') or 0
    def med(n):
        x = r.get(n, {})
        return x.get('median_ms') or 0
    p, m, g = med('pion'), med('rust_miniz_oxide'), med('go')
    print(f'| {corpus} | {ops.get(op, op)} | {mbs("pion"):.1f} | {mbs("rust_miniz_oxide"):.1f} | {mbs("go"):.1f} | '
          f'{(m / p if p else 0):.2f}x | {(g / p if p else 0):.2f}x |')


# Compression ratio (raw DEFLATE bytes) per corpus/level, same binaries
import subprocess
print()
print('| corpus | level | pion bytes | miniz_oxide bytes | go bytes | pion vs miniz size |')
print('| --- | ---: | ---: | ---: | ---: | ---: |')
corpora = sorted({c for c, _ in rows})
for c in corpora:
    src = os.path.join(out, f'corpus_{c}.bin')
    for lvl in ('1', '6', '9'):
        sz = {}
        for t in ('pion', 'rust', 'go'):
            o = subprocess.run([os.path.join(out, 'bin', f'{t}_audit'), 'cfile', lvl, src, os.path.join(out, 'ratio.out')],
                               capture_output=True, text=True).stdout.split()
            sz[t] = int(o[1]) if len(o) > 1 else -1
        print(f"| {c} | {lvl} | {sz['pion']} | {sz['rust']} | {sz['go']} | {sz['pion'] / sz['rust']:.3f} |")
