use minijinja::{context, Environment, Value};
use std::collections::BTreeMap;

fn main() {
    let mut env = Environment::new();
    let base_tpl = "<!DOCTYPE html><html><head><title>{% block title %}Dashboard{% endblock %}</title></head><body><main>{% block content %}{% endblock %}</main></body></html>";
    let page_tpl = "{% extends 'base.html' %}{% block title %}{{ super() }} - {{ page_title }}{% endblock %}{% block content %}<h1>{{ heading|title }}</h1><table><tbody>{% for row in rows %}<tr class=\"{{ loop.cycle('odd', 'even') }}\"><td>{{ loop.index }}</td><td>{{ row.name }}</td><td>{{ row.role|upper }}</td><td>{{ row.bio|default('N/A') }}</td></tr>{% endfor %}</tbody></table><p>Total: {{ rows|length }}</p>{% endblock %}";
    env.add_template("base.html", base_tpl).unwrap();
    env.add_template("page.html", page_tpl).unwrap();
    let tpl = env.get_template("page.html").unwrap();

    let mut rows = Vec::with_capacity(20);
    for i in 0..20 {
        let mut m: BTreeMap<&str, Value> = BTreeMap::new();
        m.insert("name", Value::from(format!("User {}", i)));
        m.insert("role", Value::from(if i % 2 == 0 { "admin" } else { "member" }));
        if i % 3 == 0 {
            m.insert("bio", Value::from(format!("Engineer <team-{}> & \"core\" / R&D", i)));
        } else if i % 3 == 1 {
            m.insert("bio", Value::from(format!("Designer 'ui' & layout #{}", i)));
        }
        rows.push(Value::from(m));
    }
    let ctx = context!(
        page_title => "Team <Overview> & Roster",
        heading => "engineering roster",
        rows => rows,
    );

    let iters = 10000usize;
    let mut total_bytes = 0u64;
    let mut last = String::new();
    for r in 0..iters {
        let out = tpl.render(&ctx).unwrap();
        total_bytes += out.len() as u64;
        if r == iters - 1 {
            last = out;
        }
    }

    println!("iters={}", iters);
    println!("total_bytes={}", total_bytes);
    println!("{}", last);
}
