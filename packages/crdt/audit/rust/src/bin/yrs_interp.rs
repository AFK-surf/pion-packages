//! Rust `yrs` mirror of audit/harness (same script language, same stdout as node/interp.mjs).
use std::collections::HashMap;
use std::sync::Arc;
use yrs::types::Attrs;
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{
    Any, Array, ArrayPrelim, ArrayRef, Doc, GetString, Map, MapPrelim, MapRef, OffsetKind, Options,
    Out, ReadTxn, StateVector, Text, TextPrelim, TextRef, Transact, Update,
};

fn hex(b: &[u8]) -> String { b.iter().map(|x| format!("{:02x}", x)).collect() }
fn unhex(h: &str) -> Vec<u8> { (0..h.len() / 2).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap_or(0)).collect() }
fn hexstr(h: &str) -> String { String::from_utf8_lossy(&unhex(h)).into_owned() }

fn new_doc(client: u64) -> Doc {
    let d = Doc::with_options(Options { client_id: yrs::block::ClientID::new(client), offset_kind: OffsetKind::Utf16, ..Options::default() });
    d.get_or_insert_text("t");
    d.get_or_insert_array("a");
    d.get_or_insert_map("m");
    d
}

fn jstr(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}
fn any_json(a: &Any) -> String {
    match a {
        Any::Null | Any::Undefined => "null".into(),
        Any::Bool(b) => b.to_string(),
        Any::Number(yrs::Number::Int(i)) => i.to_string(),
        Any::Number(yrs::Number::Float(n)) => if n.fract() == 0.0 && n.abs() < 1e15 { format!("{}", *n as i64) } else { n.to_string() },
        Any::String(s) => jstr(s),
        Any::Buffer(b) => format!("{{\"$bin\":\"{}\"}}", hex(b)),
        Any::Array(xs) => format!("[{}]", xs.iter().map(any_json).collect::<Vec<_>>().join(",")),
        Any::Map(m) => {
            let mut ks: Vec<_> = m.keys().collect();
            ks.sort();
            format!("{{{}}}", ks.iter().map(|k| format!("{}:{}", jstr(k), any_json(&m[*k]))).collect::<Vec<_>>().join(","))
        }
    }
}
fn out_json<T: ReadTxn>(txn: &T, o: &Out) -> String {
    match o {
        Out::Any(a) => any_json(a),
        Out::YText(t) => jstr(&t.get_string(txn)),
        Out::YArray(a) => format!("[{}]", a.iter(txn).map(|v| out_json(txn, &v)).collect::<Vec<_>>().join(",")),
        Out::YMap(m) => {
            let mut es: Vec<(String, Out)> = m.iter(txn).map(|(k, v)| (k.to_string(), v)).collect();
            es.sort_by(|a, b| a.0.cmp(&b.0));
            format!("{{{}}}", es.iter().map(|(k, v)| format!("{}:{}", jstr(k), out_json(txn, v))).collect::<Vec<_>>().join(","))
        }
        _ => "null".into(),
    }
}
fn dump(d: &Doc) -> String {
    let a = d.get_or_insert_array("a");
    let m = d.get_or_insert_map("m");
    let t = d.get_or_insert_text("t");
    let txn = d.transact();
    format!(
        "{{\"a\":{},\"m\":{},\"t\":{}}}",
        out_json(&txn, &Out::YArray(a)),
        out_json(&txn, &Out::YMap(m)),
        jstr(&t.get_string(&txn))
    )
}
fn val(s: &str) -> Any {
    match s {
        "n" => Any::Null,
        "t" => Any::Bool(true),
        "f" => Any::Bool(false),
        _ if s.starts_with("i:") => Any::Number(yrs::Number::Int(s[2..].parse::<i64>().unwrap_or(0))),
        _ if s.starts_with("s:") => Any::String(Arc::from(hexstr(&s[2..]).as_str())),
        _ => Any::Undefined,
    }
}
fn resolve(d: &Doc, path: &str) -> Option<Out> {
    let segs: Vec<&str> = path.split('/').collect();
    let mut cur = match segs[0] {
        "t" => Out::YText(d.get_or_insert_text("t")),
        "a" => Out::YArray(d.get_or_insert_array("a")),
        "m" => Out::YMap(d.get_or_insert_map("m")),
        _ => return None,
    };
    let txn = d.transact();
    for s in &segs[1..] {
        let nx = match &cur {
            Out::YArray(a) => a.get(&txn, s.parse().ok()?),
            Out::YMap(m) => m.get(&txn, s),
            _ => None,
        }?;
        match nx {
            Out::YText(_) | Out::YArray(_) | Out::YMap(_) => cur = nx,
            _ => return None,
        }
    }
    Some(cur)
}
fn apply(d: &Doc, bytes: &[u8]) -> Result<(), String> {
    let u = Update::decode_v1(bytes).map_err(|e| e.to_string())?;
    d.transact_mut().apply_update(u).map_err(|e| e.to_string())
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: yrs_interp <script>");
    let src = std::fs::read_to_string(path).unwrap();
    let mut docs: HashMap<i64, Doc> = HashMap::new();
    let mut out = String::new();
    for line in src.lines() {
        let t: Vec<&str> = line.split_whitespace().collect();
        if t.is_empty() || t[0].starts_with('#') || t[0] == "opt" { continue; }
        let c = t[0];
        if c == "doc" { docs.insert(t[1].parse().unwrap(), new_doc(t[2].parse().unwrap())); continue; }
        if c == "merge" {
            let ups: Vec<Vec<u8>> = t[1..].iter().map(|h| unhex(h)).collect();
            match yrs::merge_updates_v1(ups.iter().map(|u| u.as_slice()).collect::<Vec<_>>()) {
                Ok(m) => out.push_str(&format!("M {}\n", hex(&m))),
                Err(e) => out.push_str(&format!("E {}\n", e)),
            }
            continue;
        }
        if c == "diff" {
            match yrs::diff_updates_v1(&unhex(t[1]), &unhex(t[2])) {
                Ok(m) => out.push_str(&format!("F {}\n", hex(&m))),
                Err(e) => out.push_str(&format!("E {}\n", e)),
            }
            continue;
        }
        let id: i64 = t[1].parse().unwrap();
        let Some(d) = docs.get(&id) else { out.push_str("X nodoc\n"); continue };
        match c {
            "apply" => { if let Err(e) = apply(d, &unhex(t.get(2).copied().unwrap_or(""))) { out.push_str(&format!("E {}\n", e)); } continue; }
            "sync" | "full" => {
                let dst = &docs[&t[2].parse::<i64>().unwrap()];
                let sv = if c == "full" { StateVector::default() } else { dst.transact().state_vector() };
                let u = d.transact().encode_state_as_update_v1(&sv);
                if let Err(e) = apply(dst, &u) { out.push_str(&format!("E {}\n", e)); }
                continue;
            }
            "dump" => { out.push_str(&format!("D {} {}\n", t[1], dump(d))); continue; }
            "upd" => { out.push_str(&format!("U {} {}\n", t[1], hex(&d.transact().encode_state_as_update_v1(&StateVector::default())))); continue; }
            "sv" => { out.push_str(&format!("S {} {}\n", t[1], hex(&d.transact().state_vector().encode_v1()))); continue; }
            "pending" => { out.push_str(&format!("P {} {}\n", t[1], d.transact().has_missing_updates() as u8)); continue; }
            _ => {}
        }
        let Some(ty) = resolve(d, t[2]) else { out.push_str("X badpath\n"); continue };
        let mut txn = d.transact_mut();
        let n = |i: usize| -> u32 { t[i].parse().unwrap() };
        match (c, ty) {
            ("ti", Out::YText(x)) => x.insert(&mut txn, n(3), &hexstr(t[4])),
            ("td", Out::YText(x)) => x.remove_range(&mut txn, n(3), n(4)),
            ("tf", Out::YText(x)) => {
                let v: Any = match hexstr(t[6]).as_str() { "true" => Any::Bool(true), "null" => Any::Null, s => Any::String(Arc::from(s.trim_matches('"'))) };
                let mut at = Attrs::new();
                at.insert(Arc::from(t[5]), v);
                x.format(&mut txn, n(3), n(4), at)
            }
            ("ai", Out::YArray(x)) => { x.insert(&mut txn, n(3), val(t[4])); }
            ("ait", Out::YArray(x)) => match t[4] {
                "text" => { x.insert(&mut txn, n(3), TextPrelim::new("")); }
                "array" => { x.insert(&mut txn, n(3), ArrayPrelim::default()); }
                _ => { x.insert(&mut txn, n(3), MapPrelim::default()); }
            },
            ("ad", Out::YArray(x)) => x.remove_range(&mut txn, n(3), n(4)),
            ("ms", Out::YMap(x)) => { x.insert(&mut txn, t[3], val(t[4])); }
            ("mst", Out::YMap(x)) => match t[4] {
                "text" => { x.insert(&mut txn, t[3], TextPrelim::new("")); }
                "array" => { x.insert(&mut txn, t[3], ArrayPrelim::default()); }
                _ => { x.insert(&mut txn, t[3], MapPrelim::default()); }
            },
            ("md", Out::YMap(x)) => { x.remove(&mut txn, t[3]); }
            _ => out.push_str("X badcmd\n"),
        }
    }
    print!("{}", out);
    let _: Option<(TextRef, ArrayRef, MapRef)> = None;
}
