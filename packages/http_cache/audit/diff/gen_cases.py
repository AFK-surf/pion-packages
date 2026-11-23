#!/usr/bin/env python3
"""Deterministic differential corpus: hand-written RFC 9111 edge cases + seeded random
matrix. Output format = bench corpus (CASE/RQ/RS/LQ/R3/END) plus TAG lines (ignored by
both engines, used by compare.py to attribute divergences)."""
import random, sys
from email.utils import formatdate

T0 = 1700000000
def D(t): return formatdate(t, usegmt=True)

cases = []
def case(cid, *, method="GET", uri=None, shared=1, rt=T0, st=T0, lt=T0 + 30, status=200,
         rq=(), rs=(), lq=None, r3=(), tags=()):
    uri = uri or f"https://diff.example/{cid}"
    cases.append(dict(id=cid, method=method, uri=uri, shared=shared, rt=rt, st=st, lt=lt,
                      status=status, rq=list(rq), rs=list(rs),
                      lq=list(rq) if lq is None else list(lq), r3=list(r3), tags=list(tags)))

d0 = ("date", D(T0))
# ---- hand-written edge cases -------------------------------------------------
case("h_nostore_public", rs=[d0, ("cache-control", "public, max-age=86400, no-store")])
case("h_nostore_2nd_hdr", rs=[d0, ("cache-control", "public, max-age=86400"), ("cache-control", "no-store")])
case("h_req_nostore", rq=[("cache-control", "no-store")], rs=[d0, ("cache-control", "max-age=600")])
case("h_private_shared", rs=[d0, ("cache-control", "private, max-age=600")])
case("h_private_private", shared=0, rs=[d0, ("cache-control", "private, max-age=600")])
case("h_private_field", rs=[d0, ("cache-control", 'public, max-age=600, private="set-cookie"'), ("set-cookie", "sid=1")], tags=["private_field", "set_cookie"])
case("h_nocache_field", rs=[d0, ("cache-control", 'public, max-age=600, no-cache="set-cookie"'), ("set-cookie", "sid=1")], tags=["nocache_field", "set_cookie"])
case("h_auth_maxage", rq=[("authorization", "Bearer x")], rs=[d0, ("cache-control", "max-age=600")])
case("h_auth_public", rq=[("authorization", "Bearer x")], rs=[d0, ("cache-control", "public, max-age=600")])
case("h_auth_smaxage", rq=[("authorization", "Bearer x")], rs=[d0, ("cache-control", "s-maxage=600")])
case("h_auth_mustrev", rq=[("authorization", "Bearer x")], rs=[d0, ("cache-control", "must-revalidate, max-age=600")])
case("h_dup_maxage", rs=[d0, ("cache-control", "max-age=3600, max-age=0")], tags=["dup_directive"])
case("h_dup_maxage_same", rs=[d0, ("cache-control", "max-age=60, max-age=60")])
case("h_nocache_maxage", rs=[d0, ("cache-control", "max-age=3600, no-cache"), ("etag", '"e"')])
case("h_vary_star", rs=[d0, ("cache-control", "max-age=600"), ("vary", "*")])
case("h_vary_star_list", rs=[d0, ("cache-control", "max-age=600"), ("vary", "accept-encoding, *")], tags=["vary_star_list"])
case("h_vary_two_hdrs_mismatch", rq=[("accept-encoding", "gzip"), ("origin", "https://a")],
     rs=[d0, ("cache-control", "max-age=600"), ("vary", "accept-encoding"), ("vary", "origin")],
     lq=[("accept-encoding", "gzip"), ("origin", "https://evil")])
case("h_vary_missing_vs_empty", rq=[], rs=[d0, ("cache-control", "max-age=600"), ("vary", "x-tenant")], lq=[("x-tenant", "")])
case("h_vary_match", rq=[("accept-language", "en")], rs=[d0, ("cache-control", "max-age=600"), ("vary", "Accept-Language")], lq=[("accept-language", "en")])
case("h_206", rq=[("range", "bytes=0-0")], status=206, rs=[d0, ("cache-control", "public, max-age=3600"), ("content-range", "bytes 0-0/100")], lq=[], tags=["status206"])
case("h_206_heur", rq=[("range", "bytes=0-0")], status=206, rs=[d0, ("last-modified", D(T0 - 864000))], lq=[], tags=["status206"])
case("h_302_maxage", status=302, rs=[d0, ("cache-control", "max-age=600"), ("location", "/x")])
case("h_302_plain", status=302, rs=[d0, ("location", "/x")])
case("h_500_maxage", status=500, rs=[d0, ("cache-control", "max-age=600")], tags=["status_not_understood"])
case("h_308", status=308, rs=[d0, ("last-modified", D(T0 - 86400))], tags=["status308"])
case("h_expires_0", rs=[d0, ("expires", "0")])
case("h_expires_future", rs=[d0, ("expires", D(T0 + 600))])
case("h_expires_past", rs=[d0, ("expires", D(T0 - 600))])
case("h_maxage_overflow", rs=[d0, ("cache-control", "max-age=99999999999999999999")], tags=["overflow_value"])
case("h_maxage_neg", rs=[d0, ("cache-control", "max-age=-1")], tags=["invalid_cc"])
case("h_maxage_suffix", rs=[d0, ("cache-control", "max-age=60abc")], tags=["invalid_cc"])
case("h_age_header", rs=[d0, ("cache-control", "max-age=600"), ("age", "100")])
case("h_age_huge", rs=[d0, ("cache-control", "max-age=600"), ("age", "99999999999")], tags=["age_model"])
case("h_heuristic", rs=[d0, ("last-modified", D(T0 - 100000))])
case("h_heuristic_huge", rs=[d0, ("last-modified", "Mon, 01 Jan 1990 00:00:00 GMT")], lt=T0 + 10, tags=["heuristic_cap"])
case("h_pragma_req", shared=0, rs=[d0, ("cache-control", "max-age=600")], lq=[("pragma", "no-cache")], tags=["pragma"])
case("h_pragma_resp", rs=[d0, ("pragma", "no-cache"), ("expires", D(T0 + 600))], tags=["pragma"])
case("h_smaxage_maxstale", rs=[d0, ("cache-control", "s-maxage=10")], lt=T0 + 100, lq=[("cache-control", "max-stale=3600")], tags=["smaxage_proxyreval"])
case("h_proxyreval_shared", rs=[d0, ("cache-control", "max-age=600, proxy-revalidate")], tags=["proxy_reval_shared"])
case("h_proxyreval_private", shared=0, rs=[d0, ("cache-control", "max-age=600, proxy-revalidate")])
case("h_swr", rs=[d0, ("cache-control", "max-age=10, stale-while-revalidate=600")], lt=T0 + 60, tags=["swr"])
case("h_maxstale_mustrev", rs=[d0, ("cache-control", "max-age=10, must-revalidate")], lt=T0 + 60, lq=[("cache-control", "max-stale")])
case("h_maxstale_ok", shared=0, rs=[d0, ("cache-control", "max-age=10")], lt=T0 + 60, lq=[("cache-control", "max-stale=100")])
case("h_minfresh", rs=[d0, ("cache-control", "max-age=100")], lt=T0 + 60, lq=[("cache-control", "min-fresh=50")])
case("h_req_maxage0", rs=[d0, ("cache-control", "max-age=100")], lq=[("cache-control", "max-age=0")])
case("h_req_nocache", rs=[d0, ("cache-control", "max-age=100")], lq=[("cache-control", "no-cache")])
case("h_304_match", rs=[d0, ("cache-control", "max-age=10"), ("etag", '"v1"')], lt=T0 + 60, r3=[("cache-control", "max-age=600"), ("etag", '"v1"')])
case("h_304_mismatch", rs=[d0, ("cache-control", "max-age=10"), ("etag", '"v1"')], lt=T0 + 60, r3=[("cache-control", "max-age=600"), ("etag", '"v2"')], tags=["etag_mismatch_304"])
case("h_304_weak", rs=[d0, ("cache-control", "max-age=10"), ("etag", 'W/"v1"')], lt=T0 + 60, r3=[("cache-control", "max-age=600"), ("etag", 'W/"v1"')])
case("h_304_nostore", rs=[d0, ("cache-control", "max-age=10"), ("expires", D(T0 + 86400)), ("etag", '"a"')], lt=T0 + 60, r3=[("cache-control", "no-store"), ("etag", '"a"')], tags=["no_store_304"])
case("h_304_shorter", rs=[d0, ("cache-control", "max-age=10"), ("etag", '"a"')], lt=T0 + 60, r3=[("cache-control", "max-age=5"), ("etag", '"a"')])
case("h_304_lm", rs=[d0, ("cache-control", "max-age=10"), ("last-modified", D(T0 - 1000))], lt=T0 + 60, r3=[("cache-control", "max-age=600"), ("last-modified", D(T0 - 1000))])
case("h_head_from_get", rs=[d0, ("cache-control", "max-age=600")])
case("h_post", method="POST", rs=[d0, ("cache-control", "max-age=600")], tags=["post"])
case("h_set_cookie_shared", rs=[d0, ("cache-control", "max-age=600"), ("set-cookie", "a=b")], tags=["set_cookie"])
case("h_set_cookie_public", rs=[d0, ("cache-control", "public, max-age=600"), ("set-cookie", "a=b")])
case("h_immutable", rs=[d0, ("cache-control", "public, immutable")], tags=["immutable"])
case("h_must_understand", status=200, rs=[d0, ("cache-control", "must-understand, no-store, max-age=60")], tags=["must_understand"])
case("h_date_skew", rt=T0 + 100, st=T0 + 100, lt=T0 + 130, rs=[d0, ("cache-control", "max-age=600")], tags=["age_model"])
case("h_rfc850_date", rs=[("date", "Tuesday, 14-Nov-23 22:13:20 GMT"), ("expires", "Tuesday, 14-Nov-23 22:23:20 GMT")], tags=["obs_date"])
case("h_asctime_date", rs=[("date", "Tue Nov 14 22:13:20 2023"), ("expires", "Tue Nov 14 22:23:20 2023")], tags=["obs_date"])
case("h_quoted_maxage", rs=[d0, ("cache-control", 'max-age="60"')])
case("h_upper_directives", rs=[d0, ("cache-control", "PUBLIC, MAX-AGE=60")], tags=["case_directive"])
case("h_1xx", status=103, rs=[d0, ("cache-control", "max-age=600")], tags=["status1xx"])

# ---- seeded random matrix ------------------------------------------------------
rng = random.Random(9111)
RESP_DIR = ["public", "private", "no-cache", "must-revalidate", "proxy-revalidate", "immutable",
            "max-age={}", "s-maxage={}", "stale-while-revalidate={}", "no-store"]
REQ_DIR = [None, "no-cache", "max-age={}", "min-fresh={}", "max-stale", "max-stale={}"]
STATUSES = [200, 200, 200, 203, 204, 301, 302, 307, 404, 410, 500]
for n in range(420):
    shared = rng.randint(0, 1)
    dirs = []
    for d in rng.sample(RESP_DIR, rng.randint(0, 3)):
        if d == "no-store" and rng.random() < 0.6:
            continue
        dirs.append(d.format(rng.choice([0, 5, 30, 60, 600, 3600])) if "{}" in d else d)
    rsh = [d0]
    if dirs:
        rsh.append(("cache-control", ", ".join(dirs)))
    if rng.random() < 0.25:
        rsh.append(("expires", D(T0 + rng.choice([-60, 0, 30, 600]))))
    if rng.random() < 0.3:
        rsh.append(("last-modified", D(T0 - rng.choice([60, 3600, 86400]))))
    if rng.random() < 0.2:
        rsh.append(("age", str(rng.choice([0, 10, 100]))))
    etag = None
    if rng.random() < 0.5:
        etag = rng.choice(['"e1"', 'W/"e1"'])
        rsh.append(("etag", etag))
    rq = []
    vary = rng.random() < 0.25
    if vary:
        rsh.append(("vary", "accept-encoding"))
        rq.append(("accept-encoding", "gzip"))
    if rng.random() < 0.1:
        rq.append(("authorization", "Bearer t"))
    lq = list(rq)
    if vary and rng.random() < 0.3:
        lq = [("accept-encoding", "br")]
    rd = rng.choice(REQ_DIR)
    if rd:
        lq.append(("cache-control", rd.format(rng.choice([0, 10, 60, 600]))))
    lt = T0 + rng.choice([0, 3, 20, 45, 100, 700, 4000])
    r3 = []
    if etag and rng.random() < 0.5:
        r3 = [("cache-control", rng.choice(["max-age=600", "max-age=5", "no-cache", "s-maxage=100"])), ("etag", etag)]
    tags = []
    cc = ", ".join(dirs)
    if "proxy-revalidate" in cc and shared: tags.append("proxy_reval_shared")
    if "s-maxage" in cc and shared: tags.append("smaxage_proxyreval")
    if "stale-while-revalidate" in cc: tags.append("swr")
    if "immutable" in cc: tags.append("immutable")
    if not any(k in cc for k in ("max-age", "s-maxage")) and not any(h[0] == "expires" for h in rsh): tags.append("heuristic_cap")
    st = rng.choice(STATUSES)
    if st in (500,): tags.append("status_not_understood")
    case(f"r{n:03d}", shared=shared, status=st, rq=rq, rs=rsh, lq=lq, lt=lt, r3=r3, tags=tags)

out = []
for c in cases:
    out.append("\t".join(["CASE", c["id"], c["method"], c["uri"], str(c["shared"]), str(c["rt"]), str(c["st"]), str(c["lt"]), str(c["status"])]))
    out.append("TAG\t" + ",".join(c["tags"]))
    for k, v in c["rq"]: out.append(f"RQ\t{k}\t{v}")
    for k, v in c["rs"]: out.append(f"RS\t{k}\t{v}")
    for k, v in c["lq"]: out.append(f"LQ\t{k}\t{v}")
    for k, v in c["r3"]: out.append(f"R3\t{k}\t{v}")
    out.append("END")
open(sys.argv[1], "w").write("\n".join(out) + "\n")
print(f"{len(cases)} cases -> {sys.argv[1]}", file=sys.stderr)
