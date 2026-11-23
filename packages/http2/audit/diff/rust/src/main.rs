//! Reference runner built on h2 0.4.20's own HPACK engine (vendored at build time, see vendor_h2_hpack.sh).
//!
//!   h2_hpack hpack <corpus.txt>                         differential output (same format as `probe hpack`)
//!   h2_hpack hpack_decode <hpack_stream.bin>            bench: packages/http2/bench corpus, 100 rounds
//!   h2_hpack hpack_encode <headers_plain.bin>           bench: h2 encoder (always Huffman), 100 rounds
#![allow(dead_code, unused_imports, clippy::all)]

mod ext;
mod hpack;

use bytes::{Bytes, BytesMut};
use http::header::HeaderName;
use std::io::{Cursor, Write};
use std::ops::ControlFlow;
use std::{env, fs, process};

use hpack::{Decoder, Encoder, Header};

fn hexs(b: &[u8]) -> String {
    const D: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(b.len() * 2);
    for &c in b {
        s.push(D[(c >> 4) as usize] as char);
        s.push(D[(c & 15) as usize] as char);
    }
    s
}

fn unhex(s: &str) -> Vec<u8> {
    let v = |c: u8| match c {
        b'0'..=b'9' => c - b'0',
        b'a'..=b'f' => c - b'a' + 10,
        _ => c - b'A' + 10,
    };
    s.as_bytes().chunks(2).map(|p| (v(p[0]) << 4) | v(p[1])).collect()
}

fn run_diff(text: &str) {
    let out = std::io::stdout();
    let mut w = std::io::BufWriter::new(out.lock());
    for line in text.lines() {
        let (name, rest) = line.split_once('\t').unwrap();
        let mut dec = Decoder::new(4096);
        let mut s = String::new();
        s.push_str(name);
        s.push('\t');
        for (i, h) in rest.split(',').enumerate() {
            if i > 0 {
                s.push('|');
            }
            let mut buf = BytesMut::from(&unhex(h)[..]);
            let mut fields = Vec::new();
            let r = dec.decode(&mut Cursor::new(&mut buf), |hd| {
                fields.push(hd);
                ControlFlow::Continue(())
            });
            if let Err(e) = r {
                s.push_str("ERR");
                if std::env::var("DIFF_REASON").as_deref() == Ok("1") {
                    let r = format!("{:?}", e).replace(['|', ';', '(', ')'], " ");
                    s.push('(');
                    s.push_str(r.trim());
                    s.push(')');
                }
                break;
            }
            for (j, f) in fields.iter().enumerate() {
                if j > 0 {
                    s.push(' ');
                }
                s.push_str(&hexs(f.name().as_slice()));
                s.push(':');
                s.push_str(&hexs(f.value_slice()));
                if f.is_sensitive() {
                    s.push('!');
                }
            }
            s.push(';');
        }
        s.push('\n');
        w.write_all(s.as_bytes()).unwrap();
    }
}

#[inline(always)]
fn mix(h: i64, v: i64) -> i64 {
    ((h * 131) + v) % 1_000_000_007
}

#[inline(always)]
fn hash_bytes(mut h: i64, b: &[u8]) -> i64 {
    h = mix(h, b.len() as i64);
    for &c in b {
        h = mix(h, c as i64);
    }
    h
}

fn hash_fields(mut h: i64, hs: &[Header]) -> i64 {
    h = mix(h, hs.len() as i64);
    for f in hs {
        h = hash_bytes(h, f.name().as_slice());
        h = hash_bytes(h, f.value_slice());
    }
    h
}

fn rd16(b: &[u8], o: usize) -> usize {
    ((b[o] as usize) << 8) | b[o + 1] as usize
}
fn rd32(b: &[u8], o: usize) -> usize {
    ((b[o] as usize) << 24) | ((b[o + 1] as usize) << 16) | ((b[o + 2] as usize) << 8) | b[o + 3] as usize
}

/// Same corpus, same 100 rounds, same checksum as packages/http2/bench (fresh decoder per round).
fn bench_decode(data: &[u8]) {
    let count = rd32(data, 0);
    let mut blocks = Vec::with_capacity(count);
    let mut pos = 4;
    for _ in 0..count {
        let l = rd32(data, pos);
        pos += 4;
        blocks.push(&data[pos..pos + l]);
        pos += l;
    }
    let (mut tb, mut th, mut ck) = (0i64, 0i64, 0i64);
    let mut fields: Vec<Header> = Vec::with_capacity(32);
    let mut buf = BytesMut::with_capacity(4096);
    for _ in 0..100 {
        let mut dec = Decoder::new(4096);
        for b in &blocks {
            buf.clear();
            buf.extend_from_slice(b);
            fields.clear();
            if let Err(e) = dec.decode(&mut Cursor::new(&mut buf), |h| {
                fields.push(h);
                ControlFlow::Continue(())
            }) {
                eprintln!("decode error: {:?}", e);
                process::exit(1);
            }
            tb += 1;
            th += fields.len() as i64;
            ck = hash_fields(ck, &fields);
        }
    }
    println!("mode=hpack_decode");
    println!("blocks={}", tb);
    println!("headers={}", th);
    println!("checksum={}", ck);
}

fn to_encodable(h: Header, sensitive: bool) -> Header<Option<HeaderName>> {
    match h {
        Header::Field { name, mut value } => {
            value.set_sensitive(sensitive);
            Header::Field { name: Some(name), value }
        }
        Header::Authority(v) => Header::Authority(v),
        Header::Method(v) => Header::Method(v),
        Header::Scheme(v) => Header::Scheme(v),
        Header::Path(v) => Header::Path(v),
        Header::Protocol(v) => Header::Protocol(v),
        Header::Status(v) => Header::Status(v),
    }
}

fn bench_encode(data: &[u8]) {
    let count = rd32(data, 0);
    let mut lists: Vec<Vec<(Bytes, Bytes, bool)>> = Vec::with_capacity(count);
    let mut pos = 4;
    for _ in 0..count {
        let hc = rd16(data, pos);
        pos += 2;
        let mut hs = Vec::with_capacity(hc);
        for _ in 0..hc {
            let nl = rd16(data, pos);
            pos += 2;
            let n = Bytes::copy_from_slice(&data[pos..pos + nl]);
            pos += nl;
            let vl = rd16(data, pos);
            pos += 2;
            let v = Bytes::copy_from_slice(&data[pos..pos + vl]);
            pos += vl;
            let s = data[pos] != 0;
            pos += 1;
            hs.push((n, v, s));
        }
        lists.push(hs);
    }
    // Typed headers are built once, outside the timed loop (Go/Pion also pre-build their field lists).
    let typed: Vec<Vec<Header<Option<HeaderName>>>> = lists
        .iter()
        .map(|hs| {
            hs.iter()
                .map(|(n, v, s)| to_encodable(Header::new(n.clone(), v.clone()).expect("valid header"), *s))
                .collect()
        })
        .collect();
    let (mut tb, mut th, mut sink, mut vck) = (0i64, 0i64, 0i64, 0i64);
    let mut dst = BytesMut::with_capacity(4096);
    let mut fields: Vec<Header> = Vec::with_capacity(32);
    for round in 0..100 {
        let mut enc = Encoder::new(4096, 0);
        let mut dec = Decoder::new(4096);
        let verify = round == 99;
        for hs in &typed {
            dst.clear();
            enc.encode(hs.iter().cloned(), &mut dst);
            tb += 1;
            th += hs.len() as i64;
            sink += dst.len() as i64;
            if verify {
                fields.clear();
                let mut b = dst.clone();
                dec.decode(&mut Cursor::new(&mut b), |h| {
                    fields.push(h);
                    ControlFlow::Continue(())
                })
                .unwrap_or_else(|e| {
                    eprintln!("verify decode error: {:?}", e);
                    process::exit(1);
                });
                vck = hash_fields(vck, &fields);
            }
        }
    }
    if sink <= 0 {
        process::exit(1);
    }
    println!("mode=hpack_encode");
    println!("blocks={}", tb);
    println!("headers={}", th);
    println!("verify_checksum={}", vck);
}

fn main() {
    let a: Vec<String> = env::args().collect();
    if a.len() < 3 {
        eprintln!("usage: h2_hpack hpack|hpack_decode|hpack_encode <file>");
        process::exit(2);
    }
    let data = fs::read(&a[2]).expect("read");
    match a[1].as_str() {
        "hpack" => run_diff(std::str::from_utf8(&data).unwrap()),
        "hpack_decode" => bench_decode(&data),
        "hpack_encode" => bench_encode(&data),
        m => {
            eprintln!("unknown mode {}", m);
            process::exit(2);
        }
    }
}
