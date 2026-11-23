//! Adversarial head-to-head benchmark (Rust + hickory-proto =0.24.2), mirrors
//! ../go/main.go and ../pion_bench byte-for-byte on stdout.
//!   rust_bench encode <names.txt> <rounds>
//!   rust_bench decode <names.txt> <rounds>
use hickory_proto::op::{Message, MessageType, OpCode, Query};
use hickory_proto::rr::{rdata::A, Name, RData, Record, RecordType};
use std::net::Ipv4Addr;
use std::str::FromStr;

fn build(names: &[String]) -> Message {
    let mut m = Message::new();
    m.set_id(0x4242)
        .set_message_type(MessageType::Response)
        .set_op_code(OpCode::Query)
        .set_recursion_desired(true)
        .set_recursion_available(true);
    m.add_query(Query::query(
        Name::from_str("q.bulk.example.").unwrap(),
        RecordType::A,
    ));
    for (i, n) in names.iter().enumerate() {
        let ip = Ipv4Addr::new(10, (i >> 16) as u8, (i >> 8) as u8, i as u8);
        m.add_answer(Record::from_rdata(
            Name::from_str(n).unwrap(),
            60,
            RData::A(A(ip)),
        ));
    }
    m
}

fn fold(mut h: u64, w: &[u8]) -> u64 {
    for b in w {
        h = (h * 131 + *b as u64) % 1_000_000_007;
    }
    h
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let names: Vec<String> = std::fs::read_to_string(&a[2])
        .unwrap()
        .lines()
        .filter(|l| !l.is_empty())
        .map(|s| s.to_string())
        .collect();
    let rounds: usize = a[3].parse().unwrap();
    let m = build(&names);
    if a[1] == "encode" {
        let (mut total, mut h) = (0u64, 0u64);
        for r in 0..rounds {
            let w = m.to_vec().expect("pack");
            total += w.len() as u64;
            if r == 0 {
                h = fold(0, &w);
            }
        }
        println!(
            "mode=encode\nrrs={}\nbytes={}\nwire_hash={}",
            names.len(),
            total,
            h
        );
    } else {
        let w = m.to_vec().expect("pack");
        let mut rrs = 0u64;
        for _ in 0..rounds {
            let d = Message::from_vec(&w).expect("unpack");
            rrs += d.answers().len() as u64;
        }
        println!("mode=decode\nrrs={}\nwire={}", rrs, w.len());
    }
}
