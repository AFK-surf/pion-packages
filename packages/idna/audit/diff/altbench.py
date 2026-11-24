"""Second benchmark corpus (independent of bench/gen_corpus.py): 200 domains that stress what the README corpora
do not: near-253-byte domains with 63-byte labels, NFD-dense input (decomposed Latin / Vietnamese, Hangul jamo)
that needs full normalisation, A-label heavy input that must be decoded and re-encoded, and RTL domains that
run the Bidi rules. No input touches the NFC gap of P1-1, so Pion and Rust must produce identical output.

  altbench.py <out.txt>   prints `<domains> <bytes>`
"""
import random
import sys


def main():
    rnd = random.Random(1946)
    out = []
    latin = "abcdefghijklmnopqrstuvwxyz"
    for i in range(50):  # long domains: 3 x 63-byte labels + tld, mixed IDN
        labs = []
        for _ in range(3):
            s = "".join(rnd.choice(latin) for _ in range(55)) + "üéå"
            labs.append(s[:58])
        out.append(".".join(labs) + ".com")
    for i in range(50):  # NFD-dense
        parts = []
        for _ in range(rnd.randint(6, 14)):
            parts.append(rnd.choice(latin) + rnd.choice(["́", "̀", "̂", "̈", "̣̂",
                                                         "̆̃", "̛̉"]))
        jamo = "".join(chr(0x1100 + rnd.randrange(19)) + chr(0x1161 + rnd.randrange(21)) +
                       (chr(0x11A8 + rnd.randrange(27)) if rnd.random() < 0.5 else "") for _ in range(4))
        out.append("".join(parts) + "." + jamo + ".vn")
    pool = ["münchen", "中文", "日本語", "한국어", "привет",
            "ไทย", "café", "bücher", "ελλάδα", "हिन्दी"]
    for i in range(50):  # A-label heavy: Punycode of the pool, upper-cased half of the time
        labs = []
        for _ in range(rnd.randint(2, 5)):
            s = "xn--" + rnd.choice(pool).encode("punycode").decode()
            labs.append(s.upper() if rnd.random() < 0.5 else s)
        out.append(".".join(labs))
    rtl = ["שלום", "ישראל", "مثال", "إختبار",
           "موقع", "شبكة", "אבג123", "العربية"]
    for i in range(50):  # Bidi domains
        out.append(".".join(rnd.choice(rtl) for _ in range(rnd.randint(2, 4))) + rnd.choice([".com", ".il", ""]))
    data = "\n".join(out) + "\n"
    with open(sys.argv[1], "w", encoding="utf-8") as f:
        f.write(data)
    print(len(out), len(data.encode()))


if __name__ == "__main__":
    main()
