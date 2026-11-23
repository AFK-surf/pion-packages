use cedar_policy::{
    Authorizer, Context, Decision, Effect, Entities, Entity, EntityId, EntityTypeName, EntityUid,
    PolicySet, Request, RestrictedExpression,
};
use std::collections::{HashMap, HashSet};
use std::env;
use std::fmt::Write as FmtWrite;
use std::str::FromStr;

fn format_decision_line(out: &mut String, idx: usize, resp: &cedar_policy::Response) {
    let dec = match resp.decision() {
        Decision::Allow => "Allow",
        Decision::Deny => "Deny",
    };
    let mut reasons: Vec<String> = resp
        .diagnostics()
        .reason()
        .map(|id| id.to_string())
        .collect();
    reasons.sort();
    let _ = writeln!(out, "{}:{}:{}", idx, dec, reasons.join(","));
}

fn build_w1_corpus() -> String {
    let mut sb = String::new();
    for i in 0..200 {
        let tid = i % 20;
        let fid = i % 12;
        let lvl = 1 + (i % 5);
        if i % 10 < 7 {
            let _ = write!(
                sb,
                "permit(\n  principal in Team::\"t{}\",\n  action in [Action::\"read\", Action::\"write\"],\n  resource is Doc in Folder::\"f{}\"\n)\nwhen {{\n  principal.active && principal.level >= {} && (resource.tenant == \"t{}\" || resource.owner == principal)\n}};\n",
                tid,
                fid,
                lvl,
                i % 5
            );
        } else {
            let _ = write!(
                sb,
                "forbid(\n  principal in Org::\"acme\",\n  action == Action::\"delete\",\n  resource is Doc in Folder::\"f{}\"\n)\nwhen {{\n  resource.locked || !(context.mfa && principal.clearance >= {})\n}};\n",
                fid,
                i % 4
            );
        }
    }
    sb
}

fn run_w1(rounds: usize) {
    let corpus = build_w1_corpus();
    let mut total_policies = 0usize;
    let mut total_permits = 0usize;
    let mut total_forbids = 0usize;
    let mut total_rt_ok = 0usize;
    for _ in 0..rounds {
        let ps = PolicySet::from_str(&corpus).expect("w1 parse failed");
        for pol in ps.policies() {
            total_policies += 1;
            match pol.effect() {
                Effect::Permit => total_permits += 1,
                Effect::Forbid => total_forbids += 1,
            }
            let fmt = pol.to_string();
            if !fmt.is_empty() {
                total_rt_ok += 1;
            }
        }
    }
    println!(
        "w1 rounds={} policies={} permits={} forbids={} formatted={}",
        rounds, total_policies, total_permits, total_forbids, total_rt_ok
    );
}

fn build_w2_policies() -> String {
    let mut sb = String::new();
    for i in 0..60 {
        let t = i % 20;
        let d = i % 5;
        let f = i % 24;
        if i < 20 {
            let _ = writeln!(
                sb,
                "permit(principal in Team::\"t{}\", action in [Action::\"read\", Action::\"write\"], resource in Folder::\"f{}\") when {{ principal.active && principal.level >= {} }};",
                t,
                f,
                1 + (i % 3)
            );
        } else if i < 32 {
            let _ = writeln!(
                sb,
                "permit(principal in Dept::\"d{}\", action == Action::\"read\", resource in Org::\"acme\") when {{ principal.active && principal.clearance >= resource.classification }};",
                d
            );
        } else if i < 42 {
            let _ = writeln!(
                sb,
                "permit(principal is User in Org::\"acme\", action in [Action::\"read\", Action::\"write\", Action::\"delete\", Action::\"share\"], resource is Doc in Folder::\"f{}\") when {{ resource.owner == principal && context.risk_score < 80 }};",
                i % 12
            );
        } else if i < 52 {
            let _ = writeln!(
                sb,
                "forbid(principal, action in [Action::\"write\", Action::\"delete\"], resource in Folder::\"f{}\") when {{ resource.locked }};",
                i % 12
            );
        } else {
            let _ = writeln!(
                sb,
                "forbid(principal in Dept::\"d{}\", action in [Action::\"delete\", Action::\"share\"], resource) when {{ !context.mfa || context.risk_score >= 70 }};",
                d
            );
        }
    }
    sb
}

fn uid(ty: &str, id: &str) -> EntityUid {
    EntityUid::from_type_name_and_id(
        EntityTypeName::from_str(ty).unwrap(),
        EntityId::from_str(id).unwrap(),
    )
}

fn build_w2_entities() -> Entities {
    let mut list: Vec<Entity> = Vec::with_capacity(250);
    let org = uid("Org", "acme");
    list.push(Entity::new(org.clone(), HashMap::new(), HashSet::new()).unwrap());

    for i in 0..5 {
        let mut parents = HashSet::new();
        parents.insert(org.clone());
        list.push(Entity::new(uid("Dept", &format!("d{}", i)), HashMap::new(), parents).unwrap());
    }
    for i in 0..20 {
        let mut parents = HashSet::new();
        parents.insert(uid("Dept", &format!("d{}", i % 5)));
        list.push(Entity::new(uid("Team", &format!("t{}", i)), HashMap::new(), parents).unwrap());
    }
    for i in 0..100 {
        let mut parents = HashSet::new();
        parents.insert(uid("Team", &format!("t{}", i % 20)));
        let mut attrs = HashMap::new();
        attrs.insert("level".to_string(), RestrictedExpression::new_long((1 + (i % 5)) as i64));
        attrs.insert("active".to_string(), RestrictedExpression::new_bool(i % 10 != 0));
        attrs.insert("clearance".to_string(), RestrictedExpression::new_long((i % 4) as i64));
        list.push(Entity::new(uid("User", &format!("u{}", i)), attrs, parents).unwrap());
    }
    for i in 0..24 {
        let mut parents = HashSet::new();
        if i < 12 {
            parents.insert(org.clone());
        } else {
            parents.insert(uid("Folder", &format!("f{}", i - 12)));
        }
        list.push(Entity::new(uid("Folder", &format!("f{}", i)), HashMap::new(), parents).unwrap());
    }
    for i in 0..100 {
        let mut parents = HashSet::new();
        parents.insert(uid("Folder", &format!("f{}", i % 24)));
        let mut attrs = HashMap::new();
        attrs.insert(
            "owner".to_string(),
            RestrictedExpression::new_entity_uid(uid("User", &format!("u{}", i))),
        );
        attrs.insert("classification".to_string(), RestrictedExpression::new_long((i % 4) as i64));
        attrs.insert("locked".to_string(), RestrictedExpression::new_bool(i % 13 == 0));
        list.push(Entity::new(uid("Doc", &format!("doc{}", i)), attrs, parents).unwrap());
    }
    Entities::from_entities(list, None).unwrap()
}

fn run_w2(num_reqs: usize) {
    let ps = PolicySet::from_str(&build_w2_policies()).unwrap();
    let entities = build_w2_entities();
    let actions = [
        uid("Action", "read"),
        uid("Action", "write"),
        uid("Action", "delete"),
        uid("Action", "share"),
    ];
    let auth = Authorizer::new();
    let mut out = String::with_capacity(num_reqs * 32);
    for i in 0..num_reqs {
        let u = (i * 7 + 3) % 100;
        let a = (i * 3 + 1) % 4;
        let d = (i * 11 + 5) % 100;
        let mfa = (i % 3) != 0;
        let risk = ((i * 17) % 100) as i64;
        let ctx = Context::from_pairs([
            ("mfa".to_string(), RestrictedExpression::new_bool(mfa)),
            ("risk_score".to_string(), RestrictedExpression::new_long(risk)),
        ])
        .unwrap();
        let req = Request::new(
            uid("User", &format!("u{}", u)),
            actions[a].clone(),
            uid("Doc", &format!("doc{}", d)),
            ctx,
            None,
        )
        .unwrap();
        let resp = auth.is_authorized(&req, &ps, &entities);
        format_decision_line(&mut out, i, &resp);
    }
    print!("{}", out);
}

fn build_w3_policies() -> String {
    let mut sb = String::new();
    sb.push_str("permit(principal, action == Action::\"pay\", resource) when { context.client_ip.isIpv4() && context.client_ip.isInRange(ip(\"10.0.0.0/8\")) && context.amount.lessThanOrEqual(decimal(\"1000.00\")) && context.path like \"/api/v*/pay*\" && context.scopes.contains(\"payments:write\") };\n");
    sb.push_str("permit(principal, action == Action::\"pay\", resource) when { context.client_ip.isIpv6() && context.client_ip.isInRange(ip(\"2001:db8::/32\")) && context.amount.lessThan(decimal(\"500.00\")) && context.scopes.containsAll([\"payments:write\", \"ipv6:ok\"]) };\n");
    sb.push_str("permit(principal, action == Action::\"refund\", resource) when { context.amount.greaterThanOrEqual(decimal(\"0.01\")) && context.amount.lessThanOrEqual(decimal(\"250.50\")) && context.path like \"/api/v1/refund\\*/*\" && context.scopes.containsAny([\"admin\", \"finance\"]) };\n");
    sb.push_str("permit(principal, action == Action::\"audit\", resource) when { !context.scopes.isEmpty() && (context.client_ip.isLoopback() || context.client_ip.isInRange(ip(\"192.168.0.0/16\"))) };\n");
    sb.push_str("forbid(principal, action, resource) when { context.client_ip.isInRange(ip(\"10.99.0.0/16\")) || context.amount.greaterThan(decimal(\"900.00\")) };\n");
    sb.push_str("forbid(principal, action == Action::\"pay\", resource) when { context.path like \"*blocked*\" };\n");
    sb
}

fn run_w3(num_reqs: usize) {
    let ps = PolicySet::from_str(&build_w3_policies()).unwrap();
    let entities = Entities::empty();
    let actions = [
        uid("Action", "pay"),
        uid("Action", "refund"),
        uid("Action", "audit"),
    ];
    let ip_exprs = [
        RestrictedExpression::new_ip("10.1.2.3"),
        RestrictedExpression::new_ip("10.99.4.5"),
        RestrictedExpression::new_ip("192.168.10.20"),
        RestrictedExpression::new_ip("127.0.0.1"),
        RestrictedExpression::new_ip("2001:db8::42"),
        RestrictedExpression::new_ip("2001:dead::1"),
        RestrictedExpression::new_ip("172.16.0.1"),
    ];
    let dec_exprs = [
        RestrictedExpression::new_decimal("10.00"),
        RestrictedExpression::new_decimal("250.50"),
        RestrictedExpression::new_decimal("499.99"),
        RestrictedExpression::new_decimal("850.00"),
        RestrictedExpression::new_decimal("950.00"),
        RestrictedExpression::new_decimal("0.01"),
        RestrictedExpression::new_decimal("1200.00"),
    ];
    let paths = [
        "/api/v2/payments/create",
        "/api/v1/refund*/order-9",
        "/api/v2/pay-blocked-item",
        "/api/v1/refund/normal",
        "/internal/audit/log",
    ];
    let scope_sets = [
        RestrictedExpression::new_set([
            RestrictedExpression::new_string("payments:write".to_string()),
            RestrictedExpression::new_string("ipv6:ok".to_string()),
        ]),
        RestrictedExpression::new_set([RestrictedExpression::new_string(
            "payments:write".to_string(),
        )]),
        RestrictedExpression::new_set([
            RestrictedExpression::new_string("finance".to_string()),
            RestrictedExpression::new_string("read".to_string()),
        ]),
        RestrictedExpression::new_set([]),
    ];

    let auth = Authorizer::new();
    let mut out = String::with_capacity(num_reqs * 24);
    for i in 0..num_reqs {
        let ctx = Context::from_pairs([
            ("client_ip".to_string(), ip_exprs[i % 7].clone()),
            ("amount".to_string(), dec_exprs[(i * 3) % 7].clone()),
            (
                "path".to_string(),
                RestrictedExpression::new_string(paths[(i * 2) % 5].to_string()),
            ),
            ("scopes".to_string(), scope_sets[i % 4].clone()),
        ])
        .unwrap();
        let req = Request::new(
            uid("User", &format!("u{}", i % 50)),
            actions[i % 3].clone(),
            uid("Account", &format!("acct{}", i % 10)),
            ctx,
            None,
        )
        .unwrap();
        let resp = auth.is_authorized(&req, &ps, &entities);
        format_decision_line(&mut out, i, &resp);
    }
    print!("{}", out);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: cedar_rust_bench <w1|w2|w3> [count]");
        std::process::exit(1);
    }
    let mode = args[1].as_str();
    match mode {
        "w1" => {
            let count = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(50);
            run_w1(count);
        }
        "w2" => {
            let count = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(3000);
            run_w2(count);
        }
        "w3" => {
            let count = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(2000);
            run_w3(count);
        }
        _ => {
            eprintln!("unknown mode: {}", mode);
            std::process::exit(1);
        }
    }
}
