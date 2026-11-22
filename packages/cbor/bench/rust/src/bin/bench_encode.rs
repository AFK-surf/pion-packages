use ciborium::Value;

fn make_bytes(len: usize, seed: usize) -> Vec<u8> {
    let mut b = Vec::with_capacity(len);
    for i in 0..len {
        b.push(((seed * 31 + i * 17 + 7) & 0xFF) as u8);
    }
    b
}

fn fnv1a_update(mut acc: u64, data: &[u8]) -> u64 {
    for &b in data {
        acc = (acc ^ (b as u64)).wrapping_mul(1099511628211);
    }
    acc
}

fn sort_cbor_map(pairs: Vec<(Value, Value)>) -> Value {
    let mut keyed: Vec<(Vec<u8>, Value, Value)> = Vec::with_capacity(pairs.len());
    for (k, v) in pairs {
        let mut kb = Vec::with_capacity(16);
        ciborium::into_writer(&k, &mut kb).unwrap();
        keyed.push((kb, k, v));
    }
    keyed.sort_by(|a, b| a.0.cmp(&b.0));
    Value::Map(keyed.into_iter().map(|(_, k, v)| (k, v)).collect())
}

fn main() {
    let ops: usize = 50000;
    let mut total_bytes: u64 = 0;
    let mut hash: u64 = 14695981039346656037;
    let mut buf = Vec::with_capacity(512);

    for i in 0..ops {
        let auth_data = make_bytes(37, i);
        let sig = make_bytes(64, i + 1);
        let x_coord = make_bytes(32, i + 2);
        let y_coord = make_bytes(32, i + 3);

        let cose_key = sort_cbor_map(vec![
            (Value::from(1u64), Value::from(2u64)),
            (Value::from(3u64), Value::from(-7i64)),
            (Value::from(-1i64), Value::from(1u64)),
            (Value::from(-2i64), Value::Bytes(x_coord)),
            (Value::from(-3i64), Value::Bytes(y_coord)),
        ]);

        let att_stmt = sort_cbor_map(vec![
            (Value::Text("alg".into()), Value::from(-7i64)),
            (Value::Text("sig".into()), Value::Bytes(sig)),
        ]);

        let telemetry = sort_cbor_map(vec![
            (Value::Text("ok".into()), Value::Bool(i % 2 == 0)),
            (Value::Text("seq".into()), Value::from(i as u64)),
            (
                Value::Text("tags".into()),
                Value::Array(vec![
                    Value::Text("tokyo".into()),
                    Value::Text("arm64".into()),
                    Value::Text("cbor".into()),
                ]),
            ),
            (Value::Text("latency_ms".into()), Value::Float(12.3f64)),
        ]);

        let record = sort_cbor_map(vec![
            (Value::Text("fmt".into()), Value::Text("packed".into())),
            (Value::Text("coseKey".into()), cose_key),
            (Value::Text("attStmt".into()), att_stmt),
            (Value::Text("authData".into()), Value::Bytes(auth_data)),
            (Value::Text("telemetry".into()), telemetry),
        ]);

        buf.clear();
        ciborium::into_writer(&record, &mut buf).unwrap();
        total_bytes += buf.len() as u64;
        hash = fnv1a_update(hash, &buf);
    }

    println!("ops={}\ntotal_bytes={}\nfnv1a={}", ops, total_bytes, hash);
}
