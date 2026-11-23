use rmpv::{Integer, Utf8String, Value};
use std::env;
use std::fs;
use std::io::Cursor;

struct WalkStats {
    nodes: i64,
    checksum: u64,
}

fn parse_timestamp_ext(data: &[u8]) -> Option<(i64, u32)> {
    match data.len() {
        4 => {
            let sec = u32::from_be_bytes([data[0], data[1], data[2], data[3]]) as i64;
            Some((sec, 0))
        }
        8 => {
            let d64 = u64::from_be_bytes([
                data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7],
            ]);
            let nsec = (d64 >> 34) as u32;
            let sec = (d64 & 0x3_FFFF_FFFF) as i64;
            Some((sec, nsec))
        }
        12 => {
            let nsec = u32::from_be_bytes([data[0], data[1], data[2], data[3]]);
            let sec = i64::from_be_bytes([
                data[4], data[5], data[6], data[7], data[8], data[9], data[10], data[11],
            ]);
            Some((sec, nsec))
        }
        _ => None,
    }
}

fn walk_value(v: &Value) -> WalkStats {
    match v {
        Value::Nil => WalkStats { nodes: 1, checksum: 19 },
        Value::Boolean(b) => WalkStats {
            nodes: 1,
            checksum: if *b { 13 } else { 17 },
        },
        Value::Integer(n) => {
            if let Some(u) = n.as_u64() {
                WalkStats {
                    nodes: 1,
                    checksum: u.wrapping_add(1),
                }
            } else {
                let i = n.as_i64().unwrap();
                WalkStats {
                    nodes: 1,
                    checksum: (0u64.wrapping_sub(i as u64)).wrapping_mul(3).wrapping_add(5),
                }
            }
        }
        Value::F32(f) => WalkStats {
            nodes: 1,
            checksum: (*f as f64).to_bits(),
        },
        Value::F64(d) => WalkStats {
            nodes: 1,
            checksum: d.to_bits(),
        },
        Value::String(s) => {
            let bytes = s.as_bytes();
            let mut h = (bytes.len() as u64).wrapping_mul(11);
            if !bytes.is_empty() {
                h = h.wrapping_add(bytes[0] as u64);
                h = h.wrapping_add(bytes[bytes.len() - 1] as u64);
            }
            WalkStats { nodes: 1, checksum: h }
        }
        Value::Binary(b) => {
            let mut h = (b.len() as u64).wrapping_mul(7);
            if !b.is_empty() {
                h = h.wrapping_add(b[0] as u64);
                h = h.wrapping_add(b[b.len() - 1] as u64);
            }
            WalkStats { nodes: 1, checksum: h }
        }
        Value::Ext(tag, b) => {
            if *tag == -1 {
                if let Some((sec, nsec)) = parse_timestamp_ext(b) {
                    return WalkStats {
                        nodes: 1,
                        checksum: (sec as u64).wrapping_mul(31).wrapping_add(nsec as u64),
                    };
                }
            }
            let h = ((*tag as i64 + 128) as u64)
                .wrapping_mul(29)
                .wrapping_add(b.len() as u64);
            WalkStats { nodes: 1, checksum: h }
        }
        Value::Array(items) => {
            let mut nodes = 1i64;
            let mut sum = (items.len() as u64).wrapping_mul(37);
            for item in items {
                let sub = walk_value(item);
                nodes += sub.nodes;
                sum = sum.wrapping_add(sub.checksum);
            }
            WalkStats { nodes, checksum: sum }
        }
        Value::Map(pairs) => {
            let mut nodes = 1i64;
            let mut sum = (pairs.len() as u64).wrapping_mul(41);
            for (k, val) in pairs {
                let sk = walk_value(k);
                let sv = walk_value(val);
                nodes += sk.nodes + sv.nodes;
                sum = sum
                    .wrapping_add(sk.checksum.wrapping_mul(131))
                    .wrapping_add(sv.checksum);
            }
            WalkStats { nodes, checksum: sum }
        }
    }
}

fn run_decode(path: &str, rounds: usize) {
    let data = fs::read(path).expect("failed to read corpus");
    let mut total_nodes: i64 = 0;
    let mut total_checksum: u64 = 0;
    for _ in 0..rounds {
        let mut cur = Cursor::new(data.as_slice());
        let v = rmpv::decode::read_value(&mut cur).expect("decode failed");
        let st = walk_value(&v);
        total_nodes += st.nodes;
        total_checksum = total_checksum.wrapping_add(st.checksum);
    }
    println!("rounds={}", rounds);
    println!("bytes={}", data.len());
    println!("nodes={}", total_nodes);
    println!("checksum={}", total_checksum);
}

fn run_encode_rpc() {
    let ops = 50000usize;
    let regions = ["ap-northeast-1", "us-east-1", "eu-west-1", "us-west-2"];
    let svcs = [
        "edge-gw-0", "edge-gw-1", "edge-gw-2", "edge-gw-3",
        "edge-gw-4", "edge-gw-5", "edge-gw-6", "edge-gw-7",
        "edge-gw-8", "edge-gw-9", "edge-gw-10", "edge-gw-11",
        "edge-gw-12", "edge-gw-13", "edge-gw-14", "edge-gw-15",
    ];
    let tags = Value::Array(vec![
        Value::String(Utf8String::from("prod")),
        Value::String(Utf8String::from("telemetry")),
        Value::String(Utf8String::from("v2")),
        Value::String(Utf8String::from("grpc")),
    ]);
    let mut payload = Vec::with_capacity(24);
    for p in 0..24 {
        payload.push(((p * 13 + 5) & 0xFF) as u8);
    }
    let mut total_bytes: i64 = 0;
    let mut checksum: u64 = 0;
    let mut buf = Vec::with_capacity(256);
    for i in 0..ops {
        let i64v = i as i64;
        let meta = Value::Map(vec![
            (Value::String(Utf8String::from("err")), Value::Nil),
            (Value::String(Utf8String::from("region")), Value::String(Utf8String::from(regions[i & 3]))),
            (Value::String(Utf8String::from("retries")), Value::Integer(Integer::from((i & 3) as u64))),
        ]);
        let rec = Value::Map(vec![
            (Value::String(Utf8String::from("delta")), Value::Integer(Integer::from(-(i64v * 17 + 1)))),
            (Value::String(Utf8String::from("id")), Value::Integer(Integer::from((1000000 + i64v) as u64))),
            (Value::String(Utf8String::from("latency_ms")), Value::F64(1.25 + ((i % 97) as f64) * 0.25)),
            (Value::String(Utf8String::from("meta")), meta),
            (Value::String(Utf8String::from("ok")), Value::Boolean((i % 5) != 0)),
            (Value::String(Utf8String::from("payload")), Value::Binary(payload.clone())),
            (Value::String(Utf8String::from("svc")), Value::String(Utf8String::from(svcs[i & 15]))),
            (Value::String(Utf8String::from("tags")), tags.clone()),
        ]);
        buf.clear();
        rmpv::encode::write_value(&mut buf, &rec).expect("encode failed");
        let n = buf.len();
        total_bytes += n as i64;
        checksum = checksum.wrapping_add(n as u64);
        checksum = checksum.wrapping_add(buf[0] as u64);
        checksum = checksum.wrapping_add(buf[n / 2] as u64);
        checksum = checksum.wrapping_add(buf[n - 1] as u64);
    }
    println!("ops={}", ops);
    println!("total_bytes={}", total_bytes);
    println!("checksum={}", checksum);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: bench_rust <decode-rpc|encode-rpc|decode-large> [path]");
        std::process::exit(1);
    }
    match args[1].as_str() {
        "decode-rpc" => run_decode(&args[2], 40),
        "encode-rpc" => run_encode_rpc(),
        "decode-large" => run_decode(&args[2], 4),
        other => {
            eprintln!("unknown cmd: {}", other);
            std::process::exit(1);
        }
    }
}
