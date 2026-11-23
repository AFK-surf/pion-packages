"""DoS / complexity / crash probes for from_tex (Double-Array Trie build) and the query paths.

Every run is its own process under /usr/bin/time -l (wall seconds + peak RSS, TIMEOUT per process).
Each probe runs at sizes N and 2N: growth ~2 = linear, ~4 = quadratic. Pion = native --release probe,
Rust = hyphenation 0.8.4 (fst) loading the same tokens. Limits are raised where a probe would
otherwise stop at the default caps, so the builder itself is measured.
Crash probes: Int32 overflow of the packed value pointer, and (--huge) of the max_input_bytes sum.
Usage: dos.py [--quick] [--huge] [--json out.json]
"""
import json, os, random, re, signal, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, PION, RUST, write_records

TIMEOUT = int(os.environ.get("DOS_TIMEOUT", "120"))
QUICK = "--quick" in sys.argv
BIG = ["1073741824", "16777216", "16777216", "4096", "4096", "67108864"]  # in_bytes pats excs pat_len exc_len nodes


def timed(cmd):
    t0 = time.time()
    p = subprocess.Popen(["/usr/bin/time", "-l"] + cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        so, se = p.communicate(timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return {"status": f"TIMEOUT>{TIMEOUT}s", "secs": TIMEOUT, "rss_mb": None, "out": ""}
    dt = time.time() - t0
    m = re.search(rb"(\d+)\s+maximum resident set size", se)
    rss = round(int(m.group(1)) / 1048576, 1) if m else None
    out = so.decode(errors="replace").strip()[:60]
    st = "ok" if p.returncode == 0 else f"CRASH rc={p.returncode} {se.decode(errors='replace')[-160:]!r}"
    if p.returncode == 0 and out.startswith("ERR"):
        st = "error-result"
    return {"status": st, "secs": round(dt, 3), "rss_mb": rss, "out": out}


def alphabet():
    """Characters whose UTF-8 bytes cover every byte value a TeX token may contain: ASCII controls
    except the 4 separators, printable ASCII except digits, every 0x80-0xBF continuation and every
    0xC2-0xF4 lead byte -> Pion alphabet size 216 (the char_map / DAT id space is saturated)."""
    asc = [chr(b) for b in range(1, 128) if chr(b) not in " \t\n\r.0123456789"]
    multi = [chr(0x80 + i) for i in range(64)]                       # C2 80..C2 BF: all continuations
    multi += [bytes([lead, 0x80]).decode() for lead in range(0xC3, 0xE0)]
    multi += [bytes([lead, 0xA0 if lead == 0xE0 else 0x80, 0x80]).decode() for lead in range(0xE0, 0xF0)]
    multi += [bytes([lead, 0x90 if lead == 0xF0 else 0x80, 0x80, 0x80]).decode() for lead in range(0xF0, 0xF5)]
    return asc, multi


def pat_random(n, rng, A):
    return [(rng.choice("12345") if rng.random() < .5 else "") + "".join(rng.choice(A) + rng.choice(["", "", "1", "2", "3"]) for _ in range(rng.randint(2, 7))) for _ in range(n)]


def gen_patterns(kind, n, rng):
    asc, multi = alphabet()
    A = asc + multi
    if kind == "random_saturated_alphabet":
        return pat_random(n, rng, A)
    if kind == "fanout_all_pairs":           # every 2-char pair over k chars: root + k nodes have k children
        k = int(n ** 0.5)
        return [a + "1" + b for a in A[:k] for b in A[:k]]
    if kind == "sparse_two_children":        # every node has exactly children {min id, max id}: worst gaps
        lo, hi = "\x01", "\x7f"
        depth = max(1, n.bit_length() - 1)
        out = ["".join(lo if (i >> d) & 1 else hi for d in range(depth)) + "1" for i in range(n)]
        return out + ["".join(asc[1:-1]) + "1"]  # put every other ASCII byte into the alphabet
    if kind == "sparse_byte_extremes":       # children {0x01, 0xF4 lead}: ids 1 and alpha_size
        lo, hi = "\x01", "\U00100000"
        depth = max(1, n.bit_length() - 1)
        out = ["".join(lo if (i >> d) & 1 else hi for d in range(depth)) + "1" for i in range(n)]
        return out + ["".join(A[1:])[:4000]]
    if kind == "duplicates_multi_digit":     # the same key n times, 31 non-zero values each
        return ["1" + "1".join("abcdefghijklmnopqrstuvwxyzabcde") + "1" for _ in range(n)]
    if kind == "nested_prefixes":            # a, aa, aaa ... up to 64, then rotate the letter
        return [chr(97 + (i // 64) % 26) * (1 + i % 64) + "1" for i in range(n)]
    if kind == "long_disjoint_64":           # 64-byte unrelated patterns: ~64 trie nodes each
        return ["".join(rng.choice(A[:120]) for _ in range(40)) + "1" for _ in range(n)]
    raise KeyError(kind)


def main():
    sys.stdout.reconfigure(line_buffering=True)
    rng = random.Random(1)
    N = 20000 if QUICK else 60000
    report = {}
    kinds = ["random_saturated_alphabet", "fanout_all_pairs", "sparse_two_children", "sparse_byte_extremes",
             "duplicates_multi_digit", "nested_prefixes", "long_disjoint_64"]
    print(f"  {'probe':34s} {'impl':5s} {'N':>8s} {'secs':>8s} {'rss MB':>8s} {'2N secs':>8s} {'growth':>6s}  status")
    for kind in kinds:
        for impl, binary in (("pion", PION), ("rust", RUST)):
            row = {}
            for k in (1, 2):
                pats = gen_patterns(kind, N * k, random.Random(k))
                pf = os.path.join(TMP, f"dos_{kind}_{k}.pat.txt")
                open(pf, "w", encoding="utf-8").write("\n".join(pats) + "\n")
                cmd = [binary, "load", pf, "-", "1", "1", "1"] + (BIG if impl == "pion" else [])
                row[k] = timed(cmd)
                row[k]["bytes"] = os.path.getsize(pf)
            g = round(row[2]["secs"] / max(row[1]["secs"], 1e-3), 2)
            report[f"{kind}/{impl}"] = {"N": row[1], "2N": row[2], "growth": g}
            print(f"  {kind:34s} {impl:5s} {N:8d} {row[1]['secs']:8.3f} {row[1]['rss_mb']!s:>8s} {row[2]['secs']:8.3f} {g:6.2f}  {row[1]['status']}/{row[2]['status']} {row[2]['out'][:40]}")
    # Query-side probes: en_us over huge single words and huge texts.
    qs = 2_000_000 if QUICK else 8_000_000
    words = [w.strip().lower() for w in open("/usr/share/dict/words") if w.strip()]
    for name, gen in (
        ("one_word_all_a", lambda m: ["a" * m]),
        ("one_word_random_letters", lambda m: ["".join(random.Random(3).choices("etaoinshrdlcumwfgypbvkjxqz", k=m))]),
        ("one_word_concat_dict", lambda m: ["".join(words[: m // 10])[:m]]),
        ("one_word_multibyte_e_acute", lambda m: ["é" * (m // 2)]),
    ):
        for k in (1, 2):
            write_records(os.path.join(TMP, f"dosq_{name}_{k}.in"), gen(qs * k))
        for impl, binary in (("pion", PION), ("rust", RUST)):
            row = {}
            for k in (1, 2):
                inp = os.path.join(TMP, f"dosq_{name}_{k}.in")
                row[k] = timed([binary, "bulk", "@en_us", "-", "2", "3", inp, "1"])
            g = round(row[2]["secs"] / max(row[1]["secs"], 1e-3), 2)
            report[f"query/{name}/{impl}"] = {"N": row[1], "2N": row[2], "growth": g}
            print(f"  {'q:' + name:34s} {impl:5s} {qs:8d} {row[1]['secs']:8.3f} {row[1]['rss_mb']!s:>8s} {row[2]['secs']:8.3f} {g:6.2f}  {row[1]['status']}/{row[2]['status']}")
    # Crash probes: Int32 packing of the DAT value pointer `-((off << 8) | cnt)` (Int is 32-bit in
    # Pion: 1 << 40 == 256). 524,289 copies of a 16-value pattern push val_pairs past 2^23 entries;
    # needs only raised Limits (16.8 MB input, 524,289 patterns), load succeeds, the query panics.
    pat = "1" + "1".join("abcdefghijklmno") + "1"
    pf = os.path.join(TMP, "dos_meta_overflow.pat.txt")
    open(pf, "w").write((pat + "\n") * 524289)
    inp = os.path.join(TMP, "dos_meta_overflow.in")
    write_records(inp, ["abcdefghijklmno"])
    for impl, cmd in (("pion", [PION, "opp", pf, "-", "1", "1", inp, inp + ".out"] + BIG),
                      ("rust", [RUST, "opp", pf, "-", "1", "1", inp, inp + ".out"])):
        r = timed(cmd)
        report[f"crash/meta_offset_int32_overflow/{impl}"] = r
        print(f"  {'crash:meta_offset_int32_overflow':34s} {impl:5s} {524289:8d} {r['secs']:8.3f} {r['rss_mb']!s:>8s}  {r['status'][:120]}")
    if "--huge" in sys.argv:
        # max_input_bytes check `patterns.length() + exceptions.length() > max` wraps for 2 x 1.1 GB
        # of whitespace: DEFAULT limits (1 MiB) and the load returns Ok. Needs ~3.3 GB RSS.
        blk = b" " * (1 << 24)
        files = [os.path.join(TMP, "huge1.pat"), os.path.join(TMP, "huge2.hyp")]
        for f in files:
            with open(f, "wb") as o:
                for _ in range(66):
                    o.write(blk)
        r = timed([PION, "load", files[0], files[1], "2", "3", "1"])
        report["limits/max_input_bytes_int32_wrap/pion"] = r
        print(f"  {'limits:max_input_bytes_int32_wrap':34s} pion  {'2x1.1GB':>8s} {r['secs']:8.3f} {r['rss_mb']!s:>8s}  {r['status']} {r['out']}")
        for f in files:
            os.unlink(f)
    if "--json" in sys.argv:
        json.dump(report, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
