#!/usr/bin/env python3
"""Three-way differential: Rust pulldown-cmark 0.13.1 vs Pion to_html_pulldown vs
Pion render_html_pulldown(parse()) (+ to_html vs render_html(parse()) internal check).

usage: difftest.py <rust_ref_bin> <pion_harness_bin> <pulldown_crate_dir> <out_dir> [--fuzz N]
"""
import json, os, random, re, subprocess, sys, collections

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from corpus import handcrafted, nul_cases  # noqa: E402

RUST, PION, CRATE, OUT = sys.argv[1:5]
FUZZ = int(sys.argv[sys.argv.index("--fuzz") + 1]) if "--fuzz" in sys.argv else 3000
os.makedirs(OUT, exist_ok=True)

# mask bits shared by both implementations
CM, GFM, GFM_SMART = 0, 1 | 2 | 4, 1 | 2 | 4 | 16
PION_ONLY_BITS = 8 | 32  # autolinks, cjk_friendly (no pulldown-cmark 0.13.1 equivalent)


def suite_inputs():
    out = []
    d = os.path.join(CRATE, "tests", "suite")
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".rs"):
            continue
        txt = open(os.path.join(d, fn), encoding="utf-8").read()
        for i, m in enumerate(re.finditer(r'let original = r##"(.*?)"##;', txt, re.S)):
            out.append((f"suite/{fn[:-3]}#{i + 1}", m.group(1)))
    return out


ATOMS = ["*", "**", "_", "__", "~", "~~", "`", "``", "[", "]", "(", ")", "![", "<", ">", "\\",
         "&amp;", "&#x", ";", "\"", "'", "--", "---", "...", "|", ":", "-", "+", "1.", "#", "\t",
         "  ", " ", "\n", "\n\n", "\r\n", "\r", "a", "foo", "b", "x", "中文", "（", "）", "é",
         "😀", "http://x.y", "www.a.b", "<a@b.c>", "<http://u>", "<div>", "</div>", "<!--", "-->",
         "[x]: /u", "[^1]", "    ", "> ", "- ", "* ", "```", "~~~", "$", "{#id}", "\u00a0", "!"]


def fuzz_inputs(n, seed=0x5EED):
    rnd = random.Random(seed)
    out = []
    for k in range(n):
        ln = rnd.randint(1, 40)
        s = "".join(rnd.choice(ATOMS) for _ in range(ln))
        if rnd.random() < 0.5:
            s += "\n"
        out.append((f"fuzz#{k}", s))
    return out


def write_batch(path, cases):
    with open(path, "wb") as f:
        for _, mask, src in cases:
            b = src.encode("utf-8")
            f.write(f"{mask}\t{len(b)}\n".encode() + b)


def read_frames(data, per):
    res, i = [], 0
    while i < len(data):
        nl = data.index(b"\n", i)
        ln = int(data[i:nl])
        res.append(data[nl + 1:nl + 1 + ln])
        i = nl + 1 + ln
    assert len(res) % per == 0
    return [res[j:j + per] for j in range(0, len(res), per)]


def run(cmd, timeout=600):
    p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError(f"{cmd} rc={p.returncode} {p.stderr[-2000:]!r}")
    return p.stdout


def main():
    base = [(n, s) for n, s in suite_inputs()] + list(handcrafted()) + nul_cases() + fuzz_inputs(FUZZ)
    cases = []
    for name, src in base:
        for mask in (CM, GFM, GFM_SMART):
            cases.append((name, mask, src))
    batch = os.path.join(OUT, "batch.bin")
    write_batch(batch, cases)
    rust = [f[0] for f in read_frames(run([RUST, "batch", batch]), 1)]
    # Pion may crash on a case; run in chunks so one crash does not hide the rest
    pion = []
    crashes = []
    CH = 400
    for c0 in range(0, len(cases), CH):
        chunk = cases[c0:c0 + CH]
        write_batch(batch + ".chunk", chunk)
        try:
            pion += read_frames(run([PION, "batch", batch + ".chunk"]), 4)
        except Exception as e:  # bisect to single cases
            for c in chunk:
                write_batch(batch + ".one", [c])
                try:
                    pion += read_frames(run([PION, "batch", batch + ".one"]), 4)
                except Exception as e1:
                    crashes.append({"name": c[0], "mask": c[1], "src": c[2], "err": str(e1)[:300]})
                    pion.append([b"<CRASH>"] * 4)
    stats = collections.Counter()
    rows = []
    for (name, mask, src), r, p in zip(cases, rust, pion):
        direct, evp, direct_cm, evp_cm = p
        k_rust_direct = direct != r
        k_rust_events = evp != r
        k_paths = direct != evp
        k_paths_cm = direct_cm != evp_cm
        stats["cases"] += 1
        for key, bad in (("direct!=rust", k_rust_direct), ("events!=rust", k_rust_events),
                         ("direct!=events(pulldown)", k_paths), ("to_html!=render_html(parse)", k_paths_cm)):
            if bad:
                stats[key] += 1
        if k_rust_direct or k_rust_events or k_paths or k_paths_cm:
            rows.append({"name": name, "mask": mask, "src": src,
                         "rust": r.decode("utf-8", "replace"),
                         "pion_direct": direct.decode("utf-8", "replace"),
                         "pion_events": evp.decode("utf-8", "replace"),
                         "pion_to_html": direct_cm.decode("utf-8", "replace"),
                         "pion_render_html_parse": evp_cm.decode("utf-8", "replace")})
    # internal-only consistency for pion-only options (autolinks / cjk)
    extra = [(n, m | PION_ONLY_BITS, s) for (n, m, s) in cases if m == GFM]
    write_batch(batch, extra)
    try:
        for (name, mask, src), p in zip(extra, read_frames(run([PION, "batch", batch]), 4)):
            stats["pion_only_cases"] += 1
            if p[0] != p[1] or p[2] != p[3]:
                stats["pion_only_paths_diverge"] += 1
                rows.append({"name": name, "mask": mask, "src": src, "rust": None,
                             "pion_direct": p[0].decode("utf-8", "replace"),
                             "pion_events": p[1].decode("utf-8", "replace"),
                             "pion_to_html": p[2].decode("utf-8", "replace"),
                             "pion_render_html_parse": p[3].decode("utf-8", "replace")})
    except Exception as e:
        stats["pion_only_batch_crash"] += 1
        crashes.append({"name": "pion-only batch", "err": str(e)[:300]})
    stats["crashes"] = len(crashes)
    json.dump({"stats": stats, "diffs": rows, "crashes": crashes},
              open(os.path.join(OUT, "diff_results.json"), "w"), ensure_ascii=False, indent=1)
    by_src = collections.Counter(r["name"].split("#")[0] for r in rows if r["rust"] is not None and r["pion_direct"] != r["rust"])
    print(json.dumps(dict(stats), indent=1))
    print("direct!=rust by source:", dict(by_src))
    print(f"details: {os.path.join(OUT, 'diff_results.json')}")


main()
