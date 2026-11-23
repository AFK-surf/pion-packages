//! Red-team differential oracle for packages/asn1 (Rust side).
//!
//!   oracle_rust vectors <corpus.tsv>
//!   oracle_rust certs <file.derbin> <iters>
//!
//! Typed DER values: RustCrypto `der` 0.7 (strict DER). Certificates: `x509-parser` 0.16.
//! Hostnames: `rustls-webpki` 0.103 (the verifier rustls uses). SPKI / PKCS#8: `spki` 0.7 /
//! `pkcs8` 0.10 (structural, der-based). PEM: `pem` 3.0.

use der::asn1::{
    BitStringRef, BmpString, GeneralizedTime, Ia5StringRef, Null, ObjectIdentifier, OctetStringRef,
    PrintableStringRef, UtcTime, Utf8StringRef,
};
use der::{Decode, Header, Reader, SliceReader};
use std::io::{BufRead, Write};

fn hexs(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02x}", x)).collect()
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap_or(0)).collect()
}

fn typed(kind: &str, b: &[u8]) -> String {
    let r: Option<String> = match kind {
        "bool" => bool::from_der(b).ok().map(|v| v.to_string()),
        "int64" => i64::from_der(b).ok().map(|v| v.to_string()),
        "uint64" => u64::from_der(b).ok().map(|v| v.to_string()),
        "bits" => BitStringRef::from_der(b).ok().map(|v| format!("{}:{}", v.unused_bits(), hexs(v.raw_bytes()))),
        "octet" => OctetStringRef::from_der(b).ok().map(|v| hexs(v.as_bytes())),
        "null" => Null::from_der(b).ok().map(|_| "null".to_string()),
        "oid" => ObjectIdentifier::from_der(b).ok().map(|v| v.to_string()),
        "utf8" => Utf8StringRef::from_der(b).ok().map(|v| hexs(v.as_bytes())),
        "printable" => PrintableStringRef::from_der(b).ok().map(|v| hexs(v.as_bytes())),
        "ia5" => Ia5StringRef::from_der(b).ok().map(|v| hexs(v.as_bytes())),
        "bmp" => BmpString::from_der(b).ok().map(|v| hexs(v.to_string().as_bytes())),
        "utc" => UtcTime::from_der(b).ok().map(|v| v.to_unix_duration().as_secs().to_string()),
        "gen" => GeneralizedTime::from_der(b).ok().map(|v| v.to_unix_duration().as_secs().to_string()),
        _ => return "UNKNOWN_KIND".into(),
    };
    match r {
        Some(s) => format!("OK:{}", s),
        None => "ERR".into(),
    }
}

/// Recursive strict-DER walk with der's Header decoder (depth capped at 64 like Pion's default).
fn tree(b: &[u8], depth: usize) -> Option<usize> {
    if depth > 64 {
        return None;
    }
    let mut r = SliceReader::new(b).ok()?;
    let mut n = 0;
    while !r.is_finished() {
        let h = Header::decode(&mut r).ok()?;
        let len: usize = h.length.try_into().ok()?;
        let content = r.read_slice(h.length).ok()?;
        debug_assert_eq!(content.len(), len);
        n += 1;
        if h.tag.is_constructed() {
            n += tree(content, depth + 1)?;
        }
    }
    Some(n)
}

fn x509sum(c: &x509_parser::certificate::X509Certificate) -> String {
    use x509_parser::extensions::GeneralName;
    let san = match c.subject_alternative_name() {
        Ok(Some(s)) => s
            .value
            .general_names
            .iter()
            .filter(|g| matches!(g, GeneralName::DNSName(_) | GeneralName::IPAddress(_) | GeneralName::RFC822Name(_) | GeneralName::URI(_)))
            .count(),
        _ => 0,
    };
    format!(
        "OK:v={}:tbs={}:nb={}:na={}:ext={}:san={}",
        c.version().0 + 1,
        c.tbs_certificate.as_ref().len(),
        c.validity().not_before.timestamp(),
        c.validity().not_after.timestamp(),
        c.extensions().len(),
        san
    )
}

fn parse_cert(a: &[u8]) -> Option<x509_parser::certificate::X509Certificate<'_>> {
    parse_cert_err(a).ok()
}

fn parse_cert_err(a: &[u8]) -> Result<x509_parser::certificate::X509Certificate<'_>, String> {
    match x509_parser::parse_x509_certificate(a) {
        Ok((rest, c)) if rest.is_empty() => Ok(c),
        Ok((rest, _)) => Err(format!("{} trailing bytes", rest.len())),
        Err(e) => Err(format!("{:?}", e)),
    }
}

fn run(kind: &str, a: &[u8], b: &[u8]) -> String {
    match kind {
        "tree" => {
            let mut r = match SliceReader::new(a) {
                Ok(r) => r,
                Err(_) => return "ERR".into(),
            };
            match Header::decode(&mut r) {
                Ok(h) => {
                    if r.read_slice(h.length).is_err() || !r.is_finished() {
                        return "ERR".into();
                    }
                }
                Err(_) => return "ERR".into(),
            }
            match tree(a, 1) {
                Some(n) => format!("OK:{}", n),
                None => "ERR".into(),
            }
        }
        "x509" => match parse_cert_err(a) {
            Ok(c) => x509sum(&c),
            Err(e) => format!("ERR:{}", e),
        },
        "host" => {
            if parse_cert(a).is_none() {
                return "ERR".into();
            }
            let der = rustls_pki_types::CertificateDer::from(a);
            let ee = match webpki::EndEntityCert::try_from(&der) {
                Ok(e) => e,
                Err(_) => return "WPKI_PARSE_ERR".into(),
            };
            let host = match std::str::from_utf8(b) {
                Ok(h) => h,
                Err(_) => return "OK:false".into(),
            };
            match rustls_pki_types::ServerName::try_from(host) {
                Ok(sn) => format!("OK:{}", ee.verify_is_valid_for_subject_name(&sn).is_ok()),
                Err(_) => "OK:false".into(),
            }
        }
        "spki" => match spki::SubjectPublicKeyInfoRef::from_der(a) {
            Ok(_) => "OK".into(),
            Err(e) => format!("ERR:{}", e),
        },
        "pkcs8" => match pkcs8::PrivateKeyInfo::from_der(a) {
            Ok(_) => "OK".into(),
            Err(e) => format!("ERR:{}", e),
        },
        "pem" => match pem::parse(a) {
            Ok(p) => format!("OK:{}:{}", p.tag(), hexs(p.contents())),
            Err(_) => "ERR".into(),
        },
        _ => typed(kind, a),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() > 2 && args[1] == "vectors" {
        let f = std::io::BufReader::new(std::fs::File::open(&args[2]).expect("open corpus"));
        let out = std::io::stdout();
        let mut w = std::io::BufWriter::new(out.lock());
        for line in f.lines() {
            let line = line.expect("line");
            let p: Vec<&str> = line.split('\t').collect();
            let a = unhex(p[2]);
            let b = if p.len() > 3 { unhex(p[3]) } else { vec![] };
            writeln!(w, "{}\t{}", p[0], run(p[1], &a, &b)).unwrap();
        }
        return;
    }
    if args.len() > 3 && args[1] == "certs" {
        let raw = std::fs::read(&args[2]).expect("read derbin");
        let iters: usize = args[3].parse().unwrap();
        let mut ders = vec![];
        let mut p = 0;
        while p + 4 <= raw.len() {
            let l = u32::from_be_bytes([raw[p], raw[p + 1], raw[p + 2], raw[p + 3]]) as usize;
            ders.push(&raw[p + 4..p + 4 + l]);
            p += 4 + l;
        }
        let (mut ok, mut sum) = (0usize, 0usize);
        for _ in 0..iters {
            for d in &ders {
                if let Some(c) = parse_cert(d) {
                    ok += 1;
                    sum += c.tbs_certificate.as_ref().len() + c.extensions().len();
                }
            }
        }
        println!("ok={} sum={}", ok, sum);
        return;
    }
    eprintln!("usage: oracle_rust vectors <corpus.tsv> | certs <file.derbin> <iters>");
    std::process::exit(2);
}
