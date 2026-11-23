"""DoS / complexity / crash probes. Each probe runs at size N and 2N under /usr/bin/time -l.
growth = t(2N)/t(N): ~2 linear, ~4 quadratic. rc<0 = killed by a signal (SIGSEGV=-11, SIGABRT=-6).

Pion runs with ParseOptions(1e8, 1e8, 1e8) (probe `one`) so the algorithms are measured, not the default caps;
`parsedef` rows use the library defaults. graphql-js runs with `node --stack-size=984` (default); apollo-parser
with recursion_limit = usize::MAX (`parse`) or its default 500 (`parsedef`).
Usage: dos.py [--quick] [--json out.json] [--only substr]
"""
import argparse, json, os, re, subprocess, time
from common import TMP, PION, RUST, NODE_ORACLE, NODE_MODULES


def diamond(levels, fan=2):
    """fragment F0 has `fan` aliased copies of a field spreading F1 ... ; 2^levels leaf fields from ~levels*80 bytes."""
    out = ["query Q { ...F0 }"]
    for i in range(levels):
        out.append(f"fragment F{i} on T {{ " + " ".join(f"a{k}: f {{ ...F{i + 1} }}" for k in range(fan)) + " }")
    out.append(f"fragment F{levels} on T {{ " + " ".join(f"a{k}: f" for k in range(fan)) + " }")
    return "\n".join(out)


def gen_probes():
    P = []
    # name, generator(n), base n, subs (pion, node, rust)
    P.append(("diamond fragment bomb (levels)", diamond, 13, ["valid"], ["valid"], []))
    P.append(("diamond fan-out 8 (levels)", lambda n: diamond(n, 8), 4, ["valid"], ["valid"], []))
    P.append(("deep {a{a{... selection (default opts)", lambda n: "{a" * n + "}" * n, 25000, ["parsedef"], ["parse"], ["parsedef"]))
    P.append(("deep selection, max_depth raised", lambda n: "{a" * n + "}" * n, 20000, ["parse"], [], ["parse"]))
    P.append(("deep list value, max_depth raised", lambda n: "{ f(x: " + "[" * n + "1" + "]" * n + ") }", 30000, ["parse"], [], ["parse"]))
    P.append(("deep object value, max_depth raised", lambda n: "{ f(x: " + "{a:" * n + "1" + "}" * n + ") }", 30000, ["parse"], [], ["parse"]))
    P.append(("deep list type, max_depth raised", lambda n: "type T { f: " + "[" * n + "Int" + "]" * n + " }", 100000, ["parse"], [], ["parse"]))
    P.append(("deep inline fragments, max_depth raised", lambda n: "{" + "... on T {" * n + "a" + "}" * n + "}", 20000, ["parse"], [], ["parse"]))
    P.append(("flat 1 field x n (tokens)", lambda n: "{ " + "a " * n + "}", 250000, ["parse", "parsedef", "valid", "min"], ["parse", "valid", "min"], ["parse"]))
    P.append(("n distinct aliases (HashDoS-shaped)", lambda n: "{ " + " ".join(f"a{i}: f" for i in range(n)) + " }", 60000, ["valid"], ["valid"], []))
    P.append(("n distinct args one field", lambda n: "{ f(" + " ".join(f"a{i}: 1" for i in range(n)) + ") }", 60000, ["valid"], ["valid"], []))
    P.append(("n identical args (dup storm)", lambda n: "{ f(" + "a: 1 " * n + ") }", 60000, ["valid"], ["valid"], []))
    P.append(("n input fields in one object", lambda n: "{ f(x: {" + " ".join(f"k{i}: 1" for i in range(n)) + "}) }", 60000, ["valid"], ["valid"], []))
    P.append(("n fragments chain", lambda n: "{ ...F0 } " + " ".join(f"fragment F{i} on T {{ a ...F{i + 1} }}" for i in range(n)) + f" fragment F{n} on T {{ a }}", 30000, ["valid"], ["valid"], []))
    P.append(("n variables", lambda n: "query Q(" + " ".join(f"$v{i}: Int" for i in range(n)) + ") { f(" + " ".join(f"a{i}: $v{i}" for i in range(n)) + ") }", 30000, ["valid"], ["valid"], []))
    P.append(("n unknown spreads (error storm)", lambda n: "{ " + "...X " * n + "}", 100000, ["valid"], ["valid"], []))
    P.append(("huge block string (n lines)", lambda n: '{ f(x: """' + "\n    line of text" * n + '""") }', 200000, ["parse", "min"], ["parse", "min"], ["parse"]))
    P.append(("huge block string one line", lambda n: '{ f(x: """' + "x" * n + '""") }', 4000000, ["parse"], ["parse"], ["parse"]))
    P.append(("huge string many escapes", lambda n: '{ f(x: "' + "\\u0041\\n" * n + '") }', 500000, ["parse"], ["parse"], ["parse"]))
    P.append(("huge comment", lambda n: "#" + "x" * n + "\n{ a }", 4000000, ["parse"], ["parse"], ["parse"]))
    P.append(("unterminated block string", lambda n: '{ f(x: """' + "ab\n" * n, 1000000, ["parse"], ["parse"], ["parse"]))
    P.append(("many escaped triple quotes in block", lambda n: '{ f(x: """' + '\\"""' * n + '""") }', 500000, ["parse"], ["parse"], ["parse"]))
    P.append(("SDL n types", lambda n: "\n".join(f'"""doc {i}"""\ntype T{i} implements I & J @key(fields: "id") {{ id: ID! f(a: Int = 1): [T{i}!]! }}' for i in range(n)), 20000, ["parse", "parsedef", "print"], ["parse", "print"], ["parse"]))
    return P


def run_timed(cmd, timeout):
    env = dict(os.environ, NODE_PATH=NODE_MODULES)
    t0 = time.time()
    try:
        r = subprocess.run(["/usr/bin/time", "-l"] + cmd, capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return dict(rc="TIMEOUT", secs=timeout, rss_mb=None, out="")
    dt = time.time() - t0
    m = re.search(r"(\d+)\s+maximum resident set size", r.stderr)
    rc = r.returncode
    out = r.stdout.strip().splitlines()
    return dict(rc=rc, secs=round(dt, 3), rss_mb=round(int(m.group(1)) / 1048576, 1) if m else None,
                out=(out[0] if out else r.stderr.strip()[-120:])[:120])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--json")
    ap.add_argument("--only")
    a = ap.parse_args()
    timeout = int(os.environ.get("DOS_TIMEOUT", "120"))
    rows = []
    for name, g, n0, ps, ns, rs in gen_probes():
        if a.only and a.only not in name:
            continue
        sizes = [n0] if a.quick else [n0, n0 * 2 if "levels" not in name else n0 + 1]
        res = {}
        for n in sizes:
            path = os.path.join(TMP, "dos_in.graphql")
            with open(path, "w", encoding="utf-8") as f:
                f.write(g(n))
            size = os.path.getsize(path)
            for impl, subs in (("pion", ps), ("node", ns), ("rust", rs)):
                for sub in subs:
                    cmd = {"pion": [PION, "one", path, sub], "node": ["node", NODE_ORACLE, "one", path, sub],
                           "rust": [RUST, "one", path, sub]}[impl]
                    res.setdefault((impl, sub), []).append(dict(n=n, bytes=size, **run_timed(cmd, timeout)))
        print(f"\n## {name}")
        for (impl, sub), xs in res.items():
            parts = []
            for x in xs:
                parts.append(f"n={x['n']} {x['bytes'] / 1e6:.2f}MB {x['secs']}s rc={x['rc']} rss={x['rss_mb']}MB [{x['out'][:60]}]")
            growth = ""
            if len(xs) == 2 and isinstance(xs[0]["secs"], float) and xs[0]["secs"] > 0.05 and xs[0]["rc"] == 0 and xs[1]["rc"] == 0:
                growth = f" growth={xs[1]['secs'] / xs[0]['secs']:.2f}"
            print(f"  {impl:4s} {sub:8s} " + " | ".join(parts) + growth)
            rows.append(dict(probe=name, impl=impl, sub=sub, runs=xs))
    if a.json:
        json.dump(rows, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
