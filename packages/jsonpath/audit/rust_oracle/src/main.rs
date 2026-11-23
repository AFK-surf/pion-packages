//! Rust reference oracle (serde_json_path 0.7.2 + json-patch 4.2.0 + jsonptr 0.7.1)
//! for the packages/jsonpath red-team audit. Same JSONL protocol as audit/pion_driver.
use serde_json::{json, Map, Value};
use serde_json_path::JsonPath;
use std::io::Write;

fn s(v: &Value) -> String {
    serde_json::to_string(v).unwrap()
}

fn err(id: &str, kind: &str) -> Value {
    json!({"id": id, "ok": false, "kind": kind})
}

fn field<'a>(c: &'a Value, k: &str) -> Value {
    c.get(k).cloned().unwrap_or(Value::Null)
}

fn run(c: &Value) -> Value {
    let id = c.get("id").and_then(|v| v.as_str()).unwrap_or("");
    let op = c.get("op").and_then(|v| v.as_str()).unwrap_or("");
    match op {
        "query" => {
            let sel = c.get("selector").and_then(|v| v.as_str()).unwrap_or("");
            let doc = field(c, "document");
            let jp = match JsonPath::parse(sel) {
                Ok(p) => p,
                Err(_) => return err(id, "ParseError"),
            };
            let vals: Vec<Value> = jp.query(&doc).all().into_iter().cloned().collect();
            let located = jp.query_located(&doc);
            let paths: Vec<Value> = located
                .iter()
                .map(|n| Value::String(n.location().to_string()))
                .collect();
            let pvals: Vec<Value> = located.iter().map(|n| n.node().clone()).collect();
            let vt = s(&Value::Array(vals));
            let pt = s(&Value::Array(pvals));
            json!({"id": id, "ok": true, "values": vt, "paths": paths, "values_paths_consistent": vt == pt})
        }
        "parse" => {
            let text = c.get("text").and_then(|v| v.as_str()).unwrap_or("");
            match serde_json::from_str::<Value>(text) {
                Ok(v) => {
                    let out = s(&v);
                    let rt = serde_json::from_str::<Value>(&out).map(|v2| v2 == v).unwrap_or(false);
                    json!({"id": id, "ok": true, "text": out, "roundtrip": rt})
                }
                Err(_) => err(id, "JsonError"),
            }
        }
        "pointer" => {
            let p = c.get("pointer").and_then(|v| v.as_str()).unwrap_or("");
            let doc = field(c, "document");
            let ptr = match jsonptr::Pointer::parse(p) {
                Ok(p) => p,
                Err(_) => return err(id, "PointerError"),
            };
            match ptr.resolve(&doc) {
                Ok(v) => json!({"id": id, "ok": true, "found": true, "value": s(v), "to_string": ptr.as_str()}),
                Err(_) => json!({"id": id, "ok": true, "found": false, "to_string": ptr.as_str()}),
            }
        }
        "patch" => {
            let mut doc = field(c, "document");
            let before = s(&doc);
            let patch: json_patch::Patch = match serde_json::from_value(field(c, "patch")) {
                Ok(p) => p,
                Err(_) => return err(id, "PatchError"),
            };
            match json_patch::patch(&mut doc, &patch) {
                Ok(()) => json!({"id": id, "ok": true, "value": s(&doc), "doc_unchanged": true}),
                Err(_) => json!({"id": id, "ok": false, "kind": "PatchError", "doc_unchanged": s(&doc) == before}),
            }
        }
        "merge" => {
            let mut t = field(c, "target");
            json_patch::merge(&mut t, &field(c, "patch"));
            json!({"id": id, "ok": true, "value": s(&t)})
        }
        "diff" => {
            let before = field(c, "before");
            let after = field(c, "after");
            let p = json_patch::diff(&before, &after);
            let pv = serde_json::to_value(&p).unwrap();
            let mut d = before.clone();
            match json_patch::patch(&mut d, &p) {
                Ok(()) => json!({"id": id, "ok": true, "patch": s(&pv), "applied": s(&d), "roundtrip_eq": d == after}),
                Err(_) => json!({"id": id, "ok": false, "kind": "PatchError", "patch": s(&pv)}),
            }
        }
        "eq" => json!({"id": id, "ok": true, "equal": field(c, "a") == field(c, "b")}),
        _ => err(id, "UnknownOp"),
    }
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: rust_oracle <cases.jsonl>");
    let src = std::fs::read_to_string(path).expect("read cases");
    let out = std::io::stdout();
    let mut out = out.lock();
    for line in src.lines().filter(|l| !l.is_empty()) {
        let res = match serde_json::from_str::<Value>(line) {
            Ok(c) => {
                let r = std::panic::catch_unwind(|| run(&c));
                r.unwrap_or_else(|_| {
                    let id = c.get("id").and_then(|v| v.as_str()).unwrap_or("");
                    err(id, "Panic")
                })
            }
            Err(_) => Value::Object(Map::new()),
        };
        writeln!(out, "{}", s(&res)).unwrap();
    }
}
