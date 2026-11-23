//! Differential driver: Rust + hickory-proto =0.24.2 (default-features = false,
//! same feature set as packages/dns/bench/rust).
//! Usage: rust_driver <msg|name|ip6> <cases.tsv>   (line: <id>\t<hex>)
//! Output format mirrors ../pion_driver/src/main.pion exactly.
use hickory_proto::op::Message;
use hickory_proto::rr::{Name, RData, Record};
use hickory_proto::serialize::binary::BinEncodable;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::str::FromStr;

fn hex(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push_str(&format!("{:02x}", x));
    }
    s
}

fn unhex(s: &str) -> Vec<u8> {
    let b = s.as_bytes();
    let v = |c: u8| -> u8 {
        match c {
            b'0'..=b'9' => c - b'0',
            b'a'..=b'f' => c - b'a' + 10,
            b'A'..=b'F' => c - b'A' + 10,
            _ => 0,
        }
    };
    (0..b.len() / 2)
        .map(|i| (v(b[2 * i]) << 4) | v(b[2 * i + 1]))
        .collect()
}

fn name_key(n: &Name) -> String {
    match n.to_lowercase().to_bytes() {
        Ok(b) => hex(&b),
        Err(_) => "PACKERR".to_string(),
    }
}

fn rr_key(s: &mut String, r: &Record) {
    s.push_str(&format!(
        " {}/{}/{}/{}",
        name_key(r.name()),
        u16::from(r.record_type()),
        u16::from(r.dns_class()),
        r.ttl()
    ));
    match r.data() {
        Some(RData::A(a)) => s.push_str(&format!("/{}", hex(&a.0.octets()))),
        Some(RData::AAAA(a)) => s.push_str(&format!("/{}", hex(&a.0.octets()))),
        Some(RData::CNAME(n)) => s.push_str(&format!("/{}", name_key(&n.0))),
        Some(RData::NS(n)) => s.push_str(&format!("/{}", name_key(&n.0))),
        Some(RData::PTR(n)) => s.push_str(&format!("/{}", name_key(&n.0))),
        Some(RData::MX(mx)) => {
            s.push_str(&format!("/{},{}", mx.preference(), name_key(mx.exchange())))
        }
        _ => {}
    }
}

fn msg_verdict(b: &[u8]) -> String {
    let m = match Message::from_vec(b) {
        Ok(m) => m,
        Err(e) => return format!("ERR {}", e).replace(['\t', '\n'], " "),
    };
    let opt = if m.extensions().is_some() { 1 } else { 0 };
    let mut s = format!(
        "OK qd={} an={} ns={} ar={} opt={}",
        m.queries().len(),
        m.answers().len(),
        m.name_servers().len(),
        m.additionals().len(),
        opt
    );
    for q in m.queries() {
        s.push_str(&format!(
            " q:{}/{}/{}",
            name_key(q.name()),
            u16::from(q.query_type()),
            u16::from(q.query_class())
        ));
    }
    for r in m.answers() {
        rr_key(&mut s, r);
    }
    for r in m.name_servers() {
        rr_key(&mut s, r);
    }
    for r in m.additionals() {
        rr_key(&mut s, r);
    }
    s.push('\t');
    match m.to_vec() {
        Err(_) => s.push_str("enc=ERR"),
        Ok(w) => {
            s.push_str(&format!("enc={}", w.len()));
            s.push_str(if Message::from_vec(&w).is_ok() {
                " rt=ok"
            } else {
                " rt=ERR"
            });
        }
    }
    s
}

fn name_verdict(b: &[u8]) -> String {
    let st = match std::str::from_utf8(b) {
        Ok(s) => s,
        Err(_) => return "ERR".to_string(),
    };
    match Name::from_ascii(st) {
        Ok(n) => match n.to_bytes() {
            Ok(w) => format!("OK {} {}", hex(&w), n.to_ascii()),
            Err(_) => "ERR".to_string(),
        },
        Err(_) => "ERR".to_string(),
    }
}

fn ip6_verdict(b: &[u8]) -> String {
    match std::str::from_utf8(b)
        .ok()
        .and_then(|s| std::net::Ipv6Addr::from_str(s).ok())
    {
        Some(a) => format!("OK {}", a),
        None => "ERR".to_string(),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: rust_driver <msg|name|ip6> <cases.tsv>");
        std::process::exit(2);
    }
    let f = std::fs::File::open(&args[2]).expect("open cases");
    let out = std::io::stdout();
    let mut out = BufWriter::new(out.lock());
    for line in BufReader::new(f).lines() {
        let line = line.expect("line");
        let Some(tab) = line.find('\t') else { continue };
        let id = &line[..tab];
        let payload = unhex(&line[tab + 1..]);
        // hickory may panic on some inputs; a panic is itself a finding, so
        // catch it per case and report PANIC instead of aborting the run.
        let mode = args[1].clone();
        let v = std::panic::catch_unwind(move || match mode.as_str() {
            "msg" => msg_verdict(&payload),
            "name" => name_verdict(&payload),
            "ip6" => ip6_verdict(&payload),
            _ => "UNSUPPORTED".to_string(),
        })
        .unwrap_or_else(|_| "PANIC".to_string());
        writeln!(out, "{}\t{}", id, v).unwrap();
    }
}
