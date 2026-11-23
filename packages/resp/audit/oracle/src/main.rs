//! Rust `redis-protocol 6.0.0` oracle for the `packages/resp` red-team audit.
//!
//! Modes (inputs are `id<TAB>hex` files produced by tools/prep.py):
//!   decode <hex.tsv>  -> id<TAB>OK <ocanon> | INC | ERR <msg> | PANIC   (RESP3 streaming decoder + codec-style
//!                        reassembly of streamed frames; ocanon = sorted maps/sets, all nulls `_`)
//!   keys <hex.tsv>    -> id<TAB>redis_keyslot(key)
//!   w1fair <corpus>   -> timing of the README W1 loop (buf.clone().freeze()) vs zero-copy decode_bytes_mut
//!   w3split           -> timing of redis_keyslot-only vs MOVED-parse-only halves of README W3
use bytes::{Bytes, BytesMut};
use redis_protocol::redis_keyslot;
use redis_protocol::resp3::decode::streaming;
use redis_protocol::resp3::types::{BytesFrame, DecodedFrame, Resp3Frame, VerbatimStringFormat};
use std::time::Instant;
use std::{env, fs, process};

fn esc(b: &[u8]) -> String {
    let mut s = String::from("\"");
    for &c in b {
        if (32..=126).contains(&c) && c != b'"' && c != b'\\' {
            s.push(c as char);
        } else {
            s.push_str(&format!("\\x{:02x}", c));
        }
    }
    s.push('"');
    s
}

fn dbl(d: f64) -> String {
    if d.is_nan() {
        "nan".into()
    } else {
        format!("0x{:016x}", d.to_bits())
    }
}

fn attrs_prefix(a: Option<&redis_protocol::resp3::types::BytesAttributes>) -> String {
    match a {
        None => String::new(),
        Some(m) => {
            let mut parts: Vec<String> = m.iter().map(|(k, v)| format!("{}:{}", canon(k), canon(v))).collect();
            parts.sort();
            format!("|{{{}}}", parts.join(","))
        }
    }
}

fn canon(f: &BytesFrame) -> String {
    let body = match f {
        BytesFrame::SimpleString { data, .. } => format!("+{}", esc(data)),
        BytesFrame::SimpleError { data, .. } => format!("-{}", esc(data.as_bytes())),
        BytesFrame::Number { data, .. } => format!(":{}", data),
        BytesFrame::BlobString { data, .. } => format!("${}", esc(data)),
        BytesFrame::BlobError { data, .. } => format!("!{}", esc(data)),
        BytesFrame::Null => "_".into(),
        BytesFrame::Boolean { data, .. } => if *data { "#t".into() } else { "#f".into() },
        BytesFrame::Double { data, .. } => format!(",{}", dbl(*data)),
        BytesFrame::BigNumber { data, .. } => format!("({}", esc(data)),
        BytesFrame::VerbatimString { data, format, .. } => {
            let tag = match format {
                VerbatimStringFormat::Text => "txt",
                VerbatimStringFormat::Markdown => "mkd",
            };
            format!("={}:{}", esc(tag.as_bytes()), esc(data))
        }
        BytesFrame::Array { data, .. } => format!("*[{}]", data.iter().map(canon).collect::<Vec<_>>().join(",")),
        BytesFrame::Push { data, .. } => format!(">[{}]", data.iter().map(canon).collect::<Vec<_>>().join(",")),
        BytesFrame::Set { data, .. } => {
            let mut v: Vec<String> = data.iter().map(canon).collect();
            v.sort();
            format!("~[{}]", v.join(","))
        }
        BytesFrame::Map { data, .. } => {
            let mut v: Vec<String> = data.iter().map(|(k, x)| format!("{}:{}", canon(k), canon(x))).collect();
            v.sort();
            format!("%{{{}}}", v.join(","))
        }
        BytesFrame::Hello { .. } => "HELLO".into(),
        BytesFrame::ChunkedString(b) => format!(";{}", esc(b)),
    };
    format!("{}{}", attrs_prefix(f.attributes()), body)
}

/// Decode one frame like `redis_protocol::codec::Resp3` (streaming decoder + StreamedFrame reassembly).
fn decode_one(input: &[u8]) -> String {
    let buf = Bytes::copy_from_slice(input);
    let mut off = 0usize;
    let mut stream: Option<redis_protocol::resp3::types::StreamedFrame<BytesFrame>> = None;
    loop {
        if off >= buf.len() {
            return "INC".into();
        }
        let view = buf.slice(off..);
        match streaming::decode_bytes(&view) {
            Ok(None) => return "INC".into(),
            Err(e) => return format!("ERR {:?}", e.kind()),
            Ok(Some((decoded, used))) => {
                off += used;
                let done = match (stream.as_mut(), decoded) {
                    (None, DecodedFrame::Complete(f)) => Some(f),
                    (None, DecodedFrame::Streaming(s)) => {
                        stream = Some(s);
                        None
                    }
                    (Some(_), DecodedFrame::Streaming(_)) => return "ERR nested-stream".into(),
                    (Some(s), DecodedFrame::Complete(f)) => {
                        s.add_frame(f);
                        if s.is_finished() {
                            match s.take() {
                                Ok(f) => Some(f),
                                Err(e) => return format!("ERR {:?}", e.kind()),
                            }
                        } else {
                            None
                        }
                    }
                };
                if let Some(f) = done {
                    if off != buf.len() {
                        return "ERR trailing".into();
                    }
                    return format!("OK {}", canon(&f));
                }
            }
        }
    }
}

fn read_cases(path: &str) -> Vec<(String, Vec<u8>)> {
    let text = fs::read_to_string(path).expect("read cases");
    text.lines()
        .filter_map(|l| {
            let (id, hex) = l.split_once('\t')?;
            let bytes = (0..hex.len() / 2)
                .map(|i| u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).unwrap())
                .collect();
            Some((id.to_string(), bytes))
        })
        .collect()
}

fn run_decode(path: &str) {
    // redis-protocol's decoder is recursive (nom): give it a large stack and isolate panics per case.
    let cases = read_cases(path);
    let child = std::thread::Builder::new()
        .stack_size(512 << 20)
        .spawn(move || {
            std::panic::set_hook(Box::new(|_| {}));
            let mut out = String::new();
            for (id, data) in cases {
                let r = std::panic::catch_unwind(|| decode_one(&data)).unwrap_or_else(|_| "PANIC".into());
                out.push_str(&format!("{}\t{}\n", id, r));
            }
            out
        })
        .unwrap();
    print!("{}", child.join().unwrap());
}

fn run_keys(path: &str) {
    for (id, key) in read_cases(path) {
        println!("{}\t{}", id, redis_keyslot(&key));
    }
}

fn run_w1fair(path: &str) {
    let data = fs::read(path).expect("read corpus");
    for variant in ["readme_clone_freeze", "decode_bytes_mut"] {
        let t = Instant::now();
        let mut frames = 0u64;
        let mut buf = BytesMut::with_capacity(4096);
        for chunk in data.chunks(137) {
            buf.extend_from_slice(chunk);
            loop {
                if buf.is_empty() {
                    break;
                }
                if variant == "readme_clone_freeze" {
                    let view = buf.clone().freeze();
                    match redis_protocol::resp3::decode::complete::decode_bytes(&view) {
                        Ok(Some((_f, used))) => {
                            let _ = buf.split_to(used);
                            frames += 1;
                        }
                        Ok(None) => break,
                        Err(_) => process::exit(3),
                    }
                } else {
                    match redis_protocol::resp3::decode::complete::decode_bytes_mut(&mut buf) {
                        Ok(Some((_f, _used, _b))) => frames += 1,
                        Ok(None) => break,
                        Err(_) => process::exit(3),
                    }
                }
            }
        }
        println!("{}\tframes={} ms={:.3}", variant, frames, t.elapsed().as_secs_f64() * 1e3);
    }
}

fn parse_moved_rust(s: &str) -> Option<(u16, u16)> {
    let rest = s.strip_prefix("MOVED ")?;
    let (slot_s, addr) = rest.split_once(' ')?;
    let slot: u16 = slot_s.parse().ok()?;
    let port_s = if let Some(after) = addr.strip_prefix('[') {
        after.split_once("]:")?.1
    } else {
        addr.rsplit_once(':')?.1
    };
    Some((slot, port_s.parse().ok()?))
}

fn run_w3split() {
    let keys: [&[u8]; 4] = [b"foo", b"{user1000}.following", b"foo{bar}{zap}", b"rate:{ip-10.0.0.1}:minute"];
    let redirects = ["MOVED 3999 127.0.0.1:6381", "MOVED 5061 [::1]:7002"];
    let t = Instant::now();
    let mut acc = 0u64;
    for i in 0..2_000_000usize {
        acc = acc.wrapping_add(redis_keyslot(std::hint::black_box(keys[i & 3])) as u64);
    }
    println!("rust_keyslot_2m\tms={:.3} acc={}", t.elapsed().as_secs_f64() * 1e3, acc);
    let t = Instant::now();
    let mut acc2 = 0u64;
    for i in 0..500_000usize {
        let (s, p) = parse_moved_rust(std::hint::black_box(redirects[i & 1])).unwrap();
        acc2 = acc2.wrapping_add(s as u64 + p as u64);
    }
    println!("rust_moved_500k\tms={:.3} acc={}", t.elapsed().as_secs_f64() * 1e3, acc2);
}

fn main() {
    let a: Vec<String> = env::args().collect();
    match (a.get(1).map(String::as_str), a.get(2)) {
        (Some("decode"), Some(p)) => run_decode(p),
        (Some("keys"), Some(p)) => run_keys(p),
        (Some("w1fair"), Some(p)) => run_w1fair(p),
        (Some("w3split"), _) => run_w3split(),
        _ => {
            eprintln!("usage: resp_audit_oracle decode|keys <hex.tsv> | w1fair <corpus> | w3split");
            process::exit(1);
        }
    }
}
