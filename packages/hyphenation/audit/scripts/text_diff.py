"""hyphenate_text round-trip and word-consistency probe (Pion en_us).

Texts are dictionary words joined by separators drawn from ASCII punctuation / whitespace / digits and
from common Unicode punctuation (curly quotes, dashes, NBSP, ellipsis, guillemets, soft hyphen...).
Checks, for every text and every sep in SEPS:
  roundtrip : removing the inserted seps gives the input back (sep not occurring in the input)
  per-word  : the breaks inserted inside each dictionary word equal en_us.opportunities(word)
              (the bare word, which Pion and Rust agree on 100%), reported per neighbouring separator
              class; breaks closer than left_min=2 / right_min=3 letters to the word edge are counted apart.
Usage: text_diff.py [--n N] [--show K] [--json out.json]
"""
import collections, json, os, random, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import PION, run_batch

N = int(sys.argv[sys.argv.index("--n") + 1]) if "--n" in sys.argv else 4000
SHOW = int(sys.argv[sys.argv.index("--show") + 1]) if "--show" in sys.argv else 2
ASCII_SEPS = [" ", "  ", "\t", "\n", "\r\n", ", ", ". ", "...", "!?", " (", ") ", "\"", "'", " - ", "-", "--", "/", " 42 ", "_", ";\t"]
UNI_SEPS = ["“", "”", "‘", "’", "—", "–", " ", "…", "«", "»", "­",
            "​", "　", "¿", "¡", "•", " ", "\U0001F600"]
SEPS = ["-", "­", "==", "<shy>"]


def main():
    sys.stdout.reconfigure(line_buffering=True)
    rng = random.Random(5)
    words = sorted({w.strip().lower() for w in open("/usr/share/dict/words") if len(w.strip()) >= 7 and w.strip().isalpha()})
    texts, layout = [], []
    for t in range(N):
        uni = t % 2 == 1
        parts, spans, pos, kinds = [], [], 0, []
        for i in range(rng.randint(1, 12)):
            s = rng.choice(UNI_SEPS if (uni and rng.random() < .6) else ASCII_SEPS)
            w = rng.choice(words)
            if rng.random() < .2:
                w = w.capitalize()
            if i == 0 and rng.random() < .5:
                parts.append(s); pos += len(s.encode())
            spans.append((pos, w, s))
            parts.append(w); pos += len(w.encode())
            s2 = rng.choice(UNI_SEPS if (uni and rng.random() < .6) else ASCII_SEPS)
            parts.append(s2); pos += len(s2.encode())
        texts.append("".join(parts))
        # neighbour classes for each word
        lay = []
        tb = texts[-1].encode()
        for (p, w, _) in spans:
            wb = w.encode()
            before = tb[:p].decode()[-1:] if p else ""
            after = tb[p + len(wb):].decode()[:1]
            lay.append((p, w, before, after))
        layout.append(lay)
    bare = sorted({w for lay in layout for (_, w, _, _) in lay})
    opp = dict(zip(bare, run_batch(PION, "opp", ("@en_us", "-", 2, 3), bare, "txt_bare")))
    report = {}
    for sep in SEPS:
        out = run_batch(PION, "text", ("@en_us", "-", 2, 3), texts, f"txt_{len(sep)}", extra=(sep,))
        rt_bad, per = 0, collections.Counter()
        ex = collections.defaultdict(list)
        for text, o, lay in zip(texts, out, layout):
            if sep not in text and o.replace(sep, "") != text:
                rt_bad += 1
                ex["roundtrip"].append((text, o))
            # recover inserted break offsets (original byte offsets)
            ob, sb = o.encode(), sep.encode()
            brk, i, orig = set(), 0, 0
            tb = text.encode()
            while i < len(ob):
                if ob.startswith(sb, i) and not tb.startswith(sb, orig):
                    brk.add(orig); i += len(sb); continue
                i += 1; orig += 1
            for (p, w, b, a) in lay:
                wb = w.encode()
                got = sorted(x - p for x in brk if p < x < p + len(wb))
                exp = [int(x) for x in opp[w].split(",")] if opp[w] else []
                cls = "ascii-neighbours" if all(c == "" or ord(c) < 128 for c in (b, a)) else "unicode-neighbour"
                per[(cls, "total")] += 1
                if got != exp:
                    per[(cls, "diff")] += 1
                    lw = len(w)
                    if any(x < 2 or x > lw - 3 for x in got):
                        per[(cls, "minima_violation")] += 1
                        if len(ex["minima:" + cls]) < SHOW:
                            ex["minima:" + cls].append((b + w + a, got, exp))
                    if len(ex[cls]) < SHOW:
                        ex[cls].append((b + w + a, got, exp))
        report[repr(sep)] = {"roundtrip_fail": rt_bad, "per_word": {f"{k[0]}/{k[1]}": v for k, v in per.items()},
                             "examples": {k: v for k, v in ex.items()}}
        print(f"  sep={sep!r:9s} texts={len(texts)} roundtrip_fail={rt_bad}  " +
              "  ".join(f"{c}: {per[(c, 'diff')]}/{per[(c, 'total')]} diff ({per[(c, 'minima_violation')]} break <2/>len-3 letters)"
                        for c in ("ascii-neighbours", "unicode-neighbour")))
        for k, v in ex.items():
            for e in v[:SHOW]:
                print(f"      {k}: {e!r}"[:220])
    if "--json" in sys.argv:
        json.dump(report, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
