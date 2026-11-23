//! Benchmark-fairness re-run for `packages/cedar/bench` (Rust `cedar-policy =4.15.0`).
//!
//! w2f / w3f: byte-identical stdout to `bench/rust_bench` w2 / w3, but with the per-request work
//!   that the Pion side does NOT do hoisted out of the loop, exactly like `bench/pion_bench`:
//!   - entity UIDs are built from pre-parsed `EntityTypeName`s (`bench/rust_bench::uid()` runs the
//!     full Cedar name parser twice per request; Pion's `EntityUid::new` is a struct literal);
//!   - contexts are built once per distinct value (W2: 300, W3: 140) and cloned (`Context::from_pairs`
//!     re-evaluates every `RestrictedExpression`, incl. `ip(..)`/`decimal(..)` parsing, per request;
//!     Pion parses its 7 ips / 7 decimals once before the loop).
//! w4 / w5 / w6: blind-spot workloads missing from the published table (twins in
//!   `audit/bench_fair/pion`): JSON entity loading, large-set predicates, `like`-heavy policies.
use cedar_policy::{
    Authorizer, Context, Decision, Entities, EntityId, EntityTypeName, EntityUid, PolicySet, Request,
    RestrictedExpression,
};
use std::fmt::Write as _;
use std::str::FromStr;

fn line(out: &mut String, idx: usize, resp: &cedar_policy::Response) {
    let dec = if resp.decision() == Decision::Allow { "Allow" } else { "Deny" };
    let mut reasons: Vec<String> = resp.diagnostics().reason().map(|id| id.to_string()).collect();
    reasons.sort();
    let _ = writeln!(out, "{}:{}:{}", idx, dec, reasons.join(","));
}

struct Ty(EntityTypeName);
impl Ty {
    fn new(s: &str) -> Self {
        Ty(EntityTypeName::from_str(s).unwrap())
    }
    fn uid(&self, id: &str) -> EntityUid {
        EntityUid::from_type_name_and_id(self.0.clone(), EntityId::new(id))
    }
}

// ---- W2 (policies / entities copied verbatim from bench/rust_bench) -------------------------
fn w2_policies() -> String {
    let mut sb = String::new();
    for i in 0..60 {
        let (t, d, f) = (i % 20, i % 5, i % 24);
        if i < 20 {
            let _ = writeln!(sb, "permit(principal in Team::\"t{}\", action in [Action::\"read\", Action::\"write\"], resource in Folder::\"f{}\") when {{ principal.active && principal.level >= {} }};", t, f, 1 + (i % 3));
        } else if i < 32 {
            let _ = writeln!(sb, "permit(principal in Dept::\"d{}\", action == Action::\"read\", resource in Org::\"acme\") when {{ principal.active && principal.clearance >= resource.classification }};", d);
        } else if i < 42 {
            let _ = writeln!(sb, "permit(principal is User in Org::\"acme\", action in [Action::\"read\", Action::\"write\", Action::\"delete\", Action::\"share\"], resource is Doc in Folder::\"f{}\") when {{ resource.owner == principal && context.risk_score < 80 }};", i % 12);
        } else if i < 52 {
            let _ = writeln!(sb, "forbid(principal, action in [Action::\"write\", Action::\"delete\"], resource in Folder::\"f{}\") when {{ resource.locked }};", i % 12);
        } else {
            let _ = writeln!(sb, "forbid(principal in Dept::\"d{}\", action in [Action::\"delete\", Action::\"share\"], resource) when {{ !context.mfa || context.risk_score >= 70 }};", d);
        }
    }
    sb
}

fn w2_entities() -> Entities {
    use cedar_policy::Entity;
    use std::collections::{HashMap, HashSet};
    let (org_t, dept, team, user, folder, doc) =
        (Ty::new("Org"), Ty::new("Dept"), Ty::new("Team"), Ty::new("User"), Ty::new("Folder"), Ty::new("Doc"));
    let org = org_t.uid("acme");
    let mut list = vec![Entity::new(org.clone(), HashMap::new(), HashSet::new()).unwrap()];
    for i in 0..5 {
        list.push(Entity::new(dept.uid(&format!("d{i}")), HashMap::new(), HashSet::from([org.clone()])).unwrap());
    }
    for i in 0..20 {
        list.push(Entity::new(team.uid(&format!("t{i}")), HashMap::new(), HashSet::from([dept.uid(&format!("d{}", i % 5))])).unwrap());
    }
    for i in 0..100 {
        let attrs = HashMap::from([
            ("level".to_string(), RestrictedExpression::new_long((1 + (i % 5)) as i64)),
            ("active".to_string(), RestrictedExpression::new_bool(i % 10 != 0)),
            ("clearance".to_string(), RestrictedExpression::new_long((i % 4) as i64)),
        ]);
        list.push(Entity::new(user.uid(&format!("u{i}")), attrs, HashSet::from([team.uid(&format!("t{}", i % 20))])).unwrap());
    }
    for i in 0..24 {
        let p = if i < 12 { org.clone() } else { folder.uid(&format!("f{}", i - 12)) };
        list.push(Entity::new(folder.uid(&format!("f{i}")), HashMap::new(), HashSet::from([p])).unwrap());
    }
    for i in 0..100 {
        let attrs = HashMap::from([
            ("owner".to_string(), RestrictedExpression::new_entity_uid(user.uid(&format!("u{i}")))),
            ("classification".to_string(), RestrictedExpression::new_long((i % 4) as i64)),
            ("locked".to_string(), RestrictedExpression::new_bool(i % 13 == 0)),
        ]);
        list.push(Entity::new(doc.uid(&format!("doc{i}")), attrs, HashSet::from([folder.uid(&format!("f{}", i % 24))])).unwrap());
    }
    Entities::from_entities(list, None).unwrap()
}

fn run_w2f(n: usize) {
    let ps = PolicySet::from_str(&w2_policies()).unwrap();
    let entities = w2_entities();
    let (user, doc, act) = (Ty::new("User"), Ty::new("Doc"), Ty::new("Action"));
    let actions: Vec<EntityUid> = ["read", "write", "delete", "share"].iter().map(|a| act.uid(a)).collect();
    let users: Vec<EntityUid> = (0..100).map(|i| user.uid(&format!("u{i}"))).collect();
    let docs: Vec<EntityUid> = (0..100).map(|i| doc.uid(&format!("doc{i}"))).collect();
    // (i % 3, (i * 17) % 100) repeats with period 300
    let ctxs: Vec<Context> = (0..300usize)
        .map(|i| {
            Context::from_pairs([
                ("mfa".to_string(), RestrictedExpression::new_bool(i % 3 != 0)),
                ("risk_score".to_string(), RestrictedExpression::new_long(((i * 17) % 100) as i64)),
            ])
            .unwrap()
        })
        .collect();
    let auth = Authorizer::new();
    let mut out = String::with_capacity(n * 32);
    for i in 0..n {
        let req = Request::new(
            users[(i * 7 + 3) % 100].clone(),
            actions[(i * 3 + 1) % 4].clone(),
            docs[(i * 11 + 5) % 100].clone(),
            ctxs[i % 300].clone(),
            None,
        )
        .unwrap();
        line(&mut out, i, &auth.is_authorized(&req, &ps, &entities));
    }
    print!("{out}");
}

fn w3_policies() -> String {
    let mut sb = String::new();
    sb.push_str("permit(principal, action == Action::\"pay\", resource) when { context.client_ip.isIpv4() && context.client_ip.isInRange(ip(\"10.0.0.0/8\")) && context.amount.lessThanOrEqual(decimal(\"1000.00\")) && context.path like \"/api/v*/pay*\" && context.scopes.contains(\"payments:write\") };\n");
    sb.push_str("permit(principal, action == Action::\"pay\", resource) when { context.client_ip.isIpv6() && context.client_ip.isInRange(ip(\"2001:db8::/32\")) && context.amount.lessThan(decimal(\"500.00\")) && context.scopes.containsAll([\"payments:write\", \"ipv6:ok\"]) };\n");
    sb.push_str("permit(principal, action == Action::\"refund\", resource) when { context.amount.greaterThanOrEqual(decimal(\"0.01\")) && context.amount.lessThanOrEqual(decimal(\"250.50\")) && context.path like \"/api/v1/refund\\*/*\" && context.scopes.containsAny([\"admin\", \"finance\"]) };\n");
    sb.push_str("permit(principal, action == Action::\"audit\", resource) when { !context.scopes.isEmpty() && (context.client_ip.isLoopback() || context.client_ip.isInRange(ip(\"192.168.0.0/16\"))) };\n");
    sb.push_str("forbid(principal, action, resource) when { context.client_ip.isInRange(ip(\"10.99.0.0/16\")) || context.amount.greaterThan(decimal(\"900.00\")) };\n");
    sb.push_str("forbid(principal, action == Action::\"pay\", resource) when { context.path like \"*blocked*\" };\n");
    sb
}

fn run_w3f(n: usize) {
    let ps = PolicySet::from_str(&w3_policies()).unwrap();
    let entities = Entities::empty();
    let (user, acct, act) = (Ty::new("User"), Ty::new("Account"), Ty::new("Action"));
    let actions: Vec<EntityUid> = ["pay", "refund", "audit"].iter().map(|a| act.uid(a)).collect();
    let users: Vec<EntityUid> = (0..50).map(|i| user.uid(&format!("u{i}"))).collect();
    let accts: Vec<EntityUid> = (0..10).map(|i| acct.uid(&format!("acct{i}"))).collect();
    let ips = ["10.1.2.3", "10.99.4.5", "192.168.10.20", "127.0.0.1", "2001:db8::42", "2001:dead::1", "172.16.0.1"];
    let decs = ["10.00", "250.50", "499.99", "850.00", "950.00", "0.01", "1200.00"];
    let paths = ["/api/v2/payments/create", "/api/v1/refund*/order-9", "/api/v2/pay-blocked-item", "/api/v1/refund/normal", "/internal/audit/log"];
    let sets: Vec<Vec<&str>> = vec![vec!["payments:write", "ipv6:ok"], vec!["payments:write"], vec!["finance", "read"], vec![]];
    // (i % 7, (i*3) % 7, (i*2) % 5, i % 4) repeats with period lcm(7, 5, 4) = 140
    let ctxs: Vec<Context> = (0..140usize)
        .map(|i| {
            Context::from_pairs([
                ("client_ip".to_string(), RestrictedExpression::new_ip(ips[i % 7])),
                ("amount".to_string(), RestrictedExpression::new_decimal(decs[(i * 3) % 7])),
                ("path".to_string(), RestrictedExpression::new_string(paths[(i * 2) % 5].to_string())),
                ("scopes".to_string(), RestrictedExpression::new_set(sets[i % 4].iter().map(|s| RestrictedExpression::new_string(s.to_string())))),
            ])
            .unwrap()
        })
        .collect();
    let auth = Authorizer::new();
    let mut out = String::with_capacity(n * 24);
    for i in 0..n {
        let req = Request::new(users[i % 50].clone(), actions[i % 3].clone(), accts[i % 10].clone(), ctxs[i % 140].clone(), None).unwrap();
        line(&mut out, i, &auth.is_authorized(&req, &ps, &entities));
    }
    print!("{out}");
}

// ---- W4: JSON entity loading (2,000-entity DAG text, parsed + TC'd `rounds` times) ----------
fn w4_json() -> String {
    let mut v = Vec::new();
    for o in 0..20 {
        v.push(format!("{{\"uid\":{{\"type\":\"Org\",\"id\":\"o{o}\"}},\"attrs\":{{\"name\":\"org {o}\"}},\"parents\":[]}}"));
    }
    for g in 0..200 {
        v.push(format!("{{\"uid\":{{\"type\":\"Group\",\"id\":\"g{g}\"}},\"attrs\":{{\"rank\":{g}}},\"parents\":[{{\"type\":\"Org\",\"id\":\"o{}\"}}]}}", g % 20));
    }
    for u in 0..1780 {
        v.push(format!(
            "{{\"uid\":{{\"type\":\"User\",\"id\":\"u{u}\"}},\"attrs\":{{\"level\":{},\"tags\":[\"t{}\",\"t{}\",\"t{}\"],\"ip\":{{\"__extn\":{{\"fn\":\"ip\",\"arg\":\"10.{}.{}.1\"}}}},\"mgr\":{{\"__entity\":{{\"type\":\"User\",\"id\":\"u{}\"}}}}}},\"parents\":[{{\"type\":\"Group\",\"id\":\"g{}\"}},{{\"type\":\"Group\",\"id\":\"g{}\"}}]}}",
            u % 7, u % 5, u % 11, u % 13, u % 250, u % 200, (u + 1) % 1780, u % 200, (u * 7) % 200
        ));
    }
    format!("[{}]", v.join(","))
}

fn run_w4(rounds: usize) {
    let src = w4_json();
    let ps = PolicySet::from_str("permit(principal in Org::\"o3\", action, resource) when { principal.level > 2 };").unwrap();
    let (user, act, doc) = (Ty::new("User"), Ty::new("Action"), Ty::new("Doc"));
    let mut allows = 0usize;
    let mut count = 0usize;
    for _ in 0..rounds {
        let es = Entities::from_json_str(&src, None).unwrap();
        count = es.iter().count();
        for k in 0..20 {
            let r = Request::new(user.uid(&format!("u{}", k * 89)), act.uid("view"), doc.uid("d"), Context::empty(), None).unwrap();
            if Authorizer::new().is_authorized(&r, &ps, &es).decision() == Decision::Allow {
                allows += 1;
            }
        }
    }
    println!("w4 rounds={rounds} entities={count} allows={allows}");
}

// ---- W5: large-set predicates (contexts pre-built on both sides) -----------------------------
fn run_w5(n: usize) {
    let ps = PolicySet::from_str(concat!(
        "permit(principal, action, resource) when { context.granted.containsAll(context.required) };\n",
        "permit(principal, action, resource) when { context.granted.containsAny(context.flagged) && context.granted.contains(\"s7\") };\n",
        "forbid(principal, action, resource) when { context.revoked == context.required };\n",
    ))
    .unwrap();
    let strs = |lo: usize, hi: usize, step: usize| RestrictedExpression::new_set((lo..hi).step_by(step).map(|k| RestrictedExpression::new_string(format!("s{k}"))));
    let ctxs: Vec<Context> = (0..10usize)
        .map(|v| {
            Context::from_pairs([
                ("granted".to_string(), strs(0, 1000 - v * 37, 1)),
                ("required".to_string(), strs(v * 50, v * 50 + 200, 1)),
                ("flagged".to_string(), strs(1000 + v, 1300, 3)),
                ("revoked".to_string(), strs(v * 50 + (v % 2), v * 50 + 200, 1)),
            ])
            .unwrap()
        })
        .collect();
    let (user, act, doc) = (Ty::new("User"), Ty::new("Action"), Ty::new("Doc"));
    let (p, a, r) = (user.uid("alice"), act.uid("view"), doc.uid("d"));
    let auth = Authorizer::new();
    let es = Entities::empty();
    let mut out = String::new();
    for i in 0..n {
        let req = Request::new(p.clone(), a.clone(), r.clone(), ctxs[i % 10].clone(), None).unwrap();
        line(&mut out, i, &auth.is_authorized(&req, &ps, &es));
    }
    print!("{out}");
}

// ---- W6: like-heavy policies ----------------------------------------------------------------
fn w6_policies() -> String {
    let pats = ["*/api/*/v*/*", "*.example.com", "*admin*", "/static/*.js", "*a*b*c*d*e*", "*-prod-*-*",
                "/users/*/settings", "*\\**", "*%2e%2e*", "*.internal*", "/v1/*/*/*/*", "*?*=*&*=*"];
    let mut sb = String::new();
    for (k, p) in pats.iter().enumerate() {
        let eff = if k % 4 == 3 { "forbid" } else { "permit" };
        let _ = writeln!(sb, "{eff}(principal, action, resource) when {{ context.url like \"{p}\" || context.host like \"{p}\" }};");
    }
    sb
}

fn w6_strings() -> Vec<(String, String)> {
    (0..64usize)
        .map(|v| {
            let seg = "abcdefghij".repeat(1 + v % 5);
            (
                format!(
                    "/api/{}/v{}/{}-prod-{}-x{}{}",
                    seg,
                    v % 3,
                    seg,
                    v,
                    if v % 3 == 0 { format!("?q={}&r={}", v * 7, v % 9) } else { String::new() },
                    if v % 8 == 0 { "*" } else { "" }
                ),
                format!("{}{}.{}", if v % 2 == 0 { "admin-" } else { "" }, seg, if v % 3 == 0 { "example.com" } else { "internal.net" }),
            )
        })
        .collect()
}

fn run_w6(n: usize) {
    let ps = PolicySet::from_str(&w6_policies()).unwrap();
    let ctxs: Vec<Context> = w6_strings()
        .into_iter()
        .map(|(u, h)| Context::from_pairs([("url".to_string(), RestrictedExpression::new_string(u)), ("host".to_string(), RestrictedExpression::new_string(h))]).unwrap())
        .collect();
    let (user, act, doc) = (Ty::new("User"), Ty::new("Action"), Ty::new("Doc"));
    let (p, a, r) = (user.uid("alice"), act.uid("view"), doc.uid("d"));
    let auth = Authorizer::new();
    let es = Entities::empty();
    let mut out = String::new();
    for i in 0..n {
        let req = Request::new(p.clone(), a.clone(), r.clone(), ctxs[i % 64].clone(), None).unwrap();
        line(&mut out, i, &auth.is_authorized(&req, &ps, &es));
    }
    print!("{out}");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let n: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(1000);
    match args.get(1).map(String::as_str) {
        Some("w2f") => run_w2f(n),
        Some("w3f") => run_w3f(n),
        Some("w4") => run_w4(n),
        Some("w5") => run_w5(n),
        Some("w6") => run_w6(n),
        _ => {
            eprintln!("usage: bench_fair <w2f|w3f|w4|w5|w6> <n>");
            std::process::exit(2);
        }
    }
}
