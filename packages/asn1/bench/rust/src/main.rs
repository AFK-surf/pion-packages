use der::asn1::{ObjectIdentifier, OctetStringRef, Utf8StringRef};
use der::{Decode, Encode, Reader, SliceReader};
use std::env;
use std::fs;
use std::process;
use x509_parser::extensions::GeneralName;
use x509_parser::prelude::*;

fn run_pem_chain(path: &str) {
    let raw = fs::read(path).expect("read pem corpus");
    let mut total_certs: usize = 0;
    let mut cn_bytes: i64 = 0;
    let mut san_count: i64 = 0;
    let mut ca_count: usize = 0;
    let mut spki_bytes: i64 = 0;
    let mut sig_bytes: i64 = 0;
    let mut time_sum: i64 = 0;

    for _ in 0..100 {
        let blocks = ::pem::parse_many(&raw).expect("pem parse_many");
        for block in blocks {
            if block.tag() != "CERTIFICATE" {
                continue;
            }
            let (_, cert) = X509Certificate::from_der(block.contents()).expect("x509 parse");
            total_certs += 1;
            if let Some(cn) = cert.subject().iter_common_name().next() {
                if let Ok(s) = cn.as_str() {
                    cn_bytes += s.len() as i64;
                }
            }
            if let Ok(Some(san)) = cert.subject_alternative_name() {
                san_count += san.value.general_names.len() as i64;
            }
            if cert.is_ca() {
                ca_count += 1;
            }
            spki_bytes += cert.public_key().raw.len() as i64;
            sig_bytes += cert.signature_value.data.len() as i64;
            time_sum += cert.validity().not_before.timestamp() + cert.validity().not_after.timestamp();
        }
    }

    println!("certs={}", total_certs);
    println!("cn_bytes={}", cn_bytes);
    println!("san_count={}", san_count);
    println!("ca_count={}", ca_count);
    println!("spki_bytes={}", spki_bytes);
    println!("sig_bytes={}", sig_bytes);
    println!("time_sum={}", time_sum);
}

fn match_dns_pattern(pattern: &str, host: &str) -> bool {
    let p = pattern.trim_end_matches('.');
    let h = host.trim_end_matches('.');
    if p.is_empty() || h.is_empty() {
        return false;
    }
    if let Some(suffix) = p.strip_prefix("*.") {
        if !suffix.contains('.') {
            return false;
        }
        if let Some(dot) = h.find('.') {
            if dot == 0 {
                return false;
            }
            return h[dot + 1..].eq_ignore_ascii_case(suffix);
        }
        false
    } else if p.contains('*') {
        false
    } else {
        p.eq_ignore_ascii_case(h)
    }
}

fn verify_host(cert: &X509Certificate, host: &str) -> bool {
    if let Ok(Some(san)) = cert.subject_alternative_name() {
        for gn in &san.value.general_names {
            if let GeneralName::DNSName(dns) = gn {
                if match_dns_pattern(dns, host) {
                    return true;
                }
            }
        }
    }
    false
}

fn run_der_x509_host(path: &str) {
    let raw = fs::read(path).expect("read derbin corpus");
    let mut ders: Vec<&[u8]> = Vec::new();
    let mut pos = 0;
    while pos + 4 <= raw.len() {
        let clen = u32::from_be_bytes([raw[pos], raw[pos + 1], raw[pos + 2], raw[pos + 3]]) as usize;
        pos += 4;
        ders.push(&raw[pos..pos + clen]);
        pos += clen;
    }
    let exact_hosts: Vec<String> = (0..ders.len())
        .map(|i| format!("svc-{:03}.pion.dev", i))
        .collect();
    let wild_hosts: Vec<String> = (0..ders.len())
        .map(|i| format!("api.t{:03}.pion.dev", i))
        .collect();

    let mut total_certs: usize = 0;
    let mut host_ok: usize = 0;
    let mut host_fail: usize = 0;
    let mut tbs_bytes: i64 = 0;
    let mut time_sum: i64 = 0;

    for _ in 0..500 {
        for (i, der) in ders.iter().enumerate() {
            let (_, cert) = X509Certificate::from_der(der).expect("x509 parse");
            total_certs += 1;
            tbs_bytes += cert.tbs_certificate.as_ref().len() as i64;
            time_sum += cert.validity().not_before.timestamp();
            if verify_host(&cert, &exact_hosts[i]) {
                host_ok += 1;
            } else {
                host_fail += 1;
            }
            if verify_host(&cert, &wild_hosts[i]) {
                host_ok += 1;
            } else {
                host_fail += 1;
            }
            if verify_host(&cert, "nope.other.invalid") {
                host_ok += 1;
            } else {
                host_fail += 1;
            }
        }
    }

    println!("certs={}", total_certs);
    println!("host_ok={}", host_ok);
    println!("host_fail={}", host_fail);
    println!("tbs_bytes={}", tbs_bytes);
    println!("time_sum={}", time_sum);
}

fn run_der_tlv_roundtrip() {
    let payloads: Vec<[u8; 24]> = (0..100)
        .map(|i| {
            let mut p = [0u8; 24];
            for k in 0..24 {
                p[k] = ((i + k * 7) & 0xFF) as u8;
            }
            p
        })
        .collect();
    let labels: Vec<String> = (0..100).map(|i| format!("asn1-record-{}", i)).collect();
    let oid = ObjectIdentifier::new_unwrap("1.2.840.113549.1.1.11");

    let mut ops: usize = 0;
    let mut encoded_bytes: i64 = 0;
    let mut int_sum: i64 = 0;
    let mut bool_true: usize = 0;
    let mut payload_sum: i64 = 0;
    let mut str_bytes: i64 = 0;

    let mut sub_buf = Vec::with_capacity(32);
    let mut inner_buf = Vec::with_capacity(128);
    let mut out_buf = Vec::with_capacity(128);

    for _ in 0..1000 {
        for i in 0..100usize {
            sub_buf.clear();
            inner_buf.clear();
            out_buf.clear();

            let a_in: i64 = (i as i64) * 3;
            let b_in: i64 = -((i as i64) * 5) - 1;
            let c_in: i64 = (i as i64) * 17 + 128;
            a_in.encode_to_vec(&mut sub_buf).unwrap();
            b_in.encode_to_vec(&mut sub_buf).unwrap();
            c_in.encode_to_vec(&mut sub_buf).unwrap();

            let id_in: i64 = (i as i64) * 100003 + 7;
            let active_in: bool = (i & 1) == 0;
            id_in.encode_to_vec(&mut inner_buf).unwrap();
            active_in.encode_to_vec(&mut inner_buf).unwrap();
            OctetStringRef::new(&payloads[i]).unwrap().encode_to_vec(&mut inner_buf).unwrap();
            oid.encode_to_vec(&mut inner_buf).unwrap();
            Utf8StringRef::new(&labels[i]).unwrap().encode_to_vec(&mut inner_buf).unwrap();
            let sub_hdr = der::Header::new(der::Tag::Sequence, der::Length::try_from(sub_buf.len()).unwrap()).unwrap();
            sub_hdr.encode_to_vec(&mut inner_buf).unwrap();
            inner_buf.extend_from_slice(&sub_buf);

            let out_hdr = der::Header::new(der::Tag::Sequence, der::Length::try_from(inner_buf.len()).unwrap()).unwrap();
            out_hdr.encode_to_vec(&mut out_buf).unwrap();
            out_buf.extend_from_slice(&inner_buf);

            encoded_bytes += out_buf.len() as i64;

            // Decode back strictly
            let mut reader = SliceReader::new(&out_buf).unwrap();
            reader
                .sequence(|seq| {
                    let id = i64::decode(seq)?;
                    let active = bool::decode(seq)?;
                    let os = OctetStringRef::decode(seq)?;
                    let _o = ObjectIdentifier::decode(seq)?;
                    let lbl = Utf8StringRef::decode(seq)?;
                    let (a, b, c) = seq.sequence(|sub| {
                        Ok((i64::decode(sub)?, i64::decode(sub)?, i64::decode(sub)?))
                    })?;
                    int_sum += id + a + b + c;
                    if active {
                        bool_true += 1;
                    }
                    for &byte in os.as_bytes() {
                        payload_sum += byte as i64;
                    }
                    str_bytes += lbl.as_str().len() as i64;
                    Ok(())
                })
                .unwrap();
            ops += 1;
        }
    }

    println!("ops={}", ops);
    println!("encoded_bytes={}", encoded_bytes);
    println!("int_sum={}", int_sum);
    println!("bool_true={}", bool_true);
    println!("payload_sum={}", payload_sum);
    println!("str_bytes={}", str_bytes);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: rust_bench <pem_chain|der_x509_host|der_tlv_roundtrip> [corpus]");
        process::exit(1);
    }
    match args[1].as_str() {
        "pem_chain" => run_pem_chain(&args[2]),
        "der_x509_host" => run_der_x509_host(&args[2]),
        "der_tlv_roundtrip" => run_der_tlv_roundtrip(),
        other => {
            eprintln!("unknown cmd: {}", other);
            process::exit(1);
        }
    }
}
