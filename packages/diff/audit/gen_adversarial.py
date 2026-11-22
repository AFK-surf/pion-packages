#!/usr/bin/env python3
"""Deterministic adversarial benchmark corpora for the diff red-team audit.

usage: gen_adversarial.py OUT_DIR
Every pair is chosen so that Pion and imara-diff *should* print the same unified diff
(context 3, all files end with a newline, first hunk at line 0 or > 6) so that
`scripts/bench_compare.py` can enforce its SHA-256 check; where they still differ that
is itself reported as a correctness finding.
"""
import os, random, sys

def code_line(r, i):
    k = r.randrange(9)
    return [
        f"    let v{i} = input[{i} % n] as usize + {r.randrange(1000)};",
        f"    total = total.wrapping_add(v{i % 97});",
        "    if total > limit {",
        f"        return Err(Error::Limit({i}));",
        "    }",
        "",
        f"    cursor = (cursor + {i % 13}) % n;",
        f"fn helper_{i}(x: u64) -> u64 {{ x.rotate_left({i % 63}) }}",
        "}",
    ][k]

def write(out, name, before, after):
    for suf, txt in (("before", before), ("after", after)):
        with open(os.path.join(out, f"{name}.{suf}"), "w", newline="") as f:
            f.write(txt)

def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    r = random.Random(20261123)

    # A. full rewrite: 20k lines, no common prefix/suffix, ~no shared lines
    b = [f"alpha_{i}_{r.randrange(10**9)}();" for i in range(20000)]
    a = [f"beta_{i}_{r.randrange(10**9)}();" for i in range(20000)]
    write(out, "rewrite", "\n".join(b) + "\n", "\n".join(a) + "\n")

    # B. highly repetitive (every line occurs >63 times -> Histogram falls back to Myers)
    alpha = ["}", "", "    }", "        break;", "    return x;"]
    b = [r.choice(alpha) for _ in range(30000)]
    a = list(b)
    for _ in range(600):
        p = r.randrange(1, len(a) - 1)
        if r.random() < 0.5:
            a.insert(p, r.choice(alpha))
        else:
            del a[p]
    b[0] = "// header before"; a[0] = "// header after"
    write(out, "repetitive", "\n".join(b) + "\n", "\n".join(a) + "\n")

    # C. minified JSON: one 8 MB line, one byte changed in the middle
    items = ",".join(f'{{"id":{i},"name":"n{i}","v":{r.randrange(10**6)}}}' for i in range(220000))
    b = "[" + items + "]\n"
    mid = len(b) // 2
    a = b[:mid] + ("7" if b[mid] != "7" else "8") + b[mid + 1:]
    write(out, "minified", b, a)

    # D. edge-triggered double computation: 200k-line file whose header line changed
    #    (so nothing is stripped as prefix) plus one `}` added inside a 40-line run of `}`.
    #    The slider walks the hunk to the 21-line window edge, `hit_suf` fires and Pion
    #    re-interns + re-diffs the *whole* file. Output stays identical to imara-diff.
    body = [code_line(r, i) for i in range(200000)]
    mid = 100000
    b = body[:mid] + ["}"] * 40 + body[mid:]
    a = body[:mid] + ["}"] * 41 + body[mid:]
    b[0] = "// v1"; a[0] = "// v2"
    write(out, "edge_fallback", "\n".join(b) + "\n", "\n".join(a) + "\n")
    # D'. control: same file, same header edit, one ordinary line edited instead
    a2 = list(b); a2[mid + 60] = a2[mid + 60] + " // touched"; a2[0] = "// v2"
    write(out, "edge_control", "\n".join(b) + "\n", "\n".join(a2) + "\n")
    # D''. correctness: the same shape with a run of *blank* lines -> Pion's hunk lands
    #     elsewhere and its trailing context is cut short (not benchmarkable: SHA differs)
    b = body[:mid] + [""] * 40 + body[mid:]
    a = body[:mid] + [""] * 41 + body[mid:]
    b[0] = "// v1"; a[0] = "// v2"
    write(out, "edge_blank", "\n".join(b) + "\n", "\n".join(a) + "\n")

    # E. 1M lines, single-line change in the middle (prefix/suffix fast path)
    big = [f"line {i} {r.randrange(10**6)}" for i in range(1000000)]
    a = list(big); a[500000] = "CHANGED"
    write(out, "million", "\n".join(big) + "\n", "\n".join(a) + "\n")

    # F. 200k lines, an edit every 50 lines (no long common prefix/suffix to strip)
    body = [code_line(r, i) for i in range(200000)]
    a = list(body)
    for i in range(7, len(a), 50):
        a[i] = a[i] + " // edited"
    write(out, "scattered", "\n".join(body) + "\n", "\n".join(a) + "\n")

    # G. high-D Myers: 30k lines over a 300-line vocabulary, 30% rewritten
    vocab = [f"tok_{i};" for i in range(300)]
    b = [r.choice(vocab) for _ in range(30000)]
    a = [x if r.random() > 0.3 else r.choice(vocab) for x in b]
    b[0] = "// G before"; a[0] = "// G after"
    write(out, "high_d", "\n".join(b) + "\n", "\n".join(a) + "\n")

    # H. interner reuse: one 50k-line before vs 8 different afters
    base = [code_line(r, i) for i in range(50000)]
    with open(os.path.join(out, "multi.before"), "w") as f:
        f.write("\n".join(base) + "\n")
    for j in range(8):
        a = list(base)
        for _ in range(20):
            p = r.randrange(10, len(a) - 10)
            a[p] = f"// variant {j} edit {p}"
        with open(os.path.join(out, f"multi.after{j}"), "w") as f:
            f.write("\n".join(a) + "\n")

def probes(out):
    """Robustness probes (not SHA-benchmarked: some differ only by the no-newline marker)."""
    r = random.Random(1)
    s = "".join(r.choice("abcdefghij") for _ in range(10_000_000))
    write(out, "probe_longline_10mb_no_eol", s, s[:5_000_000] + "Z" + s[5_000_001:])
    write(out, "probe_identical_200k_one_changed", "x\n" * 200000, "x\n" * 100000 + "y\n" + "x\n" * 99999)
    write(out, "probe_identical_200k_truncated", "x\n" * 200000, "x\n" * 150000)
    write(out, "probe_alternating_100k", "a\nb\n" * 50000 + "END1\n", "START\n" + "b\na\n" * 50000)
    write(out, "probe_empty_vs_empty", "", "")
    write(out, "probe_lf_vs_crlf", "\n" * 1000, "\r\n" * 1000)
    write(out, "probe_utf8_multibyte", "日本語🙂\n" * 5000, "日本語🙂\n" * 2500 + "日本人🙂\n" + "日本語🙂\n" * 2499)

if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[2] == "--probes":
        probes(sys.argv[1])
        sys.exit(0)
    main()
