//! Rust `handlebars =6.4.4` oracle for the packages/handlebars red-team audit.
//! Same JSONL protocol as audit/probe (see its header): one case per line in, one result per line out.
use handlebars::{
    Context, Handlebars, Helper, HelperResult, Output, RenderContext, RenderError, Renderable,
};
use serde_json::{json, Value};
use std::io::{BufRead, Write};

fn wrap<'reg, 'rc>(
    h: &Helper<'rc>,
    r: &'reg Handlebars<'reg>,
    ctx: &'rc Context,
    rc: &mut RenderContext<'reg, 'rc>,
    out: &mut dyn Output,
) -> HelperResult {
    out.write("<b>")?;
    if let Some(t) = h.template() {
        t.render(r, ctx, rc, out)?;
    }
    out.write("</b>")?;
    Ok(())
}

fn safe(h: &Helper, _: &Handlebars, _: &Context, _: &mut RenderContext, out: &mut dyn Output) -> HelperResult {
    if let Some(Value::String(s)) = h.param(0).map(|p| p.value()) {
        out.write(s)?;
    }
    Ok(())
}

handlebars::handlebars_helper!(echo: |v: Json| v.clone());

fn run(case: &Value) -> Result<String, String> {
    let mut reg = Handlebars::new();
    reg.set_strict_mode(case["strict"].as_bool().unwrap_or(false));
    if case["no_escape"].as_bool().unwrap_or(false) {
        reg.register_escape_fn(handlebars::no_escape);
    }
    reg.register_helper("wrap", Box::new(wrap));
    reg.register_helper("safe", Box::new(safe));
    reg.register_helper("echo", Box::new(echo));
    if let Some(ps) = case["partials"].as_object() {
        for (k, v) in ps {
            reg.register_partial(k, v.as_str().unwrap_or("")).map_err(|e| format!("{e}"))?;
        }
    }
    let data: Value = serde_json::from_str(case["data"].as_str().unwrap_or("{}")).map_err(|e| format!("json: {e}"))?;
    reg.render_template(case["tmpl"].as_str().unwrap_or(""), &data).map_err(|e: RenderError| format!("{e}"))
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: rt_handlebars_oracle <cases.jsonl>");
    let f = std::io::BufReader::new(std::fs::File::open(path).unwrap());
    let stdout = std::io::stdout();
    let mut o = std::io::BufWriter::new(stdout.lock());
    for line in f.lines() {
        let line = line.unwrap();
        if line.is_empty() {
            continue;
        }
        let case: Value = serde_json::from_str(&line).unwrap();
        let id = case["id"].clone();
        // A panic inside the engine is reported as an error result, not a crashed oracle.
        let r = std::panic::catch_unwind(|| run(&case)).unwrap_or_else(|_| Err("panic".into()));
        let v = match r {
            Ok(s) => json!({"id": id, "ok": true, "out": s}),
            Err(m) => json!({"id": id, "ok": false, "kind": "Error", "msg": m}),
        };
        writeln!(o, "{}", v).unwrap();
    }
}
