use bytes::{Bytes, BytesMut};
use redis_protocol::redis_keyslot;
use redis_protocol::resp3::decode::complete::decode_bytes;
use redis_protocol::resp3::encode::complete::extend_encode;
use redis_protocol::resp3::types::BytesFrame;
use std::env;
use std::fs;
use std::process;

fn walk_frame(f: &BytesFrame) -> (i64, u64) {
    match f {
        BytesFrame::SimpleString { data, .. } => {
            let n = data.len();
            let mut h = (n as u64).wrapping_mul(11).wrapping_add(1);
            if n > 0 {
                h = h
                    .wrapping_add(data[0] as u64)
                    .wrapping_add(data[n - 1] as u64);
            }
            (1, h)
        }
        BytesFrame::SimpleError { data, .. } => {
            let n = data.len();
            let mut h = (n as u64).wrapping_mul(13).wrapping_add(2);
            if n > 0 {
                h = h.wrapping_add(data.as_bytes()[0] as u64);
            }
            (1, h)
        }
        BytesFrame::Number { data, .. } => (1, (*data as u64).wrapping_mul(17).wrapping_add(3)),
        BytesFrame::BlobString { data, .. } => {
            let n = data.len();
            let mut h = (n as u64).wrapping_mul(19).wrapping_add(4);
            if n > 0 {
                h = h
                    .wrapping_add(data[0] as u64)
                    .wrapping_add(data[n - 1] as u64);
            }
            (1, h)
        }
        BytesFrame::Double { data, .. } => (1, data.to_bits().wrapping_add(5)),
        BytesFrame::Boolean { data, .. } => (1, if *data { 61 } else { 67 }),
        BytesFrame::Null => (1, 71),
        BytesFrame::BigNumber { data, .. } => {
            (1, (data.len() as u64).wrapping_mul(23).wrapping_add(83))
        }
        BytesFrame::BlobError { data, .. } => {
            (1, (data.len() as u64).wrapping_mul(29).wrapping_add(89))
        }
        BytesFrame::VerbatimString { data, .. } => {
            (1, (data.len() as u64).wrapping_mul(31).wrapping_add(97))
        }
        BytesFrame::Array { data, .. } => {
            let mut nodes: i64 = 1;
            let mut sum: u64 = (data.len() as u64).wrapping_mul(37);
            for item in data {
                let (cn, ch) = walk_frame(item);
                nodes += cn;
                sum = sum.wrapping_add(ch);
            }
            (nodes, sum)
        }
        BytesFrame::Set { data, .. } => {
            let mut nodes: i64 = 1;
            let mut sum: u64 = (data.len() as u64).wrapping_mul(41);
            for item in data {
                let (cn, ch) = walk_frame(item);
                nodes += cn;
                sum = sum.wrapping_add(ch);
            }
            (nodes, sum)
        }
        BytesFrame::Push { data, .. } => {
            let mut nodes: i64 = 1;
            let mut sum: u64 = (data.len() as u64).wrapping_mul(43);
            for item in data {
                let (cn, ch) = walk_frame(item);
                nodes += cn;
                sum = sum.wrapping_add(ch);
            }
            (nodes, sum)
        }
        BytesFrame::Map { data, .. } => {
            let mut nodes: i64 = 1;
            let mut sum: u64 = (data.len() as u64).wrapping_mul(47);
            for (k, v) in data {
                let (kn, kh) = walk_frame(k);
                let (vn, vh) = walk_frame(v);
                nodes += kn + vn;
                sum = sum.wrapping_add(kh.wrapping_mul(131).wrapping_add(vh));
            }
            (nodes, sum)
        }
        _ => (1, 0),
    }
}

fn run_w1(path: &str) {
    let data = fs::read(path).expect("failed to read w1 corpus");
    let mut buf = BytesMut::with_capacity(4096);
    let mut frames: i64 = 0;
    let mut nodes: i64 = 0;
    let mut checksum: u64 = 0;

    for chunk in data.chunks(137) {
        buf.extend_from_slice(chunk);
        loop {
            if buf.is_empty() {
                break;
            }
            let view = buf.clone().freeze();
            match decode_bytes(&view) {
                Ok(Some((frame, consumed))) => {
                    let _ = buf.split_to(consumed);
                    let (n, h) = walk_frame(&frame);
                    frames += 1;
                    nodes += n;
                    checksum = checksum.wrapping_add(h);
                }
                Ok(None) => break,
                Err(e) => {
                    eprintln!("w1 decode error: {:?}", e);
                    process::exit(3);
                }
            }
        }
    }

    println!("frames={}", frames);
    println!("nodes={}", nodes);
    println!("checksum={}", checksum);
}

fn mk_blob(b: &Bytes) -> BytesFrame {
    BytesFrame::BlobString {
        data: b.clone(),
        attributes: None,
    }
}

fn run_w2() {
    let batches = 500usize;
    let batch_size = 1000usize;
    let cmd_set = Bytes::from_static(b"SET");
    let cmd_get = Bytes::from_static(b"GET");
    let cmd_hset = Bytes::from_static(b"HSET");
    let cmd_mget = Bytes::from_static(b"MGET");
    let f1 = Bytes::from_static(b"f1");
    let f2 = Bytes::from_static(b"f2");

    let mut keys = Vec::with_capacity(64);
    let mut vals = Vec::with_capacity(64);
    for p in 0..64 {
        keys.push(Bytes::from(format!("user:session:key:{}", p)));
        vals.push(Bytes::from(format!("payload-value-item-{}", p)));
    }

    let mut wire = BytesMut::with_capacity(65536);
    let mut total_cmds: i64 = 0;
    let mut total_bytes: i64 = 0;
    let mut checksum: u64 = 0;

    for b in 0..batches {
        wire.clear();
        for i in 0..batch_size {
            let idx = (b * 13 + i) & 63;
            let idx2 = (idx + 1) & 63;
            let idx3 = (idx + 2) & 63;
            let frame = match i & 3 {
                0 => BytesFrame::Array {
                    data: vec![mk_blob(&cmd_set), mk_blob(&keys[idx]), mk_blob(&vals[idx])],
                    attributes: None,
                },
                1 => BytesFrame::Array {
                    data: vec![mk_blob(&cmd_get), mk_blob(&keys[idx])],
                    attributes: None,
                },
                2 => BytesFrame::Array {
                    data: vec![
                        mk_blob(&cmd_hset),
                        mk_blob(&keys[idx]),
                        mk_blob(&f1),
                        mk_blob(&vals[idx]),
                        mk_blob(&f2),
                        mk_blob(&vals[idx2]),
                    ],
                    attributes: None,
                },
                _ => BytesFrame::Array {
                    data: vec![
                        mk_blob(&cmd_mget),
                        mk_blob(&keys[idx]),
                        mk_blob(&keys[idx2]),
                        mk_blob(&keys[idx3]),
                    ],
                    attributes: None,
                },
            };
            extend_encode(&mut wire, &frame, false).expect("encode failed");
        }
        total_bytes += wire.len() as i64;
        let mut frozen = wire.split().freeze();
        while !frozen.is_empty() {
            match decode_bytes(&frozen) {
                Ok(Some((frame, consumed))) => {
                    let _ = frozen.split_to(consumed);
                    let (_, h) = walk_frame(&frame);
                    total_cmds += 1;
                    checksum = checksum.wrapping_add(h);
                }
                Ok(None) => {
                    eprintln!("w2 unexpected incomplete");
                    process::exit(3);
                }
                Err(e) => {
                    eprintln!("w2 decode error: {:?}", e);
                    process::exit(3);
                }
            }
        }
    }

    println!("cmds={}", total_cmds);
    println!("bytes={}", total_bytes);
    println!("checksum={}", checksum);
}

fn parse_moved_rust(s: &str) -> Option<(u16, u16)> {
    let rest = s.strip_prefix("MOVED ")?;
    let (slot_s, addr) = rest.split_once(' ')?;
    let slot: u16 = slot_s.parse().ok()?;
    if slot > 16383 {
        return None;
    }
    let port_s = if let Some(after) = addr.strip_prefix('[') {
        let (_, tail) = after.split_once("]:")?;
        tail
    } else {
        let (_, tail) = addr.rsplit_once(':')?;
        tail
    };
    let port: u16 = port_s.parse().ok()?;
    if port == 0 {
        return None;
    }
    Some((slot, port))
}

fn run_w3() {
    let keys: [&[u8]; 16] = [
        b"foo",
        b"bar",
        b"123456789",
        b"{user1000}.following",
        b"{user1000}.followers",
        b"foo{}{bar}",
        b"foo{{bar}}zap",
        b"foo{bar}{zap}",
        b"{}foo",
        b"session:{tenant-99}:tok",
        b"order:{acct-42}:items",
        b"a{b}c",
        b"a{b",
        b"a}b",
        b"cache:v2:homepage:en-US",
        b"rate:{ip-10.0.0.1}:minute",
    ];
    let redirects: [&str; 4] = [
        "MOVED 3999 127.0.0.1:6381",
        "MOVED 12182 10.0.0.3:6379",
        "MOVED 5061 [::1]:7002",
        "MOVED 3443 redis-node-1:6379",
    ];
    let ops = 2_000_000usize;
    let mut slot_sum: u64 = 0;
    let mut moved_sum: u64 = 0;
    for i in 0..ops {
        let s = redis_keyslot(keys[i & 15]);
        slot_sum = slot_sum.wrapping_add(s as u64);
        if (i & 3) == 0 {
            let (ms, port) = parse_moved_rust(redirects[(i >> 2) & 3]).expect("moved parse");
            moved_sum = moved_sum.wrapping_add(ms as u64).wrapping_add(port as u64);
        }
    }
    println!("ops={}", ops);
    println!("slot_sum={}", slot_sum);
    println!("moved_sum={}", moved_sum);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: resp_bench_rust <w1 <path>|w2|w3>");
        process::exit(1);
    }
    match args[1].as_str() {
        "w1" => run_w1(&args[2]),
        "w2" => run_w2(),
        "w3" => run_w3(),
        other => {
            eprintln!("unknown mode: {}", other);
            process::exit(1);
        }
    }
}
