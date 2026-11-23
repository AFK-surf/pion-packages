#!/usr/bin/env python3
"""RT-xpath DoS / resource-limit battery.

usage: run_dos.py --out DIR --impl name=CMD [--impl ...] [--only a,b] [--timeout S]
Every case runs in its own process (wall time + peak RSS via /usr/bin/time -l on macOS or
/usr/bin/time -v on Linux).  Impls named `pion*` run with XPathLimits::default() (2nd runner
argument `default`), i.e. what `xpath::eval*` give every caller; oracles run unlimited.

Each case has a verdict for pion (the subject):
  budget  - with default limits pion must finish (value or LimitExceeded ERR) within LIMIT s;
            today it runs for tens of seconds because the work is not metered.
  accept  - a legitimate query on a modest document; pion must return the oracle-agreed value,
            not a LimitExceeded ERR.
  stack   - deep but legal nesting; every mode must finish without crashing (exit code 0).
Exit 1 if any pion verdict fails (defect still present), else 0.
"""
import argparse
import os
import platform
import shlex
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "diff"))
import packlib  # noqa: E402


def wide(n):
    return "<r>" + "".join("<e>v%07d</e>" % i for i in range(n)) + "</r>"


def ab(n):
    return "<r>" + "".join("<a>a%d</a>" % i for i in range(n)) + "".join("<b>b%d</b>" % i for i in range(n)) + "</r>"


def attrs(n):
    return "<r>" + "".join('<e k="%d">t</e>' % i for i in range(n)) + "</r>"


def empties(n):
    return "<r>" + "<e/>" * n + "</r>"


def deep(d):
    return "<a>" * d + "x" + "</a>" * d


OR_CHAIN = " or ".join('@id="%d"' % i for i in range(200)) + ' or @id="L"'
# name, verdict, limit_s, xml-builder, query, expected (accept cases)
CASES = [
    ("budget_string_root_per_node", "budget", 5.0, lambda: wide(50000), 'count(//e[string(/) = "x"])', None),
    ("budget_nodeset_eq_nodeset_30k", "budget", 5.0, lambda: ab(30000), "//a = //b", None),
    ("budget_normalize_root_per_node", "budget", 5.0, lambda: wide(30000), 'count(//e[normalize-space(/) = "x"])', None),
    ("accept_or_chain_201", "accept", 30.0, lambda: '<r id="L"/>', "count(/r[%s])" % OR_CHAIN, "NUM 3ff0000000000000"),
    ("accept_plus_chain_200", "accept", 30.0, lambda: "<r/>", "+".join(["1"] * 200), "NUM 4069000000000000"),
    ("accept_union_chain_200", "accept", 30.0, lambda: "<r><a/></r>", "count(" + "|".join(["/r/a"] * 200) + ")", "NUM 3ff0000000000000"),
    ("accept_count_300k_children", "accept", 30.0, lambda: empties(300000), "count(/r/e)", "NUM 41124f8000000000"),
    ("accept_count_attr_120k", "accept", 30.0, lambda: attrs(120000), "count(//@k)", "NUM 40fd4c0000000000"),
    ("accept_desc_250k", "accept", 30.0, lambda: attrs(250000), "count(//e[@k >= 0])", "NUM 410e848000000000"),
    ("stack_parens_120", "stack", 30.0, lambda: "<r/>", "(" * 120 + "1" + ")" * 120, None),
    ("stack_preds_60", "stack", 30.0, lambda: deep(60), "count(/a" + "[a" * 60 + "]" * 60 + ")", None),
    ("stack_deep_xml_255_strings", "stack", 30.0, lambda: deep(255), "count(//a[string-length(.) = 1])", None),
    ("stack_unary_100k", "stack", 30.0, lambda: "<r/>", "-" * 100000 + "1", None),
    ("stack_path_10k", "stack", 30.0, lambda: "<r/>", "count(/r" + "/.." * 10000 + ")", None),
    ("stack_func_nest_60", "stack", 30.0, lambda: "<r/>", "concat(" * 60 + "'a'" + ",'b')" * 60, None),
]


def measure(cmd, timeout):
    tool = ["/usr/bin/time", "-l"] if platform.system() == "Darwin" else ["/usr/bin/time", "-v"]
    t = time.time()
    try:
        p = subprocess.run(tool + cmd, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, timeout, 0, ""
    dt = time.time() - t
    rss = 0
    for line in p.stderr.decode("utf-8", "replace").split("\n"):
        if "maximum resident set size" in line:
            rss = int(line.split()[0])
        elif "Maximum resident set size" in line:
            rss = int(line.split()[-1]) * 1024
    res = packlib.parse_output(p.stdout.decode("utf-8", "replace"))
    return p.returncode, dt, rss, (res[0].split("\n")[0] if res else "<no output>")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--impl", action="append", required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("--timeout", type=int, default=60)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    only = set(x for x in a.only.split(",") if x)
    impls = [i.split("=", 1) for i in a.impl]
    fails = []
    print("  %-32s %-14s %8s %9s  %s" % ("case", "impl", "wall_s", "rss_MiB", "result"))
    for name, verdict, limit, mk, q, expect in CASES:
        if only and name not in only:
            continue
        pack, _ = packlib.build([(mk(), [], [q])])
        path = os.path.join(a.out, name + ".pack")
        open(path, "wb").write(pack)
        for iname, cmd in impls:
            is_pion = iname.startswith("pion")
            argv = shlex.split(cmd) + [path] + (["default"] if is_pion else [])
            to = a.timeout if not (verdict == "budget" and is_pion) else max(a.timeout, int(limit * 8))
            rc, dt, rss, head = measure(argv, to)
            shown = head if rc is not None else "TIMEOUT"
            ok = ""
            if is_pion:
                if rc is None or rc != 0:
                    good = False
                elif verdict == "budget":
                    good = dt <= limit
                elif verdict == "accept":
                    good = head == expect and dt <= limit
                else:
                    good = True
                ok = "ok" if good else "DEFECT"
                if not good:
                    fails.append("%s/%s" % (name, iname))
            print("  %-32s %-14s %8.2f %9.1f  %-28s %s" % (name, iname, dt, rss / 1048576.0, shown[:28], ok), flush=True)
    print("  -> pion verdict failures: %d%s" % (len(fails), (" (" + ", ".join(fails) + ")") if fails else ""))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
