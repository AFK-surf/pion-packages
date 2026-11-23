#!/usr/bin/env python3
"""Compare Pion `http_cache` vs Rust `http-cache-semantics 3.0.0` decisions and attribute
every divergence to a named cause. Exit 1 if any divergence stays unexplained."""
import os, sys, collections
VERBOSE = os.environ.get("VERBOSE") == "1"

def load(p):
    out = {}
    for line in open(p):
        parts = line.split()
        if parts:
            out[parts[0]] = dict(kv.split("=", 1) for kv in parts[1:] if "=" in kv)
    return out

def corpus(p):
    cases, cur = {}, None
    for line in open(p):
        f = line.rstrip("\n").split("\t")
        if f[0] == "CASE":
            cur = dict(id=f[1], method=f[2], shared=f[4] == "1", rt=int(f[5]), st=int(f[6]), lt=int(f[7]), status=int(f[8]), tags=[], rq=[], rs=[], lq=[], r3=[])
        elif f[0] == "TAG":
            cur["tags"] = [t for t in f[1].split(",") if t]
        elif f[0] in ("RQ", "RS", "LQ", "R3"):
            cur[f[0].lower()].append((f[1].lower(), f[2] if len(f) > 2 else ""))
        elif f[0] == "END":
            cases[cur["id"]] = cur
    return cases

def hv(hs, n): return [v for k, v in hs if k == n]
def cc(hs): return ", ".join(hv(hs, "cache-control")).lower()

def classify(c, P, R):
    t, rcc, lcc = set(c["tags"]), cc(c["rs"]), cc(c["lq"])
    shared = c["shared"]
    if "status206" in t: return "FINDING P1-2: Pion stores 206 as complete response"
    if "private_field" in t: return "FINDING P0-1: private=\"field\" ignored (Rust refuses to store)"
    if "nocache_field" in t: return "FINDING P0-1b: no-cache=\"field\" ignored on fresh reuse"
    if "etag_mismatch_304" in t: return "FINDING P1-4: 304 with non-matching strong ETag merged"
    if "no_store_304" in t: return "FINDING P1-5: 304 no-store keeps entry fresh"
    if "pragma" in t: return "FINDING P2-9: Pragma: no-cache ignored"
    if "status1xx" in t: return "FINDING P2-11: 1xx storable"
    if "status308" in t: return "FINDING P2-14: 308 missing from heuristically cacheable statuses"
    if "smaxage_proxyreval" in t and "max-stale" in lcc and R.get("lk") == "stale" and P.get("lk") == "fresh":
        return "FINDING P2-8: s-maxage does not imply proxy-revalidate"
    if c["method"] == "POST": return "ORACLE-EXT: Rust caches POST with explicit freshness"
    if "set-cookie" in [k for k, _ in c["rs"]] and shared and "public" not in rcc:
        return "ORACLE-HARDENING H-1: Rust refuses fresh reuse of Set-Cookie responses in shared caches"
    if "vary" in [k for k, _ in c["rs"]] and "*" in ",".join(hv(c["rs"], "vary")):
        return "EQUIV: Vary:* (Pion refuses store, Rust stores-but-never-matches)"
    if "dup_directive" in t: return "PION-SAFER: duplicate max-age -> min (Rust: first value + must-revalidate)"
    if "invalid_cc" in t: return "PION-SAFER: invalid delta-seconds -> Err/not stored (Rust: stored, stale)"
    if "overflow_value" in t: return "PION-CORRECT: RFC 9111 §1.2.2 clamp to 2^31 (Rust: unparsable -> 0)"
    if "obs_date" in t: return "PION-CORRECT: RFC 850 / asctime dates accepted (RFC 9110 §5.6.7 MUST); Rust parses RFC 2822 only"
    if "case_directive" in t: return "PION-CORRECT: case-insensitive directive names (Rust case-sensitive)"
    if "status_not_understood" in t or c["status"] not in (200, 203, 204, 300, 301, 302, 303, 307, 308, 404, 405, 410, 414, 501):
        return "POLICY: Rust refuses status codes outside its understood list; Pion stores any final status with explicit freshness (RFC-permitted)"
    if "proxy-revalidate" in rcc and shared:
        return "PION-CORRECT: proxy-revalidate only forbids stale reuse (Rust: freshness forced to 0 in shared caches)"
    if "no-cache" in rcc and P.get("lk") == R.get("lk") and P.get("ttl") != R.get("ttl"):
        return "TTL-REPORTING: Rust reports ttl=0 for no-cache, Pion reports raw lifetime (both revalidate)"
    if "age_model" in t or c["rt"] != c["st"] or any(k == "age" for k, _ in c["rs"]) and P.get("age") != R.get("age"):
        return "PION-CORRECT: RFC 9111 §4.2.3 apparent_age/response_delay (Rust: Age + resident only)"
    if P.get("st") == "1" and R.get("st") == "0" and c["status"] in (301, 302, 303, 307, 308, 404, 405, 410, 414, 501) and "private" in rcc and not shared:
        return "PION-CORRECT: `private` is explicit permission for a private cache (RFC 9111 §3); Rust ignores it"
    if "no-cache" in rcc and "max-stale" in lcc and R.get("lk") == "fresh" and P.get("lk") == "stale":
        return "PION-SAFER: response no-cache always revalidates; Rust serves it stale under request max-stale"
    if P.get("lk") == R.get("lk") and P.get("st") == R.get("st") and (P.get("a304") != R.get("a304") or P.get("ttl2") != R.get("ttl2")) and c["r3"]:
        if "cache-control" not in [k for k, _ in c["rs"]] and "cache-control" in [k for k, _ in c["r3"]]:
            return "PION-CORRECT: Rust after_response drops 304 header fields absent from the stored response (RFC 9111 §3.2: add them)"
        if "no-cache" in cc(c["r3"]) and "max-stale" in lcc and R.get("a304") == "fresh" and P.get("a304") == "stale":
            return "PION-SAFER: response no-cache always revalidates; Rust serves it stale under request max-stale"
        if not hv(c["r3"], "date"):
            return "FINDING P2-15: Date-less 304 not stamped with Date; age counted from original Date (RFC 9110 §6.6.1)"
    if "public" in rcc and c["status"] not in (200, 203, 204, 206, 300, 301, 308, 404, 405, 410, 414, 501) and P.get("lk") == R.get("lk"):
        return "PION-CONSERVATIVE: no heuristic freshness for public non-heuristic statuses (RFC 9111 §4.2.2 MAY)"
    if P.get("st") == R.get("st") == "1" and P.get("lk") == R.get("lk") and abs(int(P.get("ttl", 0)) - int(R.get("ttl", 0))) <= 1 and P.get("a304") == R.get("a304") and P.get("ttl2") == R.get("ttl2"):
        return "ROUNDING: heuristic float vs integer (±1 s)"
    return None

def main():
    cases = corpus(sys.argv[1]); P = load(sys.argv[2]); R = load(sys.argv[3])
    buckets = collections.Counter(); unexplained = []; same = 0
    for cid, c in cases.items():
        p, r = P.get(cid, {}), R.get(cid, {})
        if p == r:
            same += 1
            continue
        why = classify(c, p, r)
        if why is None:
            unexplained.append((cid, p, r, c))
        else:
            buckets[why] += 1
            if VERBOSE:
                print(f"[{why[:24]}] {cid} pion={p} rust={r} shared={c['shared']} status={c['status']} dt={c['lt']-c['st']} rcc={cc(c['rs'])!r} lcc={cc(c['lq'])!r} exp={hv(c['rs'],'expires')} lm={hv(c['rs'],'last-modified')} r3={c['r3']}")
    total = len(cases)
    print(f"cases={total} identical={same} divergent={total - same} unexplained={len(unexplained)}")
    for why, n in sorted(buckets.items(), key=lambda x: (-x[1], x[0])):
        print(f"  {n:4d}  {why}")
    for cid, p, r, c in unexplained:
        print(f"UNEXPLAINED {cid}\n  pion={p}\n  rust={r}\n  shared={c['shared']} status={c['status']} lt-st={c['lt']-c['st']}\n  rs={c['rs']}\n  lq={c['lq']}\n  r3={c['r3']}")
    sys.exit(1 if unexplained else 0)

main()
