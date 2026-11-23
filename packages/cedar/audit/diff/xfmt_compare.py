#!/usr/bin/env python3
"""usage: xfmt_compare.py <rust transcript of originals> <rust transcript of xfmt cases> [--details F]
Exit 1 if cedar-policy reads Pion's formatted text differently from the original text."""
import sys
sys.path.insert(0, __import__("os").path.dirname(__file__))
from compare import load  # noqa: E402

args = sys.argv[1:]
details = None
if "--details" in args:
    j = args.index("--details"); details = args[j + 1]; del args[j:j + 2]
orig, _ = load(args[0])
xf, order = load(args[1])
# Only policy sets the reference itself accepts carry a meaning to preserve.
order = [k for k in order if orig[k[:-5]] != "PERR"]
bad = [k for k in order if xf[k] != orig[k[:-5]]]
print("  %-10s %d formatted policy sets re-read by cedar-policy: %d same meaning, %d DIFFERENT"
      % ("xfmt", len(order), len(order) - len(bad), len(bad)))
for k in bad[:12]:
    print("    %-34s original=%s | formatted=%s" % (k[:-5], orig[k[:-5]], xf[k]))
if details:
    with open(details, "w", encoding="utf-8") as f:
        for k in bad:
            f.write("XFMT %s\toriginal=%s\tformatted=%s\n" % (k[:-5], orig[k[:-5]], xf[k]))
sys.exit(1 if bad else 0)
