#!/usr/bin/env python3
"""Brute-force a collision of packages/http2 src/hpack.pion `str_hash` (31-bit FNV-1a variant, unsalted).

Prints two distinct printable strings with equal str_hash. Used by control_dynamic_table_hash_collision_safe:
the encoder must still compare full strings (it does), so a collision cannot merge distinct entries.
"""
import itertools, string

def str_hash(s: bytes) -> int:
    h = 216613626
    for c in s:
        h = ((h ^ c) * 16777619) & 0x7FFFFFFF
    return h

seen = {}
alpha = (string.ascii_letters + string.digits).encode()
for tup in itertools.product(alpha, repeat=4):
    s = b"v-" + bytes(tup)
    h = str_hash(s)
    if h in seen and seen[h] != s:
        print(seen[h].decode(), s.decode(), hex(h))
        break
    seen[h] = s
