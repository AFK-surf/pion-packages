"""Comparisons for the RT-unicode-linebreak audit (stdlib only).

  compare.py same <a> <b>                                    byte-identical dumps (mode determinism)
  compare.py lbtest <ucd> <cases> <pion_dump>                official LineBreakTest-16.0.0 positions, Mandatory /
                                                             Allowed kinds and output invariants
  compare.py model <ucd> <cases> <pion_dump>                 Pion vs the independent model (offsets + kinds);
                                                             divergences attributed to findings by emulation
  compare.py icu <ucd> <cases> <pion_dump> <icu_dump> <icu_lbtest_dump> <lbtest_cases> [<icuprobe cases> <icu dump>]
        Pion vs Rust icu_segmenter 2.4.0 (offsets only: ICU does not report the kind). A divergence is explained
        when (a) the model, with the open findings emulated, reproduces Pion, and (b) ICU's side is reproduced by the
        model's ICU profile (15.1 Line_Break data, pre-15.1 LB19, pre-16.0 LB21a, U+25CC-pair quirk), or lies at an
        SA boundary (implementation-defined), or is a boundary key ICU 2.4.0 demonstrably gets wrong on the
        official LineBreakTest-16.0.0 vectors or on the icuprobe contexts (measured here, not assumed)
  compare.py invariants <cases> <pion_dump>                  output invariants only

Lines printed as `FINDINGS <id> ...` list the open finding ids a comparison reproduced. Exit 1 on any
unexplained divergence.
"""
import itertools
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model  # noqa: E402
import ucd  # noqa: E402

FINDINGS = ("P2-1", "P2-2", "P2-3")


def lines(path):
    with open(path) as f:
        return [l.rstrip("\n") for l in f]


def parse_dump(s):
    """`3a,5m` -> [(3, 'a'), (5, 'm')]; `-` -> []; ICU dumps have no kind -> kind None."""
    if s == "-" or s == "":
        return []
    out = []
    for t in s.split(","):
        t = t.split(":", 1)[0]
        if t[-1] in "am":
            out.append((int(t[:-1]), t[-1]))
        else:
            out.append((int(t), None))
    return out


def invariant_errors(data, br):
    """Monotonic, on decoder code point boundaries, in 1..len, ends with (len, Mandatory), [] for empty."""
    if not data:
        return [] if not br else ["non-empty result for empty input"]
    starts = set(o for _, o in model.decode(data))
    errs = []
    prev = 0
    for o, k in br:
        if o <= prev:
            errs.append("not strictly increasing at %d" % o)
        if o != len(data) and o not in starts:
            errs.append("offset %d is not a code point boundary" % o)
        if o > len(data):
            errs.append("offset %d > len" % o)
        prev = o
    if not br or br[-1] != (len(data), "m"):
        errs.append("does not end with (%d, Mandatory)" % len(data))
    return errs


def hard_kind_errors(data, br):
    """Independent of the model: every break right after BK / LF / NL / CR-not-before-LF is Mandatory, every
    other break is Allowed, and there is never a break between CR and LF."""
    cps = model.decode(data)
    want = {}
    for i, (cp, o) in enumerate(cps):
        nxt = cps[i + 1][1] if i + 1 < len(cps) else len(data)
        if cp in (0x0A, 0x0B, 0x0C, 0x85, 0x2028, 0x2029):
            want[nxt] = "m"
        elif cp == 0x0D:
            if i + 1 < len(cps) and cps[i + 1][0] == 0x0A:
                want[nxt] = "x"
            else:
                want[nxt] = "m"
    errs = []
    got = dict(br)
    for o, k in want.items():
        if k == "x" and o in got:
            errs.append("break between CR and LF at %d" % o)
        if k == "m" and got.get(o) != "m":
            errs.append("offset %d after a hard break is %s, want Mandatory" % (o, got.get(o, "no break")))
    for o, k in br:
        if k == "m" and want.get(o) != "m" and o != len(data):
            errs.append("offset %d is Mandatory without a hard break" % o)
    return errs


def cmd_same(a, b):
    if open(a, "rb").read() == open(b, "rb").read():
        return 0
    la, lb = lines(a), lines(b)
    for i, (x, y) in enumerate(zip(la, lb)):
        if x != y:
            print("  first difference at line %d: %s | %s" % (i + 1, x[:100], y[:100]))
            break
    else:
        print("  length differs: %d vs %d lines" % (len(la), len(lb)))
    return 1


def cmd_invariants(cases_path, pion_path, quiet=False):
    cases = model.read_cases(cases_path)
    pion = lines(pion_path)
    bad = 0
    nbreaks = 0
    for (name, data), p in zip(cases, pion):
        br = parse_dump(p)
        nbreaks += len(br)
        errs = invariant_errors(data, br) + hard_kind_errors(data, br)
        if errs:
            bad += 1
            if bad <= 5:
                print("  invariant FAIL %s %s: %s" % (name, data.hex(), "; ".join(errs[:3])))
    if len(pion) != len(cases):
        print("  dump has %d lines for %d cases" % (len(pion), len(cases)))
        bad += 1
    if not quiet:
        print("  invariants (monotonic, code point boundaries, eot Mandatory, CR x LF, hard-break kinds): %d/%d cases ok, %d opportunities"
              % (len(cases) - bad, len(cases), nbreaks))
    return bad


def cmd_lbtest(ucd_dir, cases_path, pion_path):
    vec = model.parse_lbtest(ucd.read(ucd_dir, "LineBreakTest.txt").decode("utf-8"))
    pion = lines(pion_path)
    M = model.Model(ucd_dir)
    pos_fail = kind_fail = 0
    for (no, data, exp), p in zip(vec, pion):
        br = parse_dump(p)
        if [o for o, _ in br] != exp:
            pos_fail += 1
            if pos_fail <= 5:
                print("  LineBreakTest line %d FAIL: got %s want %s" % (no, p, exp))
        mk = [(o, k) for o, k, _ in M.breaks(data)]
        if [o for o, _ in mk] == [o for o, _ in br] and mk != br:
            kind_fail += 1
            if kind_fail <= 5:
                print("  LineBreakTest line %d kind FAIL: got %s model %s" % (no, p, model.fmt([(o, k, "") for o, k in mk])))
    nm = sum(1 for p in pion for o, k in parse_dump(p) if k == "m")
    na = sum(1 for p in pion for o, k in parse_dump(p) if k == "a")
    print("  LineBreakTest-16.0.0.txt: %d/%d vectors pass (break positions), kinds (Mandatory %d / Allowed %d) vs model: %d mismatches"
          % (len(vec) - pos_fail, len(vec), nm, na, kind_fail))
    inv = cmd_invariants(cases_path, pion_path)
    return 1 if pos_fail or kind_fail or inv or len(pion) != len(vec) else 0


def attribute(base, models, data, got):
    """Smallest set of findings whose emulation reproduces `got` exactly (None if none does)."""
    for r in range(1, len(FINDINGS) + 1):
        for combo in itertools.combinations(FINDINGS, r):
            if [(o, k) for o, k, _ in models[combo].breaks(data)] == got:
                return combo
    return None


def build_models(ucd_dir):
    base = model.Model(ucd_dir)
    models = {}
    for r in range(1, len(FINDINGS) + 1):
        for combo in itertools.combinations(FINDINGS, r):
            models[combo] = model.Model(ucd_dir, combo, props=base.P)
    return base, models


def cmd_model(ucd_dir, cases_path, pion_path):
    cases = model.read_cases(cases_path)
    pion = lines(pion_path)
    base, models = build_models(ucd_dir)
    agree = 0
    by = {}
    unexplained = 0
    for (name, data), p in zip(cases, pion):
        got = parse_dump(p)
        want = [(o, k) for o, k, _ in base.breaks(data)]
        if got == want:
            agree += 1
            continue
        combo = attribute(base, models, data, got)
        if combo is None:
            unexplained += 1
            if unexplained <= 10:
                print("  UNEXPLAINED %s %s: pion %s model %s" % (name, data.hex(), p, model.fmt(base.breaks(data), True)))
        else:
            by.setdefault(combo, []).append(name)
    print("  Pion == model (offsets + kinds): %d/%d; divergences explained by open findings: %s; unexplained: %d"
          % (agree, len(cases), ", ".join("%s x%d (e.g. %s)" % ("+".join(k), len(v), v[0]) for k, v in sorted(by.items())) or "none",
             unexplained))
    ids = sorted(set(i for k in by for i in k))
    if ids:
        print("FINDINGS " + " ".join(ids))
    return 1 if unexplained or len(pion) != len(cases) else 0


def sa_adjacent(base, data):
    """Byte offsets of boundaries with an SA (Line_Break=SA, raw) code point on either side."""
    cps = model.decode(data)
    out = set()
    for i in range(1, len(cps)):
        if base.P.lb[cps[i - 1][0]] == "SA" or base.P.lb[cps[i][0]] == "SA":
            out.add(cps[i][1])
    return out


def icu_lag_keys(ucd_dir, icu_lb_path, icu_model):
    """ICU 2.4.0 on the official vectors: (fails, total, {key: count}) where a key `<rule>:<A>><B>` is the
    boundary (as the ICU-data model decides it) at which ICU still differs once its 15.1 / SA data is
    reproduced: the rules ICU 2.4.0 has not caught up with, measured on Unicode's own vectors."""
    vec = model.parse_lbtest(ucd.read(ucd_dir, "LineBreakTest.txt").decode("utf-8"))
    icu = lines(icu_lb_path)
    keys = {}
    fails = 0
    for (no, data, exp), q in zip(vec, icu):
        got = [o for o, _ in parse_dump(q)]
        if got == exp:
            continue
        fails += 1
        mi = [o for o, _, _ in icu_model.breaks(data)]
        ks = icu_model.keys(data)
        for o in sorted(set(got) ^ set(mi)):
            k = ks.get(o, "?")
            keys[k] = keys.get(k, 0) + 1
    return fails, len(vec), keys


def icu_probe_keys(base, icu_model, probe_cases, probe_icu):
    """Keys at which ICU departs from the ICU-data model on the short icuprobe contexts (SA boundaries and the
    U+25CC-pair probes, which the model emulates explicitly, excluded)."""
    keys = {}
    for (name, data), q in zip(model.read_cases(probe_cases), lines(probe_icu)):
        if name.startswith("dd"):
            continue
        qo = [o for o, _ in parse_dump(q)]
        mi = [o for o, _, _ in icu_model.breaks(data)]
        if qo == mi:
            continue
        ks = icu_model.keys(data)
        sa = sa_adjacent(base, data)
        for o in sorted(set(qo) ^ set(mi)):
            if o not in sa:
                k = ks.get(o, "?")
                keys[k] = keys.get(k, 0) + 1
    return keys


def cmd_icu(ucd_dir, cases_path, pion_path, icu_path, icu_lb_path, lb_cases, probe_cases=None, probe_icu=None):
    base, models = build_models(ucd_dir)
    icu_model = model.Model(ucd_dir, ("ICU",), props=base.P)
    fails, total, lag = icu_lag_keys(ucd_dir, icu_lb_path, icu_model)
    if probe_cases:
        pk = icu_probe_keys(base, icu_model, probe_cases, probe_icu)
        print("  ICU 2.4.0 on the icuprobe contexts departs at: %s" % (", ".join("%s x%d" % kv for kv in sorted(pk.items())) or "none"))
        for k, v in pk.items():
            lag[k] = lag.get(k, 0) + v
    cases = model.read_cases(cases_path)
    pion = lines(pion_path)
    icu = lines(icu_path)
    same = 0
    data_lag = 0
    sa_cases = 0
    rule_lag = {}
    pion_find = {}
    unexplained = 0
    for (name, data), p, q in zip(cases, pion, icu):
        po = [o for o, _ in parse_dump(p)]
        qo = [o for o, _ in parse_dump(q)]
        if po == qo:
            same += 1
            continue
        mb = base.breaks(data)
        got = parse_dump(p)
        ok = True
        if [(o, k) for o, k, _ in mb] != got:
            combo = attribute(base, models, data, got)
            if combo is None:
                ok = False
            else:
                pion_find.setdefault(combo, []).append(name)  # ICU is still compared with the models below
        mi = [o for o, _, _ in icu_model.breaks(data)]
        if ok and qo != mi:
            ks = icu_model.keys(data)
            # UAX #14 LB1: SA (complex-context) breaks need dictionary / morphological analysis and are
            # implementation-defined; ICU's rule-only segmenter has its own SA handling. Boundaries touching an SA
            # code point are therefore not an ICU oracle (Pion's are checked against the model above).
            sa = sa_adjacent(base, data)
            diff = [ks.get(o, "?") for o in sorted(set(qo) ^ set(mi)) if o not in sa]
            if not diff:
                sa_cases += 1
            elif all(k in lag for k in diff):
                for k in set(diff):
                    rule_lag[k] = rule_lag.get(k, 0) + 1
            else:
                ok = False
        elif ok and qo != [o for o, _, _ in mb]:
            data_lag += 1
        if not ok:
            unexplained += 1
            if unexplained <= 10:
                print("  UNEXPLAINED %s %s: pion %s icu %s model %s icu-data model %s" % (
                    name, data.hex(), p, q, model.fmt(mb, True), ",".join(map(str, mi))))
    print("  ICU 2.4.0 on the official LineBreakTest-16.0.0 vectors: %d/%d pass; boundaries it still gets wrong with its own"
          " data / LB19 / LB21a reproduced: %s" % (total - fails, total, ", ".join("%s x%d" % kv for kv in sorted(lag.items())) or "none"))
    print("  Pion == ICU (offsets): %d/%d; ICU-side: ICU profile (15.1 data, pre-15.1 LB19, pre-16.0 LB21a, U+25CC pair) x%d, rule lag (keys ICU"
          " fails on the official vectors / icuprobe) x%d, only at SA boundaries x%d; Pion-side (open findings): %s; unexplained: %d"
          % (same, len(cases), data_lag, sum(rule_lag.values()), sa_cases,
             ", ".join("%s x%d" % ("+".join(k), len(v)) for k, v in sorted(pion_find.items())) or "none", unexplained))
    if rule_lag:
        print("    rule-lag keys: %s" % ", ".join("%s x%d" % kv for kv in sorted(rule_lag.items(), key=lambda x: -x[1])[:12]))
    ids = sorted(set(i for k in pion_find for i in k))
    if ids:
        print("FINDINGS " + " ".join(ids))
    return 1 if unexplained or len(pion) != len(cases) or len(icu) != len(cases) else 0


def main(argv):
    cmd = argv[0]
    if cmd == "same":
        return cmd_same(argv[1], argv[2])
    if cmd == "lbtest":
        return cmd_lbtest(argv[1], argv[2], argv[3])
    if cmd == "model":
        return cmd_model(argv[1], argv[2], argv[3])
    if cmd == "icu":
        return cmd_icu(*argv[1:9])
    if cmd == "invariants":
        return 1 if cmd_invariants(argv[1], argv[2]) else 0
    print("unknown command", cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
