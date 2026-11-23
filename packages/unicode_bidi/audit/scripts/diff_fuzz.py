"""Differential fuzz: Pion `unicode_bidi` vs Rust `unicode-bidi =0.3.18` on the full `info` dump
(paragraphs, per-byte classes + levels, has_rtl, base direction, and for each whole/split line the
L1 levels, L2 visual runs, per-char levels, reorder_line bytes, paragraph direction).
Corpus = targeted UAX #9 trap families (BD16 canonical brackets, 63-entry bracket stack, depth 125,
overflow counters, unmatched isolates, FSI first-strong skipping, W1-W7 BN/NSM, L1 resets, CR LF)
+ random/mutated sequences over a multi-byte-heavy alphabet.
Usage: diff_fuzz.py [--fuzz N] [--seed S] [--show N] [--json out.json]
"""
import json, os, random, sys, collections
sys.path.insert(0, os.path.dirname(__file__))
from common import REP, run

ALPHA = list(REP.values()) + [
    "A", "z", "ב", "ب", "ႀ0"[0:0] or "\U00010800", "\U0001EE00", "\U0001E900",  # 4-byte R/AL
    "0", "9", "۱", "١", "؀", "-", ".", ":", "/", " ", "⁄", "٫", "#", "%",
    "€", "°", "́", "ٰ", "\U0001D167", "​", "﻿", "‍", "\u0000", "\x7f",
    "\r", "\n", "\r\n", "\u0085", "\x1c", "\x1f", "\x0b", "　", " ", "(", ")", "[", "]", "{",
    "}", "〈", "〉", "〈", "〉", "（", "）", "༺", "༻", "⁅",
    "⁆", "「", "」", "<", ">", "«", "»", "\U0001F600", "−", "￿",
    "﷐", "࡫", "\U00010D28", "‎", "‏", "؜", " ",
]
CTRL = [REP[k] for k in ("LRE", "RLE", "LRO", "RLO", "PDF", "LRI", "RLI", "FSI", "PDI")]
OPEN = ["(", "[", "{", "〈", "〈", "（", "༺"]
CLOSE = {"(": ")", "[": "]", "{": "}", "〈": "〉", "〈": "〉", "（": "）", "༺": "༻"}
STRONG = ["a", "א", "ا", "1", "٠"]


def targeted():
    a, r, al = "a", "א", "ا"
    T = []
    # BD16 canonical equivalence + cross-type mismatches, across isolate-split sequences.
    for o in OPEN:
        for c in set(CLOSE.values()):
            for inner in (a, r, "1", " ", al + "1"):
                for pre in ("", r, a, al):
                    T.append(pre + o + inner + c + pre[::-1])
    # 63-entry bracket stack: N opens then closes, also with isolates splitting the IRS.
    for n in (61, 62, 63, 64, 65, 70, 130):
        for mid in (a, r, "1", "⁦" + a + "⁩", "⁧" + r + "⁩", "⁨" + r + "⁩"):
            T.append(r + "(" * n + mid + ")" * n + a)
            T.append(a + "(" * n + mid + ")" * n + r)
            T.append(r + "(" * n + "⁦" + a + "⁩" + ")" + r + ")" * (n - 1) + "1")
            T.append(r + "a(" + "[" * n + mid + "]" * n + ")" + r)
    # Explicit depth 125 boundary and overflow counters.
    for n in (60, 61, 62, 63, 64, 120, 123, 124, 125, 126, 127, 130, 250):
        for o in CTRL[:4] + CTRL[5:8]:
            for tail in ("", REP["PDF"], REP["PDI"], REP["PDF"] * 3 + REP["PDI"], REP["PDI"] * 2 + REP["PDF"]):
                T.append(o * n + r + a + "1" + tail + r + " " + a)
        T.append((REP["RLE"] + REP["LRI"]) * (n // 2) + r + REP["PDI"] * n + a + REP["PDF"] * n + r)
        T.append(REP["RLI"] * n + REP["LRE"] * 3 + a + REP["PDI"] * (n + 2) + r)
        T.append(REP["LRO"] * n + REP["RLI"] + r + REP["PDI"] + REP["PDF"] * n + "1")
    # Unmatched / isolated PDI, PDF; FSI first-strong probing skipping nested isolates.
    for s in ("", a, r, al, "1", "٠"):
        for nest in ("⁦" + r + "⁩", "⁧" + a + "⁩", "⁨" + r + "⁩",
                     "⁦" + r, "‫" + r + "‬", "⁨⁨" + r):
            T.append("⁨" + nest + s + "⁩" + r + a)
            T.append("⁩‬" + "⁨" + s + nest + a)
            T.append(r + "⁨" + " " + nest + s + "\n" + "⁩" + a + s)
            T.append(nest + "⁩" * 3 + s + "‬" * 3)
    # W1-W7 with BN / NSM / isolates / paragraph boundaries.
    seps = ["+", "-", ",", ".", ":", "/", " ", "⁄", "$", "%", "€", "#"]
    for x in seps:
        for bn in ("", "­", "​", "‪‬", "﻿­"):
            for pre in (a, r, al, ""):
                T.append(pre + "1" + bn + x + bn + "2" + " " + r)
                T.append(pre + "٠" + bn + x + bn + "١" + a)
                T.append(pre + x + bn + "1" + bn + x + bn)
                T.append(pre + "⁩̀" + bn + x + "1")
                T.append(pre + "⁦̀" + x + "⁩̀" + "1")
                T.append(pre + bn + "̀" + x + "\U0001D167" + "1" + "\n" + "̀" + x)
    # L1: trailing whitespace/isolates/explicit/BN before S/B/CRLF/end of line.
    tails = [" ", "\t", "⁦", "⁧", "⁨", "⁩", "‪", "‫", "‭", "‮", "‬",
             "­", "　", " "]
    for t1 in tails:
        for t2 in tails:
            for end in ("", "\t", "\r\n", "\n", " ", "\u0085", "\x1f" + r):
                T.append(r + a + t1 + t2 + end + r + t1)
                T.append("‫" + a + t1 + "1" + t2 + end)
    # N0 "first strong before the opening bracket" across level runs split by an isolate.
    for s1 in (a, r, al, "1", ""):
        for s2 in (a, r, al, "\u0660", ""):
            for iso in ("\u2066x\u2069", "\u2067" + r + "\u2069", "\u2068y\u2069", "\u2066\u2069"):
                for inner in (r, a, "1", " "):
                    T.append(s1 + s2 + iso + "(" + inner + ")" + s1)
                    T.append(s1 + s2 + iso + "\u00AD" + "[" + iso + inner + "]")
    return T


def rand_text(rng):
    k = rng.random()
    n = rng.randint(0, 40 if k < 0.6 else 200)
    out = []
    for _ in range(n):
        x = rng.random()
        if x < 0.15:
            out.append(rng.choice(CTRL))
        elif x < 0.28:
            o = rng.choice(OPEN); out.append(o if rng.random() < 0.6 else CLOSE[o])
        elif x < 0.45:
            out.append(rng.choice(STRONG))
        else:
            out.append(rng.choice(ALPHA))
    if rng.random() < 0.1:  # burst of nested controls
        i = rng.randint(0, len(out))
        out[i:i] = [rng.choice(CTRL)] * rng.randint(60, 140)
    if rng.random() < 0.1:  # burst of brackets
        i = rng.randint(0, len(out))
        o = rng.choice(OPEN)
        out[i:i] = [o] * rng.randint(55, 70) + [rng.choice(STRONG)] + [CLOSE[o]] * rng.randint(0, 70)
    return "".join(out)


def mutate(rng, s):
    s = list(s)
    for _ in range(rng.randint(1, 4)):
        op = rng.random()
        i = rng.randint(0, len(s))
        if op < 0.4:
            s.insert(i, rng.choice(ALPHA + CTRL))
        elif op < 0.7 and s:
            del s[min(i, len(s) - 1)]
        elif s:
            s[min(i, len(s) - 1)] = rng.choice(ALPHA + CTRL)
    return "".join(s)


_BN = None


def run_cls_bn(ch):
    """True if `ch` is X9-removed BN (ICU keeps a different level for those, so they are skipped)."""
    global _BN
    if _BN is None:
        _BN = open(os.path.join(os.environ.get("AUDIT_TMP", "/private/tmp/redteam-bidi"), "rust.cls"), "rb").read()
    c = ord(ch)
    return _BN[c if c < 0xD800 else c - 0x800] == ord("D")


def first_diff(a, b):
    la, lb = a.split(b"\n"), b.split(b"\n")
    for i, (x, y) in enumerate(zip(la, lb)):
        if x != y:
            return i, x[:200], y[:200]
    return min(len(la), len(lb)), b"<len>", b"<len>"


def main():
    args = sys.argv
    fuzz = int(args[args.index("--fuzz") + 1]) if "--fuzz" in args else 30000
    seed = int(args[args.index("--seed") + 1]) if "--seed" in args else 1
    show = int(args[args.index("--show") + 1]) if "--show" in args else 6
    rng = random.Random(seed)
    base = targeted()
    rand = [rand_text(rng) for _ in range(fuzz)]
    muts = [mutate(rng, rng.choice(base)) for _ in range(fuzz // 3)]
    texts = base + rand + muts
    recs = [rng.choice("-01") + t if i >= len(base) else d + t for i, t in enumerate(texts) for d in (("-", "0", "1") if i < len(base) else ("",))]
    print(f"  corpus: targeted={len(base)}x3 dirs random={len(rand)} mutated={len(muts)} -> {len(recs)} records")
    P = run("pion", "info", recs)
    R = run("rust", "info", recs)
    bad = [i for i in range(len(recs)) if P[i] != R[i]]
    panics = [i for i in range(len(recs)) if R[i].startswith(b"PANIC")]
    kinds = collections.Counter()
    for i in bad:
        kinds[first_diff(P[i], R[i])[1].split(b" ")[0].strip()[:8]] += 1
    print(f"  records={len(recs)} identical={len(recs) - len(bad)} mismatches={len(bad)} rust_panics={len(panics)}")
    print(f"  first-diff field histogram: {dict(kinds)}")
    bad.sort(key=lambda i: len(recs[i]))
    for i in bad[:show]:
        ln, x, y = first_diff(P[i], R[i])
        print(f"    MISMATCH input={recs[i][:1]}{recs[i][1:].encode('unicode_escape').decode()[:220]}")
        print(f"      dump line {ln}: pion={x!r}\n                    rust={y!r}")
    # Adjudicate every mismatch with ICU4C ubidi (third implementation). BD16 overflow cases are
    # tagged separately: ICU's bracket stack is not capped at 63, so only the spec text decides them.
    import icu_oracle
    from common import CLASSES
    X9 = {"\u202A", "\u202B", "\u202C", "\u202D", "\u202E"}
    verdict = collections.Counter()
    UCD_DIFF = set(json.load(open(os.path.join(os.environ.get("AUDIT_TMP", "/private/tmp/redteam-bidi"), "ucd_diff.json"))))
    pc_p = run("pion", "pcl", [recs[i] for i in bad]) if bad else []
    pc_r = run("rust", "pcl", [recs[i] for i in bad]) if bad else []
    for k, i in enumerate(bad):
        t = recs[i][1:]
        opens = sum(t.count(o) for o in OPEN)
        if opens >= 63:
            verdict["bd16_overflow(spec-adjudicated)"] += 1
            continue
        if any(ord(ch) in UCD_DIFF for ch in t):
            verdict["ucd_table_confounded"] += 1
            continue
        _, icu = icu_oracle.levels(recs[i])
        keep = [j for j, ch in enumerate(t) if ch not in X9 and run_cls_bn(ch) is False]
        gp = [int(x) for x in pc_p[k].decode().split(";")[1].split(",")]
        gr = [int(x) for x in pc_r[k].decode().split(";")[1].split(",")]
        mp = all(gp[j] == icu[j] for j in keep)
        mr = all(gr[j] == icu[j] for j in keep)
        if not mp:
            print(f"    !! pion disagrees with ICU: {recs[i]!r} pion={gp} icu={icu}")
        verdict[{(True, False): "icu_agrees_pion", (False, True): "icu_agrees_rust",
                 (True, True): "icu_agrees_both", (False, False): "icu_agrees_neither"}[(mp, mr)]] += 1
    print(f"  ICU4C adjudication of mismatches: {dict(verdict)}")
    if "--json" in args:
        json.dump(dict(records=len(recs), mismatches=len(bad), rust_panics=len(panics),
                       examples=[(recs[i], P[i].decode("utf-8", "replace"), R[i].decode("utf-8", "replace"))
                                 for i in bad[:50]]),
                  open(args[args.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
