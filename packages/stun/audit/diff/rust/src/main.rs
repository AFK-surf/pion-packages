//! Red-team differential oracle (Rust side): webrtc-rs `stun` 0.8.0.
//!
//!   oracle_rust decode <corpus.tsv>   "<label>\tD=..\tFP=..\tMI=..\tM2=na\tXA=.." (same canonical line as Pion / ref.py)
//!   oracle_rust encode <specs.tsv>    "<label>\tW=<hex>" (MI-SHA256 modes print "W=na": not supported by stun 0.8)
use std::env;
use std::fs;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use stun::attributes::{AttrType, ATTR_FINGERPRINT, ATTR_MESSAGE_INTEGRITY};
use stun::error_code::{ErrorCode, ErrorCodeAttribute};
use stun::fingerprint::FINGERPRINT;
use stun::integrity::MessageIntegrity;
use stun::message::{Getter, Message, Setter};
use stun::xoraddr::XorMappedAddress;

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap_or(0)).collect()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Lenient TLV scan (same definition as the Pion oracle / ref.py): is attribute `t` present?
fn has_attr(raw: &[u8], t: u16) -> bool {
    if raw.len() < 20 {
        return false;
    }
    let mut pos = 20;
    while pos + 4 <= raw.len() {
        let at = u16::from_be_bytes([raw[pos], raw[pos + 1]]);
        let al = u16::from_be_bytes([raw[pos + 2], raw[pos + 3]]) as usize;
        if at == t {
            return true;
        }
        pos += 4 + ((al + 3) & !3);
    }
    false
}

fn addr_str(ip: IpAddr, port: u16) -> String {
    match ip {
        IpAddr::V4(v4) => format!("{v4}:{port}"),
        IpAddr::V6(v6) => format!("[{}]:{port}", hex(&v6.octets())),
    }
}

fn decode_line(raw: &[u8], key: &[u8]) -> String {
    let mut m = Message::new();
    m.raw = raw.to_vec();
    let ok = m.decode().is_ok();
    let d = if ok {
        let types: Vec<String> = m.attributes.0.iter().take(12).map(|a| format!("{:04x}", a.typ.0)).collect();
        format!("ok:{}:{}", m.attributes.0.len(), types.join(","))
    } else {
        "err".to_string()
    };
    let fp = if !has_attr(raw, 0x8028) {
        "none"
    } else if !ok {
        "err"
    } else {
        match FINGERPRINT.check(&m) {
            Ok(()) => "true",
            Err(stun::Error::ErrFingerprintMismatch) => "false",
            Err(_) => "err",
        }
    };
    let mi = if !has_attr(raw, 0x0008) {
        "none"
    } else if !ok {
        "err"
    } else {
        let mut mm = m.clone();
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| MessageIntegrity(key.to_vec()).check(&mut mm))) {
            Ok(Ok(())) => "true",
            Ok(Err(stun::Error::ErrIntegrityMismatch)) => "false",
            Ok(Err(_)) => "err",
            Err(_) => "panic",
        }
    };
    let xa = if ok {
        let mut x = XorMappedAddress::default();
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| x.get_from(&m))) {
            Ok(Ok(())) => addr_str(x.ip, x.port),
            Ok(Err(stun::Error::ErrAttributeNotFound)) => "-".to_string(),
            Ok(Err(_)) => "err".to_string(),
            Err(_) => "panic".to_string(),
        }
    } else {
        "-".to_string()
    };
    let _ = (ATTR_FINGERPRINT, ATTR_MESSAGE_INTEGRITY);
    format!("D={d}\tFP={fp}\tMI={mi}\tM2=na\tXA={xa}")
}

fn plain_addr(v: &[u8]) -> (IpAddr, u16) {
    let port = u16::from_be_bytes([v[2], v[3]]);
    if v[1] == 1 {
        (IpAddr::V4(Ipv4Addr::new(v[4], v[5], v[6], v[7])), port)
    } else {
        let mut o = [0u8; 16];
        o.copy_from_slice(&v[4..20]);
        (IpAddr::V6(Ipv6Addr::from(o)), port)
    }
}

fn encode_line(f: &[&str]) -> String {
    let mt = u16::from_str_radix(f[1], 16).unwrap();
    let tx = unhex(f[2]);
    let key = unhex(f[3]);
    let mode = f[4];
    if mode.starts_with("s2") {
        return "W=na".to_string();
    }
    let mut m = Message::new();
    m.typ.read_value(mt);
    m.transaction_id.0.copy_from_slice(&tx);
    m.write_header();
    if f.len() > 5 && !f[5].is_empty() {
        for tok in f[5].split(';').filter(|s| !s.is_empty()) {
            let (t, v) = tok.split_once(':').unwrap();
            let t = u16::from_str_radix(t, 16).unwrap();
            let v = unhex(v);
            if t == 0x0020 {
                let (ip, port) = plain_addr(&v);
                XorMappedAddress { ip, port }.add_to(&mut m).unwrap();
            } else if t == 0x0009 {
                let code = (v[2] & 7) as u16 * 100 + v[3] as u16;
                ErrorCodeAttribute { code: ErrorCode(code), reason: v[4..].to_vec() }.add_to(&mut m).unwrap();
            } else {
                m.add(AttrType(t), &v);
            }
        }
    }
    if mode == "s1" || mode == "s1f" {
        MessageIntegrity(key).add_to(&mut m).unwrap();
    }
    if mode == "f" || mode == "s1f" {
        FINGERPRINT.add_to(&mut m).unwrap();
    }
    format!("W={}", hex(&m.raw))
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: oracle_rust decode|encode <tsv>");
        std::process::exit(2);
    }
    let text = fs::read_to_string(&args[2]).expect("read");
    let mut out = String::new();
    for line in text.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        let res = match args[1].as_str() {
            "decode" => decode_line(&unhex(f[1]), &unhex(f.get(2).copied().unwrap_or(""))),
            "encode" => encode_line(&f),
            _ => std::process::exit(2),
        };
        out.push_str(f[0]);
        out.push('\t');
        out.push_str(&res);
        out.push('\n');
    }
    print!("{out}");
}
