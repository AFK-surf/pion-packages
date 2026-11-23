#!/usr/bin/env python3
"""Adversarial benchmark corpora for the json5 audit (deterministic).

usage: gen_bench.py <out_dir>

  unikeys.json5   60k objects with unquoted non-ASCII identifier keys (Greek/Cyrillic/CJK/Hangul) - all
                  three parsers accept every key
  numbers.json    300k 17-significant-digit doubles across the full exponent range
  wide_a.json     one object with 50k keys
  wide_b.json     wide_a with one value changed (k25000)
  spine_a.json    100-level nested object chain, each level carries a 5,000-int `pad` array
  spine_b.json    spine_a with the innermost leaf changed
  grow.txt        `patch`-mode case: {"a":null} + 18,000 constant-size ops (add /b {}, move /a -> /b/a,
                  move /b -> /a) x 6,000 that nest the document 6,000 levels deep
  big.json        ~2.5 MB document (`meta.rev` + 40k records) for repeated single-op atomic apply
"""
import json
import os
import random
import sys

R = random.Random(20261123)
ALPH = ["αβγδεζηθικλμνξοπρστυφχψω", "абвгдежзийклмнопрстуфхцчшщ", "日本語中文漢字東京大阪北京上海", "한국어서울부산대구인천"]


def ident():
    a = R.choice(ALPH)
    return "".join(R.choice(a) for _ in range(R.randrange(3, 10)))


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "unikeys.json5"), "w", encoding="utf-8") as f:
        f.write("[\n")
        for i in range(60000):
            keys = []
            while len(keys) < 4:
                k = ident()
                if k not in keys:
                    keys.append(k)
            f.write("  {" + ", ".join(f"{k}: {R.randrange(1000)}" for k in keys) + "},\n")
        f.write("]\n")
    with open(os.path.join(out, "numbers.json"), "w") as f:
        nums = [f"{R.uniform(1, 10):.16e}".replace("e+00", "e").split("e")[0] + f"e{R.randrange(-300, 300)}" for _ in range(300000)]
        f.write("[" + ",".join(nums) + "]\n")
    wide = {f"k{i}": i for i in range(50000)}
    with open(os.path.join(out, "wide_a.json"), "w") as f:
        json.dump(wide, f, separators=(",", ":"))
    wide["k25000"] = -1
    with open(os.path.join(out, "wide_b.json"), "w") as f:
        json.dump(wide, f, separators=(",", ":"))

    def spine(leaf):
        v = {"leaf": leaf}
        for d in range(100):
            v = {"pad": list(range(d, d + 5000)), "c": v}
        return v

    with open(os.path.join(out, "spine_a.json"), "w") as f:
        json.dump(spine(1), f, separators=(",", ":"))
    with open(os.path.join(out, "spine_b.json"), "w") as f:
        json.dump(spine(2), f, separators=(",", ":"))
    big = {"meta": {"rev": 0}, "records": [{"id": i, "name": f"rec-{i}", "tags": ["a", "b"], "score": i * 0.5} for i in range(40000)]}
    with open(os.path.join(out, "big.json"), "w") as f:
        json.dump(big, f, separators=(",", ":"))
    ops = []
    for _ in range(6000):
        ops += [{"op": "add", "path": "/b", "value": {}}, {"op": "move", "from": "/a", "path": "/b/a"},
                {"op": "move", "from": "/b", "path": "/a"}]
    with open(os.path.join(out, "grow.txt"), "w") as f:
        f.write(b'{"a":null}'.hex() + " " + json.dumps(ops, separators=(",", ":")).encode().hex() + "\n")
    for n in sorted(os.listdir(out)):
        print(f"{n:16s} {os.path.getsize(os.path.join(out, n)):>10d} B")


if __name__ == "__main__":
    main()
