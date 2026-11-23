use std::env;
use std::fs;
use sxd_document::parser;
use sxd_xpath::{Context, Factory, Value, XPath};

fn eval_int(xpath: &XPath, ctx: &Context<'_>, root: sxd_document::dom::Root<'_>) -> i64 {
    match xpath.evaluate(ctx, root) {
        Ok(v) => v.number() as i64,
        Err(_) => -1,
    }
}

fn run_w1(root: sxd_document::dom::Root<'_>, rounds: usize) -> String {
    let queries = [
        "count(/catalog/section/book[@available='true' and price >= 50])",
        "sum(/catalog/section[@name='systems']/book/price)",
        "count(//book[@lang='en' or @lang='ja'][year >= 2015])",
        "count(//book[tags/tag = 'wasm' and tags/tag = 'core'])",
        "string-length(normalize-space((//book[@id='b1500']/title)[1]))",
        "count(/catalog/section[1]/book[position() <= 20] | /catalog/section[last()]/book[position() > 280])",
        "sum(//section[@name='compilers']/book[@available='true']/price)",
        "count(//book[contains(summary, 'security') and price < 40])",
        "count(//book[starts-with(@id, 'b10')]/tags/tag)",
        "count(//section[@name='ml']/book[1]/following-sibling::book[@lang='en'])",
    ];
    let factory = Factory::new();
    let ctx = Context::new();
    let compiled: Vec<XPath> = queries
        .iter()
        .map(|q| factory.build(q).expect("parse").expect("some"))
        .collect();

    let mut acc: i64 = 0;
    let mut vec_str = String::new();
    for r in 0..rounds {
        for xp in &compiled {
            acc += eval_int(xp, &ctx, root);
        }
        if r == 0 {
            let parts: Vec<String> = compiled
                .iter()
                .map(|xp| eval_int(xp, &ctx, root).to_string())
                .collect();
            vec_str = parts.join(",");
        }
    }
    format!("w1 rounds={} sum={} vec={}", rounds, acc, vec_str)
}

fn run_w2(root: sxd_document::dom::Root<'_>, iters: usize) -> String {
    let queries = [
        "count(/store/item[@lang='en'])",
        "sum(/store/item[@stock > 0]/cost)",
        "string-length(string(/store/item[@id='i10']/name))",
        "count(/store/item/meta[tier = 2])",
        "number(/store/item[5]/cost) * 2",
        "count(/store/item[starts-with(meta/sku, 'SKU-002')])",
        "count(/store/item[@lang='fr' or @lang='de'])",
        "string-length(concat(/store/item[1]/name, '-', /store/item[2]/name))",
        "count(/store/item[cost >= 30 and cost <= 50])",
        "count(/store/item[last()]/preceding-sibling::item[@lang='ja'])",
    ];
    let factory = Factory::new();
    let ctx = Context::new();
    let mut acc: i64 = 0;
    for i in 0..iters {
        let q = queries[i % queries.len()];
        let xp = factory.build(q).expect("parse").expect("some");
        let val: Value = xp.evaluate(&ctx, root).expect("eval");
        acc += val.number() as i64;
    }
    format!("w2 iters={} sum={}", iters, acc)
}

fn run_w3(root: sxd_document::dom::Root<'_>, rounds: usize) -> String {
    let queries = [
        "count(descendant-or-self::*[ancestor::dept[@region='r0'] and @active='yes'])",
        "sum(descendant-or-self::project[ancestor::team[@tier='1']]/budget)",
        "count(//project[@active='yes']/following-sibling::project[@active='yes'])",
        "sum(//milestone[ancestor::dept[@region='r2']]/hours)",
        "count(//project[string-length(normalize-space(label)) >= 8])",
    ];
    let factory = Factory::new();
    let ctx = Context::new();
    let compiled: Vec<XPath> = queries
        .iter()
        .map(|q| factory.build(q).expect("parse").expect("some"))
        .collect();

    let mut acc: i64 = 0;
    let mut vec_str = String::new();
    for r in 0..rounds {
        for xp in &compiled {
            acc += eval_int(xp, &ctx, root);
        }
        if r == 0 {
            let parts: Vec<String> = compiled
                .iter()
                .map(|xp| eval_int(xp, &ctx, root).to_string())
                .collect();
            vec_str = parts.join(",");
        }
    }
    format!("w3 rounds={} sum={} vec={}", rounds, acc, vec_str)
}

fn run_batch(tag: &str, queries: &[&str], root: sxd_document::dom::Root<'_>, rounds: usize) -> String {
    let factory = Factory::new();
    let ctx = Context::new();
    let compiled: Vec<XPath> = queries
        .iter()
        .map(|q| factory.build(q).expect("parse").expect("some"))
        .collect();

    let mut acc: i64 = 0;
    let mut vec_str = String::new();
    for r in 0..rounds {
        for xp in &compiled {
            acc += eval_int(xp, &ctx, root);
        }
        if r == 0 {
            let parts: Vec<String> = compiled
                .iter()
                .map(|xp| eval_int(xp, &ctx, root).to_string())
                .collect();
            vec_str = parts.join(",");
        }
    }
    format!("{} rounds={} sum={} vec={}", tag, rounds, acc, vec_str)
}

fn run_w4(root: sxd_document::dom::Root<'_>, rounds: usize) -> String {
    let queries = [
        "number(//a = //b)",
        "number(//a != //b)",
        "number(//a < //b)",
        "number(//a > //b)",
    ];
    run_batch("w4", &queries, root, rounds)
}

fn run_w5(root: sxd_document::dom::Root<'_>, rounds: usize) -> String {
    let queries = [
        "count(/r/e)",
        "count(//@k)",
        "count(//e[@k >= 25000])",
        "sum(//e[@k < 1000]/@k)",
    ];
    run_batch("w5", &queries, root, rounds)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: rust_xpath <w1|w2|w3|w4|w5> <xml_path> <iters>");
        std::process::exit(1);
    }
    let mode = &args[1];
    let path = &args[2];
    let iters: usize = args[3].parse().unwrap_or(1);
    let xml = fs::read_to_string(path).expect("read xml");
    let pkg = parser::parse(&xml).expect("parse xml");
    let doc = pkg.as_document();
    let root = doc.root();
    let out = match mode.as_str() {
        "w1" => run_w1(root, iters),
        "w2" => run_w2(root, iters),
        "w3" => run_w3(root, iters),
        "w4" => run_w4(root, iters),
        _ => run_w5(root, iters),
    };
    println!("{}", out);
}
