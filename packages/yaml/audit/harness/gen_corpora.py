#!/usr/bin/env python3
"""Generate adversarial-but-realistic YAML benchmark corpora (~3 MB each unless noted).
Only ints / strings / bools / nulls are used so canonical-JSON stdout is byte-identical
across Pion, yaml-rust2 and yaml.v3 (bench_compare.py SHA-256 gate).

usage: gen_corpora.py <out_dir>
"""
import os, random, sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
R = random.Random(1234)
TARGET = 3_000_000

def put(name, text):
    open(os.path.join(out, name + '.yaml'), 'w', encoding='utf-8').write(text)

words = ['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta', 'eta', 'theta', 'iota', 'kappa', 'lambda', 'mu']

# 1. JSON-style flow YAML (e.g. kubectl -o json piped through a YAML loader, package-lock style)
parts, n, i = [], 0, 0
while n < TARGET:
    s = '{"id": %d, "name": "item-%d", "enabled": %s, "owner": null, "tags": ["%s", "%s", "%s"], "meta": {"rev": %d, "path": "/srv/%s/%d"}}' % (
        i, i, 'true' if i % 3 else 'false', R.choice(words), R.choice(words), R.choice(words), i * 7, R.choice(words), i)
    parts.append(s); n += len(s) + 2; i += 1
put('flow_json', '[\n' + ',\n'.join(parts) + '\n]\n')

# 2. Many tiny documents (log / event streams, `kubectl get -o yaml` lists split per object)
docs, n, i = [], 0, 0
while n < TARGET:
    s = 'kind: Event\nid: %d\nreason: %s\ncount: %d\n' % (i, R.choice(words), i % 97)
    docs.append(s); n += len(s) + 4; i += 1
put('many_small_docs', '---\n'.join(docs))

# 3. Long literal / folded block scalars (Helm templates, embedded scripts, certificates)
docs, n, i = [], 0, 0
while n < TARGET:
    body = ''.join('    ' + ' '.join(R.choice(words) for _ in range(12)) + '\n' for _ in range(200))
    s = 'name: script-%d\nrun: |\n%sdescription: >-\n%s' % (i, body, body)
    docs.append(s); n += len(s); i += 1
put('block_scalars', '---\n'.join(docs))

# 4. Double-quoted strings with escapes (i18n catalogs, JSON-escaped payloads)
lines, n, i = [], 0, 0
while n < TARGET:
    s = 'msg_%d: "Line %d\\tcol\\u00e9\\\\path\\n\\"quoted\\" caf\\u00e9 \\U0001F600 %s"\n' % (i, i, R.choice(words))
    lines.append(s); n += len(s); i += 1
put('dq_escapes', ''.join(lines))

# 5. One very wide mapping (generated lookup tables, i18n bundles)
lines, n, i = [], 0, 0
while n < TARGET:
    s = 'key_%06d: value %s %d\n' % (i, R.choice(words), i)
    lines.append(s); n += len(s); i += 1
put('wide_map', ''.join(lines))

# 6. Deep-ish block nesting (100 levels, well inside every limit) repeated
docs, n, i = [], 0, 0
while n < TARGET:
    s = ''.join('  ' * d + 'level%d:\n' % d for d in range(100)) + '  ' * 100 + 'leaf: %d\n' % i
    docs.append(s); n += len(s); i += 1
put('deep_nesting', '---\n'.join(docs))

# 7. Anchor/alias heavy CI config (16k scalar + map aliases, under Pion's 100k budget)
s = 'defaults: &d {image: "ubuntu:24.04", timeout: 30, retries: 2}\nshared: &img registry.example.com/app:1.2.3\njobs:\n'
s += ''.join('  - name: job%d\n    image: *img\n    opts: *d\n' % i for i in range(8000))
put('anchors_aliases', s)

# 8. Multi-line plain scalars & comments (hand-written docs / Ansible)
lines, n, i = [], 0, 0
while n < TARGET:
    s = '# task %d: %s\n- name: %s task %d\n  description: this is a long\n    plain scalar that folds\n    across several lines %d\n  when: x == %d  # trailing comment\n' % (i, R.choice(words), R.choice(words), i, i, i)
    lines.append(s); n += len(s); i += 1
put('plain_multiline_comments', ''.join(lines))

# 9. Long single-line plain values (minified tokens / base64 blobs)
lines, n, i = [], 0, 0
while n < TARGET:
    s = 'blob%d: %s\n' % (i, ''.join(R.choice('ABCDEFGHabcdefgh0123456789+/') for _ in range(4000)))
    lines.append(s); n += len(s); i += 1
put('long_plain_lines', ''.join(lines))

for f in sorted(os.listdir(out)):
    print(f, os.path.getsize(os.path.join(out, f)))
