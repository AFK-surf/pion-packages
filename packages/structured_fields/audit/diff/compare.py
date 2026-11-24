#!/usr/bin/env python3
"""RT-sfv comparisons of dump outputs (format: diff/model.py docstring).

  compare.py official <official.json> <out>              every official parsing vector against an implementation
  compare.py official_ser <official_ser.json> <out>      every official serialisation vector
  compare.py triple <cases> <pion> <model> <rust>        Pion vs the independent model vs Rust sfv 0.16.1
  compare.py ser <vectors> <pion> <model> <rust>         serializer: Pion vs model vs Rust sfv (hand-built ASTs)
  compare.py same <a> <b>                                byte-identical (4-mode determinism)

Every Pion-vs-model divergence must be explained by a finding id (rules below) or it is UNEXPLAINED (exit 1).
Explained ids are printed as `FINDINGS <id> ...`. Rust sfv deviations from the model are classified and listed
as information (they are never a Pion finding by themselves).
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model  # noqa: E402


def read_out(path):
    res = {}
    cur = None
    for ln in open(path, encoding="latin-1").read().split("\n"):
        if ln.startswith("="):
            cur = ln[1:]
            res[cur] = []
        elif ln and cur is not None:
            res[cur].append(ln)
    return {k: tuple(v) for k, v in res.items()}


def read_cases(path):
    out = {}
    for ln in open(path).read().split("\n"):
        if ln:
            name, typ, hx = ln.split("\t")
            out[name] = (typ, [bytes.fromhex(x) for x in hx.split(",")] if hx else [])
    return out


def read_vec(path):
    out = {}
    for ln in open(path).read().split("\n"):
        if ln:
            name, typ, t = ln.split("\t")
            out[name] = (typ, t)
    return out


def official(meta_path, out_path):
    meta = json.load(open(meta_path))
    got = read_out(out_path)
    bad = []
    n = {"pass": 0, "can_fail_rejected": 0}
    for name, m in sorted(meta.items()):
        g = got.get(name)
        if g is None:
            bad.append((name, m["title"], "missing"))
            continue
        if m["must_fail"]:
            if g == ("ERR",):
                n["pass"] += 1
            else:
                bad.append((name, m["title"], "must fail, got %s" % (g,)))
            continue
        if g == ("ERR",):
            if m["can_fail"]:
                n["can_fail_rejected"] += 1
                n["pass"] += 1
            else:
                bad.append((name, m["title"], "rejected"))
            continue
        want = ("P " + m["typed"], "S " + m["canonical"])
        if g == want:
            n["pass"] += 1
        else:
            bad.append((name, m["title"], "got %s want %s" % (g, want)))
    print("official parsing vectors: %d/%d pass (%d can_fail vectors rejected)" % (n["pass"], len(meta), n["can_fail_rejected"]))
    for b in bad:
        print("  FAIL %s (%s): %s" % (b[0], b[1], b[2][:300]))
    return bad


def official_ser(meta_path, out_path):
    meta = json.load(open(meta_path))
    got = read_out(out_path)
    bad = []
    for name, m in sorted(meta.items()):
        g = got.get(name)
        want = ("S ERR",) if m["must_fail"] else ("S " + m["canonical"],)
        if g != want:
            bad.append((name, m["title"], "got %s want %s" % (g, want)))
    print("official serialisation vectors: %d/%d pass" % (len(meta) - len(bad), len(meta)))
    for b in bad:
        print("  FAIL %s (%s): %s" % (b[0], b[1], b[2][:300]))
    return bad


# ------------------------------------------------------------------------------- finding explanations
def explain_parse(typ, lines, p, m):
    """Return the finding id that explains Pion output p differing from model output m, or None."""
    raw = b", ".join(lines)
    # P2-1: trailing HTAB after the last List / Dictionary member (RFC 9651 4.2.1 step 2.2 / 4.2.2 step 1.5)
    if typ in ("list", "dictionary") and p == ("ERR",) and m != ("ERR",) and raw.endswith(b"\t"):
        return "P2-1"
    return None


def has_dup(t, typ):
    ast = model.TP(t).top(typ)

    def d(ps):
        ks = [k for k, _ in ps]
        return len(set(ks)) != len(ks)

    def e(x):
        if d(x[2]):
            return True
        return x[0] == "inner" and any(d(i[2]) for i in x[1])

    if typ == "item":
        return e(ast)
    if typ == "list":
        return any(e(x) for x in ast)
    ks = [k for k, _ in ast]
    return len(set(ks)) != len(ks) or any(e(x) for _, x in ast)


def naive(t, typ):
    """Serialization of the AST with duplicate keys written out as they are (what the Pion serializer does)."""
    saved = model.uniq
    model.uniq = lambda keys: None
    try:
        return "S " + model.serialize(model.TP(t).top(typ), typ).encode().hex()
    except model.Fail:
        return "S ERR"
    finally:
        model.uniq = saved


def explain_ser(typ, t, p, m):
    if m == ("S ERR",) and has_dup(t, typ) and p == (naive(t, typ),):
        return "P2-2"
    return None


def rust_class_parse(typ, lines, r, m):
    return "sfv-differs"


def triple(cases_p, pion_p, model_p, rust_p, ser=False):
    cases = read_vec(cases_p) if ser else read_cases(cases_p)
    P, M, R = read_out(pion_p), read_out(model_p), read_out(rust_p)
    agree = explained = 0
    unexplained = []
    found = {}
    rust_dev = []
    pion_rust = 0
    for name, (typ, x) in cases.items():
        p, m, r = P.get(name), M.get(name), R.get(name)
        if p == m:
            agree += 1
        else:
            fid = explain_ser(typ, x, p, m) if ser else explain_parse(typ, x, p, m)
            if fid:
                explained += 1
                found.setdefault(fid, []).append(name)
            else:
                unexplained.append((name, typ, x, p, m, r))
        if r != m:
            rust_dev.append((name, typ, x, r, m))
        if r == p:
            pion_rust += 1
    kind = "serializer vectors" if ser else "inputs"
    print("%d %s: Pion = model %d, explained by findings %d, UNEXPLAINED %d; Pion = Rust sfv %d; Rust sfv != model %d"
          % (len(cases), kind, agree, explained, len(unexplained), pion_rust, len(rust_dev)))
    for fid, names in sorted(found.items()):
        print("  %s explains %d (e.g. %s)" % (fid, len(names), ", ".join(names[:3])))
    for u in unexplained[:40]:
        print("  UNEXPLAINED %s %s %s\n      pion=%s\n      model=%s\n      rust=%s" % (
            u[0], u[1], u[2] if ser else [l.hex() for l in u[2]], u[3], u[4], u[5]))
    for d in rust_dev[:15]:
        print("  sfv-vs-model %s %s %s rust=%s model=%s" % (d[0], d[1], d[2] if ser else [l[:60] for l in d[2]],
                                                            d[3], d[4]))
    if found:
        print("FINDINGS " + " ".join(sorted(found)))
    return 1 if unexplained else 0


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "official":
        sys.exit(1 if official(sys.argv[2], sys.argv[3]) else 0)
    if mode == "official_ser":
        sys.exit(1 if official_ser(sys.argv[2], sys.argv[3]) else 0)
    if mode == "triple":
        sys.exit(triple(*sys.argv[2:6]))
    if mode == "ser":
        sys.exit(triple(*sys.argv[2:6], ser=True))
    if mode == "same":
        a, b = open(sys.argv[2], "rb").read(), open(sys.argv[3], "rb").read()
        sys.exit(0 if a == b else 1)
