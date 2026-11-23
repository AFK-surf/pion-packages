#!/usr/bin/env python3
"""Red-team audit orchestrator for packages/jsonpath (invoked by run_audit.sh with `python3 -I`).

Stages (all artifacts under --out, never inside the git worktree):
  1. build   : pion_driver + pion_probe in 4 modes (serial) and the locked Rust oracle
  2. cts     : official jsonpath-compliance-test-suite (vendored cts.json) — Pion vs CTS, Rust vs CTS
  3. rfc     : hand-written RFC 9535/9485/8259/6901/6902/7396 cases (cases.py) — Pion vs RFC expectation,
               Rust oracle shown as reference; Pion diff_patch output cross-applied by Rust json-patch
  4. modes   : byte-for-byte identical driver stdout across native_dbg/native_rel/wasm_dbg/wasm_rel
  5. probes  : DoS / stack-safety / amplification probes in all 4 modes (timeout, crash, RSS)
  6. bench   : (optional, --bench) W1 fairness split: regex vs non-regex queries
Exit status: 0 iff every gating check passes.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import threading
import time

AUDIT_DIR = os.path.dirname(os.path.abspath(__file__))
PKG_DIR = os.path.dirname(AUDIT_DIR)
REPO_ROOT = os.path.dirname(os.path.dirname(PKG_DIR))
sys.dont_write_bytecode = True  # keep the git worktree free of __pycache__
sys.path.insert(0, AUDIT_DIR)
import cases as CASES_MOD  # noqa: E402

MODES = ["native_dbg", "native_rel", "wasm_dbg", "wasm_rel"]
CTS_PIN = "20ebdcce5008c8a777ee9c80ad853ecf606950b5"
CTS_SHA256 = "f4ab5e3d3c17b40bf59cb0fa94425790b1401eb30c35a54902a119c65c851d36"

RESULTS = []  # (status, check, detail, finding)


def record(ok, check, detail="", finding=None, gate=True):
    status = "INFO" if not gate else ("PASS" if ok else "FAIL")
    RESULTS.append((status, check, detail, finding))
    tag = (" [" + finding + "]") if finding else ""
    print("%s %s%s %s" % (status, check, tag, detail), flush=True)


def log(msg):
    print("==> " + msg, flush=True)


# ------------------------------------------------------------------------------------------
# process helpers
# ------------------------------------------------------------------------------------------
def run_proc(argv, timeout, stdout_path=None, cwd=None, env=None):
    """Run argv; return dict(code, signal, timed_out, secs, max_rss_mb, stdout, stderr)."""
    out_f = open(stdout_path, "wb") if stdout_path else subprocess.PIPE
    t0 = time.time()
    p = subprocess.Popen(argv, stdout=out_f, stderr=subprocess.PIPE, cwd=cwd, env=env)
    timed_out = [False]

    def killer():
        timed_out[0] = True
        try:
            p.kill()
        except OSError:
            pass

    timer = threading.Timer(timeout, killer)
    timer.start()
    err_chunks = []

    def drain(stream, sink):
        for chunk in iter(lambda: stream.read(65536), b""):
            sink.append(chunk)

    out_chunks = []
    th = [threading.Thread(target=drain, args=(p.stderr, err_chunks))]
    if out_f is subprocess.PIPE:
        th.append(threading.Thread(target=drain, args=(p.stdout, out_chunks)))
    for t in th:
        t.start()
    _, status, ru = os.wait4(p.pid, 0)
    p.returncode = os.waitstatus_to_exitcode(status)
    for t in th:
        t.join()
    timer.cancel()
    if stdout_path:
        out_f.close()
    rss = ru.ru_maxrss / (1024.0 * 1024.0) if sys.platform == "darwin" else ru.ru_maxrss / 1024.0
    code = p.returncode
    return {
        "code": code,
        "signal": -code if code < 0 else 0,
        "timed_out": timed_out[0],
        "secs": time.time() - t0,
        "max_rss_mb": rss,
        "stdout": b"".join(out_chunks).decode("utf-8", "replace"),
        "stderr": b"".join(err_chunks).decode("utf-8", "replace"),
    }


def which(name):
    return shutil.which(name)


# ------------------------------------------------------------------------------------------
# build
# ------------------------------------------------------------------------------------------
def build_all(args):
    pionc = args.pionc
    bins = {}
    for prog in ["pion_driver", "pion_probe"]:
        for mode in MODES:
            out = os.path.join(args.out, "bin", "%s.%s%s" % (prog, mode, ".wasm" if mode.startswith("wasm") else ""))
            argv = [pionc, "build"]
            if mode.endswith("rel"):
                argv.append("--release")
            if mode.startswith("wasm"):
                argv += ["--target", "wasm32"]
            argv += ["-o", out, os.path.join(AUDIT_DIR, prog)]
            log("build %s %s" % (prog, mode))
            r = run_proc(argv, 600)
            ok = r["code"] == 0 and os.path.exists(out)
            record(ok, "build.%s.%s" % (prog, mode), "" if ok else (r["stderr"][-2000:] or r["stdout"][-2000:]))
            if not ok:
                return None
            bins[(prog, mode)] = out
    log("build rust oracle (cargo --locked --release)")
    env = dict(os.environ)
    env["CARGO_TARGET_DIR"] = os.path.join(args.out, "rust-target")
    r = run_proc([args.cargo, "build", "--locked", "--release", "--quiet",
                  "--manifest-path", os.path.join(AUDIT_DIR, "rust_oracle", "Cargo.toml")], 900, env=env)
    exe = os.path.join(args.out, "rust-target", "release", "jsonpath_audit_oracle")
    ok = r["code"] == 0 and os.path.exists(exe)
    record(ok, "build.rust_oracle", "" if ok else r["stderr"][-3000:])
    if not ok:
        return None
    bins["rust"] = exe
    return bins


def mode_argv(bins, prog, mode, wasm_rt, node):
    b = bins[(prog, mode)]
    if mode.startswith("wasm"):
        return [node, wasm_rt, b]
    return [b]


# ------------------------------------------------------------------------------------------
# JSON comparison helpers
# ------------------------------------------------------------------------------------------
def jeq(a, b):
    """RFC 8259 value equality: numbers compared mathematically, bools are not numbers."""
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if type(a) is not type(b):
        return False
    if isinstance(a, list):
        return len(a) == len(b) and all(jeq(x, y) for x, y in zip(a, b))
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(jeq(a[k], b[k]) for k in a)
    return a == b


def loads_exact(text):
    return json.loads(text)


def float_bits(x):
    return struct.pack("<d", float(x))


def case_line(c):
    """Serialize a case; `<key>_text` fields are spliced in verbatim (duplicate keys, big ints)."""
    base = {k: v for k, v in c.items() if not k.endswith("_text") and (k + "_text") not in c}
    s = json.dumps(base, ensure_ascii=False, separators=(",", ":"))
    for k, v in c.items():
        if k.endswith("_text") and k != "text":
            s = s[:-1] + ',"%s":%s}' % (k[:-5], v)
    return s


def read_jsonl(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    out.append({"ok": False, "kind": "UnparseableOutput", "raw": line[:200]})
    return out


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


# ------------------------------------------------------------------------------------------
# CTS
# ------------------------------------------------------------------------------------------
def cts_check(t, r):
    if t.get("invalid_selector"):
        return (not r.get("ok")), "expected invalid selector"
    if not r.get("ok"):
        return False, "rejected valid selector (%s)" % r.get("kind")
    try:
        vals = json.loads(r["values"])
    except (ValueError, KeyError):
        return False, "unparseable values"
    paths = r.get("paths", [])
    if not r.get("values_paths_consistent", True):
        return False, "query() and query_with_paths() disagree"
    if "result" in t:
        if not jeq(vals, t["result"]):
            return False, "values: expected %s got %s" % (json.dumps(t["result"], ensure_ascii=False)[:160], r["values"][:160])
        if "result_paths" in t and paths != t["result_paths"]:
            return False, "paths: expected %s got %s" % (t["result_paths"], paths)
        return True, ""
    for i, v in enumerate(t["results"]):
        if jeq(vals, v) and ("results_paths" not in t or paths == t["results_paths"][i]):
            return True, ""
    return False, "none of the %d permitted results matched (got %s)" % (len(t["results"]), r["values"][:160])


def cts_finding(t):
    sel = t["selector"]
    if ("match(" in sel or "search(" in sel) and ("^" in sel or "$'" in sel or '$"' in sel):
        return "P1-2"
    return "NEW"


def stage_cts(args, bins, primary):
    cts_path = os.path.join(AUDIT_DIR, "cts", "cts.json")
    record(sha256(cts_path) == CTS_SHA256, "cts.pinned_sha256", "cts.json @ %s" % CTS_PIN)
    tests = json.load(open(cts_path, encoding="utf-8"))["tests"]
    case_path = os.path.join(args.out, "cases_cts.jsonl")
    with open(case_path, "w", encoding="utf-8") as f:
        for i, t in enumerate(tests):
            f.write(json.dumps({"id": "cts:%d" % i, "op": "query", "selector": t["selector"],
                                "document": t.get("document")}, ensure_ascii=False) + "\n")
    outs = {}
    for name, argv in [("pion", primary), ("rust", [bins["rust"]])]:
        out = os.path.join(args.out, "out_cts_%s.jsonl" % name)
        r = run_proc(argv + [case_path], 300, stdout_path=out)
        if r["code"] != 0 or r["timed_out"]:
            record(False, "cts.run.%s" % name, "exit=%s timeout=%s %s" % (r["code"], r["timed_out"], r["stderr"][-500:]))
        outs[name] = read_jsonl(out)
    stats = {}
    for name in ["pion", "rust"]:
        res = outs[name]
        fails = []
        for i, t in enumerate(tests):
            r = res[i] if i < len(res) else {"ok": False, "kind": "missing output"}
            ok, why = cts_check(t, r)
            if not ok:
                fails.append((i, t, why))
        stats[name] = (len(tests) - len(fails), len(tests), fails)
    p_pass, total, p_fails = stats["pion"]
    r_pass, _, r_fails = stats["rust"]
    for i, t, why in p_fails:
        record(False, "cts.pion[%d] %s" % (i, t["name"]), "%s | selector=%s" % (why, json.dumps(t["selector"], ensure_ascii=False)),
               finding=cts_finding(t))
    record(not p_fails, "cts.pion.total", "%d/%d (%.2f%%)" % (p_pass, total, 100.0 * p_pass / total),
           finding=",".join(sorted(set(cts_finding(t) for _, t, _ in p_fails))) or None)
    rv_pass = sum(1 for i, t, why in r_fails if why.startswith("paths"))
    record(True, "cts.rust_reference.total",
           "%d/%d (%.2f%%); %d of its %d failures are Normalized-Path escaping only" % (
               r_pass, total, 100.0 * r_pass / total, rv_pass, len(r_fails)), gate=False)
    for i, t, why in r_fails:
        record(True, "cts.rust_reference[%d] %s" % (i, t["name"]), why[:200], gate=False)
    return stats


# ------------------------------------------------------------------------------------------
# RFC differential
# ------------------------------------------------------------------------------------------
def check_expect(c, exp, r):
    op = c["op"]
    if op == "query":
        if exp.get("invalid"):
            return (not r.get("ok")), "expected invalid selector, got %s" % (r.get("values") or r.get("kind"))
        if not r.get("ok"):
            return False, "query failed: %s" % r.get("kind")
        vals = json.loads(r["values"])
        if not r.get("values_paths_consistent", True):
            return False, "query() vs query_with_paths() disagree"
        if not jeq(vals, exp["values"]):
            return False, "values expected %s got %s" % (json.dumps(exp["values"], ensure_ascii=False)[:200], r["values"][:200])
        if r.get("paths") != exp["paths"]:
            return False, "paths expected %s got %s" % (exp["paths"], r.get("paths"))
        return True, ""
    if op == "parse":
        if exp.get("error"):
            return (not r.get("ok")), "expected parse error, got %s" % r.get("text", "")[:120]
        if not r.get("ok"):
            return False, "parse failed: %s" % r.get("kind")
        if not r.get("roundtrip"):
            return False, "parse(to_json_string(v)) != v or unstable output"
        text = r["text"]
        if "value" in exp:
            got = loads_exact(text)
            if not jeq(got, exp["value"]):
                return False, "expected %s got %s" % (json.dumps(exp["value"])[:200], text[:200])
        if "floats" in exp:
            got = json.loads(text, parse_int=float, parse_float=float)
            bad = [(e, g) for e, g in zip(exp["floats"], got) if float_bits(e) != float_bits(g)]
            if len(got) != len(exp["floats"]) or bad:
                return False, "%d/%d doubles not bit-exact, e.g. %s" % (len(bad), len(exp["floats"]), bad[:3])
        if exp.get("text_unique_keys"):
            dup = []

            def hook(pairs):
                ks = [k for k, _ in pairs]
                if len(ks) != len(set(ks)):
                    dup.append(ks)
                return dict(pairs)
            json.loads(text, object_pairs_hook=hook)
            if dup:
                return False, "serialized output has duplicate member names: %s" % text[:120]
        return True, ""
    if op == "pointer":
        if exp.get("error"):
            return (not r.get("ok")), "expected pointer syntax error, got %s" % r
        if not r.get("ok"):
            return False, "pointer rejected: %s" % r.get("kind")
        if "found" in exp and not exp["found"]:
            return (not r.get("found")), "expected not found, got %s" % r.get("value")
        if not r.get("found"):
            return False, "expected %s, not found" % json.dumps(exp["value"])[:120]
        return jeq(json.loads(r["value"]), exp["value"]), "value %s" % r.get("value", "")[:120]
    if op == "patch":
        if exp.get("error"):
            if r.get("ok"):
                return False, "expected error, got %s" % r.get("value", "")[:160]
            if not r.get("doc_unchanged", True):
                return False, "error but input document was mutated (atomicity)"
            return True, ""
        if not r.get("ok"):
            return False, "patch failed: %s" % r.get("kind")
        return jeq(json.loads(r["value"]), exp["value"]), "got %s" % r.get("value", "")[:160]
    if op == "merge":
        return jeq(json.loads(r["value"]), exp["value"]), "got %s" % r.get("value", "")[:160]
    if op == "eq":
        return r.get("equal") == exp["equal"], "equal=%s" % r.get("equal")
    if op == "diff":
        if not r.get("ok"):
            return False, "applying own diff failed: %s (patch %s)" % (r.get("kind"), r.get("patch", "")[:160])
        if not r.get("roundtrip_eq") or not jeq(json.loads(r["applied"]), c["after"]):
            return False, "apply(before, diff) != after: %s" % r.get("applied", "")[:160]
        return True, ""
    return False, "unknown op"


def stage_rfc(args, bins, primary):
    case_path = os.path.join(args.out, "cases_rfc.jsonl")
    cs = CASES_MOD.CASES
    with open(case_path, "w", encoding="utf-8") as f:
        for e in cs:
            f.write(case_line(e["case"]) + "\n")
    outs = {}
    for name, argv in [("pion", primary), ("rust", [bins["rust"]])]:
        out = os.path.join(args.out, "out_rfc_%s.jsonl" % name)
        r = run_proc(argv + [case_path], 300, stdout_path=out)
        if r["code"] != 0 or r["timed_out"]:
            record(False, "rfc.run.%s" % name, "exit=%s timeout=%s %s" % (r["code"], r["timed_out"], r["stderr"][-500:]))
        outs[name] = read_jsonl(out)
    p_ok = 0
    r_ok = 0
    for i, e in enumerate(cs):
        c, exp = e["case"], e["expect"]
        pr = outs["pion"][i] if i < len(outs["pion"]) else {"ok": False, "kind": "missing"}
        rr = outs["rust"][i] if i < len(outs["rust"]) else {"ok": False, "kind": "missing"}
        try:
            ok, why = check_expect(c, exp, pr)
        except Exception as ex:  # noqa: BLE001
            ok, why = False, "checker exception %r on %s" % (ex, json.dumps(pr)[:200])
        try:
            rok, rwhy = check_expect(c, exp, rr)
        except Exception as ex:  # noqa: BLE001
            rok, rwhy = False, "checker exception %r" % ex
        p_ok += ok
        r_ok += rok
        fid = e["finding"] or ("NEW" if not ok else None)
        record(ok, "rfc.%s" % c["id"], "" if ok else (why + (" | rust-oracle: %s" % ("agrees with RFC" if rok else rwhy[:120]))),
               finding=fid if not ok else None, gate=e["gate"])
        if not rok:
            record(True, "rfc.rust_reference.%s" % c["id"], rwhy[:200], gate=False)
    record(True, "rfc.summary", "pion %d/%d, rust reference %d/%d" % (p_ok, len(cs), r_ok, len(cs)), gate=False)

    # Cross-apply: Rust json-patch must accept Pion's diff_patch output and reach `after`.
    xs = []
    for i, e in enumerate(cs):
        c = e["case"]
        pr = outs["pion"][i] if i < len(outs["pion"]) else {}
        if c["op"] == "diff" and "patch" in pr:
            xs.append({"id": "x." + c["id"], "op": "patch", "document": c["before"], "patch": json.loads(pr["patch"]),
                       "_after": c["after"]})
    xpath = os.path.join(args.out, "cases_xdiff.jsonl")
    with open(xpath, "w", encoding="utf-8") as f:
        for x in xs:
            f.write(json.dumps({k: v for k, v in x.items() if k != "_after"}, ensure_ascii=False) + "\n")
    out = os.path.join(args.out, "out_xdiff_rust.jsonl")
    run_proc([bins["rust"], xpath], 120, stdout_path=out)
    rres = read_jsonl(out)
    for x, rr in zip(xs, rres):
        ok = rr.get("ok") and jeq(json.loads(rr["value"]), x["_after"])
        record(bool(ok), "rfc.cross_apply.%s" % x["id"], "" if ok else "Rust json-patch rejected/mis-applied Pion diff: %s" % json.dumps(rr)[:200],
               finding=None if ok else "NEW")
    return case_path


# ------------------------------------------------------------------------------------------
# 4-mode consistency
# ------------------------------------------------------------------------------------------
def stage_modes(args, bins, wasm_rt, node, case_paths):
    for cp in case_paths:
        digests = {}
        for mode in MODES:
            out = os.path.join(args.out, "modes_%s_%s.jsonl" % (os.path.basename(cp).split(".")[0], mode))
            r = run_proc(mode_argv(bins, "pion_driver", mode, wasm_rt, node) + [cp], 600, stdout_path=out)
            ok = r["code"] == 0 and not r["timed_out"]
            record(ok, "modes.%s.%s.exit" % (os.path.basename(cp), mode),
                   "" if ok else "exit=%s timeout=%s %s" % (r["code"], r["timed_out"], r["stderr"][-400:]))
            digests[mode] = sha256(out)
        same = len(set(digests.values())) == 1
        record(same, "modes.%s.stdout_sha256_identical" % os.path.basename(cp),
               digests[MODES[0]] if same else json.dumps(digests))


# ------------------------------------------------------------------------------------------
# DoS / stack-safety probes
# ------------------------------------------------------------------------------------------
OK_OR_LIMIT = r"^(ok.*|err LimitExceeded)$"
PROBES = [
    # (probe, arg, timeout_s (native, wasm), max_rss_mb (native only) or None, finding, {step: regex})
    ("deep_array", 20000, (30, 60), 256, None, {
        "parse_default": r"^err LimitExceeded$", "parse_raised": r"^ok$", "to_json": r"^ok same$",
        "json_value_eq": r"^ok true$", "query_descendant": r"^ok n=20000$",
        "query_descendant_default_limits": r"^err LimitExceeded$"}),
    ("deep_object", 1000, (30, 60), 256, None, {
        "parse_raised": r"^ok$", "pointer_resolve": r"^ok found$", "pointer_resolve_mut": r"^ok len=6001$",
        "patch_replace_deep": r"^ok len=6001$", "patch_add_deep": r"^ok len=6001$",
        "patch_add_deep_default_limits": OK_OR_LIMIT, "patch_remove_deep_default_limits": OK_OR_LIMIT,
        "patch_test_deep_default_limits": OK_OR_LIMIT, "patch_copy_deep_default_limits": OK_OR_LIMIT,
        "diff_patch": r"^ok ops=\d+$", "diff_apply_roundtrip": r"^(ok eq|err LimitExceeded)$",
        "merge_patch_with_limits": r"^ok len=6001$", "merge_patch_with_default_limits": OK_OR_LIMIT,
        "merge_patch_default_correct": r"^ok eq$",
        "merge_patch_default_null_leaf": (r"^ok deleted$", "P2-1")}),
    ("deep_object", 20000, (60, 120), 512, "P0-1", {
        "parse_raised": r"^ok$", "pointer_resolve": r"^ok found$", "pointer_resolve_mut": OK_OR_LIMIT,
        "patch_replace_deep": OK_OR_LIMIT, "patch_add_deep": OK_OR_LIMIT,
        "patch_remove_deep_default_limits": OK_OR_LIMIT, "patch_test_deep_default_limits": OK_OR_LIMIT,
        "patch_copy_deep_default_limits": OK_OR_LIMIT, "diff_apply_roundtrip": r"^(ok eq|err LimitExceeded)$",
        "merge_patch_with_limits": OK_OR_LIMIT, "merge_patch_default_correct": r"^ok eq$",
        "merge_patch_default_null_leaf": (r"^ok deleted$", "P2-1")}),
    ("deep_via_copy", 20, (30, 60), 256, "P0-1", {
        "grow_via_copy": OK_OR_LIMIT, "remove_deep": r"^(ok.*|err (LimitExceeded|PatchError|PointerError))$",
        "replace_deep": r"^(ok.*|err (LimitExceeded|PatchError|PointerError))$", "merge_patch_on_grown": r"^ok eq$"}),
    ("deep_via_copy", 1000, (30, 60), 512, "P0-1", {
        "grow_via_copy": OK_OR_LIMIT, "remove_deep": r"^(ok.*|err (LimitExceeded|PatchError|PointerError))$",
        "replace_deep": r"^(ok.*|err (LimitExceeded|PatchError|PointerError))$", "merge_patch_on_grown": r"^ok eq$"}),
    ("copy_bomb", 64, (20, 40), 1024, "P0-2", {"apply_copy_bomb": OK_OR_LIMIT}),
    ("copy_bomb_test", 30, (20, 40), 1024, "P0-2", {"apply_copy_bomb": OK_OR_LIMIT}),
    ("query_amp", 0, (30, 60), 512, None, {
        "desc4": OK_OR_LIMIT, "desc4_paths": OK_OR_LIMIT, "dup_wildcards": OK_OR_LIMIT, "dup_index": OK_OR_LIMIT,
        "dup_slice": OK_OR_LIMIT, "dup_name": OK_OR_LIMIT, "huge_slice": r"^ok n=10$", "huge_slice_max": r"^ok n=10$",
        "huge_neg_step": r"^ok n=1$", "int64_min_slice": r"^err ParseError$", "nested_filter": OK_OR_LIMIT,
        "long_index_chain": OK_OR_LIMIT, "deep_parens": r"^(ok.*|err (LimitExceeded|ParseError))$",
        "deep_funcs": r"^(ok.*|err (LimitExceeded|ParseError|TypeError))$",
        "deep_brackets": r"^(ok.*|err (LimitExceeded|ParseError))$", "many_or": OK_OR_LIMIT,
        "filter_root_scan": OK_OR_LIMIT, "filter_root_desc_scan": OK_OR_LIMIT}),
    ("regex", 0, (30, 60), 1024, None, {
        "nested_counted_3x1000": OK_OR_LIMIT, "nested_counted_2x100000": OK_OR_LIMIT, "counted_100000": OK_OR_LIMIT,
        "class_counted": OK_OR_LIMIT, "dynamic_nested_counted": OK_OR_LIMIT}),
    ("wide_parse", 100000, (20, 40), 512, None, {"parse_wide_object": r"^ok len=\d+$"}),
    ("wide_eq", 100000, (10, 20), 512, "P1-1", {"eq_wide_object": r"^ok true$"}),
    ("wide_test_op", 100000, (10, 20), 512, "P1-1", {"patch_test_wide": r"^ok len=\d+$"}),
    ("wide_diff", 100000, (10, 20), 512, "P1-1", {"diff_wide_object": r"^ok ops=100000$"}),
    ("wide_apply", 100000, (10, 20), 512, "P2-4", {"apply_wide_adds": r"^ok len=\d+$"}),
    ("deep_paths", 20000, (30, 60), 256, "P2-5", {"query_paths_descendant": r"^(ok n=20000|err LimitExceeded)$"}),
]


def stage_probes(args, bins, wasm_rt, node):
    for probe, arg, (t_native, t_wasm), max_rss, finding, steps in PROBES:
        outputs = {}
        for mode in MODES:
            wasm = mode.startswith("wasm")
            argv = mode_argv(bins, "pion_probe", mode, wasm_rt, node) + [probe, str(arg)]
            r = run_proc(argv, t_wasm if wasm else t_native)
            name = "probe.%s(%s).%s" % (probe, arg, mode)
            lines = r["stdout"].splitlines()
            got = {}
            for ln in lines:
                m = re.match(r"^step=(\S+) (.*)$", ln)
                if m:
                    got[m.group(1)] = m.group(2)
            done = ("probe=%s done" % probe) in lines
            problems = []
            if r["timed_out"]:
                problems.append("TIMEOUT after %ds" % (t_wasm if wasm else t_native))
            elif r["signal"]:
                problems.append("killed by signal %d (%s)" % (r["signal"], {11: "SIGSEGV", 6: "SIGABRT", 9: "SIGKILL", 10: "SIGBUS"}.get(r["signal"], "?")))
            elif r["code"] != 0:
                tail = [x for x in r["stderr"].splitlines() if x.strip()][:1]
                problems.append("exit=%d %s" % (r["code"], tail[0][:120] if tail else ""))
            if not done and not problems:
                problems.append("did not reach done")
            step_findings = set()
            for step, spec in steps.items():
                rx, sf = (spec if isinstance(spec, tuple) else (spec, None))
                if step not in got:
                    if not problems:
                        problems.append("missing step %s" % step)
                    continue
                if not re.match(rx, got[step]):
                    problems.append("%s=%r !~ %s" % (step, got[step], rx))
                    if sf:
                        step_findings.add(sf)
            # wasm runs are measured including the node runtime itself (~60-100 MiB baseline)
            rss_cap = None if max_rss is None else (max_rss + 160 if wasm else max_rss)
            if rss_cap is not None and r["max_rss_mb"] > rss_cap and not r["timed_out"]:
                problems.append("peak RSS %.0f MiB > %d MiB" % (r["max_rss_mb"], rss_cap))
            last = lines[-1] if lines else "<no output>"
            fid = None
            if problems:
                only_steps = all("!~" in p for p in problems)
                fid = ",".join(sorted(step_findings)) if (only_steps and step_findings) else (finding or "NEW")
            record(not problems, name, ("%.2fs rss=%.0fMiB" % (r["secs"], r["max_rss_mb"])) +
                   ("" if not problems else " | " + "; ".join(problems) + " | last: " + last[:80]), finding=fid)
            outputs[mode] = [ln for ln in lines]
        complete = [m for m in MODES if outputs[m] and outputs[m][-1] == "probe=%s done" % probe]
        if len(complete) >= 2:
            same = len(set("\n".join(outputs[m]) for m in complete)) == 1
            record(same, "probe.%s(%s).modes_identical" % (probe, arg),
                   "over %s" % ",".join(complete) if same else json.dumps({m: outputs[m] for m in complete})[:400])


# ------------------------------------------------------------------------------------------
# optional benchmark fairness split
# ------------------------------------------------------------------------------------------
def stage_bench(args):
    bench = os.path.join(PKG_DIR, "bench")
    bdir = os.path.join(args.out, "bench")
    os.makedirs(bdir, exist_ok=True)
    run_proc([sys.executable, "-I", os.path.join(bench, "gen_data.py"), bdir], 120)
    pion_bin = os.path.join(bdir, "pion_jsonpath")
    run_proc([args.pionc, "build", "--release", "-o", pion_bin, os.path.join(bench, "pion_bench")], 600)
    env = dict(os.environ)
    env["CARGO_TARGET_DIR"] = os.path.join(bdir, "rust-target")
    run_proc([args.cargo, "build", "--locked", "--release", "--quiet", "--manifest-path",
              os.path.join(bench, "rust_bench", "Cargo.toml")], 900, env=env)
    rust_bin = os.path.join(bdir, "rust-target", "release", "jsonpath_bench_rust")
    queries = [q for q in open(os.path.join(bdir, "w1_queries.txt")).read().splitlines() if q]
    groups = {
        "all": queries,
        "regex_only": [q for q in queries if "match(" in q or "search(" in q],
        "no_regex": [q for q in queries if "match(" not in q and "search(" not in q],
    }
    iters = "20"
    for g, qs in groups.items():
        qf = os.path.join(bdir, "w1_%s.txt" % g)
        open(qf, "w").write("\n".join(qs) + "\n")
        times = {}
        outs = {}
        for impl, exe in [("pion", pion_bin), ("rust", rust_bin)]:
            best = []
            for _ in range(5):
                r = run_proc([exe, "w1", os.path.join(bdir, "w1_k8s.json"), qf, iters], 120)
                best.append(r["secs"])
                outs[impl] = r["stdout"]
            best.sort()
            times[impl] = best[len(best) // 2]
        record(outs["pion"] == outs["rust"], "bench.w1_%s" % g,
               "median pion=%.1fms rust=%.1fms pion_speedup=%.2fx (%d queries x %s iters) stdout_identical=%s" % (
                   times["pion"] * 1e3, times["rust"] * 1e3, times["rust"] / times["pion"], len(qs), iters,
                   outs["pion"] == outs["rust"]), gate=False)


# ------------------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--pionc", default=os.environ.get("PIONC") or which("pionc") or os.path.expanduser("~/.pion/bin/pionc"))
    ap.add_argument("--cargo", default=os.environ.get("CARGO") or which("cargo") or os.path.expanduser("~/.cargo/bin/cargo"))
    ap.add_argument("--node", default=os.environ.get("NODE") or which("node") or "node")
    ap.add_argument("--bench", action="store_true")
    ap.add_argument("--skip-probes", action="store_true")
    args = ap.parse_args()
    os.makedirs(os.path.join(args.out, "bin"), exist_ok=True)
    wasm_rt = os.environ.get("PION_WASM_RT") or os.path.join(
        os.path.dirname(os.path.dirname(os.path.realpath(args.pionc))), "share", "pion", "pion_wasm_rt.mjs")
    log("pionc=%s cargo=%s node=%s wasm_rt=%s out=%s" % (args.pionc, args.cargo, args.node, wasm_rt, args.out))
    r = run_proc([args.pionc, "--version"], 30)
    log("pionc version: " + r["stdout"].strip())

    bins = build_all(args)
    if bins is None:
        summarize(args)
        return 1
    primary = mode_argv(bins, "pion_driver", "native_rel", wasm_rt, args.node)
    log("stage: official CTS")
    stage_cts(args, bins, primary)
    log("stage: RFC differential")
    rfc_cases = stage_rfc(args, bins, primary)
    log("stage: 4-mode byte-for-byte consistency")
    stage_modes(args, bins, wasm_rt, args.node, [os.path.join(args.out, "cases_cts.jsonl"), rfc_cases])
    if not args.skip_probes:
        log("stage: DoS / stack-safety probes (4 modes, serial)")
        stage_probes(args, bins, wasm_rt, args.node)
    if args.bench:
        log("stage: benchmark fairness split (informational)")
        stage_bench(args)
    return summarize(args)


def summarize(args):
    fails = [x for x in RESULTS if x[0] == "FAIL"]
    passes = [x for x in RESULTS if x[0] == "PASS"]
    infos = [x for x in RESULTS if x[0] == "INFO"]
    print("")
    print("=" * 100)
    print("SUMMARY: %d PASS, %d FAIL, %d INFO (non-gating)" % (len(passes), len(fails), len(infos)))
    by = {}
    for st, check, detail, fid in fails:
        for f in (fid or "NEW").split(","):
            by.setdefault(f, []).append(check)
    for f in sorted(by):
        print("  FAIL %-5s %3d check(s): %s" % (f, len(by[f]), ", ".join(by[f][:6]) + (" ..." if len(by[f]) > 6 else "")))
    with open(os.path.join(args.out, "summary.json"), "w") as fp:
        json.dump([{"status": s, "check": c, "detail": d, "finding": f} for s, c, d, f in RESULTS], fp, indent=1)
    print("RESULT: %s (details: %s)" % ("PASS" if not fails else "FAIL", os.path.join(args.out, "summary.json")))
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
