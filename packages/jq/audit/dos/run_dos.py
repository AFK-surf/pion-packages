#!/usr/bin/env python3
"""Security / DoS / complexity battery for packages/jq vs gojq v0.12.17.

usage: run_dos.py --pion BIN --gojq ORACLE --out DIR [--timeout 20] [--only NAME,...]

Each case runs in its own process (one-case corpus) so a crash, OOM or hang is
isolated. Wall time is measured around the process; peak RSS is sampled every
50 ms and the process is SIGKILLed above RT_MEM_CAP_MIB (default 3072).
Verdicts: ok | limit (JqLimits tripped: the intended outcome for bombs) | crash
(signal / non-zero exit) | timeout | oom_killed | err.
"""
import argparse, json, os, subprocess, sys, time

N = 50000


def deep(open_s, close_s, n, mid="1"):
    return open_s * n + mid + close_s * n


def big_obj(n):
    return json.dumps({f"k{i}": i for i in range(n)}, separators=(",", ":"))


CASES = [
    # name, query, input, kind  (kind: perf = must finish fast; bomb = must stay bounded)
    # --- quadratic update/assign operators (gojq's own "update performance" suite, 50k) ---
    ("upd_iter_array_50k", "[range(.)] | .[] |= . * 2 | add", str(N), "perf"),
    ("upd_iter_object_50k", "[range(.) | {key:tostring,value:.}] | from_entries | [.[] |= . * 2 | .[]] | add", str(N), "perf"),
    ("assign_iter_array_50k", "[range(.)] | .[] = 1 | add", str(N), "perf"),
    ("assign_index_range_50k", "[range(.)] | .[range(length)] = 1 | add", str(N), "perf"),
    ("upd_select_50k", "[range(.)] | (.[] | select(. % 2 > 0)) |= (. * 2) | add", str(N), "perf"),
    ("del_select_50k", "[range(.)] | del(.[] | select(. % 5 == 0)) | add", str(N), "perf"),
    ("map_values_50k", "[range(.)] | map_values(. + 1) | add", str(N), "perf"),
    ("upd_recurse_numbers_50k", "[range(.)] | (.. | numbers) |= . + 1 | add", str(N), "perf"),
    # --- the same quadratic paths fed by a big *input* (no [range] needed, default JqLimits) ---
    ("input_array_100k_update", ".[] |= . + 1 | length", json.dumps(list(range(100000))), "perf"),
    ("input_array_100k_assign", ".[] = 0 | length", json.dumps(list(range(100000))), "perf"),
    ("input_object_50k_update", ".[] |= . + 1 | length", big_obj(N), "perf"),
    # --- big-object / collection complexity ---
    ("obj_build_reduce_20k", "reduce range(20000) as $i ({}; .[\"k\\($i)\"] = $i) | length", "null", "perf"),
    ("obj_lookup_50k_keys", "[.k49999, .k0, .k25000] | add", big_obj(N), "perf"),
    ("obj_has_loop_5k_on_50k", ". as $o | [range(5000) | \"k\\(.)\" | select(. as $k | $o | has($k))] | length", big_obj(N), "perf"),
    ("obj_to_entries_50k", "to_entries | from_entries | length", big_obj(N), "perf"),
    ("obj_merge_50k", ". + . | length", big_obj(N), "perf"),
    ("obj_keys_50k", "keys | length", big_obj(N), "perf"),
    ("unique_50k", "[range(50000) | . % 977] | unique | length", "null", "perf"),
    ("group_by_50k", "[range(50000) | {k: (. % 101)}] | group_by(.k) | length", "null", "perf"),
    ("sort_by_50k", "[range(50000) | -.] | sort_by(.) | .[0]", "null", "perf"),
    ("contains_10k_arrays", "[range(10000)] | contains([range(9000;10000)])", "null", "perf"),
    ("inside_10k", "[range(5000)] | inside([range(10000)])", "null", "perf"),
    ("index_substr_1mb", "(\"ab\" * 500000) + \"c\" | index(\"c\")", "null", "perf"),
    ("indices_overlap_200k", "\"a\" * 200000 | indices(\"aa\") | length", "null", "perf"),
    ("split_200k", "\"a,\" * 200000 | split(\",\") | length", "null", "perf"),
    ("join_200k", "[range(200000) | tostring] | join(\",\") | length", "null", "perf"),
    ("tojson_200k", "[range(200000)] | tojson | length", "null", "perf"),
    ("regex_test_10k_calls", "[range(10000) | tostring | test(\"^[0-9]+5$\")] | map(select(.)) | length", "null", "perf"),
    ("regex_gsub_100k", "\"ab\" * 50000 | gsub(\"a\"; \"x\") | length", "null", "perf"),
    ("explode_implode_1mb", "\"é\" * 500000 | explode | implode | length", "null", "perf"),
    ("ascii_downcase_4mb", "\"ABCD\" * 1000000 | ascii_downcase | length", "null", "perf"),
    # --- regex ReDoS (gojq = RE2, linear) ---
    ("redos_nested_plus", "\"a\" * 30 + \"!\" | test(\"(a+)+$\")", "null", "perf"),
    ("redos_alt", "\"a\" * 30 + \"!\" | test(\"(a|a)*$\")", "null", "perf"),
    ("redos_dotstar", "\"x\" * 5000 | test(\"(.*a){10}\")", "null", "perf"),
    # --- memory / output bombs (must hit a JqLimit, not OOM) ---
    ("bomb_str_repeat_1e8", "\"a\" * 100000000 | length", "null", "bomb"),
    ("bomb_str_double_40", "reduce range(40) as $i (\"x\"; . + .) | length", "null", "bomb"),
    ("bomb_shared_array_doubling_tojson", "reduce range(40) as $i ([1]; [., .]) | tojson | length", "null", "bomb"),
    ("bomb_shared_array_doubling_flatten", "reduce range(40) as $i ([1]; [., .]) | flatten | length", "null", "bomb"),
    ("bomb_shared_array_doubling_output", "reduce range(26) as $i ([1]; [., .])", "null", "bomb"),
    ("bomb_shared_obj_doubling_tostring", "reduce range(40) as $i ({}; {a: ., b: .}) | tostring | length", "null", "bomb"),
    ("bomb_shared_paths", "reduce range(30) as $i ([1]; [., .]) | [paths] | length", "null", "bomb"),
    ("bomb_setpath_sparse_1e8", "null | setpath([100000000]; 1) | length", "null", "bomb"),
    ("bomb_index_assign_sparse_1e9", "null | .[1000000000] = 1 | length", "null", "bomb"),
    ("bomb_cartesian_1000x1000", "[range(1000) as $a | range(1000) | [$a, .]] | length", "null", "bomb"),
    ("bomb_combinations_10x10", "[[range(10)] | ., ., ., ., ., ., .] | [combinations] | length", "null", "bomb"),
    ("bomb_range_1e9", "[range(1000000000)] | length", "null", "bomb"),
    ("bomb_infinite_recursion", "def f: f; f", "null", "bomb"),
    ("bomb_infinite_stream_recursion", "def r: ., (. + 1 | r); [limit(100000000; 0 | r)] | length", "null", "bomb"),
    ("bomb_implode_1e7", "[range(10000000) | 65] | implode | length", "null", "bomb"),
    ("bomb_tostring_huge_array", "[range(1000000)] | tostring | length", "null", "bomb"),
    ("bomb_sort_1e6", "[range(1000000) | -.] | sort | .[0]", "null", "bomb"),
    ("bomb_base64_8mb", "\"abcdefgh\" * 1000000 | @base64 | @base64d | length", "null", "bomb"),
    # --- deep nesting / stack (Native + Wasm32 must not SIGSEGV) ---
    ("deep_json_input_10k", ". | tojson | length", deep("[", "]", 10000), "stack"),
    ("deep_json_input_100k", "length", deep("[", "]", 100000), "stack"),
    ("deep_json_object_10k", "[paths] | length", deep("{\"a\":", "}", 10000), "stack"),
    ("deep_parens_query_10k", deep("(", ")", 10000, "."), "null", "stack"),
    ("deep_array_literal_query_5k", deep("[", "]", 5000), "null", "stack"),
    ("deep_pipe_chain_10k", " | ".join(["."] * 10000), "null", "stack"),
    ("deep_comma_chain_20k", "[" + ",".join(["1"] * 20000) + "] | length", "null", "stack"),
    ("deep_plus_chain_20k", "+".join(["1"] * 20000), "null", "stack"),
    ("deep_field_chain_20k", "." + ".a" * 20000, "null", "stack"),
    ("deep_if_nesting_2k", "if true then " * 2000 + "1" + " end" * 2000, "null", "stack"),
    ("deep_def_recursion_250", "def f: if . < 250 then . + 1 | f else . end; 0 | f", "null", "stack"),
    ("deep_def_recursion_10k", "def f: if . < 10000 then . + 1 | f else . end; 0 | f", "null", "stack"),
    ("deep_build_nested_10k", "reduce range(10000) as $i (0; [.]) | tojson | length", "null", "stack"),
    ("deep_build_nested_100k_eq", "reduce range(100000) as $i (0; [.]) as $a | $a == $a", "null", "stack"),
    ("deep_recurse_built_10k", "reduce range(10000) as $i (0; [.]) | [..] | length", "null", "stack"),
    ("deep_string_interp_500", "\"\\(" * 500 + "1" + ")\"" * 500, "null", "stack"),
    ("deep_reduce_build_obj_tojson_5k", "reduce range(5000) as $i (null; {a: .}) | tojson | length", "null", "stack"),
]


MEM_CAP_MIB = int(os.environ.get("RT_MEM_CAP_MIB", "3072"))


def rss_mib(pid):
    try:
        o = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        return int(o) / 1024 if o else 0.0
    except Exception:
        return 0.0


def run_one(binp, mode_args, q, inp, timeout, tmp, env=None):
    """Run one case; sample RSS every 50 ms and SIGKILL above RT_MEM_CAP_MIB (shared machine safety)."""
    path = os.path.join(tmp, "dos_case.json")
    with open(path, "w") as f:
        json.dump([[q, inp]], f)
    outp, errp = os.path.join(tmp, "dos.out"), os.path.join(tmp, "dos.err")
    t0 = time.time()
    with open(outp, "wb") as fo, open(errp, "wb") as fe:
        p = subprocess.Popen([binp] + mode_args + [path], stdout=fo, stderr=fe, env=env)
        peak, verdict = 0.0, None
        while p.poll() is None:
            peak = max(peak, rss_mib(p.pid))
            if peak > MEM_CAP_MIB:
                p.kill(); verdict = "oom_killed"
            elif time.time() - t0 > timeout:
                p.kill(); verdict = "timeout"
            time.sleep(0.05)
    dt = time.time() - t0
    rec = {"s": round(dt, 3), "rss_mib": round(peak, 1), "rc": p.returncode}
    if verdict:
        rec["verdict"] = verdict
        return rec
    out = open(outp, "rb").read().decode(errors="replace").strip()
    err = open(errp, "rb").read().decode(errors="replace")
    if p.returncode != 0 or not out:
        rec["verdict"] = "crash"
        rec["stderr"] = err[-300:]
        return rec
    try:
        r = json.loads(out.splitlines()[0])
    except Exception:
        rec["verdict"] = "err"
        rec["raw"] = out[:200]
        return rec
    if "timeout" in r:
        rec["verdict"] = "timeout"
    elif "err" in r:
        rec["verdict"] = "limit" if r["err"].startswith("limit") else "err"
        rec["msg"] = r["err"][:160]
    else:
        rec["verdict"] = "ok"
        rec["out"] = [o[:80] for o in r["ok"][:3]]
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pion", required=True, action="append", help="NAME=BIN (first one is compared with gojq)")
    ap.add_argument("--gojq", default=None)
    ap.add_argument("--out", required=True)
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    only = set(x for x in a.only.split(",") if x)
    env = dict(os.environ, RT_TIMEOUT_MS=str(int(a.timeout * 1000)))
    rows = []
    for name, q, inp, kind in CASES:
        if only and name not in only:
            continue
        row = {"name": name, "kind": kind, "q": q[:160], "input_bytes": len(inp)}
        for spec in a.pion:
            mname, binp = spec.split("=", 1)
            parts = binp.split()
            row[mname] = run_one(parts[0], parts[1:], q, inp, a.timeout, a.out)
        if a.gojq:
            row["gojq"] = run_one(a.gojq, ["run"], q, inp, a.timeout + 5, a.out, env)
        rows.append(row)
        brief = {k: (v.get("verdict"), v.get("s"), v.get("rss_mib")) for k, v in row.items() if isinstance(v, dict)}
        print(f"{name:40s} {brief}", file=sys.stderr, flush=True)
    with open(os.path.join(a.out, "dos_results.json"), "w") as f:
        json.dump(rows, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
