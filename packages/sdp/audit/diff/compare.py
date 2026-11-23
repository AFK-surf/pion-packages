#!/usr/bin/env python3
"""Join Pion probe verdicts with the Rust oracle (webrtc-rs sdp =0.9.0, Mozilla webrtc-sdp =0.3.17).

usage: compare.py <pion.out> <rust.out> [--md out.md]
Flags a case when Pion's accept/reject (parse, then summary) disagrees with an oracle, or when
the parsed m-line count differs. The full verdicts are printed so every claim in REPORT.md can
be checked against them.
"""
import sys


def load(path):
    out = {}
    order = []
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split("\t")
        out[parts[0]] = parts[1:]
        order.append(parts[0])
    return out, order


def accept(v):
    return v.startswith("OK")


def mcount(v):
    for tok in v.split():
        if tok.startswith("m="):
            return tok
    return None


def main():
    pion, order = load(sys.argv[1])
    rust, _ = load(sys.argv[2])
    md = sys.argv[sys.argv.index("--md") + 1] if "--md" in sys.argv else None
    rows = []
    disagree = 0
    for name in order:
        p = pion[name][0]
        w, m = rust.get(name, ["W:?", "M:?"])
        w, m = w[2:], m[2:]
        p_acc = accept(p) and "sum=err" not in p
        flags = []
        if p_acc != accept(w):
            flags.append("vs-webrtc-rs")
        if p_acc != accept(m):
            flags.append("vs-mozilla")
        if accept(p) and accept(w) and mcount(p) != mcount(w):
            flags.append("m-count")
        if flags:
            disagree += 1
        rows.append((name, p, w, m, ",".join(flags)))
    lines = ["| case | pion (parse + summary) | webrtc-rs sdp 0.9.0 | mozilla webrtc-sdp 0.3.17 | disagreement |",
             "|---|---|---|---|---|"]
    for name, p, w, m, f in rows:
        short = p if len(p) < 160 else p[:157] + "..."
        lines.append(f"| `{name}` | `{short}` | `{w}` | `{m}` | {f} |")
    text = "\n".join(lines)
    print(text)
    print(f"\n{len(rows)} cases, {disagree} with an accept/reject or m-count disagreement")
    if md:
        open(md, "w").write(text + "\n")


if __name__ == "__main__":
    main()
