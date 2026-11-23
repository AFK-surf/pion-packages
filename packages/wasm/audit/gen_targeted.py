#!/usr/bin/env python3
"""Write the hand-written red-team vectors (targeted.py) into a corpus dir."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from targeted import cases  # noqa: E402

d = sys.argv[1]
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "manifest.tsv"), "w") as m:
    for i, (n, e, b, _note) in enumerate(cases()):
        with open(os.path.join(d, f"{i}.wasm"), "wb") as f:
            f.write(b)
        m.write(f"{i}\t{n}\t{e}\n")
print(f"wrote {len(cases())} targeted vectors to {d}")
