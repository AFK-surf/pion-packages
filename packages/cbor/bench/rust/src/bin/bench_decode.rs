use ciborium::Value;
use std::env;
use std::fs;

fn walk_value(v: &Value) -> (i64, u64) {
    match v {
        Value::Integer(int) => {
            let i: i128 = (*int).into();
            if i >= 0 {
                (1, (i as u64).wrapping_add(1))
            } else {
                (1, ((-i) as u64).wrapping_mul(3))
            }
        }
        Value::Bytes(b) => {
            let mut h = (b.len() as u64).wrapping_mul(7);
            if !b.is_empty() {
                h = h.wrapping_add(b[0] as u64).wrapping_add(b[b.len() - 1] as u64);
            }
            (1, h)
        }
        Value::Text(s) => (1, (s.len() as u64).wrapping_mul(11)),
        Value::Bool(b) => (1, if *b { 13 } else { 17 }),
        Value::Null => (1, 19),
        Value::Float(f) => (1, f.to_bits()),
        Value::Tag(t, inner) => {
            let (sn, sc) = walk_value(inner);
            (1 + sn, t.wrapping_mul(31).wrapping_add(sc))
        }
        Value::Array(items) => {
            let mut nodes: i64 = 1;
            let mut sum: u64 = (items.len() as u64).wrapping_mul(37);
            for item in items {
                let (sn, sc) = walk_value(item);
                nodes += sn;
                sum = sum.wrapping_add(sc);
            }
            (nodes, sum)
        }
        Value::Map(pairs) => {
            let mut nodes: i64 = 1;
            let mut sum: u64 = (pairs.len() as u64).wrapping_mul(41);
            for (k, val) in pairs {
                let (kn, kc) = walk_value(k);
                let (vn, vc) = walk_value(val);
                nodes += kn + vn;
                sum = sum.wrapping_add(kc).wrapping_add(vc);
            }
            (nodes, sum)
        }
        _ => (1, 23),
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: rust_decode <corpus.cbor>");
        std::process::exit(1);
    }
    let data = fs::read(&args[1]).expect("read corpus");
    let rounds = 40usize;
    let mut total_nodes: i64 = 0;
    let mut total_checksum: u64 = 0;
    for _ in 0..rounds {
        let v: Value = ciborium::from_reader(data.as_slice()).expect("decode cbor");
        let (n, c) = walk_value(&v);
        total_nodes += n;
        total_checksum = total_checksum.wrapping_add(c);
    }
    println!(
        "rounds={}\nbytes={}\nnodes={}\nchecksum={}",
        rounds,
        data.len(),
        total_nodes,
        total_checksum
    );
}
