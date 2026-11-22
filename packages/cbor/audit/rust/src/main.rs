//! Red-team differential probe: Rust ciborium side (same protocol as the Pion probe).
use ciborium::Value;
use std::io::{BufRead, BufReader, Write};

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect()
}

fn tohex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02x}", x)).collect()
}

fn enc(v: &Value) -> Vec<u8> {
    let mut out = Vec::new();
    ciborium::ser::into_writer(v, &mut out).unwrap();
    out
}

/// Recursively sort map keys: bytewise (RFC 8949 core det) or length-first (CTAP2).
fn canon(v: Value, length_first: bool) -> Result<Value, String> {
    Ok(match v {
        Value::Array(a) => Value::Array(a.into_iter().map(|x| canon(x, length_first)).collect::<Result<_, _>>()?),
        Value::Tag(t, b) => Value::Tag(t, Box::new(canon(*b, length_first)?)),
        Value::Map(m) => {
            let mut kv: Vec<(Vec<u8>, Value, Value)> = Vec::new();
            for (k, x) in m {
                let k = canon(k, length_first)?;
                kv.push((enc(&k), k, canon(x, length_first)?));
            }
            kv.sort_by(|a, b| if length_first { a.0.len().cmp(&b.0.len()).then(a.0.cmp(&b.0)) } else { a.0.cmp(&b.0) });
            for w in kv.windows(2) {
                if w[0].0 == w[1].0 {
                    return Err("duplicate map key".into());
                }
            }
            Value::Map(kv.into_iter().map(|(_, k, x)| (k, x)).collect())
        }
        x => x,
    })
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args[1].as_str();
    let f = BufReader::new(std::fs::File::open(&args[2]).unwrap());
    let stdout = std::io::stdout();
    let mut w = std::io::BufWriter::new(stdout.lock());
    for line in f.lines() {
        let line = line.unwrap();
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let input = unhex(line);
        let mut rd: &[u8] = &input;
        let r: Result<Value, _> = ciborium::de::from_reader(&mut rd);
        match r {
            Err(e) => writeln!(w, "ERR {:?}", e).unwrap(),
            Ok(_) if !rd.is_empty() => writeln!(w, "ERR trailing bytes").unwrap(),
            Ok(v) => {
                let v = match mode {
                    "enc_ctap2" => canon(v, true),
                    "enc_det" => canon(v, false),
                    _ => Ok(v),
                };
                match v {
                    Ok(v) => writeln!(w, "OK {}", tohex(&enc(&v))).unwrap(),
                    Err(e) => writeln!(w, "ENCERR {}", e).unwrap(),
                }
            }
        }
    }
}
