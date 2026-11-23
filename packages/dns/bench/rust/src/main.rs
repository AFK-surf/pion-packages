use hickory_proto::op::{Message, MessageType, OpCode, Query};
use hickory_proto::rr::{Name, RData, Record, RecordType};
use hickory_proto::serialize::binary::{BinDecodable, BinEncodable, BinEncoder, EncodeMode};
use std::env;
use std::fs;
use std::str::FromStr;

#[inline]
fn mix(h: i64, v: i64) -> i64 {
    (h * 131 + v) % 1_000_000_007
}

fn hash_rr(mut h: i64, rr: &Record) -> i64 {
    let rtype = u16::from(rr.record_type()) as i64;
    h = mix(h, rtype);
    h = mix(h, rr.ttl() as i64);
    if let Some(rdata) = rr.data() {
        match rdata {
            RData::A(a) => {
                let oct = a.0.octets();
                h = mix(h, oct[0] as i64);
                h = mix(h, oct[1] as i64);
                h = mix(h, oct[2] as i64);
                h = mix(h, oct[3] as i64);
            }
            RData::AAAA(aaaa) => {
                let seg = aaaa.0.segments();
                h = mix(h, seg[0] as i64);
                h = mix(h, seg[7] as i64);
            }
            RData::CNAME(c) => h = mix(h, c.0.num_labels() as i64),
            RData::NS(ns) => h = mix(h, ns.0.num_labels() as i64),
            RData::PTR(p) => h = mix(h, p.0.num_labels() as i64),
            RData::MX(mx) => {
                h = mix(h, mx.preference() as i64);
                h = mix(h, mx.exchange().num_labels() as i64);
            }
            RData::TXT(txt) => {
                let tlen: usize = txt.txt_data().iter().map(|b| b.len()).sum();
                h = mix(h, tlen as i64);
            }
            RData::SOA(soa) => {
                h = mix(h, soa.serial() as i64);
                h = mix(h, soa.minimum() as i64);
            }
            RData::SRV(srv) => {
                h = mix(h, srv.priority() as i64);
                h = mix(h, srv.weight() as i64);
                h = mix(h, srv.port() as i64);
            }
            _ => {}
        }
    }
    h
}

fn hash_msg(mut h: i64, m: &Message) -> i64 {
    h = mix(h, m.id() as i64);
    h = mix(h, u16::from(m.response_code()) as i64);
    for q in m.queries() {
        h = mix(h, u16::from(q.query_type()) as i64);
    }
    for rr in m.answers() {
        h = hash_rr(h, rr);
    }
    for rr in m.name_servers() {
        h = hash_rr(h, rr);
    }
    for rr in m.additionals() {
        h = hash_rr(h, rr);
    }
    // hickory-proto separates OPT into `extensions()` instead of `additionals()`
    if let Some(edns) = m.extensions() {
        h = mix(h, 41); // TYPE OPT
        let ttl_u32: u32 = ((u32::from(edns.version()) & 0xFF) << 16)
            | if edns.dnssec_ok() { 0x8000 } else { 0 };
        h = mix(h, ttl_u32 as i64);
        h = mix(h, edns.max_payload() as i64);
    }
    h
}

fn count_rrs(m: &Message) -> i64 {
    let opt = if m.extensions().is_some() { 1 } else { 0 };
    (m.answers().len() + m.name_servers().len() + m.additionals().len() + opt) as i64
}

fn bench_decode(data: &[u8]) {
    let mut packets: i64 = 0;
    let mut total_rrs: i64 = 0;
    let mut checksum: i64 = 0;
    let dlen = data.len();
    for _ in 0..200 {
        let mut pos = 0;
        while pos + 2 <= dlen {
            let plen = u16::from_be_bytes([data[pos], data[pos + 1]]) as usize;
            let pstart = pos + 2;
            let pend = pstart + plen;
            let m = Message::from_bytes(&data[pstart..pend]).expect("decode failed");
            packets += 1;
            total_rrs += count_rrs(&m);
            checksum = hash_msg(checksum, &m);
            pos = pend;
        }
    }
    println!(
        "mode=decode\npackets={}\nrrs={}\nchecksum={}",
        packets, total_rrs, checksum
    );
}

fn bench_encode(data: &[u8]) {
    let mut msgs = Vec::with_capacity(1000);
    let dlen = data.len();
    let mut pos = 0;
    while pos + 2 <= dlen {
        let plen = u16::from_be_bytes([data[pos], data[pos + 1]]) as usize;
        let pstart = pos + 2;
        let pend = pstart + plen;
        let m = Message::from_bytes(&data[pstart..pend]).expect("preload failed");
        msgs.push(m);
        pos = pend;
    }
    let mut encoded: i64 = 0;
    let mut hdr_hash: i64 = 0;
    let mut rt_hash: i64 = 0;
    let mut buf = Vec::with_capacity(512);
    for round in 0..200 {
        for m in &msgs {
            buf.clear();
            {
                let mut enc = BinEncoder::with_mode(&mut buf, EncodeMode::Normal);
                m.emit(&mut enc).expect("emit failed");
            }
            encoded += 1;
            for &b in &buf[0..12] {
                hdr_hash = mix(hdr_hash, b as i64);
            }
            if round == 0 {
                let rt = Message::from_bytes(&buf).expect("rt decode failed");
                rt_hash = hash_msg(rt_hash, &rt);
            }
        }
    }
    println!(
        "mode=encode\nencoded={}\nhdr_hash={}\nrt_hash={}",
        encoded, hdr_hash, rt_hash
    );
}

fn bench_query_rt() {
    let names: Vec<Name> = (0..100)
        .map(|i| Name::from_str(&format!("host{}.api.example.com.", i)).unwrap())
        .collect();
    let qtypes = [
        RecordType::A,
        RecordType::AAAA,
        RecordType::MX,
        RecordType::TXT,
    ];
    let mut ops: i64 = 0;
    let mut total_bytes: i64 = 0;
    let mut checksum: i64 = 0;
    let mut buf = Vec::with_capacity(128);
    for i in 0..500_000usize {
        let mut m = Message::new();
        m.set_id((i & 0xFFFF) as u16)
            .set_message_type(MessageType::Query)
            .set_op_code(OpCode::Query)
            .set_recursion_desired(true)
            .add_query(Query::query(names[i % 100].clone(), qtypes[i & 3]));
        buf.clear();
        {
            let mut enc = BinEncoder::with_mode(&mut buf, EncodeMode::Normal);
            m.emit(&mut enc).expect("emit query failed");
        }
        total_bytes += buf.len() as i64;
        let dec = Message::from_bytes(&buf).expect("decode query failed");
        ops += 1;
        checksum = mix(checksum, dec.id() as i64);
        checksum = mix(checksum, u16::from(dec.queries()[0].query_type()) as i64);
        checksum = mix(checksum, buf.len() as i64);
    }
    println!(
        "mode=query_rt\nops={}\nbytes={}\nchecksum={}",
        ops, total_bytes, checksum
    );
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        std::process::exit(1);
    }
    match args[1].as_str() {
        "query_rt" => bench_query_rt(),
        "decode" => {
            let data = fs::read(&args[2]).expect("read corpus");
            bench_decode(&data);
        }
        "encode" => {
            let data = fs::read(&args[2]).expect("read corpus");
            bench_encode(&data);
        }
        _ => std::process::exit(1),
    }
}
