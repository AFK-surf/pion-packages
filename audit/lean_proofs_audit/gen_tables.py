#!/usr/bin/env python3
"""Render per-theorem grade tables (markdown) from scan.py's theorems.csv.

Usage: python3 -I gen_tables.py <scan-out-dir> [pkg ...]   (no pkg: all packages)
"""
import csv, os, sys, collections

out = sys.argv[1]
want = sys.argv[2:]
rows = list(csv.DictReader(open(os.path.join(out, 'theorems.csv'), encoding='utf-8')))
by = collections.defaultdict(list)
for r in rows:
    by[r['pkg']].append(r)
for pkg in (want or sorted(by)):
    rs = by[pkg]
    c = collections.Counter(r['manual'][0] for r in rs)
    print(f"#### {pkg} — {len(rs)} 条：A {c['A']} / B {c['B']} / C {c['C']}\n")
    print('| # | 定理 | 位置 | 级别 | 依据 |')
    print('|---:|---|---|---|---|')
    for i, r in enumerate(sorted(rs, key=lambda r: (r['file'], int(r['line']))), 1):
        note = r['note'].replace('|', '\\|')
        print(f"| {i} | `{r['name']}` | `{r['file']}:{r['line']}` | **{r['manual']}** | {note} |")
    print()
