#!/usr/bin/env python3
"""Targeted differential probes: the same bytes through Pion / yaml-rust2 / yaml.v3.

usage: probes.py <pion_driver> <rust_driver> <go_driver> <work_dir>
Prints a Markdown table (verdict column = what YAML 1.2.2 / the references require).
"""
import os, subprocess, sys

P = [
    # id, bytes, expectation
    ('float_precision', b'a: 0.30000000000000004\nb: 3.141592653589793\nc: 1.7976931348623157e308\n', 'exact doubles (Rust & Go print 17 sig. digits)'),
    ('dup_key', b'admin: false\nadmin: true\n', 'reject (YAML 1.2 §3.2.1.1; Rust & Go reject)'),
    ('dup_key_flow', b'{a: 1, a: 2}\n', 'reject'),
    ('dup_merge_key', b'a: &a {x: 1}\nd:\n  <<: *a\n  <<: {x: 2, z: 3}\n', 'reject (Rust & Go)'),
    ('int_str_key_collide', b'1: a\n"1": b\n', 'distinct keys; JSON view must not silently drop one'),
    ('recursive_alias_seq', b'&a [&b 1, *a]\n', 'reject (Go: anchor contains itself)'),
    ('recursive_alias_map', b'&a {x: &b 1, y: *a}\n', 'reject'),
    ('recursive_alias_self', b'&a [*a]\n', 'reject'),
    ('invalid_utf8', b'a: \xff\xfe\n', 'reject (Go; Rust cannot even accept &str)'),
    ('overlong_utf8', b'a: \xc0\x81\n', 'reject'),
    ('c0_control_plain', b'a: x\x01y\n', 'reject (§5.1 c-printable; Go rejects)'),
    ('nul_byte', b'a: x\x00y\n', 'reject'),
    ('bigint', b'a: 9223372036854775808\nb: 18446744073709551615\n', 'Core int (Go: uint64; Rust: number), not a string'),
    ('hex_u64', b'a: 0xFFFFFFFFFFFFFFFF\n', 'Core int (Go: uint64)'),
    ('custom_tag', b'a: !foo 12\nb: !foo "12"\n', '"12" (Rust & Go keep tagged scalar as string)'),
    ('merge_scalar', b'd:\n  <<: 5\n', 'reject (Go)'),
    ('merge_basic', b'base: &b {x: 1, y: 2}\nd:\n  <<: *b\n  y: 3\n', 'Go/Pion merge; Rust has no merge support'),
    ('tab_indent_error_pos', b'a: 1\n\tb: 2\n', 'error on line 2 (Go)'),
    ('nesting_300', ('\n'.join(' ' * i + 'k%d:' % i for i in range(300)) + ' v\n').encode(), 'accept (Rust; Go limit 10000)'),
    ('bom_mid_document', b'a: 1\n\xef\xbb\xbfb: 2\n', 'reject (§9.1.1) — Pion correct here'),
    ('escapes_full', b'"\\x41\\u00e9\\U0001F600\\N\\_\\L\\P\\/\\ \\e"\n', 'accept (Go lacks \\/)'),
    ('flow_multiline_key', b'{ a\n  b: c }\n', 'accept'),
    ('complex_key', b'? [a, b]\n: v\n? {x: 1}\n: w\n', 'accept (Go cannot decode into map)'),
    ('leading_zero_int', b'a: 0012\n', '12 (Go: octal 10)'),
    ('timestamp', b'a: 2002-12-14\n', 'string under Core schema (Go: time.Time)'),
]

def run(drv, mode, path):
    try:
        p = subprocess.run([drv, mode, path], capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        return 'TIMEOUT'
    o = p.stdout.decode('utf-8', 'replace').strip().replace('\n', ' \u23ce ')
    if p.returncode < 0:
        o = 'CRASH signal %d' % -p.returncode
    return o

def cell(s, n=70):
    s = s.replace('|', '\\|')
    return '`' + (s[:n] + '\u2026' if len(s) > n else s) + '`' if s else '`(empty)`'

def main():
    pion, rust, go, work = sys.argv[1:5]
    os.makedirs(work, exist_ok=True)
    print('| probe | Pion | yaml-rust2 | yaml.v3 | requirement |')
    print('|---|---|---|---|---|')
    for pid, data, exp in P:
        f = os.path.join(work, pid + '.yaml')
        open(f, 'wb').write(data)
        print('| %s | %s | %s | %s | %s |' % (pid, cell(run(pion, 'json', f)), cell(run(rust, 'json', f)), cell(run(go, 'json', f)), exp))
    print()
    print('Emitter round trip (`stringify` -> `parse`, type-aware) on the same probes:')
    print()
    rt = [
        ('float_2_0', b'a: 2.0\nprice: 450.00\n'),
        ('float_precision', b'pi: 3.141592653589793\nmax: 1.7976931348623157e308\n'),
        ('doc_end_string', b'"..."\n'),
        ('quoted_merge_key', b'"<<": {a: 1}\nb: 2\n'),
        ('bom_string', b'k: "\\ufeffbom"\n'),
        ('long_key_1100', ('? ' + 'k' * 1100 + '\n: v\n').encode()),
    ]
    print('| case | Pion stringify | yaml-rust2 YamlEmitter | yaml.v3 Marshal |')
    print('|---|---|---|---|')
    for pid, data in rt:
        f = os.path.join(work, 'rt_' + pid + '.yaml')
        open(f, 'wb').write(data)
        print('| %s | %s | %s | %s |' % (pid, cell(run(pion, 'rt', f), 90), cell(run(rust, 'rt', f), 90), cell(run(go, 'rt', f), 90)))

main()
