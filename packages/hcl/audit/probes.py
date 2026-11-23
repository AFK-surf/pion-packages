#!/usr/bin/env python3
"""DoS / robustness probes for packages/hcl, run in every build mode.

usage: probes.py MODE=CMD [MODE=CMD ...]     (CMD is split on spaces; `probe <kind> <n> [depth]`
                                                is appended)

Each probe builds a hostile input inside the driver (so the input never touches disk) and
evaluates it under `HclLimits::default()` (or a raised `max_depth`). A probe PASSes in a mode when
  * the process exits 0 (no SIGSEGV / panic abort / wasm trap / RangeError / OOM / timeout),
  * the result is a clean `ERR <kind>` or an `OK` whose output is <= max_output_bytes (16 MiB),
  * the child's peak RSS stays <= RSS_LIMIT_MB (default 256 MiB; ~16x the output budget).
"""
import os
import resource
import subprocess
import sys

RSS_LIMIT_MB = int(os.environ.get("HCL_AUDIT_RSS_LIMIT_MB", "256"))
OUTPUT_BUDGET = 16 * 1024 * 1024
TIMEOUT = 120

# (label, kind, n, max_depth or 0 for the default 128)
PROBES = [
    ("nest/tuple", "tuple", 100000, 0),
    ("nest/paren", "paren", 100000, 0),
    ("nest/object", "object", 100000, 0),
    ("nest/unary_neg", "unary", 100000, 0),
    ("nest/unary_not", "not", 100000, 0),
    ("nest/binop_chain", "binop", 100000, 0),
    ("nest/conditional", "cond", 100000, 0),
    ("nest/conditional_tail", "cond_tail", 100000, 0),
    ("nest/funcall", "funcall", 100000, 0),
    ("nest/template", "template", 100000, 0),
    ("nest/for", "for", 50000, 0),
    ("nest/tmpl_if", "tmpl_if", 50000, 0),
    ("nest/block", "block", 100000, 0),
    ("nest/attr_chain", "attr_chain", 100000, 0),
    ("nest/json_array", "json_array", 100000, 0),
    ("fmt/nested_tuple", "fmt_tuple", 100000, 0),
    ("fmt/nested_block", "fmt_block", 100000, 0),
    ("fmt/align_3000", "fmt_align", 3000, 0),
    ("unclosed/heredoc", "heredoc_unclosed", 1000000, 0),
    ("unclosed/comment", "comment_unclosed", 1000000, 0),
    ("long/identifier", "long_ident", 1000000, 0),
    ("amp/for_product_100^3", "for_product", 100, 0),
    ("amp/range", "range_huge", 100000000, 0),
    ("amp/template_200MB", "amp_template", 200, 0),
    ("amp/eval_body_to_json_200MB", "amp_body", 200, 0),
    ("amp/jsonencode_200MB", "amp_jsonencode", 200, 0),
    ("raised_depth/tuple", "tuple", 100000, 1000000),
    ("raised_depth/paren", "paren", 100000, 1000000),
    ("raised_depth/block", "block", 100000, 1000000),
    ("raised_depth/template", "template", 100000, 1000000),
    ("raised_depth/for", "for", 50000, 1000000),
]


def peak_rss_mb_of(cmd):
    """Run cmd in a fresh python child so RUSAGE_CHILDREN is that one process tree."""
    code = (
        "import resource,subprocess,sys,json\n"
        "try:\n"
        "  p=subprocess.run(sys.argv[1:],capture_output=True,timeout=%d); rc=p.returncode; o=p.stdout; e=p.stderr\n"
        "except subprocess.TimeoutExpired:\n"
        "  rc='timeout'; o=b''; e=b'timeout'\n"
        "r=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss\n"
        "r=r/1048576 if sys.platform=='darwin' else r/1024\n"
        "print(json.dumps([rc,o.decode('utf-8','replace'),e.decode('utf-8','replace'),r]))\n" % TIMEOUT
    )
    p = subprocess.run([sys.executable, "-c", code] + cmd, capture_output=True)
    import json
    return json.loads(p.stdout)


def main():
    modes = [a.split("=", 1) for a in sys.argv[1:]]
    fails = 0
    total = 0
    for label, kind, n, depth in PROBES:
        for mode, cmd in modes:
            total += 1
            argv = cmd.split() + ["probe", kind, str(n)] + ([str(depth)] if depth else [])
            rc, out, err, rss = peak_rss_mb_of(argv)
            out = out.strip()
            why = []
            if rc != 0:
                lines = err.strip().splitlines() or [""]
                msg = next((l for l in lines if "Error" in l or "panic" in l), lines[-1])
                why.append(f"rc={rc} {msg.strip()[:100]}".rstrip())
            elif "-> ERR" not in out and "-> OK" not in out:
                why.append("no verdict")
            if "-> OK out_bytes=" in out and int(out.rsplit("=", 1)[1]) > OUTPUT_BUDGET:
                why.append(f"output {int(out.rsplit('=', 1)[1]) >> 20} MiB > 16 MiB max_output_bytes")
            if rss > RSS_LIMIT_MB:
                why.append(f"peak RSS {rss:.0f} MiB > {RSS_LIMIT_MB} MiB")
            verdict = "FAIL" if why else "PASS"
            fails += bool(why)
            res = out.split("-> ", 1)[1] if "-> " in out else "-"
            print(f"{verdict} probe/{label} [{mode}] {res} rss={rss:.0f}MiB" + (f"  <- {'; '.join(why)}" if why else ""))
    print(f"probes: {total - fails}/{total} PASS, {fails} FAIL")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
