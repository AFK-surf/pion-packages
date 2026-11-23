//! Rust webrtc-rs (rtp 0.12 / rtcp 0.12 / webrtc-srtp 0.14) oracle for the packages/rtp red-team
//! audit. Modes (all output is line-oriented text, see ../README.md):
//!   rtp_oracle gen                  -> interop cases encrypted by webrtc-srtp (stdout)
//!   rtp_oracle verify <cases.txt>   -> decrypt Pion's cases, re-encrypt and byte-compare, codec check
//!   rtp_oracle fuzz <corpus.txt>    -> verdict per corpus line (panics caught and reported as PANIC)
//!   rtp_oracle dos-ssrc <n>         -> n forged SRTP packets with distinct SSRCs, then 10k genuine
use bytes::Bytes;
use rtcp::goodbye::Goodbye;
use rtcp::packet::Packet as RtcpPacketT;
use rtcp::payload_feedbacks::full_intra_request::{FirEntry, FullIntraRequest};
use rtcp::payload_feedbacks::picture_loss_indication::PictureLossIndication;
use rtcp::payload_feedbacks::receiver_estimated_maximum_bitrate::ReceiverEstimatedMaximumBitrate;
use rtcp::reception_report::ReceptionReport;
use rtcp::receiver_report::ReceiverReport;
use rtcp::sender_report::SenderReport;
use rtcp::source_description::{SdesType, SourceDescription, SourceDescriptionChunk, SourceDescriptionItem};
use rtcp::transport_feedbacks::transport_layer_nack::{NackPair, TransportLayerNack};
use rtp::header::{Extension, Header};
use rtp::packet::Packet;
use std::collections::HashMap;
use std::io::Write;
use webrtc_srtp::context::Context;
use webrtc_srtp::option::{srtcp_replay_protection, srtp_replay_protection};
use webrtc_srtp::protection_profile::ProtectionProfile;
use webrtc_util::{Marshal, Unmarshal};

fn hex(d: &[u8]) -> String {
    d.iter().map(|b| format!("{:02x}", b)).collect()
}
fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect()
}
fn profile(name: &str) -> ProtectionProfile {
    match name {
        "cm80" => ProtectionProfile::Aes128CmHmacSha1_80,
        "cm32" => ProtectionProfile::Aes128CmHmacSha1_32,
        "gcm" => ProtectionProfile::AeadAes128Gcm,
        _ => panic!("profile"),
    }
}
fn ctx(name: &str) -> Context {
    let mk = unhex("e1f97a0d3e018be0d64fa32c06de4139");
    let ms = if name == "gcm" { unhex("517569642070726f2071756f") } else { unhex("0ec675ad498afeebb6960b3aabe6") };
    Context::new(&mk, &ms, profile(name), Some(srtp_replay_protection(64)), Some(srtcp_replay_protection(64))).unwrap()
}
fn fill(n: usize, v: usize) -> Bytes {
    Bytes::from((0..n).map(|i| ((v + i * 7) & 0xff) as u8).collect::<Vec<u8>>())
}
fn rtp_pkt(seq: u16, ssrc: u32, payload: Bytes) -> Packet {
    Packet {
        header: Header { version: 2, payload_type: 96, sequence_number: seq, timestamp: 90000 + seq as u32, ssrc, ..Default::default() },
        payload,
    }
}

/// (case, profile, kind, plaintext)
fn rust_cases() -> Vec<(String, String, &'static str, Vec<u8>)> {
    let mut out = vec![];
    for p in ["cm80", "cm32", "gcm"] {
        let c = |n: &str| format!("rs_{}_{}", n, p);
        for s in 1..=5u16 {
            out.push((c("simple"), p.into(), "rtp", rtp_pkt(s, 0x11111111, fill(160, s as usize)).marshal().unwrap().to_vec()));
        }
        // one-byte extensions + CSRC + marker
        let mut pk = rtp_pkt(100, 0x22222222, fill(300, 3));
        pk.header.marker = true;
        pk.header.csrc = vec![0x01020304, 0x05060708];
        pk.header.extension = true;
        pk.header.extension_profile = 0xBEDE;
        pk.header.extensions = vec![
            Extension { id: 1, payload: Bytes::from_static(&[0x30]) },
            Extension { id: 3, payload: Bytes::from_static(&[1, 2, 3]) },
            Extension { id: 14, payload: fill(16, 9) },
        ];
        out.push((c("ext1"), p.into(), "rtp", pk.marshal().unwrap().to_vec()));
        // two-byte extensions (incl. zero-length element and id 200)
        let mut pk = rtp_pkt(101, 0x22222222, fill(50, 4));
        pk.header.extension = true;
        pk.header.extension_profile = 0x1000;
        pk.header.extensions = vec![
            Extension { id: 200, payload: fill(40, 1) },
            Extension { id: 2, payload: Bytes::new() },
            Extension { id: 7, payload: fill(255, 2) },
        ];
        out.push((c("ext2"), p.into(), "rtp", pk.marshal().unwrap().to_vec()));
        // ROC wrap 65530 .. 65535, 0 .. 5 with one reordered late packet
        let mut seqs: Vec<u16> = (65530..=65535).collect();
        seqs.extend(0..=5);
        seqs.swap(6, 7); // 1 arrives before 0... sender order matters for the encrypt side only
        for s in seqs {
            out.push((c("rocwrap"), p.into(), "rtp", rtp_pkt(s, 0x33333333, fill(100, s as usize)).marshal().unwrap().to_vec()));
        }
        // large payload: > 256 AES blocks (counter carry into byte 14 / inc32 byte 14)
        out.push((c("big"), p.into(), "rtp", rtp_pkt(7, 0x44444444, fill(5000, 1)).marshal().unwrap().to_vec()));
        out.push((c("empty"), p.into(), "rtp", rtp_pkt(8, 0x44444444, Bytes::new()).marshal().unwrap().to_vec()));
        // RTCP compound SR + SDES + BYE
        let rr = ReceptionReport { ssrc: 0xabcdef01, fraction_lost: 25, total_lost: 0xFFFFF0, last_sequence_number: 0x10001, jitter: 77, last_sender_report: 5, delay: 6 };
        let pkts: Vec<Box<dyn RtcpPacketT + Send + Sync>> = vec![
            Box::new(SenderReport { ssrc: 0x55555555, ntp_time: 0x0102030405060708, rtp_time: 9, packet_count: 10, octet_count: 11, reports: vec![rr.clone()], profile_extensions: Bytes::new() }),
            Box::new(SourceDescription { chunks: vec![SourceDescriptionChunk { source: 0x55555555, items: vec![SourceDescriptionItem { sdes_type: SdesType::SdesCname, text: Bytes::from_static(b"audit@pion") }] }] }),
            Box::new(Goodbye { sources: vec![0x55555555], reason: Bytes::from_static(b"bye") }),
        ];
        out.push((c("rtcp_sr_sdes_bye"), p.into(), "rtcp", rtcp::packet::marshal(&pkts).unwrap().to_vec()));
        let pkts: Vec<Box<dyn RtcpPacketT + Send + Sync>> = vec![
            Box::new(ReceiverReport { ssrc: 0x55555555, reports: vec![rr.clone(), rr.clone()], profile_extensions: Bytes::new() }),
            Box::new(TransportLayerNack { sender_ssrc: 0x55555555, media_ssrc: 0x11111111, nacks: vec![NackPair { packet_id: 65535, lost_packets: 0x8001 }] }),
            Box::new(PictureLossIndication { sender_ssrc: 0x55555555, media_ssrc: 0x11111111 }),
            Box::new(FullIntraRequest { sender_ssrc: 0x55555555, media_ssrc: 0, fir: vec![FirEntry { ssrc: 0x11111111, sequence_number: 42 }] }),
            Box::new(ReceiverEstimatedMaximumBitrate { sender_ssrc: 0x55555555, bitrate: 2_500_000.0, ssrcs: vec![0x11111111, 0x22222222] }),
        ];
        out.push((c("rtcp_rr_fb"), p.into(), "rtcp", rtcp::packet::marshal(&pkts).unwrap().to_vec()));
        // RFC-conformant per-SSRC SRTCP indices from two RTCP senders in ONE webrtc-srtp context
        // (exercises finding P1-2 in the Rust -> Pion direction).
        for i in 0..71u32 {
            let s = if i < 70 { 0x77770001 } else { 0x77770002 };
            let pkts: Vec<Box<dyn RtcpPacketT + Send + Sync>> = vec![Box::new(PictureLossIndication { sender_ssrc: s, media_ssrc: i })];
            out.push((c("rtcp_two_ssrc"), p.into(), "rtcp", rtcp::packet::marshal(&pkts).unwrap().to_vec()));
        }
        for i in 0..70u32 {
            let pkts: Vec<Box<dyn RtcpPacketT + Send + Sync>> = vec![Box::new(PictureLossIndication { sender_ssrc: 0x66666666, media_ssrc: i })];
            out.push((c("rtcp_many"), p.into(), "rtcp", rtcp::packet::marshal(&pkts).unwrap().to_vec()));
        }
    }
    out
}

fn gen() {
    let mut enc: HashMap<String, Context> = HashMap::new();
    let mut so = std::io::stdout().lock();
    for (case, p, kind, plain) in rust_cases() {
        let c = enc.entry(case.clone()).or_insert_with(|| ctx(&p));
        let w = if kind == "rtp" { c.encrypt_rtp(&plain) } else { c.encrypt_rtcp(&plain) }.unwrap();
        writeln!(so, "{} {} {} {} {}", case, p, kind, hex(&plain), hex(&w)).unwrap();
    }
}

fn codec_check(kind: &str, plain: &[u8]) -> &'static str {
    if kind == "rtp" {
        let mut b = Bytes::copy_from_slice(plain);
        match Packet::unmarshal(&mut b) {
            Ok(p) => {
                if p.header.padding {
                    return "CODEC_SKIP_PADDING";
                }
                match p.marshal() {
                    Ok(m) if m.as_ref() == plain => "CODEC_OK",
                    _ => "CODEC_DIFF",
                }
            }
            Err(_) => "CODEC_REJECT",
        }
    } else {
        let mut b = Bytes::copy_from_slice(plain);
        match rtcp::packet::unmarshal(&mut b) {
            Ok(v) => match rtcp::packet::marshal(&v) {
                Ok(m) if m.as_ref() == plain => "CODEC_OK",
                _ => "CODEC_DIFF",
            },
            Err(_) => "CODEC_REJECT",
        }
    }
}

fn verify(path: &str) {
    let text = std::fs::read_to_string(path).unwrap();
    let mut dec: HashMap<String, Context> = HashMap::new();
    let mut enc: HashMap<String, Context> = HashMap::new();
    let mut idx: HashMap<String, usize> = HashMap::new();
    let mut so = std::io::stdout().lock();
    for line in text.lines() {
        let f: Vec<&str> = line.split(' ').collect();
        if f.len() != 5 {
            continue;
        }
        let (case, p, kind, plain, wire) = (f[0], f[1], f[2], unhex(f[3]), unhex(f[4]));
        let i = idx.entry(case.into()).or_insert(0);
        let d = dec.entry(case.into()).or_insert_with(|| ctx(p));
        let r = if kind == "rtp" { d.decrypt_rtp(&wire) } else { d.decrypt_rtcp(&wire) };
        let dv = match r {
            Ok(b) if b.as_ref() == plain.as_slice() => "DEC_OK".to_string(),
            Ok(_) => "DEC_WRONG_PLAINTEXT".to_string(),
            Err(e) => format!("DEC_FAIL({})", e).replace(' ', "_"),
        };
        let e = enc.entry(case.into()).or_insert_with(|| ctx(p));
        let w2 = if kind == "rtp" { e.encrypt_rtp(&plain) } else { e.encrypt_rtcp(&plain) };
        let ev = match w2 {
            Ok(b) if b.as_ref() == wire.as_slice() => "ENC_EQ",
            Ok(_) => "ENC_DIFF",
            Err(_) => "ENC_ERR",
        };
        writeln!(so, "{} {} {} {} {} {}", case, i, kind, dv, ev, codec_check(kind, &plain)).unwrap();
        *i += 1;
    }
}

fn verdict(kind: &str, data: &[u8]) -> String {
    match kind {
        "rtp" => {
            let mut b = Bytes::copy_from_slice(data);
            match Packet::unmarshal(&mut b) {
                Ok(p) => {
                    let h = &p.header;
                    format!(
                        "OK seq={} ts={} ssrc={} pt={} m={} cc={} x={} prof={} ne={} pl={}",
                        h.sequence_number, h.timestamp, h.ssrc, h.payload_type, h.marker as u8, h.csrc.len(), h.extension as u8,
                        h.extension_profile, h.extensions.len(), p.payload.len()
                    )
                }
                Err(_) => "ERR".into(),
            }
        }
        "rtcp" => {
            let mut b = Bytes::copy_from_slice(data);
            match rtcp::packet::unmarshal(&mut b) {
                Ok(v) => {
                    let parts: Vec<String> = v.iter().map(|p| { let h = p.header(); format!("{}/{}", h.packet_type as u8, h.count) }).collect();
                    format!("OK {}", parts.join(","))
                }
                Err(_) => "ERR".into(),
            }
        }
        "srtp" | "srtcp" => {
            let mut out = vec![];
            for p in ["cm80", "gcm"] {
                let mut c = ctx(p);
                let r = if kind == "srtp" { c.decrypt_rtp(data) } else { c.decrypt_rtcp(data) };
                out.push(match r { Ok(b) => format!("{}:OK:{}", p, hex(&b)), Err(_) => format!("{}:ERR", p) });
            }
            out.join(" ")
        }
        _ => "?".into(),
    }
}

fn fuzz(path: &str) {
    std::panic::set_hook(Box::new(|_| {}));
    let text = std::fs::read_to_string(path).unwrap();
    let mut so = std::io::stdout().lock();
    for line in text.lines() {
        let mut it = line.splitn(2, ' ');
        let kind = it.next().unwrap_or("");
        let data = unhex(it.next().unwrap_or(""));
        let k = kind.to_string();
        let v = std::panic::catch_unwind(move || verdict(&k, &data)).unwrap_or_else(|_| "PANIC".into());
        writeln!(so, "{} {}", kind, v).unwrap();
    }
}

fn dos_ssrc(n: u32) {
    let mut tx = ctx("cm80");
    let mut rx = ctx("cm80");
    let t0 = std::time::Instant::now();
    for i in 0..n {
        let mut w = rtp_pkt((i & 0xffff) as u16, 0x01000000 + i, fill(32, 1)).marshal().unwrap().to_vec();
        w.extend_from_slice(&[0u8; 10]);
        let _ = rx.decrypt_rtp(&w);
    }
    let forged = t0.elapsed();
    let t1 = std::time::Instant::now();
    let mut ok = 0;
    for s in 0..10000u32 {
        let w = tx.encrypt_rtp(&rtp_pkt((s & 0xffff) as u16, 0x00ABCDEF, fill(32, 2)).marshal().unwrap()).unwrap();
        if rx.decrypt_rtp(&w).is_ok() {
            ok += 1;
        }
    }
    println!("rust forged={} forged_ms={} genuine_ok={} genuine_10k_ms={}", n, forged.as_millis(), ok, t1.elapsed().as_millis());
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    match a.get(1).map(|s| s.as_str()) {
        Some("gen") => gen(),
        Some("verify") => verify(&a[2]),
        Some("fuzz") => fuzz(&a[2]),
        Some("dos-ssrc") => dos_ssrc(a[2].parse().unwrap()),
        _ => {
            eprintln!("usage: rtp_oracle gen|verify <f>|fuzz <f>|dos-ssrc <n>");
            std::process::exit(2)
        }
    }
}
