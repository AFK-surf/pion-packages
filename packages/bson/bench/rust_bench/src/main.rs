use bson::{Bson, Document};
use std::env;
use std::fs;

fn split_corpus(data: &[u8]) -> Vec<&[u8]> {
    let mut docs = Vec::new();
    let mut pos = 0usize;
    let n = data.len();
    while pos + 4 <= n {
        let dlen = i32::from_le_bytes([data[pos], data[pos + 1], data[pos + 2], data[pos + 3]]) as usize;
        if dlen < 5 || pos + dlen > n {
            break;
        }
        docs.push(&data[pos..pos + dlen]);
        pos += dlen;
    }
    docs
}

#[inline]
fn fnv_update_bytes(mut h: u64, b: &[u8]) -> u64 {
    for &byte in b {
        h = (h ^ (byte as u64)).wrapping_mul(1099511628211u64);
    }
    h
}

#[inline]
fn fnv_update_u64(h: u64, v: u64) -> u64 {
    (h ^ v).wrapping_mul(1099511628211u64)
}

fn walk_doc_checksum(doc: &Document) -> (i64, u64) {
    let mut elems: i64 = 0;
    let mut h: u64 = 14695981039346656037u64;
    let mut stack: Vec<Bson> = vec![Bson::Document(doc.clone())];
    while let Some(cur) = stack.pop() {
        match cur {
            Bson::Document(d) => {
                let n = d.len();
                elems += n as i64;
                h = fnv_update_u64(h, n as u64);
                let entries: Vec<(String, Bson)> = d.into_iter().collect();
                for (k, v) in entries.into_iter().rev() {
                    h = fnv_update_bytes(h, k.as_bytes());
                    stack.push(v);
                }
            }
            Bson::Array(items) => {
                let n = items.len();
                elems += n as i64;
                h = fnv_update_u64(h, n as u64);
                for item in items.into_iter().rev() {
                    stack.push(item);
                }
            }
            Bson::Double(x) => h = fnv_update_u64(h, x.to_bits()),
            Bson::String(s) => h = fnv_update_bytes(h, s.as_bytes()),
            Bson::Binary(bin) => {
                let sub: u8 = bin.subtype.into();
                h = fnv_update_u64(h, sub as u64);
                h = fnv_update_bytes(h, &bin.bytes);
            }
            Bson::ObjectId(oid) => h = fnv_update_bytes(h, &oid.bytes()),
            Bson::Boolean(b) => h = fnv_update_u64(h, if b { 1 } else { 0 }),
            Bson::DateTime(dt) => h = fnv_update_u64(h, dt.timestamp_millis() as u64),
            Bson::Null => h = fnv_update_u64(h, 10),
            Bson::Int32(n) => h = fnv_update_u64(h, (n as i64) as u64),
            Bson::Int64(n) => h = fnv_update_u64(h, n as u64),
            Bson::Decimal128(dec) => h = fnv_update_bytes(h, &dec.bytes()),
            _ => h = fnv_update_u64(h, 99),
        }
    }
    (elems, h)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: rust_bench <decode|encode|extjson> <corpus.bson> <rounds>");
        std::process::exit(1);
    }
    let mode = &args[1];
    let path = &args[2];
    let rounds: usize = args[3].parse().expect("invalid rounds");
    let data = fs::read(path).expect("failed to read corpus");
    let raw_docs = split_corpus(&data);

    if mode == "decode" {
        let mut total_docs: i64 = 0;
        let mut total_elems: i64 = 0;
        let mut checksum: u64 = 14695981039346656037u64;
        for _ in 0..rounds {
            for raw in &raw_docs {
                let doc = Document::from_reader(&mut &raw[..]).expect("decode failed");
                let (ec, ch) = walk_doc_checksum(&doc);
                total_docs += 1;
                total_elems += ec;
                checksum = fnv_update_u64(checksum, ch);
            }
        }
        println!("mode=decode docs={} elems={} checksum={}", total_docs, total_elems, checksum);
        return;
    }

    let docs: Vec<Document> = raw_docs
        .iter()
        .map(|raw| Document::from_reader(&mut &raw[..]).expect("pre-decode failed"))
        .collect();

    if mode == "encode" {
        let mut total_docs: i64 = 0;
        let mut total_bytes: i64 = 0;
        let mut checksum: u64 = 14695981039346656037u64;
        for _ in 0..rounds {
            for doc in &docs {
                let mut buf = Vec::new();
                doc.to_writer(&mut buf).expect("encode failed");
                total_docs += 1;
                total_bytes += buf.len() as i64;
                checksum = fnv_update_bytes(checksum, &buf);
            }
        }
        println!("mode=encode docs={} bytes={} checksum={}", total_docs, total_bytes, checksum);
        return;
    }

    if mode == "extjson" {
        let mut total_docs: i64 = 0;
        let mut canon_bytes: i64 = 0;
        let mut relaxed_bytes: i64 = 0;
        let mut checksum: u64 = 14695981039346656037u64;
        for _ in 0..rounds {
            for doc in &docs {
                let canon_val = Bson::Document(doc.clone()).into_canonical_extjson();
                let canon = serde_json::to_string(&canon_val).expect("canon ser");
                let canon_parsed: serde_json::Value = serde_json::from_str(&canon).expect("canon de");
                let doc_c: Document = match Bson::try_from(canon_parsed).expect("canon bson") {
                    Bson::Document(d) => d,
                    _ => panic!("expected doc"),
                };
                let relaxed_val = Bson::Document(doc_c).into_relaxed_extjson();
                let relaxed = serde_json::to_string(&relaxed_val).expect("relaxed ser");
                let relaxed_parsed: serde_json::Value = serde_json::from_str(&relaxed).expect("relaxed de");
                let doc_r: Document = match Bson::try_from(relaxed_parsed).expect("relaxed bson") {
                    Bson::Document(d) => d,
                    _ => panic!("expected doc"),
                };
                total_docs += 1;
                canon_bytes += canon.len() as i64;
                relaxed_bytes += relaxed.len() as i64;
                checksum = fnv_update_bytes(checksum, canon.as_bytes());
                checksum = fnv_update_bytes(checksum, relaxed.as_bytes());
                checksum = fnv_update_u64(checksum, doc_r.len() as u64);
            }
        }
        println!(
            "mode=extjson docs={} canon_bytes={} relaxed_bytes={} checksum={}",
            total_docs, canon_bytes, relaxed_bytes, checksum
        );
        return;
    }

    eprintln!("unknown mode: {}", mode);
    std::process::exit(1);
}
