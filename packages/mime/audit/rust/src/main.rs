//! Rust reference side (mime 0.3.18 + infer 0.16.0) of the packages/mime red-team harness.
//! Modes: `mt` (Mime::from_str: essence + raw params) and `sniff` (infer::get).
use std::io::Write;

fn h(b: &[u8]) -> String {
    let mut s = String::from(".");
    for c in b {
        s.push_str(&format!("{:02x}", c));
    }
    s
}

fn unhex(f: &str) -> Vec<u8> {
    let f = &f[1..];
    (0..f.len() / 2).map(|i| u8::from_str_radix(&f[2 * i..2 * i + 2], 16).unwrap_or(0)).collect()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = &args[1];
    let data = std::fs::read_to_string(&args[2]).unwrap();
    let out = std::io::stdout();
    let mut w = std::io::BufWriter::new(out.lock());
    for line in data.lines() {
        let f: Vec<Vec<u8>> = line.split(' ').filter(|s| !s.is_empty()).map(unhex).collect();
        let a0 = f.get(0).cloned().unwrap_or_default();
        let res = match mode.as_str() {
            "mt" => match std::str::from_utf8(&a0).ok().and_then(|s| s.parse::<mime::Mime>().ok()) {
                Some(m) => {
                    let mut ps: Vec<(String, String)> =
                        m.params().map(|(k, v)| (k.as_str().to_ascii_lowercase(), v.as_str().to_string())).collect();
                    ps.sort();
                    let mut s = format!("OK {}", h(m.essence_str().as_bytes()));
                    for (k, v) in ps {
                        s.push_str(&format!(" {}={}", h(k.as_bytes()), h(v.as_bytes())));
                    }
                    s
                }
                None => "ERR rust".to_string(),
            },
            "sniff" => match infer::get(&a0) {
                Some(t) => t.mime_type().to_string(),
                None => "NONE".to_string(),
            },
            _ => "BADMODE".to_string(),
        };
        writeln!(w, "{}", res).unwrap();
    }
}
