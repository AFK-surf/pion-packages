//! Differential oracle: official Rust `cedar-policy =4.15.0`.
//!
//! Reads a case file (one case per line, `#` comments allowed):
//!     <id>\t<mode>\t<hex policies>\t<hex entities json>\t<hex request json>
//! and prints, per case, `## <id>` followed by exactly one result line:
//!     PERR                                  policy set failed to parse
//!     EERR                                  entities JSON rejected
//!     RERR                                  request JSON rejected
//!     <Allow|Deny> r=<idx,..> e=<idx,..>    decision, determining policies, erroring policies
//!     OK n=<count>                          (mode P) policy set parsed
//! Policy indices are positional (source order), so `@id(..)` handling never skews the diff.
//! The Pion twin is `audit/diff/pion_driver`; both must print byte-identical transcripts.

use cedar_policy::{AuthorizationError, Authorizer, Context, Decision, Entities, EntityUid, PolicySet, Request};
use std::str::FromStr;

fn unhex(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len() / 2);
    let hv = |c: u8| -> u8 {
        match c {
            b'0'..=b'9' => c - b'0',
            b'a'..=b'f' => c - b'a' + 10,
            b'A'..=b'F' => c - b'A' + 10,
            _ => 0,
        }
    };
    let mut i = 0;
    while i + 1 < b.len() {
        out.push(hv(b[i]) * 16 + hv(b[i + 1]));
        i += 2;
    }
    String::from_utf8(out).expect("case strings are UTF-8")
}

fn idx_of(id: &str) -> usize {
    id.strip_prefix("policy")
        .and_then(|n| n.parse().ok())
        .expect("auto-assigned policy ids")
}

fn join(mut v: Vec<usize>) -> String {
    v.sort_unstable();
    v.dedup();
    v.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(",")
}

fn parse_request(src: &str) -> Option<Request> {
    let v: serde_json::Value = serde_json::from_str(src).ok()?;
    let obj = v.as_object()?;
    let p = EntityUid::from_json(obj.get("principal")?.clone()).ok()?;
    let a = EntityUid::from_json(obj.get("action")?.clone()).ok()?;
    let r = EntityUid::from_json(obj.get("resource")?.clone()).ok()?;
    let ctx = match obj.get("context") {
        Some(c) => Context::from_json_value(c.clone(), None).ok()?,
        None => Context::empty(),
    };
    Request::new(p, a, r, ctx, None).ok()
}

fn run_case(mode: &str, pol: &str, ents: &str, req: &str) -> String {
    let ps = match PolicySet::from_str(pol) {
        Ok(ps) => ps,
        Err(e) => {
            if std::env::var_os("ORACLE_DEBUG").is_some() {
                eprintln!("PERR: {e}");
            }
            return "PERR".to_string();
        }
    };
    if mode == "P" {
        return format!("OK n={}", ps.policies().count());
    }
    let ents_src = if ents.is_empty() { "[]" } else { ents };
    let entities = match Entities::from_json_str(ents_src, None) {
        Ok(e) => e,
        Err(e) => {
            if std::env::var_os("ORACLE_DEBUG").is_some() {
                eprintln!("EERR: {e:?}");
            }
            return "EERR".to_string();
        }
    };
    let request = match parse_request(req) {
        Some(r) => r,
        None => return "RERR".to_string(),
    };
    let resp = Authorizer::new().is_authorized(&request, &ps, &entities);
    let dec = match resp.decision() {
        Decision::Allow => "Allow",
        Decision::Deny => "Deny",
    };
    let reasons: Vec<usize> = resp.diagnostics().reason().map(|id| idx_of(id.as_ref())).collect();
    let errors: Vec<usize> = resp
        .diagnostics()
        .errors()
        .map(|e| match e {
            AuthorizationError::PolicyEvaluationError(pe) => idx_of(pe.policy_id().as_ref()),
        })
        .collect();
    format!("{} r={} e={}", dec, join(reasons), join(errors))
}

fn main() {
    // cedar-policy's LALRPOP parser recurses per nesting level; run on a 1 GiB stack so deep
    // (but valid) inputs get an answer instead of a stack-overflow abort.
    std::thread::Builder::new()
        .stack_size(1 << 30)
        .spawn(real_main)
        .expect("spawn")
        .join()
        .expect("oracle thread");
}

fn real_main() {
    let path = std::env::args().nth(1).expect("usage: oracle <cases>");
    let data = std::fs::read_to_string(&path).expect("read cases");
    let mut out = String::new();
    for line in data.lines() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 5 {
            continue;
        }
        let res = run_case(f[1], &unhex(f[2]), &unhex(f[3]), &unhex(f[4]));
        out.push_str("## ");
        out.push_str(f[0]);
        out.push('\n');
        out.push_str(&res);
        out.push('\n');
    }
    print!("{out}");
}
