use http::{Request, Response, StatusCode};
use http_cache_semantics::{AfterResponse, BeforeRequest, CacheOptions, CachePolicy};
use sha2::{Digest, Sha256};
use std::env;
use std::fs;
use std::time::{Duration, UNIX_EPOCH};

struct BenchCase {
    id: String,
    is_shared: bool,
    resp_time: u64,
    lookup_time: u64,
    req: Request<()>,
    resp: Response<()>,
    lookup_req: Request<()>,
    reval_304: Option<Response<()>>,
}

fn build_request(method: &str, uri: &str, headers: &[(String, String)]) -> Request<()> {
    let mut b = Request::builder().method(method).uri(uri);
    for (k, v) in headers {
        b = b.header(k.as_str(), v.as_str());
    }
    b.body(()).unwrap()
}

fn build_response(status: u16, headers: &[(String, String)]) -> Response<()> {
    let mut b = Response::builder().status(StatusCode::from_u16(status).unwrap());
    for (k, v) in headers {
        b = b.header(k.as_str(), v.as_str());
    }
    b.body(()).unwrap()
}

fn parse_corpus_prebuilt(data: &str) -> Vec<BenchCase> {
    let mut cases = Vec::new();
    let mut id = String::new();
    let mut method = String::new();
    let mut uri = String::new();
    let mut is_shared = false;
    let mut resp_time = 0u64;
    let mut lookup_time = 0u64;
    let mut status = 200u16;
    let mut req_h = Vec::new();
    let mut resp_h = Vec::new();
    let mut lookup_h = Vec::new();
    let mut reval_h = Vec::new();

    for line in data.lines() {
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.split('\t').collect();
        match parts[0] {
            "CASE" if parts.len() >= 9 => {
                id = parts[1].to_string();
                method = parts[2].to_string();
                uri = parts[3].to_string();
                is_shared = parts[4] == "1";
                resp_time = parts[6].parse().unwrap_or(0);
                lookup_time = parts[7].parse().unwrap_or(0);
                status = parts[8].parse().unwrap_or(200);
                req_h.clear();
                resp_h.clear();
                lookup_h.clear();
                reval_h.clear();
            }
            "RQ" if parts.len() >= 3 => req_h.push((parts[1].to_string(), parts[2].to_string())),
            "RS" if parts.len() >= 3 => resp_h.push((parts[1].to_string(), parts[2].to_string())),
            "LQ" if parts.len() >= 3 => lookup_h.push((parts[1].to_string(), parts[2].to_string())),
            "R3" if parts.len() >= 3 => reval_h.push((parts[1].to_string(), parts[2].to_string())),
            "END" => {
                let reval_304 = if reval_h.is_empty() {
                    None
                } else {
                    Some(build_response(304, &reval_h))
                };
                cases.push(BenchCase {
                    id: id.clone(),
                    is_shared,
                    resp_time,
                    lookup_time,
                    req: build_request(&method, &uri, &req_h),
                    resp: build_response(status, &resp_h),
                    lookup_req: build_request(&method, &uri, &lookup_h),
                    reval_304,
                });
            }
            _ => {}
        }
    }
    cases
}

fn eval_all_once(cases: &[BenchCase]) -> String {
    let mut out = String::new();
    for c in cases {
        let opts = CacheOptions {
            shared: c.is_shared,
            cache_heuristic: 0.1,
            immutable_min_time_to_live: Duration::from_secs(24 * 3600),
            ignore_cargo_cult: false,
        };
        let resp_ts = UNIX_EPOCH + Duration::from_secs(c.resp_time);
        let lookup_ts = UNIX_EPOCH + Duration::from_secs(c.lookup_time);
        let policy = CachePolicy::new_options(&c.req, &c.resp, resp_ts, opts);

        out.push_str(&c.id);
        out.push(':');
        if !policy.is_storable() {
            out.push_str("storable=0\n");
            continue;
        }
        out.push_str("storable=1|");
        match policy.before_request(&c.lookup_req, lookup_ts) {
            BeforeRequest::Fresh(_) => {
                let ttl = policy.time_to_live(lookup_ts).as_secs();
                out.push_str(&format!("fresh={}", ttl));
            }
            BeforeRequest::Stale {
                request: reval_parts,
                matches,
            } => {
                if !matches {
                    out.push_str("miss");
                } else {
                    let inm = reval_parts
                        .headers
                        .get("if-none-match")
                        .and_then(|v| v.to_str().ok())
                        .unwrap_or("-");
                    let ims = reval_parts
                        .headers
                        .get("if-modified-since")
                        .and_then(|v| v.to_str().ok())
                        .unwrap_or("-");
                    out.push_str(&format!("reval|inm={}|ims={}", inm, ims));
                    if let Some(ref r304) = c.reval_304 {
                        match policy.after_response(&c.lookup_req, r304, lookup_ts) {
                            AfterResponse::NotModified(new_policy, _)
                            | AfterResponse::Modified(new_policy, _) => {
                                let after_ts = lookup_ts + Duration::from_secs(10);
                                match new_policy.before_request(&c.lookup_req, after_ts) {
                                    BeforeRequest::Fresh(_) => {
                                        let ttl2 = new_policy.time_to_live(after_ts).as_secs();
                                        out.push_str(&format!("|after304_fresh={}", ttl2));
                                    }
                                    BeforeRequest::Stale { .. } => {
                                        out.push_str("|after304_stale");
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        out.push('\n');
    }
    out
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: http-cache-bench-rust-prebuilt <corpus_file> <iters>");
        std::process::exit(1);
    }
    let data = fs::read_to_string(&args[1]).expect("failed to read corpus");
    let iters: usize = args[2].parse().expect("invalid iters");
    let cases = parse_corpus_prebuilt(&data);
    if iters == 0 {
        println!("{}", eval_all_once(&cases));
        return;
    }
    let mut last_summary = String::new();
    for _ in 0..iters {
        last_summary = eval_all_once(&cases);
    }
    let mut hasher = Sha256::new();
    hasher.update(last_summary.as_bytes());
    let digest = hasher.finalize();
    let hex: String = digest.iter().map(|b| format!("{:02x}", b)).collect();
    println!(
        "cases={} iters={} summary_bytes={} summary_sha256={}",
        cases.len(),
        iters,
        last_summary.len(),
        hex
    );
}
