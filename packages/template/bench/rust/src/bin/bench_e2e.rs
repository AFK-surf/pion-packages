use minijinja::{context, Environment};

fn main() {
    let base_tpl = "<!DOCTYPE html><html><head><title>{% block title %}App{% endblock %}</title></head><body>{% include 'nav.html' %}{% block body %}{% endblock %}</body></html>";
    let nav_tpl = "<nav>{% for link in nav %}<a href=\"{{ link.href }}\">{{ link.label }}</a>{% endfor %}</nav>";
    let page_tpl = "{% extends 'base.html' %}{% block title %}{{ title }}{% endblock %}{% block body %}<section>{% for item in items %}<article><h2>{{ item.title }}</h2><p>{{ item.summary }}</p></article>{% endfor %}</section>{% endblock %}";

    let ctx = context!(
        title => "Release Notes <v0.1.0>",
        nav => vec![
            context!(href => "/docs", label => "Docs"),
            context!(href => "/bench", label => "Benchmarks"),
        ],
        items => vec![
            context!(title => "Lexer & AST", summary => "Fast pure-Pion parser & evaluator."),
            context!(title => "Security & Fuel", summary => "Cycle detection & output limits <safe>."),
            context!(title => "Wasm32 Ready", summary => "Zero C deps & deterministic output."),
        ],
    );

    let iters = 2000usize;
    let mut total_bytes = 0u64;
    let mut last = String::new();
    for r in 0..iters {
        let mut env = Environment::new();
        env.add_template("base.html", base_tpl).unwrap();
        env.add_template("nav.html", nav_tpl).unwrap();
        env.add_template("page.html", page_tpl).unwrap();
        let tpl = env.get_template("page.html").unwrap();
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
