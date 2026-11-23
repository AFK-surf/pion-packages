"""Benchmark-fairness re-run of bench/ (Pion vs Rust hyphenation 0.8.4), via scripts/bench_compare.py
(--warmup 1 --rounds 5, interleaved, stdout SHA-256 must match).

Both sides load the SAME crate hyph-en-us.pat.txt / .hyp.txt (4,938 + 1,441); Pion through from_tex,
Rust through its embedded bincode (as bench/ does). Corpora:
  bench100k : bench/gen_data.py's corpus (100,000 draws from a 214-word vocabulary)
  dict      : /usr/share/dict/words, 235,976 distinct words, original case (minus the 61 that hit a
              capitalised exception, see REPORT C-2)
Variants:
  pion_into  : opportunities_into + reused buffer           (what bench/ measures)
  pion_alloc : allocating opportunities
  rust_hyph  : Standard::hyphenate (soft-hyphen scan + case refold + Word)  (what bench/ measures)
  rust_opp   : Standard::opportunities on words lowercased once outside the timed loop
Load: Pion from_tex vs Rust building the same text (Parse::pair + fst) vs Rust's bincode.
Usage: bench_fair.py [--iters N] [--json out.json]
"""
import json, os, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, PION, RUST, CRATE_PAT, CRATE_HYP, write_records

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
ITERS = sys.argv[sys.argv.index("--iters") + 1] if "--iters" in sys.argv else "10"


def main():
    sys.stdout.reconfigure(line_buffering=True)
    wf = os.path.join(TMP, "bench_words_100k.txt")
    subprocess.run([sys.executable, os.path.join(ROOT, "packages/hyphenation/bench/gen_data.py"), wf,
                    os.path.join(TMP, "gd.pat"), os.path.join(TMP, "gd.hyp"), "100000"], check=True)
    corpora = {"bench100k": [w for w in open(wf).read().split("\n") if w],
               "dict": [w.strip() for w in open("/usr/share/dict/words") if w.strip()]}
    # Words hitting one of hyph-en-us's 175 capitalised exceptions answer differently by design (Rust
    # never matches them, Pion does like TeX: REPORT C-2); drop them so the stdout SHA-256 can match.
    cap = {e.replace("-", "").lower() for e in open(CRATE_HYP, encoding="utf-8").read().split() if e != e.lower()}
    corpora["dict"] = [w for w in corpora["dict"] if w.lower() not in cap]
    res = {}
    for name, words in corpora.items():
        inp = os.path.join(TMP, f"bench_{name}.in")
        write_records(inp, words)
        nbytes = sum(len(w.encode()) for w in words) * int(ITERS)
        ops = len(words) * int(ITERS)
        md = os.path.join(TMP, f"bench_{name}.md")
        js = os.path.join(TMP, f"bench_{name}.json")
        cmd = [sys.executable, os.path.join(ROOT, "scripts/bench_compare.py"),
               "--title", f"fairness {name} ({len(words)} words x {ITERS})",
               "--impl", f"pion_into={PION} bulk {CRATE_PAT} {CRATE_HYP} 2 3 {inp} {ITERS}",
               "--impl", f"pion_alloc={PION} bulka {CRATE_PAT} {CRATE_HYP} 2 3 {inp} {ITERS}",
               "--impl", f"rust_hyph={RUST} bulk @en_us - 2 3 {inp} {ITERS}",
               "--impl", f"rust_opp={RUST} bulkopp @en_us - 2 3 {inp} {ITERS}",
               "--baseline", "rust_hyph", "--warmup", "1", "--rounds", "5",
               "--ops", str(ops), "--bytes", str(nbytes), "--md-out", md, "--json-out", js]
        r = subprocess.run(cmd, capture_output=True, text=True)
        print(r.stdout[-3000:])
        if r.returncode != 0:
            print(r.stderr[-2000:])
        res[name] = json.load(open(js)) if os.path.exists(js) else {"error": r.stderr[-500:]}
    # Dictionary load: same work on both sides (parse TeX text + build the automaton) vs bench/'s
    # comparison against the crate's pre-built bincode.
    loads = "20"
    js = os.path.join(TMP, "bench_load.json")
    cmd = [sys.executable, os.path.join(ROOT, "scripts/bench_compare.py"),
           "--title", f"fairness load ({loads} loads of hyph-en-us 4,938 + 1,441)",
           "--impl", f"pion_from_tex={PION} load {CRATE_PAT} {CRATE_HYP} 2 3 {loads}",
           "--impl", f"rust_from_text={RUST} load {CRATE_PAT} {CRATE_HYP} 2 3 {loads}",
           "--impl", f"rust_bincode={RUST} load @en_us - 2 3 {loads}",
           "--baseline", "rust_from_text", "--warmup", "1", "--rounds", "5", "--ops", loads,
           "--md-out", os.path.join(TMP, "bench_load.md"), "--json-out", js]
    r = subprocess.run(cmd, capture_output=True, text=True)
    print(r.stdout[-3000:])
    if r.returncode != 0:
        print(r.stderr[-2000:])
    res["load"] = json.load(open(js)) if os.path.exists(js) else {"error": r.stderr[-500:]}
    if "--json" in sys.argv:
        json.dump(res, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
