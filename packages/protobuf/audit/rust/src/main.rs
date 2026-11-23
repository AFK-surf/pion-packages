//! Wire-level differential oracle for the packages/protobuf red-team audit (prost =0.13.5).
//!
//!   rust_oracle varint <hexfile>   OK <u64> <consumed> | ERR <msg>
//!   rust_oracle tag <hexfile>      OK <num> <wiretype> | ERR <msg>
//!   rust_oracle wire <hexfile>     OK <fields>          | ERR <msg>   (decode_key + skip_field, recursion limit 100)
use prost::encoding::{decode_key, decode_varint, skip_field, DecodeContext};
use std::io::Write;

fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok()).collect()
}

fn one(mode: &str, input: &[u8]) -> String {
    let mut buf: &[u8] = input;
    match mode {
        "varint" => match decode_varint(&mut buf) {
            Ok(v) => format!("OK {} {}", v, input.len() - buf.len()),
            Err(e) => format!("ERR {}", e),
        },
        "tag" => match decode_key(&mut buf) {
            Ok((num, wt)) => format!("OK {} {}", num, wt as u8),
            Err(e) => format!("ERR {}", e),
        },
        "wire" => {
            let mut n = 0u64;
            while !buf.is_empty() {
                let (num, wt) = match decode_key(&mut buf) {
                    Ok(k) => k,
                    Err(e) => return format!("ERR {}", e),
                };
                if let Err(e) = skip_field(wt, num, &mut buf, DecodeContext::default()) {
                    return format!("ERR {}", e);
                }
                n += 1;
            }
            format!("OK {}", n)
        }
        _ => "ERR mode".to_string(),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let data = std::fs::read_to_string(&args[2]).expect("read");
    let out = std::io::stdout();
    let mut w = std::io::BufWriter::new(out.lock());
    for line in data.lines() {
        let l = line.trim();
        if l.is_empty() {
            continue;
        }
        let r = match unhex(l) {
            Some(b) => one(&args[1], &b),
            None => "BADHEX".to_string(),
        };
        writeln!(w, "{}", r.replace('\n', " ")).unwrap();
    }
}
