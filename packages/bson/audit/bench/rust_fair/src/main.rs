//! Fairness re-run of packages/bson/bench W1/W2 for Rust `bson` 2.15.0.
//! Same corpus split, same FNV walk order and the same stdout as bench/rust_bench and bench/pion_bench
//! (so scripts/bench_compare.py's SHA-256 check holds), but without the extra work the official
//! harness gives Rust:
//!   decode_ref  Document::from_reader + walk by reference (no `doc.clone()`, no per-node Vec collect)
//!   decode_raw  RawDocument::from_bytes + zero-copy walk over RawBsonRef (bson's idiomatic fast path)
//!   encode_vec  Document -> bson::to_vec (same bytes as to_writer)
use bson::raw::{RawBsonRef, RawDocument};
use bson::{Bson, Document};
use std::env;
use std::fs;

const FNV0: u64 = 14695981039346656037;

fn split_corpus(data: &[u8]) -> Vec<&[u8]> {
    let mut docs = Vec::new();
    let mut pos = 0usize;
    while pos + 4 <= data.len() {
        let dlen = i32::from_le_bytes([data[pos], data[pos + 1], data[pos + 2], data[pos + 3]]) as usize;
        if dlen < 5 || pos + dlen > data.len() {
            break;
        }
        docs.push(&data[pos..pos + dlen]);
        pos += dlen;
    }
    docs
}

#[inline]
fn fb(mut h: u64, b: &[u8]) -> u64 {
    for &x in b {
        h = (h ^ x as u64).wrapping_mul(1099511628211);
    }
    h
}
#[inline]
fn fu(h: u64, v: u64) -> u64 {
    (h ^ v).wrapping_mul(1099511628211)
}

fn walk_ref(doc: &Document) -> (i64, u64) {
    let (mut elems, mut h) = (0i64, FNV0);
    enum N<'a> {
        D(&'a Document),
        V(&'a Bson),
    }
    let mut stack = vec![N::D(doc)];
    while let Some(cur) = stack.pop() {
        let v = match cur {
            N::D(d) => {
                elems += d.len() as i64;
                h = fu(h, d.len() as u64);
                let kids: Vec<(&String, &Bson)> = d.iter().collect();
                for (k, v) in kids.into_iter().rev() {
                    h = fb(h, k.as_bytes());
                    stack.push(N::V(v));
                }
                continue;
            }
            N::V(v) => v,
        };
        match v {
            Bson::Document(d) => stack.push(N::D(d)),
            Bson::Array(items) => {
                elems += items.len() as i64;
                h = fu(h, items.len() as u64);
                for it in items.iter().rev() {
                    stack.push(N::V(it));
                }
            }
            Bson::Double(x) => h = fu(h, x.to_bits()),
            Bson::String(s) => h = fb(h, s.as_bytes()),
            Bson::Binary(b) => {
                h = fu(h, u8::from(b.subtype) as u64);
                h = fb(h, &b.bytes);
            }
            Bson::ObjectId(o) => h = fb(h, &o.bytes()),
            Bson::Boolean(b) => h = fu(h, *b as u64),
            Bson::DateTime(d) => h = fu(h, d.timestamp_millis() as u64),
            Bson::Null => h = fu(h, 10),
            Bson::Int32(n) => h = fu(h, *n as i64 as u64),
            Bson::Int64(n) => h = fu(h, *n as u64),
            Bson::Decimal128(d) => h = fb(h, &d.bytes()),
            _ => h = fu(h, 99),
        }
    }
    (elems, h)
}

fn walk_raw(doc: &RawDocument) -> (i64, u64) {
    let (mut elems, mut h) = (0i64, FNV0);
    let mut stack: Vec<RawBsonRef> = vec![RawBsonRef::Document(doc)];
    while let Some(cur) = stack.pop() {
        match cur {
            RawBsonRef::Document(d) => {
                let kids: Vec<(&str, RawBsonRef)> = d.into_iter().map(|r| r.expect("raw")).collect();
                elems += kids.len() as i64;
                h = fu(h, kids.len() as u64);
                for (k, v) in kids.into_iter().rev() {
                    h = fb(h, k.as_bytes());
                    stack.push(v);
                }
            }
            RawBsonRef::Array(a) => {
                let kids: Vec<RawBsonRef> = a.into_iter().map(|r| r.expect("raw")).collect();
                elems += kids.len() as i64;
                h = fu(h, kids.len() as u64);
                for v in kids.into_iter().rev() {
                    stack.push(v);
                }
            }
            RawBsonRef::Double(x) => h = fu(h, x.to_bits()),
            RawBsonRef::String(s) => h = fb(h, s.as_bytes()),
            RawBsonRef::Binary(b) => {
                h = fu(h, u8::from(b.subtype) as u64);
                h = fb(h, b.bytes);
            }
            RawBsonRef::ObjectId(o) => h = fb(h, &o.bytes()),
            RawBsonRef::Boolean(b) => h = fu(h, b as u64),
            RawBsonRef::DateTime(d) => h = fu(h, d.timestamp_millis() as u64),
            RawBsonRef::Null => h = fu(h, 10),
            RawBsonRef::Int32(n) => h = fu(h, n as i64 as u64),
            RawBsonRef::Int64(n) => h = fu(h, n as u64),
            RawBsonRef::Decimal128(d) => h = fb(h, &d.bytes()),
            _ => h = fu(h, 99),
        }
    }
    (elems, h)
}

fn main() {
    let a: Vec<String> = env::args().collect();
    let (mode, rounds) = (&a[1], a[3].parse::<usize>().unwrap());
    let data = fs::read(&a[2]).unwrap();
    let raws = split_corpus(&data);
    let (mut td, mut te, mut ck) = (0i64, 0i64, FNV0);
    match mode.as_str() {
        "decode_ref" | "decode_raw" => {
            for _ in 0..rounds {
                for raw in &raws {
                    let (e, c) = if mode == "decode_ref" {
                        walk_ref(&Document::from_reader(&mut &raw[..]).expect("decode"))
                    } else {
                        walk_raw(RawDocument::from_bytes(raw).expect("decode"))
                    };
                    td += 1;
                    te += e;
                    ck = fu(ck, c);
                }
            }
            println!("mode=decode docs={} elems={} checksum={}", td, te, ck);
        }
        "encode_vec" => {
            let docs: Vec<Document> = raws.iter().map(|r| Document::from_reader(&mut &r[..]).unwrap()).collect();
            for _ in 0..rounds {
                for d in &docs {
                    let buf = bson::to_vec(d).expect("encode");
                    td += 1;
                    te += buf.len() as i64;
                    ck = fb(ck, &buf);
                }
            }
            println!("mode=encode docs={} bytes={} checksum={}", td, te, ck);
        }
        _ => std::process::exit(1),
    }
}
