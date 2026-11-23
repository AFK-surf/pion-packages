#!/usr/bin/env python3
"""Deterministic red-team corpus generator for packages/cron.

usage: gen_corpus.py <out_dir> [n_random] [seed]

Writes (one case per line: opts<TAB>expr<TAB>start_unix<TAB>n, with \\t \\n \\r escaped):
  std.txt     5-field Vixie/robfig/croner-comparable expressions (opts=std)
  sec.txt     6-field seconds expressions (opts=sec)
  quartz.txt  Quartz-comparable 6/7-field expressions (DOW by name only, exactly one '?')
  adv.txt     hand-written adversarial / boundary expressions (all oracles)
  inv.txt     invariant cases (every expression above x random starts in years 1..9999)
"""
import os
import random
import sys

DOW_NAMES = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
MON_NAMES = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
EPOCH_2000 = 946684800
EPOCH_2090 = 3786912000


def esc(s):
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")


def num(r, lo, hi, lead0=False):
    v = r.randint(lo, hi)
    if lead0 and v < 10 and r.random() < 0.3:
        return "0%d" % v
    return str(v)


def item(r, lo, hi, kind, wrap=False):
    """kind: n (numeric), m (month), d (dow numeric 0..7 incl 7)."""
    def atom(v):
        if kind == "m" and r.random() < 0.3:
            s = MON_NAMES[v - 1]
            return s if r.random() < 0.7 else s.lower()
        if kind == "d" and r.random() < 0.3:
            s = DOW_NAMES[v % 7]
            return s if r.random() < 0.7 else s.capitalize()
        return str(v) if r.random() < 0.85 or v >= 10 else "0%d" % v

    t = r.random()
    if t < 0.35:
        return atom(r.randint(lo, hi))
    if t < 0.6:
        a, b = sorted([r.randint(lo, hi), r.randint(lo, hi)])
        if wrap and r.random() < 0.5:
            a, b = b, a
        return "%s-%s" % (atom(a), atom(b))
    if t < 0.75:
        a, b = sorted([r.randint(lo, hi), r.randint(lo, hi)])
        return "%s-%s/%d" % (atom(a), atom(b), r.randint(1, max(1, hi - lo)))
    if t < 0.85:
        return "*/%d" % r.randint(1, max(1, hi - lo))
    return "%s/%d" % (atom(r.randint(lo, hi)), r.randint(1, max(1, hi - lo)))


def field(r, lo, hi, kind, star_p=0.35, wrap=False):
    if r.random() < star_p:
        return "*"
    k = 1 if r.random() < 0.7 else r.randint(2, 4)
    return ",".join(item(r, lo, hi, kind, wrap) for _ in range(k))


def gen_std(r):
    # croner/robfig-comparable: no reversed ranges, DOW 0..6 (robfig rejects 7)
    return " ".join([
        field(r, 0, 59, "n", 0.25),
        field(r, 0, 23, "n", 0.35),
        field(r, 1, 31, "n", 0.55),
        field(r, 1, 12, "m", 0.6),
        field(r, 0, 6, "d", 0.6),
    ])


def gen_sec(r):
    return field(r, 0, 59, "n", 0.3) + " " + gen_std(r)


def q_dom(r):
    t = r.random()
    if t < 0.12:
        return "L"
    if t < 0.2:
        return "LW"
    if t < 0.3:
        return "L-%d" % r.randint(1, 30)
    if t < 0.45:
        return "%dW" % r.randint(1, 31)
    if t < 0.55:
        return "*"
    return field(r, 1, 31, "n", 0.0)


def q_dow(r):
    t = r.random()
    d = DOW_NAMES[r.randint(0, 6)]
    if t < 0.2:
        return "%s#%d" % (d, r.randint(1, 5))
    if t < 0.35:
        return "%sL" % d
    if t < 0.45:
        return "*"
    k = 1 if r.random() < 0.7 else r.randint(2, 3)
    parts = []
    for _ in range(k):
        if r.random() < 0.5:
            parts.append(DOW_NAMES[r.randint(0, 6)])
        else:
            a, b = sorted([r.randint(0, 6), r.randint(0, 6)])
            parts.append("%s-%s" % (DOW_NAMES[a], DOW_NAMES[b]))
    return ",".join(parts)


def q_year(r):
    t = r.random()
    if t < 0.3:
        return None
    if t < 0.5:
        return "*"
    if t < 0.7:
        a = r.randint(2000, 2100)
        return "%d-%d" % (a, a + r.randint(0, 20))
    if t < 0.85:
        return ",".join(str(r.randint(2000, 2110)) for _ in range(r.randint(1, 4)))
    a = r.randint(2000, 2050)
    return "%d/%d" % (a, r.randint(1, 8))


def gen_quartz(r):
    sec = field(r, 0, 59, "n", 0.2)
    mi = field(r, 0, 59, "n", 0.2)
    hr = field(r, 0, 23, "n", 0.4)
    # Quartz 2.3.2 cannot parse name/number mixes ("JAN-11", "1-NOV") or named steps: numbers only.
    mon = field(r, 1, 12, "n", 0.6)
    if r.random() < 0.5:
        dom, dow = q_dom(r), "?"
    else:
        dom, dow = "?", q_dow(r)
    parts = [sec, mi, hr, dom, mon, dow]
    y = q_year(r)
    if y is not None:
        parts.append(y)
    return " ".join(parts)


# Hand-written adversarial / boundary set. (opts, expr)
ADV = [
    # DOM/DOW star semantics (Vixie: DOM_STAR/DOW_STAR set when field *starts* with '*')
    ("std", "0 0 */1 * MON"), ("std", "0 0 * * */1"), ("std", "0 0 */2 * MON"),
    ("std", "0 0 1-31 * MON"), ("std", "0 0 ? * MON"), ("std", "0 0 13 * ?"),
    ("std", "0 0 13 * 5"), ("and", "0 0 13 * 5"), ("std", "0 0 *,13 * 5"),
    ("std", "0 0 13 * *,5"), ("std", "0 0 */1 * */1"), ("std", "0 0 1/1 * MON"),
    # 0/7 Sunday mixing, wrap ranges
    ("std", "0 0 * * 5-7"), ("std", "0 0 * * 7-2"), ("std", "0 0 * * 0-7/2"), ("std", "0 0 * * 7/2"),
    ("std", "0 0 * * 7"), ("std", "0 0 * * 0,7"), ("std", "0 0 * * 6-7"), ("std", "0 0 * * 7-7"),
    ("std", "0 0 * * FRI-MON"), ("std", "0 0 * * FRI-MON/2"), ("std", "0 0 * * SAT-SUN"),
    ("std", "0 0 1 DEC-FEB/2 *"), ("std", "0 0 1 NOV-FEB *"), ("std", "55-5/3 * * * *"),
    ("std", "0 22-2 * * *"), ("std", "0 22-2/2 * * *"), ("std", "0 0 25-5 * *"),
    ("std", "0 0 * * 1-5,0"), ("std", "0 0 * * 6-0"),
    # leading zeros, case, whitespace
    ("std", "00 08 09 01 *"), ("std", "0 0 * jan,Feb,MAR mon-fri"), ("std", "  0\t0  *  *  * \r\n"),
    ("std", "0 0 * * mOn"), ("std", "0 0 1 jAn *"),
    # '?' everywhere
    ("std", "? * * * *"), ("std", "0 ? * * *"), ("std", "0 0 * ? *"), ("std", "0 0 ? * ?"),
    ("sec", "? * * * * *"),
    # steps/limits
    ("std", "*/60 * * * *"), ("std", "*/59 * * * *"), ("std", "0 */24 * * *"), ("std", "0 0 */32 * *"),
    ("std", "0 0 * */13 *"), ("std", "0 0 * * */8"), ("std", "0 0 * * */7"), ("std", "0-59/99999999999999999999 * * * *"),
    ("std", "*/0 * * * *"), ("std", "60 * * * *"), ("std", "0 24 * * *"), ("std", "0 0 0 * *"),
    ("std", "0 0 32 * *"), ("std", "0 0 * 0 *"), ("std", "0 0 * 13 *"), ("std", "0 0 * * 8"),
    ("std", "-1 * * * *"), ("std", "1- * * * *"), ("std", "1-2-3 * * * *"), ("std", "1//2 * * * *"),
    ("std", "1,,2 * * * *"), ("std", ",1 * * * *"), ("std", "1, * * * *"), ("std", "* * * * * * * *"),
    ("std", "+1 * * * *"), ("std", "1.0 * * * *"), ("std", "0x1 * * * *"),
    # macros
    ("std", "@yearly"), ("std", "@annually"), ("std", "@monthly"), ("std", "@weekly"), ("std", "@daily"),
    ("std", "@midnight"), ("std", "@hourly"), ("std", "@reboot"), ("std", "@every 5m"), ("std", "@DAILY"),
    ("std", " @daily "), ("std", "@daily x"),
    # Quartz L / W / LW / L-n / # (6/7-field)
    ("q", "0 0 0 L * ?"), ("q", "0 0 0 LW * ?"), ("q", "0 0 0 L-0 * ?"), ("q", "0 0 0 L-1 * ?"),
    ("q", "0 0 0 L-30 * ?"), ("q", "0 0 0 L-31 * ?"), ("q", "0 0 0 29L * ?"), ("q", "0 0 0 31L * ?"),
    ("q", "0 0 0 1W * ?"), ("q", "0 0 0 31W * ?"), ("q", "0 0 0 28W 2 ?"), ("q", "0 0 0 29W 2 ?"),
    ("q", "0 0 0 30W * ?"), ("q", "0 0 0 15W * ?"), ("q", "0 0 0 1-5W * ?"), ("q", "0 0 0 1,15W * ?"),
    ("q", "0 0 0 L,15 * ?"), ("q", "0 0 0 1,L * ?"), ("q", "0 0 0 15W,L * ?"), ("q", "0 0 0 1-5,5L * ?"),
    ("q", "0 0 0 LW,L * ?"), ("q", "0 0 0 W * ?"), ("q", "0 0 0 0W * ?"), ("q", "0 0 0 32W * ?"),
    ("q", "0 0 0 ? * FRI#5"), ("q", "0 0 0 ? * 5#5"), ("q", "0 0 0 ? * 0#1"), ("q", "0 0 0 ? * 7#1"),
    ("q", "0 0 0 ? * SUN#1"), ("q", "0 0 0 ? * 7L"), ("q", "0 0 0 ? * SUNL"), ("q", "0 0 0 ? * 1#1,5#2"),
    ("q", "0 0 0 ? * FRI#6"), ("q", "0 0 0 ? * FRI#0"), ("q", "0 0 0 ? * L"), ("q", "0 0 0 ? * 5L,MON#1"),
    ("q", "0 0 0 ? * MON-FRI#2"), ("q", "0 0 0 ? * #2"), ("q", "0 0 0 ? * 5#"),
    ("q", "0 0 0 L * MON"), ("and", "0 0 0 L * FRI"), ("q", "0 0 0 15W * MON"),
    # years
    ("q", "0 0 0 1 1 ? 2024-2026"), ("q", "0 0 0 29 2 ? 2100-2103"), ("q", "0 0 0 29 2 * 2100-2103"),
    ("and", "0 0 0 29 2 1 2000-2100"), ("q", "0 0 0 1 1 ? 0"), ("q", "0 0 0 1 1 ? 10000"),
    ("q", "0 0 0 1 1 ? 2026-2024"), ("q", "0 0 0 1 1 ? 2024,2026,2030-2032"), ("q", "0 0 0 1 1 ? */100"),
    ("q", "0 0 0 1 1 ? 2024/0"), ("q", "0 0 0 1 1 ? 9999"), ("q", "0 0 0 1 1 ? 1"),
    ("q", "0 0 0 29 2 ? 2000,2100,2400"), ("q", "0 0 0 1 1 ? 2024 extra"),
    # sparse/impossible
    ("std", "0 0 31 2 *"), ("std", "0 0 30 2 *"), ("std", "0 0 29 2 *"), ("std", "0 0 29 2 1"),
    ("and", "0 0 29 2 1"), ("and", "0 0 31 * 0"), ("std", "0 0 31 4,6,9,11 *"),
]


def main():
    out = sys.argv[1]
    n_random = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 20261123
    r = random.Random(seed)
    os.makedirs(out, exist_ok=True)

    def start_recent():
        return r.randint(EPOCH_2000, EPOCH_2090)

    sets = {
        "std.txt": [("std", gen_std(r)) for _ in range(n_random)],
        "sec.txt": [("sec", gen_sec(r)) for _ in range(n_random // 4)],
        "quartz.txt": [("q", gen_quartz(r)) for _ in range(n_random)],
        "adv.txt": [(o, e) for (o, e) in ADV if e is not None],
    }
    for name, cases in sets.items():
        with open(os.path.join(out, name), "w") as f:
            for o, e in cases:
                n = 5
                f.write("%s\t%s\t%d\t%d\n" % (o, esc(e), start_recent(), n))
    # Invariant set: every expression, random starts across the whole 1..9999 range + edges.
    edges = [-62135596800, -62135596799, -62135596801 + 86400, -2208988800, -1, 0, 951782400,
             4107542400, 13574563200, 253402300799, 253402300798, 253402214400]
    with open(os.path.join(out, "inv.txt"), "w") as f:
        for name in ("std.txt", "sec.txt", "quartz.txt", "adv.txt"):
            for o, e in sets[name]:
                starts = [r.randint(-62135596800, 253402300799) for _ in range(2)] + [start_recent()]
                starts.append(r.choice(edges))
                for s in starts:
                    f.write("%s\t%s\t%d\t1\n" % (o, esc(e), s))
    print("corpus -> %s (%s)" % (out, ", ".join("%s=%d" % (k, len(v)) for k, v in sets.items())))


if __name__ == "__main__":
    main()
