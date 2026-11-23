//! Red-team differential oracle: Rust `bson` 2.15.0.
//! stdin/file: one request per line, `<op>\t<hex>`; stdout: one result line per request.
//!   B <bson hex>       -> OK\t<re-encoded hex>\t<canonical extjson>\t<relaxed extjson> | ERR\t<msg>
//!   J <utf8 hex>       -> OK\t<bson hex> | ERR\t<msg>      (Extended JSON v2 -> BSON)
//!   D <utf8 hex>       -> OK\t<16-byte LE hex>\t<to_string> | ERR\t<msg>   (Decimal128::from_str)
//!   X <16-byte hex>    -> OK\t<to_string>                  (Decimal128 Display)
use bson::{Bson, Decimal128, Document};
use std::io::{BufRead, Write};
use std::panic;

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect()
}
fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02x}", x)).collect()
}
fn clean(s: String) -> String {
    s.replace(['\t', '\n', '\r'], " ")
}

fn op(kind: &str, arg: &str) -> String {
    let raw = unhex(arg);
    match kind {
        "B" => match Document::from_reader(&mut &raw[..]) {
            Err(e) => format!("ERR\t{}", clean(e.to_string())),
            Ok(doc) => {
                let mut buf = Vec::new();
                let re = match doc.to_writer(&mut buf) {
                    Ok(()) => hex(&buf),
                    Err(e) => format!("ENCERR:{}", clean(e.to_string())),
                };
                let c = serde_json::to_string(&Bson::Document(doc.clone()).into_canonical_extjson()).unwrap();
                let r = serde_json::to_string(&Bson::Document(doc).into_relaxed_extjson()).unwrap();
                format!("OK\t{}\t{}\t{}", re, c, r)
            }
        },
        "J" => {
            let s = match String::from_utf8(raw) {
                Ok(s) => s,
                Err(_) => return "ERR\tinput not utf-8".into(),
            };
            let v: serde_json::Value = match serde_json::from_str(&s) {
                Ok(v) => v,
                Err(e) => return format!("ERR\tjson: {}", clean(e.to_string())),
            };
            match Bson::try_from(v) {
                Ok(Bson::Document(d)) => {
                    let mut buf = Vec::new();
                    match d.to_writer(&mut buf) {
                        Ok(()) => format!("OK\t{}", hex(&buf)),
                        Err(e) => format!("ERR\tencode: {}", clean(e.to_string())),
                    }
                }
                Ok(_) => "ERR\troot not a document".into(),
                Err(e) => format!("ERR\t{}", clean(e.to_string())),
            }
        }
        "D" => {
            let s = String::from_utf8_lossy(&raw).into_owned();
            match s.parse::<Decimal128>() {
                Ok(d) => format!("OK\t{}\t{}", hex(&d.bytes()), d),
                Err(e) => format!("ERR\t{}", clean(e.to_string())),
            }
        }
        "X" => {
            let mut a = [0u8; 16];
            a.copy_from_slice(&raw[..16]);
            format!("OK\t{}", Decimal128::from_bytes(a))
        }
        _ => "ERR\tbad op".into(),
    }
}

fn main() {
    panic::set_hook(Box::new(|_| {}));
    let path = std::env::args().nth(1).expect("usage: rt_bson_oracle <requests.tsv>");
    let f = std::io::BufReader::new(std::fs::File::open(path).unwrap());
    let out = std::io::stdout();
    let mut out = std::io::BufWriter::new(out.lock());
    for line in f.lines() {
        let line = line.unwrap();
        let (k, a) = line.split_once('\t').unwrap_or((&line, ""));
        let (k, a) = (k.to_string(), a.to_string());
        let res = panic::catch_unwind(move || op(&k, &a)).unwrap_or_else(|_| "PANIC".into());
        writeln!(out, "{}", res).unwrap();
    }
}
