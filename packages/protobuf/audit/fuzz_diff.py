#!/usr/bin/env python3
"""Mutation fuzz differential: Pion native vs Pion wasm32 vs Go (dynamicpb/protojson, protocompile).

usage: fuzz_diff.py <pion_probe> <pion_probe_wasm> <go_oracle> <workdir> [wire_cases] [schema_cases] [seed]

  * wire: every seed vector of diff_vectors.py section B (+ 60 OTel spans) is mutated
    (bit flips, byte edits, truncation, splicing, length-byte skew, injected tags) and decoded by
    decode_dynamic -> to_proto3_json -> encode_dynamic on all three.
  * schema: the .proto sources of section C are mutated at the token level and parsed.
Pass criteria for Pion itself: zero crashes / traps / timeouts and zero native-vs-wasm32 differences.
Pion-vs-Go differences are classified and the first examples of each class are printed.
"""
import json
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import diff_vectors as dv  # noqa: E402
from pbvec import json_norm, run_lines, write  # noqa: E402

PION, WASM, GO, WORK = sys.argv[1:5]
N_WIRE = int(sys.argv[5]) if len(sys.argv) > 5 else 6000
N_SCHEMA = int(sys.argv[6]) if len(sys.argv) > 6 else 2000
SEED = int(sys.argv[7]) if len(sys.argv) > 7 else 20261123
os.makedirs(WORK, exist_ok=True)
rng = random.Random(SEED)

SPANS = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bench", "gen_corpus.py")).read()
ns = {"__name__": "gen_corpus_mod"}
exec(compile(SPANS, "gen_corpus.py", "exec"), ns)
SPAN_PROTO = """syntax = "proto3";
message KeyValue { string key = 1; string str_value = 2; int64 int_value = 3; }
message SpanEvent { uint64 time_unix_nano = 1; string name = 2; int32 dropped_attributes = 3; }
message Span { bytes trace_id = 1; bytes span_id = 2; string name = 3; int32 kind = 4;
  uint64 start_time_unix_nano = 5; uint64 end_time_unix_nano = 6; repeated KeyValue attributes = 7;
  repeated SpanEvent events = 8; int32 status_code = 9; string status_message = 10; }
"""


def rb(n):
    return bytes(rng.randrange(256) for _ in range(n))


def mutate(b, pool):
    b = bytearray(b)
    for _ in range(rng.choice((1, 1, 1, 2, 3))):
        op = rng.randrange(9)
        if op == 0 and b:
            i = rng.randrange(len(b)); b[i] ^= 1 << rng.randrange(8)
        elif op == 1 and b:
            i = rng.randrange(len(b)); b[i] = rng.choice((0x00, 0x01, 0x7F, 0x80, 0xFF, rng.randrange(256)))
        elif op == 2:
            i = rng.randrange(len(b) + 1); b[i:i] = bytes([rng.randrange(256)])
        elif op == 3 and b:
            i = rng.randrange(len(b)); del b[i:i + rng.randrange(1, 4)]
        elif op == 4 and b:
            del b[rng.randrange(len(b)):]
        elif op == 5 and b:
            i = rng.randrange(len(b)); j = rng.randrange(i, min(len(b), i + 16) + 1); b[j:j] = b[i:j]
        elif op == 6:
            other = rng.choice(pool); i = rng.randrange(len(other) + 1); b += other[i:]
        elif op == 7 and b:  # skew a length-ish byte
            i = rng.randrange(len(b)); b[i] = (b[i] + rng.choice((-2, -1, 1, 2))) & 0xFF
        else:  # inject a random field
            fnum = rng.choice((1, 2, 3, 5, 7, 15, 16, 99, 19000, 2**29 - 1))
            wt = rng.choice((0, 1, 2, 3, 4, 5))
            t = dv.tag(fnum, wt)
            body = {0: dv.varint(rng.choice((0, 1, 2**32, 2**63, 2**64 - 1))), 1: rb(8), 2: dv.varint(3) + b"abc",
                    3: b"", 4: b"", 5: rb(4)}[wt]
            i = rng.randrange(len(b) + 1); b[i:i] = t + body
    return bytes(b)


def _load(s):
    try:
        return json.loads(s, object_pairs_hook=lambda kv: dict(kv))
    except Exception:
        return None


def _f32(x):
    if isinstance(x, dict):
        return {k: _f32(v) for k, v in x.items()}
    if isinstance(x, list):
        return [_f32(v) for v in x]
    if isinstance(x, (int, float)) and not isinstance(x, bool):
        try:
            return struct.unpack("<f", struct.pack("<f", float(x)))[0]
        except OverflowError:
            return float(x)
    return x


def _nozero(x):
    if isinstance(x, dict):
        return {k: _nozero(v) for k, v in x.items() if v not in (0, "", False, [], {}, "0", None)}
    if isinstance(x, list):
        return [_nozero(v) for v in x]
    return x


def classify(pv, gv, sch):
    """Return (class, attributed finding)."""
    pp, gp = pv.split("\t"), gv.split("\t")
    if pp[0] != "OK" or gp[0] != "OK":
        if pp[0] == gp[0]:
            return "same-reject", ""
        if gp[0] == "OK":
            m = pp[1] if len(pp) > 1 else pv
            if "google.protobuf" in m:
                return "pion-rejects-go-accepts", "F-8 WKT import unresolved"
            if "UTF-8" in m and "proto2" in sch:
                return "pion-rejects-go-accepts", "F-9 proto2 string UTF-8"
            if "wire type mismatch" in m:
                return "pion-rejects-go-accepts", "F-11 map entry wire type"
            if "recursion depth 100" in m:
                return "pion-rejects-go-accepts", "N-3 default max_depth 100 (= prost)"
            return "pion-rejects-go-accepts", "UNEXPLAINED"
        m = gp[1] if len(gp) > 1 else gv
        if "required field" in m:
            return "pion-accepts-go-rejects", "F-13 proto2 required"
        if "message Holder" in sch:
            return "pion-accepts-go-rejects", "F-1 wrong descriptor skips validation"
        return "pion-accepts-go-rejects", "UNEXPLAINED"
    if pp[1].startswith("JSONERR") or gp[1].startswith("JSONERR"):
        if pp[1].startswith("JSONERR") == gp[1].startswith("JSONERR"):
            return "same", ""
        return "json-error-diff", "UNEXPLAINED"
    pc, pd, _ = json_norm(pp[1])
    gc, _, _ = json_norm(gp[1])
    if pc is None:
        return "pion-json-invalid", "UNEXPLAINED"
    if pc != gc:
        pj, gj = _load(pp[1]), _load(gp[1])
        if pj is not None and _f32(pj) == _f32(gj) and "float" in sch:
            return "json-value", "F-14 float32 JSON digits"
        if pj is not None and (_nozero(pj) == _nozero(gj) or (
                ("proto2" in sch or "optional" in sch) and isinstance(gj, dict)
                and all(k in gj and gj[k] == v for k, v in pj.items()))):
            return "json-value", "F-5 explicit-presence zero dropped"
        if "Item" in sch or "Status" in sch:
            return "json-value", "F-1 wrong descriptor"
        if pd:
            return "json-value", "F-6 map duplicate keys"
        return "json-value", "UNEXPLAINED"
    if pd:
        return "json-dupkey", "F-6 map duplicate keys"
    return "same", ""


def wire_fuzz():
    groups = {}
    for _, sch, msg, h in dv.DYN:
        groups.setdefault((sch, msg), []).append(bytes.fromhex(h))
    groups[(SPAN_PROTO, "Span")] = [ns["build_span"](i) for i in range(60)]
    keys = list(groups)
    per = N_WIRE // len(keys) + 1
    stats, examples, crashes, nw_diffs, total = {}, {}, [], [], 0
    canon_jobs = []
    for gi, key in enumerate(keys):
        sch, msg = key
        pool = groups[key]
        cases = [mutate(rng.choice(pool), pool) for _ in range(per)]
        hexes = [c.hex() or "-" for c in cases]
        sp = write(os.path.join(WORK, "fz%d.proto" % gi), sch)
        p, prc = run_lines([PION, "dyn", sp, msg], hexes, WORK, "fz%d_pion" % gi)
        w, wrc = run_lines([WASM, "dyn", sp, msg], hexes, WORK, "fz%d_wasm" % gi, timeout=600)
        g, grc = run_lines([GO, "dyn", sp, msg], hexes, WORK, "fz%d_go" % gi)
        if prc != 0 or len(p) != len(hexes):
            crashes.append(("native", gi, prc, len(p)))
        if wrc != 0 or len(w) != len(hexes):
            crashes.append(("wasm32", gi, wrc, len(w)))
        for k, hx in enumerate(hexes):
            total += 1
            pv = p[k] if k < len(p) else "<missing>"
            wv = w[k] if k < len(w) else "<missing>"
            gv = g[k] if k < len(g) else "<missing>"
            if pv != wv:
                nw_diffs.append((hx, pv, wv))
            c, why = classify(pv, gv, sch)
            stats[(c, why)] = stats.get((c, why), 0) + 1
            examples.setdefault((c, why), []).append((msg, hx, pv, gv))
            if c in ("same", "json-dupkey"):
                pe, ge = pv.split("\t")[2], gv.split("\t")[2]
                if not pe.startswith("ENCERR"):
                    canon_jobs.append((sp, msg, hx, pe, ge))
    # wire equivalence of re-encodings (batched per schema)
    wire_diff = []
    by = {}
    for j in canon_jobs:
        by.setdefault((j[0], j[1]), []).append(j)
    for (sp, msg), jobs in by.items():
        out, _ = run_lines([GO, "canon", sp, msg], [j[3] or "-" for j in jobs], WORK, "fzcanon")
        for j, o in zip(jobs, out):
            if o.rstrip() != ("OK " + j[4]).rstrip():
                wire_diff.append((msg, j[2], j[3], j[4], o))
    print("## Wire-level fuzz: %d mutated inputs over %d schemas (seed %d)\n" % (total, len(keys), SEED))
    print("- Pion native crashes / non-zero exits: **%d** %s" % (sum(1 for c in crashes if c[0] == "native"), [c for c in crashes if c[0] == "native"]))
    print("- Pion wasm32 traps / non-zero exits: **%d** %s" % (sum(1 for c in crashes if c[0] == "wasm32"), [c for c in crashes if c[0] == "wasm32"]))
    print("- Native vs wasm32 output differences: **%d**" % len(nw_diffs))
    for d in nw_diffs[:10]:
        print("  - in=%s\n    native=%s\n    wasm  =%s" % (d[0][:80], d[1][:160], d[2][:160]))
    print("- Re-encodings that Go does not canonicalise to the same message: **%d**" % len(wire_diff))
    for d in wire_diff[:5]:
        print("  - %s in=%s pion_enc=%s go_enc=%s go_canon(pion)=%s" % (d[0], d[1][:60], d[2][:60], d[3][:60], d[4][:60]))
    print("  (a re-encoding difference here means Go keeps a non-minimal varint of an *unknown* field verbatim while Pion")
    print("   re-encodes it minimally: same message, different bytes)")
    print("\n| Pion vs Go class | attributed to | count |\n|---|---|---:|")
    for k in sorted(stats, key=lambda x: -stats[x]):
        print("| %s | %s | %d |" % (k[0], k[1] or "-", stats[k]))
    print()
    for k in sorted(examples):
        if k[0] in ("same", "same-reject"):
            continue
        print("### %s / %s (first 3)\n" % k)
        for msg, hx, pv, gv in examples[k][:3]:
            print("- `%s` in=`%s`\n  - pion: `%s`\n  - go:   `%s`" % (msg, hx[:70], pv[:170], gv[:170]))
        print()
    return crashes, nw_diffs


TOKENS = ["{", "}", ";", "=", "message ", "enum ", "optional ", "repeated ", "required ", "oneof o ", "map<string,int32> ",
          "0x", "017", "-", "4294967297", "536870911", "\"", "'", "/*", "*/", "//", "\n", "[", "]", "(", ")", "<", ">",
          "reserved 1 to max;", "extensions 5 to 9;", "option x = 1;", "group G = 9 {}", "stream ", ".", "extend M {}",
          "syntax = \"proto2\";", "edition = \"2023\";", "int32 z = 1;", "\\x41", "\\"]


def schema_fuzz():
    seeds = [s for _, s in dv.SCHEMAS if len(s) < 5000]
    cases = []
    for _ in range(N_SCHEMA):
        s = rng.choice(seeds)
        for _ in range(rng.choice((1, 1, 2, 3))):
            op = rng.randrange(4)
            i = rng.randrange(len(s) + 1)
            if op == 0:
                s = s[:i] + rng.choice(TOKENS) + s[i:]
            elif op == 1 and s:
                s = s[:i] + s[i + rng.randrange(1, 6):]
            elif op == 2 and s:
                j = rng.randrange(i, min(len(s), i + 40) + 1); s = s[:j] + s[i:j] + s[j:]
            else:
                s = s[:i]
        cases.append(s)
    hexes = [c.encode().hex() or "-" for c in cases]
    p, prc = run_lines([PION, "schemahex"], hexes, WORK, "sfz_pion")
    w, wrc = run_lines([WASM, "schemahex"], hexes, WORK, "sfz_wasm", timeout=600)
    g, grc = run_lines([GO, "schemahex"], hexes, WORK, "sfz_go")
    nw = [(cases[i], p[i] if i < len(p) else "<missing>", w[i] if i < len(w) else "<missing>")
          for i in range(len(cases)) if (p[i] if i < len(p) else None) != (w[i] if i < len(w) else None)]
    acc = {"both-accept": 0, "both-reject": 0, "pion-accepts-go-rejects": 0, "pion-rejects-go-accepts": 0, "summary-diff": 0}
    ex = {}
    for i in range(len(cases)):
        pv = p[i] if i < len(p) else "<missing>"
        gv = g[i] if i < len(g) else "<missing>"
        pk, gk = pv.split(" ")[0], gv.split(" ")[0]
        if pk == gk == "OK":
            k = "both-accept" if pv == gv else "summary-diff"
        elif pk != "OK" and gk != "OK":
            k = "both-reject"
        elif pk == "OK":
            k = "pion-accepts-go-rejects"
        else:
            k = "pion-rejects-go-accepts"
        acc[k] += 1
        ex.setdefault(k, []).append((cases[i], pv, gv))
    print("## .proto fuzz: %d mutated schemas (seed %d)\n" % (len(cases), SEED))
    print("- Pion native exit %d, %d/%d lines; wasm32 exit %d, %d/%d lines" % (prc, len(p), len(cases), wrc, len(w), len(cases)))
    print("- Native vs wasm32 differences: **%d**" % len(nw))
    for c, a, b in nw[:5]:
        print("  - src=%r\n    native=%s\n    wasm  =%s" % (c[:100], a[:120], b[:120]))
    print("\n| Pion vs protocompile | count |\n|---|---:|")
    for k, v in acc.items():
        print("| %s | %d |" % (k, v))
    print()
    for k in ("pion-rejects-go-accepts", "summary-diff"):
        print("### %s (first 3)\n" % k)
        for c, a, b in ex.get(k, [])[:3]:
            print("- src=`%r`\n  - pion: `%s`\n  - go: `%s`" % (c[:160], a[:120], b[:120]))
        print()
    return prc, wrc, nw


if __name__ == "__main__":
    crashes, nwd = wire_fuzz()
    prc, wrc, nws = schema_fuzz()
    ok = not crashes and not nwd and prc == 0 and wrc == 0 and not nws
    print("**Pion robustness verdict:** %s" % ("PASS (0 crashes, 0 native/wasm32 differences)" if ok else "FAIL"))
