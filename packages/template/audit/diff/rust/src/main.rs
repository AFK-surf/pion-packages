//! Rust `minijinja =3.1.0` mirror of audit/probe: same corpus format, same fixed context,
//! same output records (name 0x1F OK|ERR 0x1F output-or-error 0x1E).
use indexmap::IndexMap;
use minijinja::{AutoEscape, Environment, UndefinedBehavior, Value};
use std::io::Write;

fn map(pairs: Vec<(&str, Value)>) -> Value {
    let mut m: IndexMap<Value, Value> = IndexMap::new();
    for (k, v) in pairs {
        m.insert(Value::from(k), v);
    }
    Value::from_object(m)
}

fn user(name: &str, age: i64, active: bool, group: &str) -> Value {
    map(vec![
        ("name", Value::from(name)),
        ("age", Value::from(age)),
        ("active", Value::from(active)),
        ("group", Value::from(group)),
    ])
}

fn ctx() -> Value {
    let iv = |x: i64| Value::from(x);
    let sv = |x: &str| Value::from(x);
    map(vec![
        ("xss", sv("<script>alert(\"x\")</script> & 'q' /")),
        ("close", sv("</script><script>alert(1)</script>")),
        ("attr", sv("\" onmouseover=\"alert(1)")),
        ("amp", sv("a&b")),
        ("plain", sv("hello world")),
        ("padded", sv("  padded  ")),
        ("multi", sv("line1\nline2\n\nline4")),
        ("uni", sv("héllo wörld ✓")),
        ("n", iv(42)),
        ("neg", iv(-7)),
        ("zero", iv(0)),
        ("f", Value::from(2.5f64)),
        ("imax", iv(i64::MAX)),
        ("imin", iv(i64::MIN)),
        ("t", Value::from(true)),
        ("fz", Value::from(false)),
        ("nil", Value::from(())),
        ("items", Value::from(vec![iv(3), iv(1), iv(2), iv(3)])),
        ("words", Value::from(vec![sv("b"), sv("a"), sv("C"), sv("a")])),
        ("empty", Value::from(Vec::<Value>::new())),
        (
            "users",
            Value::from(vec![
                user("alice<b>", 30, true, "admin"),
                user("bob", 25, false, "dev"),
                user("carol", 35, true, "dev"),
            ]),
        ),
        ("m", map(vec![("b", iv(1)), ("a", iv(2))])),
        ("safe_html", Value::from_safe_string("<b>ok</b>".into())),
    ])
}

fn run_case(f: &[&str]) -> String {
    let name = f[0];
    let flags: Vec<&str> = f[1].split(',').collect();
    let has = |x: &str| flags.iter().any(|y| *y == x);
    let mut env = Environment::new();
    let mode = if has("html") {
        AutoEscape::Html
    } else if has("json") {
        AutoEscape::Json
    } else {
        AutoEscape::None
    };
    env.set_auto_escape_callback(move |_| mode.clone());
    if has("strict") {
        env.set_undefined_behavior(UndefinedBehavior::Strict);
    }
    env.set_syntax(
        minijinja::syntax::SyntaxConfig::builder()
            .trim_blocks(has("trim"))
            .lstrip_blocks(has("lstrip"))
            .keep_trailing_newline(has("keepnl"))
            .build()
            .unwrap(),
    );
    if let Ok(fuel) = std::env::var("RUST_FUEL") {
        env.set_fuel(Some(fuel.parse().unwrap()));
    }
    let err = |e: minijinja::Error| format!("{name}\x1fERR\x1f{:?}: {}\x1e", e.kind(), e);
    let mut k = 3;
    while k + 1 < f.len() {
        if let Err(e) = env.add_template_owned(f[k].to_string(), f[k + 1].to_string()) {
            return err(e);
        }
        k += 2;
    }
    if let Err(e) = env.add_template_owned("main", f[2].to_string()) {
        return err(e);
    }
    match env.get_template("main").and_then(|t| t.render(ctx())) {
        Ok(out) => format!("{name}\x1fOK\x1f{out}\x1e"),
        Err(e) => err(e),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let data = std::fs::read(&args[2]).expect("corpus");
    let data = String::from_utf8(data).expect("utf8 corpus");
    let only = if args[1] == "one" { Some(args[3].as_str()) } else { None };
    let mut stdout = std::io::stdout().lock();
    for rec in data.split('\x1e') {
        let f: Vec<&str> = rec.split('\x1f').collect();
        if f.len() < 3 {
            continue;
        }
        if only.map_or(true, |o| o == f[0]) {
            stdout.write_all(run_case(&f).as_bytes()).unwrap();
        }
    }
}
