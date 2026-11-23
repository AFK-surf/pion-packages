use sha2::{Digest, Sha256};
use std::env;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use stun::agent::TransactionId;
use stun::attributes::{ATTR_ICE_CONTROLLING, ATTR_PRIORITY, ATTR_USE_CANDIDATE};
use stun::fingerprint::FINGERPRINT;
use stun::integrity::MessageIntegrity;
use stun::message::{
    Getter, Message, Setter, BINDING_REQUEST, BINDING_SUCCESS,
};
use stun::textattrs::Username;
use stun::xoraddr::XorMappedAddress;

fn make_tx_id(i: usize) -> TransactionId {
    let v = i as u32;
    let mut b = [0u8; 12];
    b[0] = 0xA5;
    b[1] = 0x5A;
    b[2] = 0x12;
    b[3] = 0x34;
    b[4] = ((v >> 24) & 0xFF) as u8;
    b[5] = ((v >> 16) & 0xFF) as u8;
    b[6] = ((v >> 8) & 0xFF) as u8;
    b[7] = (v & 0xFF) as u8;
    b[8] = 0xFE;
    b[9] = 0xED;
    b[10] = 0xFA;
    b[11] = 0xCE;
    TransactionId(b)
}

fn make_ipv6(i: usize) -> Ipv6Addr {
    let b = [
        0x20,
        0x01,
        0x0d,
        0xb8,
        0x12,
        0x34,
        0x56,
        0x78,
        0x00,
        0x11,
        0x22,
        0x33,
        ((i >> 24) & 0xFF) as u8,
        ((i >> 16) & 0xFF) as u8,
        ((i >> 8) & 0xFF) as u8,
        (i & 0xFF) as u8,
    ];
    Ipv6Addr::from(b)
}

struct RawPriority(u32);
impl Setter for RawPriority {
    fn add_to(&self, m: &mut Message) -> std::result::Result<(), stun::Error> {
        m.add(ATTR_PRIORITY, &self.0.to_be_bytes());
        Ok(())
    }
}

struct RawIceControlling(u64);
impl Setter for RawIceControlling {
    fn add_to(&self, m: &mut Message) -> std::result::Result<(), stun::Error> {
        m.add(ATTR_ICE_CONTROLLING, &self.0.to_be_bytes());
        Ok(())
    }
}

struct RawUseCandidate;
impl Setter for RawUseCandidate {
    fn add_to(&self, m: &mut Message) -> std::result::Result<(), stun::Error> {
        m.add(ATTR_USE_CANDIDATE, &[]);
        Ok(())
    }
}

fn build_packet(i: usize, key: &str) -> Vec<u8> {
    let kind = i % 3;
    let tx = make_tx_id(i);
    let mut msg = Message::new();
    let mi = MessageIntegrity::new_short_term_integrity(key.to_string());
    if kind == 0 {
        let prio: u32 = 2130706431u32 - (i & 0xFFFF) as u32;
        let tb: u64 = 0x1122334455667788u64 + i as u64;
        msg.build(&[
            Box::new(tx),
            Box::new(BINDING_REQUEST),
            Box::new(Username::new(
                stun::attributes::ATTR_USERNAME,
                "rUfrag99:lUfrag42".to_string(),
            )),
            Box::new(RawPriority(prio)),
            Box::new(RawIceControlling(tb)),
            Box::new(RawUseCandidate),
            Box::new(mi),
            Box::new(FINGERPRINT),
        ])
        .unwrap();
    } else if kind == 1 {
        let addr = XorMappedAddress {
            ip: IpAddr::V4(Ipv4Addr::new(192, 0, 2, (i & 0xFF) as u8)),
            port: (10000 + (i & 0x7FFF)) as u16,
        };
        msg.build(&[
            Box::new(tx),
            Box::new(BINDING_SUCCESS),
            Box::new(addr),
            Box::new(mi),
            Box::new(FINGERPRINT),
        ])
        .unwrap();
    } else {
        let addr = XorMappedAddress {
            ip: IpAddr::V6(make_ipv6(i)),
            port: (20000 + (i & 0x7FFF)) as u16,
        };
        msg.build(&[
            Box::new(tx),
            Box::new(BINDING_SUCCESS),
            Box::new(addr),
            Box::new(mi),
            Box::new(FINGERPRINT),
        ])
        .unwrap();
    }
    msg.raw
}

fn bench_encode_sign(count: usize) {
    let key = "VOkJxbRl1RmTxUk/WvJxBt";
    let mut hasher = Sha256::new();
    let mut total_bytes: i64 = 0;
    for i in 0..count {
        let raw = build_packet(i, key);
        total_bytes += raw.len() as i64;
        hasher.update(&raw);
    }
    let digest = hasher.finalize();
    let mut hex = String::with_capacity(64);
    for b in digest {
        use std::fmt::Write;
        let _ = write!(&mut hex, "{:02x}", b);
    }
    println!("mode=encode_sign");
    println!("count={}", count);
    println!("bytes={}", total_bytes);
    println!("sha256={}", hex);
}

fn bench_decode_verify(count: usize) {
    let key = "VOkJxbRl1RmTxUk/WvJxBt";
    let mi = MessageIntegrity::new_short_term_integrity(key.to_string());
    let mut corpus: Vec<Vec<u8>> = Vec::with_capacity(300);
    for k in 0..300 {
        corpus.push(build_packet(k, key));
    }

    let mut total_bytes: i64 = 0;
    let mut checksum: i64 = 0;
    let mut msg = Message::new();
    for i in 0..count {
        let pkt = &corpus[i % 300];
        total_bytes += pkt.len() as i64;
        msg.raw.clear();
        msg.raw.extend_from_slice(pkt);
        msg.decode().unwrap();
        FINGERPRINT.check(&mut msg).unwrap();
        mi.check(&mut msg).unwrap();

        checksum = (checksum * 131 + msg.attributes.0.len() as i64) % 1000000007;
        for attr in &msg.attributes.0 {
            if attr.typ == ATTR_PRIORITY {
                let p = u32::from_be_bytes([
                    attr.value[0],
                    attr.value[1],
                    attr.value[2],
                    attr.value[3],
                ]);
                checksum = (checksum * 131 + p as i64) % 1000000007;
            } else if attr.typ == stun::attributes::ATTR_XORMAPPED_ADDRESS {
                let mut xma = XorMappedAddress::default();
                xma.get_from(&msg).unwrap();
                match xma.ip {
                    IpAddr::V4(v4) => {
                        let ip = u32::from(v4) as i64;
                        checksum = (checksum * 131 + ip + xma.port as i64) % 1000000007;
                    }
                    IpAddr::V6(v6) => {
                        let oct = v6.octets();
                        checksum =
                            (checksum * 131 + oct[15] as i64 + xma.port as i64) % 1000000007;
                    }
                }
            }
        }
    }
    println!("mode=decode_verify");
    println!("count={}", count);
    println!("bytes={}", total_bytes);
    println!("checksum={}", checksum);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: stun-bench-rust <encode_sign|decode_verify>");
        std::process::exit(1);
    }
    let count = 100_000usize;
    match args[1].as_str() {
        "encode_sign" => bench_encode_sign(count),
        "decode_verify" => bench_decode_verify(count),
        other => {
            eprintln!("unknown mode: {}", other);
            std::process::exit(1);
        }
    }
}
