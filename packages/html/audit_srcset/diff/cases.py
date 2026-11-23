#!/usr/bin/env python3
"""srcset red-team cases + seeded random fuzz. Usage: cases.py OUT_FILE [FUZZ_N] [SEED]"""
import random, sys

CASES = [
    "", " ", ",", ",,,", " , , ", "\t\n\x0c\r", "a.jpg", "a.jpg,", "a.jpg,,,", ",,,a.jpg,,,",
    "a.jpg, b.jpg", "a.jpg,b.jpg", "a.jpg ,b.jpg", "a.jpg , b.jpg 2x",
    "https://cdn/w_400,f_auto/a.jpg 400w", "https://cdn/w_400,f_auto/a.jpg 400w, https://cdn/w_800,f_auto/b.jpg 800w",
    "https://cdn/a,b,c.jpg,,, https://cdn/d,e.jpg 2x , , ",
    "a.jpg (100w, 200w) 2x", "a.jpg (abc, b.jpg 2x", "a.jpg ((a)) 2x", "a.jpg (a) 2x", "a.jpg 2x (a)",
    "a.jpg 2x(a)", "a.jpg (", "a.jpg )", "a.jpg () 1x", "a.jpg 100w (x), b.jpg 2x",
    "a.jpg 0w", "a.jpg -100w", "a.jpg 1.5w", "a.jpg +100w", "a.jpg 0100w", "a.jpg 2147483647w",
    "a.jpg 2147483648w", "a.jpg 99999999999999999999w", "a.jpg 100W", "a.jpg w", "a.jpg 1e2w",
    "a.jpg 0x", "a.jpg -0x", "a.jpg -2x", "a.jpg NaNx", "a.jpg Infinityx", "a.jpg 1e309x", "a.jpg 1.5e308x",
    "a.jpg 1e308x", "a.jpg 1e-400x", "a.jpg 1e-300x", "a.jpg .5x", "a.jpg 5.x", "a.jpg 1.x", "a.jpg +1x",
    "a.jpg 1e+1x", "a.jpg 1E1x", "a.jpg 1ex", "a.jpg 2X", "a.jpg x", "a.jpg 2xx", "a.jpg 0.0x", "a.jpg 00x",
    "a.jpg 100w 2x", "a.jpg 2x 100w", "a.jpg 100w 200w", "a.jpg 1x 2x", "a.jpg 100w 50h", "a.jpg 50h 100w",
    "a.jpg 50h", "a.jpg 2x 50h", "a.jpg 50h 2x", "a.jpg 100w 0h", "a.jpg 100w 50h 60h", "a.jpg 2x foo",
    "a.jpg 1x,b.jpg 2x", "a.jpg 1x ,b.jpg 2x", "a.jpg 1x , , b.jpg 2x", "a.jpg 1x 2x, b.jpg 3x",
    "a.jpg\t2x,\nb.jpg\x0c3x", "a.jpg\x0b2x", "a.jpg 2x\x00", "data:image/png;base64,AAAA 2x",
    "a.jpg 400w,", "a.jpg 400w,,b.jpg 800w",
]

ALPHA = ["a", "b", ".jpg", ",", " ", "\t", "(", ")", "1", "0", "2", "w", "x", "h", "-", ".", "e", "5", "\n"]

out = list(CASES)
fuzz_n = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)
for _ in range(fuzz_n):
    out.append("".join(rng.choice(ALPHA) for _ in range(rng.randint(1, 24))))
with open(sys.argv[1], "w") as f:
    for c in out:
        f.write(c.encode("latin1").hex() + "\n")
print(len(CASES), "handpicked +", fuzz_n, "fuzz cases")
