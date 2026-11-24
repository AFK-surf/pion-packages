#!/usr/bin/env python3
"""README.md claims vs measurements for packages/opentype (stdlib only, run with `python3 -I`).
Every number is parsed from README.md at run time (nothing is hard-coded), so a fix branch that
updates README.md is judged against its own claims.

  claims.py smoke-sha <README.md>                       -> the documented wasm_smoke stdout SHA-256
  claims.py sizes <README.md>                           -> "<debug> <release>" documented wasm32 bytes
  claims.py bench <README.md> <bench_out_dir>           -> exit 1: bench output not verified / protocol;
                                                           exit 3: a documented ratio is not reproduced
  claims.py docs <README.md> <pkg_root> <unit.json> <repo_root> <oracle_tests_dir|->
                                                        -> exit 3 when a documentation / process claim fails
"""
import json
import os
import re
import sys

RATIO_TOL = 0.25  # a reproduced speedup must be within +-25 % (relative) of the documented one


def readme(p):
    return open(p, encoding="utf-8").read()


def smoke_sha(text):
    m = re.search(r"Stdout SHA-256: `([0-9a-f]{64})`", text)
    return m.group(1) if m else ""


def sizes(text):
    m = re.search(r"Wasm32 binary size: `([0-9,]+) B` \(debug\) / `([0-9,]+) B`", text)
    return (int(m.group(1).replace(",", "")), int(m.group(2).replace(",", ""))) if m else (0, 0)


def bench_sections(text):
    """[(font_label, pion_speedup, pion_median_ms, sha)] from the `####` benchmark sections."""
    out = []
    parts = re.split(r"\n#### ", text)
    for part in parts[1:]:
        head = part.split("\n", 1)[0]
        fm = re.search(r"`([^`]+\.(?:ttf|otf|ttc))`", head)
        rows = [ln for ln in part.splitlines() if ln.startswith("| `pion_opentype`")]
        sm = re.search(r"Verified stdout SHA-256: `([0-9a-f]{64})`", part)
        if not fm or not rows:
            continue
        cells = [c.strip() for c in rows[0].strip("|").split("|")]
        sp = float(cells[-1].rstrip("x"))
        out.append((fm.group(1), sp, float(cells[1]), sm.group(1) if sm else ""))
    return out


def bench(readme_path, out_dir):
    text = readme(readme_path)
    measured = {}
    rc = 0
    for fn in ("bench_main.json", "bench_synth.json"):
        p = os.path.join(out_dir, fn)
        if not os.path.exists(p):
            print("  missing %s" % p)
            return 1
        d = json.load(open(p))
        r = {x["name"]: x for x in d["results"]}
        lab = re.search(r"\(([^,]+), ", d.get("title", "")).group(1)
        ok = bool(d.get("sha256")) and d.get("rounds", 0) >= 5 and d.get("warmup", 0) >= 1
        if not ok:
            rc = 1
        measured[lab] = (r["pion_opentype"]["speedup_vs_baseline"], r["pion_opentype"]["median_ms"],
                         r["rust_ttf_parser"]["median_ms"], d.get("sha256", ""))
        print("  measured %-20s pion %8.3f ms  ttf-parser %8.3f ms  speedup %.2fx  sha256 %s  warmup %s rounds %s" % (
            lab, measured[lab][1], measured[lab][2], measured[lab][0], measured[lab][3][:16], d.get("warmup"), d.get("rounds")))
    miss = []
    for lab, sp, med, sha in bench_sections(text):
        if lab not in measured:
            print("  README %-20s %.2fx: not measurable here (font absent)" % (lab, sp))
            continue
        msp = measured[lab][0]
        rel = abs(msp - sp) / sp if sp else 1.0
        verdict = "reproduced" if rel <= RATIO_TOL else "NOT reproduced"
        print("  README %-20s %.2fx vs measured %.2fx (%+.0f%%): %s; README sha256 %s %s" % (
            lab, sp, msp, 100 * (msp - sp) / sp, verdict, sha[:16], "== measured" if sha == measured[lab][3] else "!= measured"))
        if rel > RATIO_TOL or (sha and sha != measured[lab][3]):
            miss.append(lab)
    if rc:
        return 1
    return 3 if miss else 0


def docs(readme_path, pkg_root, unit_json, repo_root, oracle_tests):
    text = readme(readme_path)
    why = []
    # 1. throughput column: bytes of the whole file x iterations, although parsing is lazy
    m = re.findall(r"\| `pion_opentype`[^\n]*", text)
    for row in m:
        cells = [c.strip() for c in row.strip("|").split("|")]
        try:
            mbps = float(cells[4])
        except (IndexError, ValueError):
            continue
        if mbps > 1000:
            why.append("throughput %s MB/s counts whole-file bytes x iterations, but a lazy parse touches "
                       "only the tables of 256 lookups + 64 outlines" % cells[4])
            break
    # 2. "Full-sweep" outline / kern claims vs the shipped differential harness
    rb = os.path.join(pkg_root, "bench", "rust_bench", "src", "main.rs")
    src = open(rb).read() if os.path.exists(rb) else ""
    if "Full-sweep" in text and re.search(r"ng\.min\(\s*(256|512)\s*\)", src):
        caps = sorted(set(re.findall(r"ng\.min\(\s*(256|512)\s*\)", src)), key=int)
        why.append("README says 'Full-sweep' outline/kern digests; the shipped oracle caps them at gid < %s"
                   % "/".join(caps))
    # 3. unit-test claim and upstream port (AGENTS.md 1.1)
    try:
        u = json.load(open(unit_json))
        total = u.get("total", 0)
    except Exception:
        total = 0
    cm = re.search(r"All (\d+) unit", text)
    if cm and int(cm.group(1)) != total:
        why.append("README claims %s unit tests, `pionc test` runs %d" % (cm.group(1), total))
    up = 0
    if oracle_tests != "-" and os.path.isdir(oracle_tests):
        for fn in os.listdir(oracle_tests):
            if fn.endswith(".rs"):
                up += open(os.path.join(oracle_tests, fn), encoding="utf-8").read().count("#[test]")
    if total < 20:
        why.append("%d package tests; upstream ttf-parser 0.25.1 ships %s #[test]s (cmap/glyf/hmtx/maxp vectors), "
                   "none ported (AGENTS.md 1.1)" % (total, up or "100+"))
    # 4. BENCHMARKS.md sync (AGENTS.md 1.3): information only. Package fix branches may not touch repository
    #    root files; the root BENCHMARKS.md section is appended when the release is merged into main.
    bm = os.path.join(repo_root, "BENCHMARKS.md")
    if os.path.exists(bm) and "opentype" not in open(bm, encoding="utf-8").read():
        print("  INFO: BENCHMARKS.md has no opentype section yet (AGENTS.md 1.3; added at release merge, not gated)")
    # 5. the Mac Roman cmap 'fallback' feature is finding P1-2
    if re.search(r"Mac Roman fallback", text) and os.environ.get("P1_2_OPEN") == "1":
        why.append("README advertises the 'Mac Roman fallback' that is finding P1-2")
    for w in why:
        print("  - " + w)
    return 3 if why else 0


def main():
    a = sys.argv[1:]
    if a[0] == "smoke-sha":
        print(smoke_sha(readme(a[1])))
    elif a[0] == "sizes":
        print("%d %d" % sizes(readme(a[1])))
    elif a[0] == "bench":
        sys.exit(bench(a[1], a[2]))
    elif a[0] == "docs":
        sys.exit(docs(a[1], a[2], a[3], a[4], a[5]))
    else:
        sys.exit(2)


if __name__ == "__main__":
    main()
