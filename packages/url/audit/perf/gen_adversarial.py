#!/usr/bin/env python3
"""Adversarial-but-realistic throughput corpora for bench_compare.py (Pion vs Rust
`url v2.5.9 --release`). Every corpus is chosen so both implementations produce
byte-identical stdout (the drivers print only field lengths via the `L` prefix),
which bench_compare.py enforces with SHA-256. IDN hosts are restricted to
precomposed, already-NFC input that Pion maps correctly (see REPORT.md F-3), so the
outputs agree — but Pion still skips the NFC / mapping-table / Bidi / ContextJ work
rust-url does, so IDN timings flatter Pion. Parse/join workloads use the `H`/`JH` ops
(serialization only), like packages/url/bench. Each corpus has a `.noop` twin (op `N`,
same bytes) that measures the drivers' own I/O + hex-decoding cost.

Usage: gen_adversarial.py <out_dir>   -> writes <name>.in for each workload below.
"""
import os
import random
import sys


def h(x):
    return "~" if x is None else x.encode().hex()


def case(*f):
    return "\t".join(h(x) for x in f)


IDN = ["bücher", "münchen", "straße", "παράδειγμα", "пример", "例え", "中国移动", "한국",
       "españa", "ไทย", "uñicode", "café", "naïve", "smörgåsbord", "日本語", "испытание"]
TLD = ["de", "com", "рф", "テスト", "中国", "org", "jp"]


def w_idn(r, n=100000):
    return [case("LH", "https://%s.%s.%s/p/%d?q=%d" % (r.choice(IDN), r.choice(IDN), r.choice(TLD), i, i))
            for i in range(n)]


def w_ipv6(r, n=200000):
    out = []
    for i in range(n):
        g = ["%x" % r.randint(0, 0xFFFF) for _ in range(8)]
        z = r.randint(0, 6)
        k = r.randint(1, 8 - z)
        form = r.randint(0, 3)
        if form == 0:
            host = ":".join(g)
        elif form == 1:
            host = ":".join(g[:z]) + "::" + ":".join(g[z + k:])
        elif form == 2:
            host = "::ffff:%d.%d.%d.%d" % tuple(r.randint(0, 255) for _ in range(4))
        else:
            host = ":".join("0" * 4 for _ in range(6)) + ":" + ":".join(g[:2])
        out.append(case("LH", "http://[%s]:%d/s/%d" % (host.upper() if i % 2 else host, 1024 + i % 5000, i)))
    return out


def w_ipv4(r, n=200000):
    out = []
    for i in range(n):
        parts = [r.randint(0, 255) for _ in range(4)]
        form = r.randint(0, 3)
        if form == 0:
            host = ".".join(map(str, parts))
        elif form == 1:
            host = ".".join("0x%x" % p for p in parts)
        elif form == 2:
            host = ".".join("0%o" % p for p in parts)
        else:
            host = str((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3])
        out.append(case("LH", "http://%s/x/%d" % (host, i)))
    return out


def w_pct(r, n=100000):
    alphabet = list("abc é<>\"`{}|^%[]#?'~") + ["€", "😀", "%zz", "%41", "\t"]
    out = []
    for i in range(n):
        seg = "".join(r.choice(alphabet) for _ in range(40))
        out.append(case("LH", "https://h/" + seg.replace("#", "/").replace("?", "/") + "?" +
                        seg.replace("#", "&") + "#" + seg))
    return out


def w_big(r, n=200):
    return [case("LH", "https://u:p@example.com/" + "/".join("seg%dé" % j for j in range(12000)) +
                 "?" + "&".join("k%d=v é" % j for j in range(3000)) + "#" + "f" * 10000) for _ in range(n)]


def w_query_sort(r, n=7500):
    out = []
    for i in range(n):
        q = "&".join("%s=%d" % (r.choice(["z", "a", "m", "é", "k%d" % (j % 50), "b+c", "%E2%82%AC"]), j)
                     for j in range(r.choice([8, 24, 25, 100, 300])))
        out.append(case("LM", q, "d", "a", "s", "m", "x", "a", "extra", "ok", "sort"))
    return out


def w_setters(r, n=40000):
    bases = ["http://u:p@h.com:8080/a/b?q#f", "https://example.org/", "foo://h/p", "ws://h/x/y"]
    out = []
    for i in range(n):
        out.append(case("LS", r.choice(bases), "hostname", "h%d.example" % i, "port", str(1000 + i % 60000),
                        "pathname", "/x/../y/%d" % i, "search", "?a=%d&b=é" % i, "hash", "#h%d" % i,
                        "username", "u%d" % i, "password", "p w"))
    return out


def w_join(r, n=200000):
    bases = ["https://h/a/b/c/d", "http://u:p@h:81/x/y?q#f", "ws://h/", "ftp://h/pub/x/"]
    rels = ["../../e", "./f?g", "//h2/p", "?q2", "#f2", "/abs/path", "a/b/../c", "..", "../%2e%2e/x",
            "g;x?y#s", "\\\\h3\\p", "  /trim  "]
    return [case("LJH", r.choice(bases), r.choice(rels)) for _ in range(n)]


WORKLOADS = {
    "adv_idn": w_idn, "adv_ipv6": w_ipv6, "adv_ipv4": w_ipv4, "adv_pct": w_pct,
    "adv_big_url": w_big, "adv_query_sort": w_query_sort, "adv_setters": w_setters,
    "adv_join": w_join,
}


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, fn in WORKLOADS.items():
        lines = fn(random.Random(len(name) * 7919))
        with open(os.path.join(out, name + ".in"), "w") as f:
            f.write("\n".join(lines) + "\n")
        # matching no-op corpus: same bytes, op `N`, to expose driver overhead
        with open(os.path.join(out, name + ".noop.in"), "w") as f:
            f.write("\n".join("4e" + l[l.index("\t"):] for l in lines) + "\n")
        print("%s %d" % (name, len(lines)))


if __name__ == "__main__":
    main()
