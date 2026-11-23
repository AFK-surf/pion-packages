#!/usr/bin/env python3
"""Deterministic benchmark corpora with *different statistical shapes* (the shipped bench uses one
highly repetitive synthetic 2 MiB corpus that compresses to 3.4 %, which mostly exercises long-match copies).

  entropy   4 MiB os-independent PRNG bytes (incompressible: stored/literal path)
  html      ~4 MiB: Go spec + memory model HTML from $GOROOT/doc, repeated with per-copy edits
  json      ~4 MiB: varied JSON records (numbers, uuids, nested arrays) from a seeded PRNG
  source    ~4 MiB: real Go source ($GOROOT/src/{net/http,go/types,runtime}/*.go, sorted)
  text      ~2.4 MiB: /usr/share/dict/web2 English word list (falls back to PRNG words)
  big16     16 MiB: concatenation of the above, for buffer-growth / memory behaviour

Writes <out>/corpus_<name>.bin and <out>/corpus_<name>.gz (zlib level 6, used as decode input for all impls).
"""
import glob
import gzip
import json
import os
import random
import subprocess
import sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
MiB = 1 << 20


def goroot():
    try:
        return subprocess.check_output(['go', 'env', 'GOROOT'], text=True).strip()
    except Exception:
        return ''


def fit(b, n):
    if not b:
        return b
    while len(b) < n:
        b += b
    return b[:n]


rnd = random.Random(20261123)
gr = goroot()
corp = {}
corp['entropy'] = bytes(rnd.getrandbits(8) for _ in range(4 * MiB))

html = b''
for f in ('go_spec.html', 'go_mem.html', 'asm.html'):
    p = os.path.join(gr, 'doc', f)
    if os.path.exists(p):
        html += open(p, 'rb').read()
if not html:
    html = b''.join(b'<div class="c%d"><p>%s</p></div>\n' % (i, str(rnd.random()).encode()) for i in range(40000))
parts, k = [], 0
while sum(map(len, parts)) < 4 * MiB:
    parts.append(html.replace(b'<p>', b'<p data-copy="%d">' % k))
    k += 1
corp['html'] = b''.join(parts)[:4 * MiB]

recs = []
while sum(map(len, recs)) < 4 * MiB:
    i = len(recs)
    recs.append((json.dumps({
        'id': i, 'uuid': '%032x' % rnd.getrandbits(128), 'score': rnd.random() * 1000,
        'user': {'name': 'user%d' % rnd.randrange(100000), 'age': rnd.randrange(18, 90),
                 'roles': rnd.sample(['admin', 'dev', 'ops', 'qa', 'pm', 'sre'], rnd.randrange(1, 4))},
        'points': [rnd.randrange(-500, 500) for _ in range(rnd.randrange(0, 12))],
        'ok': rnd.random() < 0.9}) + '\n').encode())
corp['json'] = b''.join(recs)[:4 * MiB]

src = b''
for d in ('net/http', 'go/types', 'runtime', 'cmd/compile/internal/ssa'):
    for f in sorted(glob.glob(os.path.join(gr, 'src', d, '*.go'))):
        src += open(f, 'rb').read()
        if len(src) >= 4 * MiB:
            break
    if len(src) >= 4 * MiB:
        break
corp['source'] = fit(src, 4 * MiB)

words = b''
if os.path.exists('/usr/share/dict/web2'):
    words = open('/usr/share/dict/web2', 'rb').read()
else:
    words = b'\n'.join(bytes(rnd.choice(b'etaoinshrdlucmfwyp') for _ in range(rnd.randrange(2, 12))) for _ in range(250000))
corp['text'] = words
corp['big16'] = fit(corp['source'] + corp['json'] + corp['html'] + corp['text'] + corp['entropy'][:MiB], 16 * MiB)

for k, v in corp.items():
    open(os.path.join(out, f'corpus_{k}.bin'), 'wb').write(v)
    open(os.path.join(out, f'corpus_{k}.gz'), 'wb').write(gzip.compress(v, 6, mtime=0))
    print(f'{k:8s} {len(v):9d} B  gz6={len(gzip.compress(v, 6, mtime=0)) * 100.0 / len(v):6.2f}%')
