use sdp::SessionDescription;
use sha2::{Digest, Sha256};
use std::env;
use std::fs;
use std::io::Cursor;

fn sha256_hex(data: &[u8]) -> String {
    let digest = Sha256::digest(data);
    let mut out = String::with_capacity(64);
    for b in digest {
        use std::fmt::Write;
        let _ = write!(&mut out, "{:02x}", b);
    }
    out
}

fn canonical_summary(desc: &SessionDescription) -> String {
    let mut s = String::new();
    use std::fmt::Write;
    let _ = write!(
        &mut s,
        "v={}|o={} {} {} {} {} {}|s={}|t={}|sa={}|m={}",
        desc.version,
        desc.origin.username,
        desc.origin.session_id,
        desc.origin.session_version,
        desc.origin.network_type,
        desc.origin.address_type,
        desc.origin.unicast_address,
        desc.session_name,
        desc.time_descriptions.len(),
        desc.attributes.len(),
        desc.media_descriptions.len(),
    );
    for m in &desc.media_descriptions {
        let _ = write!(
            &mut s,
            "|[ {}:{}:{}:fmts={}:attrs={}]",
            m.media_name.media,
            m.media_name.port.value,
            m.media_name.protos.join("/"),
            m.media_name.formats.len(),
            m.attributes.len(),
        );
    }
    s.replace("|[ ", "|[")
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: sdp-bench-rust <parse|roundtrip> <sdp_file> <iters>");
        std::process::exit(1);
    }
    let mode = &args[1];
    let path = &args[2];
    let iters: usize = args[3].parse().expect("invalid iters");
    let raw = fs::read(path).expect("failed to read sdp file");

    let mut last_desc: Option<SessionDescription> = None;
    let mut last_ser = String::new();

    for _ in 0..iters {
        let mut cursor = Cursor::new(raw.as_slice());
        let desc = SessionDescription::unmarshal(&mut cursor).expect("sdp unmarshal failed");
        if mode == "roundtrip" {
            last_ser = desc.marshal();
        }
        last_desc = Some(desc);
    }

    let desc = last_desc.expect("iters must be >= 1");
    let summary = canonical_summary(&desc);
    let summary_sha = sha256_hex(summary.as_bytes());
    if mode == "roundtrip" {
        let ser_sha = sha256_hex(last_ser.as_bytes());
        println!(
            "mode=roundtrip iters={} summary_sha256={} ser_bytes={} ser_sha256={}",
            iters,
            summary_sha,
            last_ser.len(),
            ser_sha
        );
    } else {
        println!("mode=parse iters={} summary_sha256={}", iters, summary_sha);
    }
}
