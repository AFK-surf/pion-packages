//! Red-team adversarial benchmark: Rust ciborium side.
//! usage: rust_bench <dec|enc_det|enc_ctap2> <file.cbor> <iters>
use ciborium::Value;

fn walk(v: &Value, acc: &mut [i64; 2]) {
    acc[0] += 1;
    match v {
        Value::Bytes(b) => acc[1] += b.len() as i64,
        Value::Text(s) => acc[1] += s.len() as i64,
        Value::Tag(_, x) => walk(x, acc),
        Value::Array(a) => a.iter().for_each(|x| walk(x, acc)),
        Value::Map(m) => m.iter().for_each(|(k, x)| {
            walk(k, acc);
            walk(x, acc)
        }),
        _ => {}
    }
}

fn enc(v: &Value) -> Vec<u8> {
    let mut out = Vec::new();
    ciborium::ser::into_writer(v, &mut out).unwrap();
    out
}

/// ciborium has no canonical mode: sort map keys by their encoding (bytewise or length-first).
fn canon(v: &Value, lf: bool) -> Value {
    match v {
        Value::Array(a) => Value::Array(a.iter().map(|x| canon(x, lf)).collect()),
        Value::Tag(t, b) => Value::Tag(*t, Box::new(canon(b, lf))),
        Value::Map(m) => {
            let mut kv: Vec<(Vec<u8>, Value, Value)> =
                m.iter().map(|(k, x)| { let k = canon(k, lf); (enc(&k), k, canon(x, lf)) }).collect();
            kv.sort_by(|a, b| if lf { a.0.len().cmp(&b.0.len()).then(a.0.cmp(&b.0)) } else { a.0.cmp(&b.0) });
            Value::Map(kv.into_iter().map(|(_, k, x)| (k, x)).collect())
        }
        x => x.clone(),
    }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let data = std::fs::read(&a[2]).unwrap();
    let iters: usize = a[3].parse().unwrap();
    let mut acc = [0i64; 2];
    match a[1].as_str() {
        "dec" => {
            for _ in 0..iters {
                let v: Value = ciborium::de::from_reader(&data[..]).unwrap();
                walk(&v, &mut acc);
            }
        }
        m => {
            let v: Value = ciborium::de::from_reader(&data[..]).unwrap();
            for _ in 0..iters {
                acc[1] += enc(&canon(&v, m == "enc_ctap2")).len() as i64;
            }
        }
    }
    println!("nodes={} bytes={}", acc[0], acc[1]);
}
