#!/usr/bin/env python3
"""Stage breakdown for the WOFF decode hot path: whole decode vs. decompression stage only,
Pion (`audit` CLI, --release) vs Rust wuff / brotli-decompressor / flate2. Median of N interleaved rounds.
Usage: prof.py <bin_dir> <iters> <rounds> <file>..."""
import statistics
import subprocess
import sys
import time

bins, iters, rounds = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
print(f'{"file":28s} {"stage":8s} {"pion ms/op":>11s} {"rust ms/op":>11s} {"ratio":>6s}')
for f in sys.argv[4:]:
    stages = ['bench', 'brotli' if f.endswith('.woff2') else 'zlib']
    res = {}
    for st in stages:
        for impl in ('pion', 'rust'):
            if impl == 'rust' and st == 'zlib':
                continue
            res[(st, impl)] = []
    for _ in range(rounds):
        for (st, impl) in res:
            t0 = time.perf_counter()
            subprocess.run([f'{bins}/{impl}_audit', st, f, str(iters)], check=True, stdout=subprocess.DEVNULL)
            res[(st, impl)].append((time.perf_counter() - t0) * 1000 / iters)
    med = {k: statistics.median(v) for k, v in res.items()}
    for st in stages:
        p = med[(st, 'pion')]
        r = med.get((st, 'rust'))
        print(f'{f.split("/")[-1]:28s} {st:8s} {p:11.3f} {r if r else float("nan"):11.3f} '
              f'{(r / p) if r else float("nan"):6.2f}x')
    d = med[('bench', 'pion')]
    s = med[(stages[1], 'pion')]
    print(f'{"":28s} pion: decompression {s / d * 100:5.1f}% of decode, reconstruction+assembly {d - s:7.3f} ms '
          f'(rust: {med[("bench", "rust")] - med.get((stages[1], "rust"), 0):7.3f} ms)' if stages[1] == 'brotli' else
          f'{"":28s} pion: zlib {s / d * 100:5.1f}% of decode, assembly {d - s:7.3f} ms')
