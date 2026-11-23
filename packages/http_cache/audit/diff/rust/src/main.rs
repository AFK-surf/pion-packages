//! Differential oracle: Rust `http-cache-semantics 3.0.0` decisions per corpus case.
//! Line format (identical to the Pion harness):
//! `<id> st=<0|1> lk=<fresh|stale|miss> ttl=<s> age=<s> a304=<-|fresh|stale> ttl2=<s>`
use http::{Request, Response, StatusCode};
use http_cache_semantics::{AfterResponse, BeforeRequest, CacheOptions, CachePolicy};
use std::time::{Duration, UNIX_EPOCH};

#[derive(Default, Clone)]
struct Case {
    id: String, method: String, uri: String, shared: bool,
    rt: u64, st: u64, lt: u64, status: u16,
    rq: Vec<(String, String)>, rs: Vec<(String, String)>,
    lq: Vec<(String, String)>, r3: Vec<(String, String)>,
}

fn parse(data: &str) -> Vec<Case> {
    let mut out = Vec::new();
    let mut c = Case::default();
    for line in data.lines() {
        let p: Vec<&str> = line.split('\t').collect();
        let kv = || (p[1].to_string(), p.get(2).unwrap_or(&"").to_string());
        match p[0] {
            "CASE" => {
                c = Case { id: p[1].into(), method: p[2].into(), uri: p[3].into(), shared: p[4] == "1",
                    rt: p[5].parse().unwrap(), st: p[6].parse().unwrap(), lt: p[7].parse().unwrap(),
                    status: p[8].parse().unwrap(), ..Default::default() };
            }
            "RQ" => c.rq.push(kv()),
            "RS" => c.rs.push(kv()),
            "LQ" => c.lq.push(kv()),
            "R3" => c.r3.push(kv()),
            "END" => out.push(c.clone()),
            _ => {}
        }
    }
    out
}

fn req(m: &str, u: &str, h: &[(String, String)]) -> Request<()> {
    let mut b = Request::builder().method(m).uri(u);
    for (k, v) in h { b = b.header(k.as_str(), v.as_str()); }
    b.body(()).unwrap()
}
fn resp(s: u16, h: &[(String, String)]) -> Response<()> {
    let mut b = Response::builder().status(StatusCode::from_u16(s).unwrap());
    for (k, v) in h { b = b.header(k.as_str(), v.as_str()); }
    b.body(()).unwrap()
}
fn at(t: u64) -> std::time::SystemTime { UNIX_EPOCH + Duration::from_secs(t) }

fn main() {
    let path = std::env::args().nth(1).expect("corpus");
    let data = std::fs::read_to_string(path).unwrap();
    let opts = |shared| CacheOptions { shared, cache_heuristic: 0.1, immutable_min_time_to_live: Duration::ZERO, ignore_cargo_cult: false };
    for c in parse(&data) {
        let policy = CachePolicy::new_options(&req(&c.method, &c.uri, &c.rq), &resp(c.status, &c.rs), at(c.st), opts(c.shared));
        if !policy.is_storable() { println!("{} st=0", c.id); continue; }
        let lreq = req(&c.method, &c.uri, &c.lq);
        let now = at(c.lt);
        let ttl = policy.time_to_live(now).as_secs();
        let age = policy.age(now).as_secs();
        let (lk, stale) = match policy.before_request(&lreq, now) {
            BeforeRequest::Fresh(_) => ("fresh", false),
            BeforeRequest::Stale { matches: false, .. } => ("miss", false),
            BeforeRequest::Stale { .. } => ("stale", true),
        };
        let mut a304 = "-".to_string();
        let mut ttl2 = 0;
        if stale && !c.r3.is_empty() {
            let np = match policy.after_response(&lreq, &resp(304, &c.r3), now) {
                AfterResponse::NotModified(p, _) | AfterResponse::Modified(p, _) => p,
            };
            let t2 = at(c.lt + 10);
            ttl2 = np.time_to_live(t2).as_secs();
            a304 = match np.before_request(&lreq, t2) { BeforeRequest::Fresh(_) => "fresh".into(), _ => "stale".into() };
        }
        println!("{} st=1 lk={} ttl={} age={} a304={} ttl2={}", c.id, lk, ttl, age, a304, ttl2);
    }
}
