#!/usr/bin/env python3
"""Derive a Rust bench variant that builds http::Request/Response objects ONCE, outside
the timed loop (the Pion harness receives pre-split Header arrays). Policy work in the
loop is unchanged: CachePolicy::new_options + before_request + after_response.
Usage: make_rust_prebuilt.py <copied rust bench dir>"""
import sys, pathlib
d = pathlib.Path(sys.argv[1])
p = d / "src/main.rs"
s = p.read_text()
rep = [
 ('fn eval_all_once(cases: &[BenchCase]) -> String {\n    let mut out = String::new();\n    for c in cases {\n        let req = build_request(&c.method, &c.uri, &c.req_headers);\n        let resp = build_response(c.status, &c.resp_headers);',
  'struct Pre { req: Request<()>, resp: Response<()>, lreq: Request<()>, r304: Option<Response<()>> }\nfn prebuild(cases: &[BenchCase]) -> Vec<Pre> { cases.iter().map(|c| Pre { req: build_request(&c.method, &c.uri, &c.req_headers), resp: build_response(c.status, &c.resp_headers), lreq: build_request(&c.method, &c.uri, &c.lookup_headers), r304: if c.reval_304_headers.is_empty() { None } else { Some(build_response(304, &c.reval_304_headers)) } }).collect() }\nfn eval_all_once(cases: &[BenchCase], pre: &[Pre]) -> String {\n    let mut out = String::new();\n    for (c, p) in cases.iter().zip(pre) {\n        let req = &p.req;\n        let resp = &p.resp;'),
 ('let policy = CachePolicy::new_options(&req, &resp, resp_ts, opts);', 'let policy = CachePolicy::new_options(req, resp, resp_ts, opts);'),
 ('let lreq = build_request(&c.method, &c.uri, &c.lookup_headers);', 'let lreq = &p.lreq;'),
 ('policy.before_request(&lreq, lookup_ts)', 'policy.before_request(lreq, lookup_ts)'),
 ('let r304 = build_response(304, &c.reval_304_headers);', 'let r304 = p.r304.as_ref().unwrap();'),
 ('policy.after_response(&lreq, &r304, lookup_ts)', 'policy.after_response(lreq, r304, lookup_ts)'),
 ('new_policy.before_request(&lreq, after_ts)', 'new_policy.before_request(lreq, after_ts)'),
 ('let cases = parse_corpus(&data);', 'let cases = parse_corpus(&data);\n    let pre = prebuild(&cases);'),
 ('eval_all_once(&cases)', 'eval_all_once(&cases, &pre)'),
]
for a, b in rep:
    if a not in s:
        sys.exit(f"patch anchor not found: {a[:60]!r}")
    s = s.replace(a, b)
p.write_text(s)
c = d / "Cargo.toml"
c.write_text(c.read_text().replace('name = "http-cache-bench-rust"', 'name = "http-cache-bench-rust-pre"'))
