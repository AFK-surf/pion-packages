use prost::Message;
use std::env;
use std::fs;
use std::process;

#[derive(Clone, PartialEq, Message)]
struct KeyValue {
    #[prost(string, tag = "1")]
    key: String,
    #[prost(string, tag = "2")]
    str_value: String,
    #[prost(int64, tag = "3")]
    int_value: i64,
}

#[derive(Clone, PartialEq, Message)]
struct SpanEvent {
    #[prost(uint64, tag = "1")]
    time_unix_nano: u64,
    #[prost(string, tag = "2")]
    name: String,
    #[prost(int32, tag = "3")]
    dropped_attributes: i32,
}

#[derive(Clone, PartialEq, Message)]
struct Span {
    #[prost(bytes = "vec", tag = "1")]
    trace_id: Vec<u8>,
    #[prost(bytes = "vec", tag = "2")]
    span_id: Vec<u8>,
    #[prost(string, tag = "3")]
    name: String,
    #[prost(int32, tag = "4")]
    kind: i32,
    #[prost(uint64, tag = "5")]
    start_time_unix_nano: u64,
    #[prost(uint64, tag = "6")]
    end_time_unix_nano: u64,
    #[prost(message, repeated, tag = "7")]
    attributes: Vec<KeyValue>,
    #[prost(message, repeated, tag = "8")]
    events: Vec<SpanEvent>,
    #[prost(int32, tag = "9")]
    status_code: i32,
    #[prost(string, tag = "10")]
    status_message: String,
}

#[derive(Clone, PartialEq, Message)]
struct NumericBatch {
    #[prost(sint64, repeated, packed = "true", tag = "1")]
    svals: Vec<i64>,
    #[prost(double, repeated, packed = "true", tag = "2")]
    dvals: Vec<f64>,
}

fn checksum_span(sp: &Span) -> u64 {
    let mut h: u64 = 0;
    if !sp.trace_id.is_empty() {
        h = h
            .wrapping_add(sp.trace_id[0] as u64)
            .wrapping_add(sp.trace_id[sp.trace_id.len() - 1] as u64);
    }
    if !sp.span_id.is_empty() {
        h = h.wrapping_add((sp.span_id[0] as u64).wrapping_mul(3));
    }
    h = h.wrapping_add((sp.name.len() as u64).wrapping_mul(7));
    h = h.wrapping_add((sp.kind as i64 as u64).wrapping_mul(11));
    h = h.wrapping_add(sp.end_time_unix_nano.wrapping_sub(sp.start_time_unix_nano));
    for kv in &sp.attributes {
        h = h.wrapping_add((kv.key.len() as u64).wrapping_mul(13));
        h = h.wrapping_add((kv.str_value.len() as u64).wrapping_mul(17));
        h = h.wrapping_add((kv.int_value as u64).wrapping_mul(19));
    }
    for ev in &sp.events {
        h = h.wrapping_add((ev.name.len() as u64).wrapping_mul(23));
        h = h.wrapping_add((ev.dropped_attributes as i64 as u64).wrapping_mul(29));
    }
    h = h.wrapping_add((sp.status_code as i64 as u64).wrapping_mul(31));
    h = h.wrapping_add((sp.status_message.len() as u64).wrapping_mul(37));
    h
}

fn build_sample_spans(count: usize) -> Vec<Span> {
    let names = [
        "grpc.order.CreateOrder",
        "grpc.payment.Authorize",
        "http.GET /api/v1/inventory",
        "db.postgres.SELECT orders",
        "redis.HGET session:meta",
        "kafka.produce order-events",
        "auth.VerifyJwtToken",
        "cache.LookupUserProfile",
    ];
    let services = ["checkout-svc", "payment-svc", "inventory-svc", "gateway-edge"];
    let regions = ["ap-northeast-1", "us-west-2", "eu-central-1", "ap-southeast-1"];
    let mut out = Vec::with_capacity(count);
    for idx in 0..count {
        let tid: Vec<u8> = (0..16).map(|k| ((idx * 31 + k * 17) & 0xFF) as u8).collect();
        let sid: Vec<u8> = (0..8).map(|k| ((idx * 13 + k * 29 + 7) & 0xFF) as u8).collect();
        let start_ns: u64 = 1700000000000000000u64 + (idx as u64) * 125000;
        let end_ns: u64 = start_ns + 45000 + ((idx % 997) as u64) * 100;
        let status_code = if (idx % 17) != 0 { 1 } else { 2 };
        let status_msg = if status_code == 1 {
            String::new()
        } else {
            "upstream deadline exceeded".to_string()
        };
        out.push(Span {
            trace_id: tid,
            span_id: sid,
            name: names[idx % names.len()].to_string(),
            kind: (idx % 5) as i32 + 1,
            start_time_unix_nano: start_ns,
            end_time_unix_nano: end_ns,
            attributes: vec![
                KeyValue {
                    key: "service.name".to_string(),
                    str_value: services[idx % services.len()].to_string(),
                    int_value: 0,
                },
                KeyValue {
                    key: "cloud.region".to_string(),
                    str_value: regions[idx % regions.len()].to_string(),
                    int_value: 0,
                },
                KeyValue {
                    key: "http.status_code".to_string(),
                    str_value: String::new(),
                    int_value: if (idx % 17) != 0 { 200 } else { 503 },
                },
                KeyValue {
                    key: "rpc.retry_count".to_string(),
                    str_value: String::new(),
                    int_value: (idx % 4) as i64,
                },
            ],
            events: vec![
                SpanEvent {
                    time_unix_nano: start_ns + 5000,
                    name: "request.received".to_string(),
                    dropped_attributes: 0,
                },
                SpanEvent {
                    time_unix_nano: end_ns - 2000,
                    name: "response.flushed".to_string(),
                    dropped_attributes: (idx % 3) as i32,
                },
            ],
            status_code,
            status_message: status_msg,
        });
    }
    out
}

fn fnv1a_update(mut h: u64, b: &[u8]) -> u64 {
    for &byte in b {
        h = (h ^ (byte as u64)).wrapping_mul(1099511628211u64);
    }
    h
}

fn run_decode_spans(path: &str) {
    let data = fs::read(path).expect("failed to read corpus");
    let mut slices: Vec<(usize, usize)> = Vec::new();
    let mut off = 0usize;
    while off + 4 <= data.len() {
        let mlen = u32::from_le_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]]) as usize;
        off += 4;
        slices.push((off, off + mlen));
        off += mlen;
    }
    let rounds = 50usize;
    let mut total_spans: i64 = 0;
    let mut total_bytes: i64 = 0;
    let mut total_checksum: u64 = 0;
    for _ in 0..rounds {
        for &(s, e) in &slices {
            let sp = Span::decode(&data[s..e]).expect("decode failed");
            total_spans += 1;
            total_bytes += (e - s) as i64;
            total_checksum = total_checksum.wrapping_add(checksum_span(&sp));
        }
    }
    println!("spans={}", total_spans);
    println!("bytes={}", total_bytes);
    println!("checksum={}", total_checksum);
}

fn run_encode_spans() {
    let spans = build_sample_spans(2000);
    let rounds = 50usize;
    let mut buf = Vec::with_capacity(512);
    let mut total_spans: i64 = 0;
    let mut total_bytes: i64 = 0;
    let mut hash: u64 = 14695981039346656037u64;
    for r in 0..rounds {
        for sp in &spans {
            buf.clear();
            sp.encode(&mut buf).expect("encode failed");
            total_spans += 1;
            total_bytes += buf.len() as i64;
            if r == 0 {
                hash = fnv1a_update(hash, &buf);
            }
        }
    }
    println!("spans={}", total_spans);
    println!("encoded_bytes={}", total_bytes);
    println!("hash={}", hash);
}

fn run_packed_numeric() {
    let n = 200_000usize;
    let mut svals = Vec::with_capacity(n);
    let mut dvals = Vec::with_capacity(n);
    for i in 0..n {
        let sign: i64 = if (i & 1) == 0 { 1 } else { -1 };
        let mag: i64 = ((i % 1000) as i64) * 37 + ((i / 1000) as i64) * 100003;
        svals.push(sign * mag);
        dvals.push((i as f64) * 0.125 - 10000.0);
    }
    let batch = NumericBatch { svals, dvals };
    let rounds = 8usize;
    let mut buf = Vec::with_capacity(3_000_000);
    let mut total_encoded: i64 = 0;
    let mut sint64_sum: i64 = 0;
    let mut double_xor: u64 = 0;
    for _ in 0..rounds {
        buf.clear();
        batch.encode(&mut buf).expect("encode failed");
        total_encoded += buf.len() as i64;
        let dec = NumericBatch::decode(buf.as_slice()).expect("decode failed");
        for v in dec.svals {
            sint64_sum = sint64_sum.wrapping_add(v);
        }
        for d in dec.dvals {
            double_xor ^= d.to_bits();
        }
    }
    println!("rounds={}", rounds);
    println!("encoded_bytes={}", total_encoded);
    println!("sint64_sum={}", sint64_sum);
    println!("double_bits_xor={}", double_xor);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: rust_bench <decode_spans|encode_spans|packed_numeric> [corpus]");
        process::exit(1);
    }
    match args[1].as_str() {
        "decode_spans" => run_decode_spans(&args[2]),
        "encode_spans" => run_encode_spans(),
        "packed_numeric" => run_packed_numeric(),
        other => {
            eprintln!("unknown cmd: {}", other);
            process::exit(1);
        }
    }
}
