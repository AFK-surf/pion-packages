#!/usr/bin/env python3
"""Path-isolating streams for the performance hot-spot notes (REPORT.md §性能热点).

Each stream stresses exactly one decoder path so Pion-vs-C time ratios attribute the Web/WOFF2 gap:
  hp_literals.br      1 MiB of literals, 1 tree, flat 8-bit codes        -> literal symbol decode loop
  hp_literals_cm.br   1 MiB of literals, UTF8 mode, 64 trees, 2 types     -> + context lookup / block switch
  hp_copy_long.br     8 MiB of 1 KiB copies at distance >= 8              -> LZ77 bulk copy
  hp_copy_short.br    8 MiB of copies at distance 2..7                    -> overlapping (byte-wise) copy
  hp_copy_rle.br      8 MiB of distance-1 copies                          -> RLE fill
  hp_dict.br          all 13,504 dictionary words x 4 transforms          -> dictionary transform path
  hp_cmds.br          ~250k short commands (insert 1 + copy 4)            -> command / distance decode
"""
import os
import random
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import brenc as E  # noqa: E402

OUT = sys.argv[1]
E.load_refs(OUT)
rng = random.Random(1)


def lit_stream(n, **kw):
    s = E.Stream(22, rng)
    data = bytes(rng.randrange(256) for _ in range(n))
    for i in range(0, n, 1 << 20):
        s.compressed([E.Cmd(data[i:i + (1 << 20)], 4, None, copy_ignored=True)], **kw)
    return s.finish()


def copy_stream(total, dists, cl):
    s = E.Stream(22, rng)
    s.uncompressed(bytes(rng.randrange(256) for _ in range(4096)))
    done = 0
    while done < total:
        cmds = []
        mb = 0
        while mb < (1 << 22) - cl and done + mb < total:
            cmds.append(E.Cmd(b'', cl, rng.choice(dists)))
            mb += cl
        cmds.append(E.Cmd(b'.', 4, None, copy_ignored=True))
        done += s.compressed(cmds)
    return s.finish()


def dict_stream():
    s = E.Stream(24, rng)
    for t in (0, 9, 10, 44):
        cmds = [E.Cmd(b'', L, ('dict', L, i, t)) for L in range(4, 25) for i in range(E.word_count(L))]
        for i in range(0, len(cmds), 4000):
            s.compressed(cmds[i:i + 4000] + [E.Cmd(b'|', 4, None, copy_ignored=True)])
    return s.finish()


def cmd_stream(n):
    s = E.Stream(22, rng)
    s.uncompressed(bytes(rng.randrange(256) for _ in range(4096)))
    for _ in range(n // 50000):
        cmds = [E.Cmd(bytes([rng.randrange(4)]), 4, rng.randint(8, 4000)) for _ in range(50000)]
        cmds.append(E.Cmd(b'.', 4, None, copy_ignored=True))
        s.compressed(cmds, npostfix=0, ndirect=0)
    return s.finish()


streams = {
    'hp_literals.br': lambda: lit_stream(1 << 20, modes=[0], ntrees_l=1),
    'hp_literals_cm.br': lambda: lit_stream(1 << 20, modes=[2, 2], ntypes=(2, 1, 1), ntrees_l=64),
    'hp_copy_long.br': lambda: copy_stream(8 << 20, [8, 100, 1000, 4000], 1024),
    'hp_copy_short.br': lambda: copy_stream(8 << 20, [2, 3, 5, 7], 1024),
    'hp_copy_rle.br': lambda: copy_stream(8 << 20, [1], 4096),
    'hp_dict.br': dict_stream,
    'hp_cmds.br': lambda: cmd_stream(250000),
}
for name, fn in streams.items():
    data = fn()
    open(os.path.join(OUT, name), 'wb').write(data)
    print(name, len(data))
