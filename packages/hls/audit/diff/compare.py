#!/usr/bin/env python3
"""Compare outputs of the audit tools.

  compare.py same <a> <b>                      byte-identical (4-mode determinism)
  compare.py model <pion_dump> <model_dump>    Pion vs reference model; divergences explained by a FLAGS id
                                               are counted per finding, others are UNEXPLAINED
  compare.py rust <pion_dump> <rust_dump> <model_dump>   Pion vs m3u8-rs 6.0.1 on the shared field subset
exit: 0 clean, 3 known findings only, 1 unexplained divergence. A `FINDINGS <ids>` line lists the ids seen.
"""

import sys
from collections import Counter, OrderedDict


def blocks(path):
    out = OrderedDict()
    cur = None
    with open(path, encoding="ascii") as f:
        for line in f.read().split("\n"):
            if line.startswith("="):
                cur = line[1:]
                out[cur] = []
            elif line and cur is not None:
                out[cur].append(line)
    return out


def same(a, b):
    with open(a, "rb") as f1, open(b, "rb") as f2:
        x, y = f1.read(), f2.read()
    if x == y:
        return 0
    la, lb = x.split(b"\n"), y.split(b"\n")
    for i, (p, q) in enumerate(zip(la, lb)):
        if p != q:
            print("  first difference at line %d:\n    %s\n    %s" % (i + 1, p[:200], q[:200]))
            break
    else:
        print("  line counts differ: %d vs %d" % (len(la), len(lb)))
    return 1


def norm(lines):
    """Error variants are implementation detail: only accept vs reject is compared."""
    return ["ERR"] if lines and lines[0].startswith("ERR|") else lines


def model(pion_path, model_path):
    P, M = blocks(pion_path), blocks(model_path)
    if list(P) != list(M):
        print("  case lists differ (%d vs %d)" % (len(P), len(M)))
        return 1
    stats = Counter()
    per = Counter()
    unexplained = []
    for name in P:
        p = norm(P[name])
        m = norm([x for x in M[name] if not x.startswith(("FLAGS|", "FFLAGS|"))])
        flags = [x[6:].split(",") for x in M[name] if x.startswith("FLAGS|")]
        flags = flags[0] if flags else []
        fflags = [x[7:].split(",") for x in M[name] if x.startswith("FFLAGS|")]
        fflags = fflags[0] if fflags else []
        # a divergence confined to the formatter line may also be explained by a format-level id
        if p != m and len(p) == len(m) and [x for x in p if not x.startswith("FMT|")] == \
                [x for x in m if not x.startswith("FMT|")]:
            flags = flags + fflags
        stats["cases"] += 1
        stats["accept" if not p[0].startswith("ERR") else "reject"] += 1
        if p == m:
            stats["identical"] += 1
            continue
        if flags:
            stats["explained"] += 1
            for f in flags:
                per[f] += 1
            continue
        unexplained.append((name, p, m))
    print("  %d cases: %d identical, %d divergent explained by findings, %d UNEXPLAINED (Pion accepts %d, rejects %d)" % (
        stats["cases"], stats["identical"], stats["explained"], len(unexplained), stats["accept"], stats["reject"]))
    if per:
        print("  divergences per finding: " + ", ".join("%s=%d" % kv for kv in sorted(per.items())))
    for name, p, m in unexplained[:8]:
        print("  UNEXPLAINED %s" % name)
        for i in range(max(len(p), len(m))):
            a = p[i] if i < len(p) else "<none>"
            b = m[i] if i < len(m) else "<none>"
            if a != b:
                print("    pion : %s\n    model: %s" % (a[:220], b[:220]))
                break
    print("FINDINGS " + " ".join(sorted(per)))
    return 1 if unexplained else (3 if per else 0)


def why(proj, r, data):
    """Classify a field difference between Pion and m3u8-rs 6.0.1 (both accepted the input)."""
    if b"#EXT-X-DEFINE" in data:
        return "m3u8rs_no_variable_substitution"
    if len(proj) != len(r):
        return "m3u8rs_drops_or_invents_entries"
    for a, b in zip(proj, r):
        if a != b:
            fa, fb = a.split("|"), b.split("|")
            if fa[0] == "S" and fa[1] != fb[1]:
                return "m3u8rs_tag_line_as_uri"
            if fa[0] == "S" and fa[2] != fb[2]:
                if int(fa[2]) < 0:
                    return "pion_negative_duration_P1-1"
                return "m3u8rs_f32_duration" if abs(int(fa[2]) - int(fb[2])) <= max(1, abs(int(fb[2])) // 10**6) else "duration"
            if fa[0] == "S" and fa[5] != fb[5]:
                return "key_attachment"
            return "field_" + fa[0]
    return "other"


def rust(pion_path, rust_path, model_path, corpus_path=None):
    """m3u8-rs is not a validator: it accepts much the spec rejects. The comparison is on the accept set of
    both parsers and on the shared field subset of `R:` lines that the Rust oracle prints."""
    P, R, M = blocks(pion_path), blocks(rust_path), blocks(model_path)
    src = {}
    if corpus_path:
        with open(corpus_path) as f:
            for line in f:
                if "\t" in line:
                    n, h = line.rstrip("\n").split("\t", 1)
                    src[n] = bytes.fromhex(h)
    cnt = Counter()
    examples = {}
    for name in P:
        p, r = P[name], R.get(name, ["<missing>"])
        pa = not p[0].startswith("ERR")
        ra = not r[0].startswith("ERR")
        ma = not M[name][0].startswith("ERR")
        if r[0].startswith("PANIC"):
            cnt["rust_panic"] += 1
            examples.setdefault("rust_panic", name)
            continue
        if pa and not ra:
            k = "pion_accepts_rust_rejects" + ("_model_rejects" if not ma else "")
        elif ra and not pa:
            k = "rust_accepts_pion_rejects" + ("_model_accepts" if ma else "")
        elif not pa:
            k = "both_reject"
        else:
            proj = project(p)
            k = "both_accept_fields_equal" if proj == r else "both_accept_fields_differ:" + why(proj, r, src.get(name, b""))
            if k.startswith("both_accept_fields_differ"):
                for a, b in zip(proj + ["<none>"] * 99, r + ["<none>"] * 99):
                    if a != b:
                        examples.setdefault("diffline:" + a.split("|")[0], (name, a[:150], b[:150]))
                        break
        cnt[k] += 1
        examples.setdefault(k, name)
    for k in sorted(cnt):
        print("  %-48s %6d   e.g. %s" % (k, cnt[k], examples[k]))
    for k in sorted(x for x in examples if x.startswith("diffline:"))[:6]:
        name, a, b = examples[k]
        print("  first field difference (%s) in %s:\n    pion: %s\n    rust: %s" % (k[9:], name, a, b))
    return 1 if cnt["rust_panic"] else 0


def project(lines):
    """Project the Pion dump onto the fields m3u8-rs exposes (see rust/src/main.rs)."""
    out = []
    for l in lines:
        f = l.split("|")
        t = f[0]
        if t == "MASTER":
            out.append("MASTER|" + f[1] + "|" + f[2])
        elif t == "V":
            out.append("V|" + "|".join([f[1], f[2], f[3], f[4], f[5], f[8], f[9], f[10]]))
        elif t == "I":
            out.append("I|" + "|".join([f[1], f[2], f[4], f[5]]))
        elif t == "M":
            out.append("M|" + "|".join(f[1:9]))
        elif t == "MEDIA":
            out.append("MEDIA|" + "|".join(f[1:8]))
        elif t == "S":
            dur_ms = (int(f[2]) + 500) // 1000
            br = f[4]
            out.append("S|" + "|".join([f[1], str(dur_ms), br.split("@")[0] if br != "-" else "-", f[5], f[8].split(",")[0], f[9].split(",")[0]]))
    return out


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "same":
        sys.exit(same(sys.argv[2], sys.argv[3]))
    if mode == "model":
        sys.exit(model(sys.argv[2], sys.argv[3]))
    if mode == "rust":
        sys.exit(rust(*sys.argv[2:6]))
    sys.exit(2)
