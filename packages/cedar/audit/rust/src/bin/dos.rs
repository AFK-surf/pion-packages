//! DoS / complexity probes on Rust `cedar-policy =4.15.0`; twin of `audit/dos/pion_dos`.
//! Same `<probe> <n> [m]` CLI, same single output line (see the Pion file for the probe list).
use cedar_policy::{
    Authorizer, Context, Decision, Entities, Entity, EntityId, EntityTypeName, EntityUid, PolicySet,
    Request, RestrictedExpression,
};
use std::collections::{HashMap, HashSet};
use std::str::FromStr;

fn uid(t: &str, id: &str) -> EntityUid {
    EntityUid::from_type_name_and_id(EntityTypeName::from_str(t).unwrap(), EntityId::new(id))
}

fn req(p: EntityUid, ctx: Context) -> Request {
    Request::new(p, uid("Action", "view"), uid("Doc", "d"), ctx, None).unwrap()
}

fn show(ps: &PolicySet, r: &Request, e: &Entities) -> String {
    let resp = Authorizer::new().is_authorized(r, ps, e);
    let d = if resp.decision() == Decision::Allow { "Allow" } else { "Deny" };
    format!("{} errors={}", d, resp.diagnostics().errors().count())
}

fn auth_src(src: &str, ctx: Context) -> String {
    match PolicySet::from_str(src) {
        Ok(ps) => show(&ps, &req(uid("User", "alice"), ctx), &Entities::empty()),
        Err(_) => "PERR".to_string(),
    }
}

fn long_set(n: usize, rev: bool) -> RestrictedExpression {
    RestrictedExpression::new_set((0..n).map(|i| {
        RestrictedExpression::new_long(if rev { (n - 1 - i) as i64 } else { i as i64 })
    }))
}

fn json_long_array(n: usize) -> String {
    let v: Vec<String> = (0..n).map(|i| i.to_string()).collect();
    format!("[{}]", v.join(","))
}

fn chain(n: usize, rev: bool) -> String {
    let mut list = Vec::with_capacity(n);
    for i in 0..n {
        let mut parents = HashSet::new();
        if rev && i > 0 {
            parents.insert(uid("G", &format!("g{}", i - 1)));
        }
        if !rev && i + 1 < n {
            parents.insert(uid("G", &format!("g{}", i + 1)));
        }
        list.push(Entity::new(uid("G", &format!("g{i}")), HashMap::new(), parents).unwrap());
    }
    let es = match Entities::from_entities(list, None) {
        Ok(e) => e,
        Err(_) => return "EERR".to_string(),
    };
    let (c, p) = if rev { (n - 1, 0) } else { (0, n - 1) };
    let ps = PolicySet::from_str(&format!("permit(principal in G::\"g{p}\", action, resource);")).unwrap();
    let r = req(uid("G", &format!("g{c}")), Context::empty());
    let allow = Authorizer::new().is_authorized(&r, &ps, &es).decision() == Decision::Allow;
    format!("in={allow}")
}

fn run(probe: &str, n: usize, m: usize) -> String {
    match probe {
        "chain_rev" => chain(n, true),
        "chain_fwd" => chain(n, false),
        "star" => {
            let mut list = vec![Entity::new_no_attrs(uid("G", "root"), HashSet::new())];
            for i in 0..n {
                let mut parents = HashSet::new();
                parents.insert(uid("G", "root"));
                list.push(Entity::new_no_attrs(uid("U", &format!("u{i}")), parents));
            }
            let es = Entities::from_entities(list, None).unwrap();
            let ps = PolicySet::from_str("permit(principal in G::\"root\", action, resource);").unwrap();
            let r = req(uid("U", &format!("u{}", n - 1)), Context::empty());
            let allow = Authorizer::new().is_authorized(&r, &ps, &es).decision() == Decision::Allow;
            format!("in={allow}")
        }
        "ctx_set" => {
            let src = format!("{{\"s\":{}}}", json_long_array(n));
            let ctx = match Context::from_json_str(&src, None) {
                Ok(c) => c,
                Err(_) => return "RERR".to_string(),
            };
            auth_src(
                &format!("permit(principal, action, resource) when {{ context.s.contains({}) }};", n - 1),
                ctx,
            )
        }
        "ent_set" => {
            let src = format!(
                "[{{\"uid\":{{\"type\":\"User\",\"id\":\"alice\"}},\"attrs\":{{\"s\":{}}},\"parents\":[]}}]",
                json_long_array(n)
            );
            match Entities::from_json_str(&src, None) {
                Ok(es) => format!("entities={}", es.iter().count()),
                Err(_) => "EERR".to_string(),
            }
        }
        "set_lit" => {
            let v: Vec<String> = (0..n).map(|i| i.to_string()).collect();
            auth_src(
                &format!(
                    "permit(principal, action, resource) when {{ [{}].contains({}) }};",
                    v.join(","),
                    n - 1
                ),
                Context::empty(),
            )
        }
        "contains_all" | "set_eq" => {
            let ctx = Context::from_pairs([
                ("a".to_string(), long_set(n, false)),
                ("b".to_string(), long_set(n, true)),
            ])
            .unwrap();
            let src = if probe == "set_eq" {
                "permit(principal, action, resource) when { context.a == context.b };"
            } else {
                "permit(principal, action, resource) when { context.a.containsAll(context.b) };"
            };
            auth_src(src, ctx)
        }
        "like" => {
            let s = "a".repeat(n);
            let pat = format!("{}*b", "*a".repeat(m));
            let ctx = Context::from_pairs([("s".to_string(), RestrictedExpression::new_string(s))]).unwrap();
            auth_src(
                &format!("permit(principal, action, resource) when {{ !(context.s like \"{pat}\") }};"),
                ctx,
            )
        }
        "fmt_chain" | "parse_chain" | "fmt_chain_default" => {
            let mut src = String::from("permit(principal, action, resource) when { true");
            for _ in 1..n {
                src.push_str(" || true");
            }
            src.push_str(" };");
            match PolicySet::from_str(&src) {
                Ok(ps) => {
                    if probe == "parse_chain" {
                        format!("parsed policies={}", ps.policies().count())
                    } else {
                        let f = ps.to_cedar().unwrap_or_default();
                        format!("parsed policies={} formatted_nonempty={}", ps.policies().count(), !f.is_empty())
                    }
                }
                Err(_) => "PERR".to_string(),
            }
        }
        "budget" => {
            let mut src = String::from("permit(principal, action, resource);\n");
            for _ in 0..n {
                src.push_str("permit(principal, action, resource) when { context.n == 0");
                for k in 1..33 {
                    src.push_str(&format!(" || context.n == {k}"));
                }
                src.push_str(" };\n");
            }
            src.push_str("forbid(principal, action, resource) when { context.n == 99 };\n");
            let ctx = Context::from_pairs([("n".to_string(), RestrictedExpression::new_long(99))]).unwrap();
            auth_src(&src, ctx)
        }
        "deep_eval" | "deep_parse" => {
            // n == 0: Pion probes max_safe_depth() - 6 (250 in v0.1.0); cedar-policy answers the same
            // at that depth and far beyond, so 250 stands in for "whatever Pion's ceiling is".
            let n = if n == 0 { 250 } else { n };
            let src = format!(
                "permit(principal, action, resource) when {{ {}true{} }};",
                "(".repeat(n),
                ")".repeat(n)
            );
            match PolicySet::from_str(&src) {
                Ok(ps) => {
                    if probe == "deep_parse" {
                        format!("parsed policies={}", ps.policies().count())
                    } else {
                        show(&ps, &req(uid("User", "alice"), Context::empty()), &Entities::empty())
                    }
                }
                Err(_) => "PERR".to_string(),
            }
        }
        _ => "unknown probe".to_string(),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: dos <probe> <n> [m]");
        std::process::exit(2);
    }
    let n: usize = args[2].parse().unwrap();
    let m: usize = args.get(3).map(|s| s.parse().unwrap()).unwrap_or(0);
    let probe = args[1].clone();
    let line = std::thread::Builder::new()
        .stack_size(1 << 30)
        .spawn(move || run(&probe, n, m))
        .unwrap()
        .join()
        .unwrap();
    println!("probe={} n={} {}", args[1], args[2], line);
}
