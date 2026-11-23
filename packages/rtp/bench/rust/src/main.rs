use bytes::Bytes;
use rtcp::packet::Packet as RtcpPacket;
use rtcp::payload_feedbacks::picture_loss_indication::PictureLossIndication;
use rtcp::reception_report::ReceptionReport;
use rtcp::sender_report::SenderReport;
use rtcp::transport_feedbacks::transport_layer_nack::{NackPair, TransportLayerNack};
use rtp::header::{Extension, Header as RtpHeader};
use rtp::packet::Packet as RtpPacket;
use webrtc_srtp::context::Context as SrtpContext;
use webrtc_srtp::protection_profile::ProtectionProfile;
use webrtc_util::{Marshal, Unmarshal};

fn to_hex(data: &[u8]) -> String {
    let mut s = String::with_capacity(data.len() * 2);
    for b in data {
        use std::fmt::Write;
        let _ = write!(&mut s, "{:02x}", b);
    }
    s
}

fn from_hex(s: &str) -> Vec<u8> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 2);
    let mut i = 0;
    while i < bytes.len() {
        let hi = (bytes[i] as char).to_digit(16).unwrap() as u8;
        let lo = (bytes[i + 1] as char).to_digit(16).unwrap() as u8;
        out.push((hi << 4) | lo);
        i += 2;
    }
    out
}

fn bench_rtp(iters: usize) {
    let mut payload = vec![0u8; 1172];
    for (i, b) in payload.iter_mut().enumerate() {
        *b = ((i * 31 + 17) & 0xFF) as u8;
    }
    let pkt = RtpPacket {
        header: RtpHeader {
            version: 2,
            padding: false,
            extension: true,
            marker: true,
            payload_type: 96,
            sequence_number: 1000,
            timestamp: 90000,
            ssrc: 0x11223344,
            csrc: vec![],
            extension_profile: 0xBEDE,
            extensions: vec![
                Extension {
                    id: 1,
                    payload: Bytes::from(from_hex("30")),
                },
                Extension {
                    id: 2,
                    payload: Bytes::from(from_hex("123456")),
                },
                Extension {
                    id: 3,
                    payload: Bytes::from(from_hex("0042")),
                },
            ],
            extensions_padding: 0,
        },
        payload: Bytes::from(payload),
    };
    let wire = pkt.marshal().unwrap();
    let mut acc: u64 = 0;
    let mut last_wire = wire.clone();
    for _ in 0..iters {
        let mut slice = &wire[..];
        let dec = RtpPacket::unmarshal(&mut slice).unwrap();
        acc = acc
            .wrapping_add(dec.header.sequence_number as u64)
            .wrapping_add(dec.header.timestamp as u64)
            .wrapping_add(dec.header.ssrc as u64)
            .wrapping_add(dec.header.extensions.len() as u64)
            .wrapping_add(dec.payload.len() as u64)
            .wrapping_add(dec.payload[0] as u64)
            .wrapping_add(dec.payload[dec.payload.len() - 1] as u64);
        let enc = dec.marshal().unwrap();
        acc = acc
            .wrapping_add(enc.len() as u64)
            .wrapping_add(enc[2] as u64)
            .wrapping_add(enc[enc.len() - 1] as u64);
        last_wire = enc;
    }
    println!(
        "rtp iters={} acc={} head={}",
        iters,
        acc,
        to_hex(&last_wire[..32])
    );
}

fn bench_rtcp(iters: usize) {
    let packets: Vec<Box<dyn RtcpPacket + Send + Sync>> = vec![
        Box::new(SenderReport {
            ssrc: 0x11223344,
            ntp_time: 0xE5A1B2C300001234,
            rtp_time: 90000,
            packet_count: 1500,
            octet_count: 1800000,
            reports: vec![ReceptionReport {
                ssrc: 0x55667788,
                fraction_lost: 12,
                total_lost: 3,
                last_sequence_number: 65541,
                jitter: 42,
                last_sender_report: 0xAABBCCDD,
                delay: 65536,
            }],
            profile_extensions: Bytes::new(),
        }),
        Box::new(PictureLossIndication {
            sender_ssrc: 0x55667788,
            media_ssrc: 0x11223344,
        }),
        Box::new(TransportLayerNack {
            sender_ssrc: 0x55667788,
            media_ssrc: 0x11223344,
            nacks: vec![NackPair {
                packet_id: 1000,
                lost_packets: 0x0005,
            }],
        }),
    ];
    let wire = rtcp::packet::marshal(&packets).unwrap();
    let mut acc: u64 = 0;
    let mut last_wire = wire.clone();
    for _ in 0..iters {
        let mut slice = &wire[..];
        let dec = rtcp::packet::unmarshal(&mut slice).unwrap();
        let enc = rtcp::packet::marshal(&dec).unwrap();
        acc = acc
            .wrapping_add(dec.len() as u64)
            .wrapping_add(enc.len() as u64)
            .wrapping_add(enc[0] as u64)
            .wrapping_add(enc[enc.len() - 1] as u64);
        last_wire = enc;
    }
    println!(
        "rtcp iters={} acc={} wire={}",
        iters,
        acc,
        to_hex(&last_wire)
    );
}

fn bench_srtp(profile: ProtectionProfile, label: &str, iters: usize) {
    let mk = from_hex("e1f97a0d3e018be0d64fa32c06de4139");
    let ms = match profile {
        ProtectionProfile::AeadAes128Gcm => from_hex("517569642070726f2071756f"),
        _ => from_hex("0ec675ad498afeebb6960b3aabe6"),
    };
    let mut tx = SrtpContext::new(&mk, &ms, profile, None, None).unwrap();
    let mut rx = SrtpContext::new(&mk, &ms, profile, None, None).unwrap();

    let mut base_pkt = vec![0u8; 1200];
    base_pkt[0] = 0x80;
    base_pkt[1] = 0x60;
    base_pkt[4] = 0x00;
    base_pkt[5] = 0x01;
    base_pkt[6] = 0x5F;
    base_pkt[7] = 0x90;
    base_pkt[8] = 0x11;
    base_pkt[9] = 0x22;
    base_pkt[10] = 0x33;
    base_pkt[11] = 0x44;
    for k in 12..1200 {
        base_pkt[k] = (((k - 12) * 31 + 17) & 0xFF) as u8;
    }

    let mut acc: u64 = 0;
    let mut last_enc = Vec::new();
    for i in 0..iters {
        let seq = ((i + 1) & 0xFFFF) as u16;
        base_pkt[2] = (seq >> 8) as u8;
        base_pkt[3] = (seq & 0xFF) as u8;
        let enc = tx.encrypt_rtp(&base_pkt).unwrap();
        let dec = rx.decrypt_rtp(&enc).unwrap();
        acc = acc
            .wrapping_add(enc.len() as u64)
            .wrapping_add(dec.len() as u64)
            .wrapping_add(dec[12] as u64)
            .wrapping_add(dec[dec.len() - 1] as u64);
        last_enc = enc.to_vec();
    }
    let tail = &last_enc[last_enc.len() - 24..];
    println!("{} iters={} acc={} tail={}", label, iters, acc, to_hex(tail));
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: rtp-bench-rust <rtp|rtcp|srtp_cm|srtp_gcm> <iters>");
        std::process::exit(1);
    }
    let mode = args[1].as_str();
    let iters: usize = args[2].parse().unwrap();
    match mode {
        "rtp" => bench_rtp(iters),
        "rtcp" => bench_rtcp(iters),
        "srtp_cm" => bench_srtp(ProtectionProfile::Aes128CmHmacSha1_80, "srtp_cm", iters),
        "srtp_gcm" => bench_srtp(ProtectionProfile::AeadAes128Gcm, "srtp_gcm", iters),
        _ => {
            eprintln!("unknown mode: {}", mode);
            std::process::exit(1);
        }
    }
}
