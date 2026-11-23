use std::env;
use std::fmt::Write as _;
use std::fs;
use std::io::Cursor;

use symphonia_core::errors::Error;
use symphonia_core::formats::{FormatOptions, FormatReader};
use symphonia_core::io::MediaSourceStream;
use symphonia_format_isomp4::IsoMp4Reader;

/// Parse an MP4 or concatenated fMP4 (init + media) buffer using Symphonia's
/// independent pure-Rust `IsoMp4Reader`, collecting (track_id, size, dur) per packet.
fn demux_symphonia(data: &[u8]) -> Result<(usize, Vec<(u32, usize, u64)>), String> {
    let cursor = Cursor::new(data.to_vec());
    let mss = MediaSourceStream::new(Box::new(cursor), Default::default());
    let mut reader =
        IsoMp4Reader::try_new(mss, &FormatOptions::default()).map_err(|e| e.to_string())?;
    let n_tracks = reader.tracks().len();
    let mut pkts = Vec::new();
    loop {
        match reader.next_packet() {
            Ok(pkt) => {
                pkts.push((pkt.track_id() + 1, pkt.buf().len(), pkt.dur()));
            }
            Err(Error::IoError(ref e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok((n_tracks, pkts))
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: mp4-bench-rust <mp4|fmp4> ...");
        std::process::exit(1);
    }
    match args[1].as_str() {
        "mp4" => {
            let data = fs::read(&args[2]).expect("read mp4");
            let iters: usize = args[3].parse().expect("iters");
            let mut total_samples: i64 = 0;
            let mut last = None;
            for r in 0..iters {
                let res = demux_symphonia(&data).expect("symphonia mp4");
                total_samples += res.1.len() as i64;
                if r == iters - 1 {
                    last = Some(res);
                }
            }
            let (n_tracks, mut pkts) = last.unwrap();
            // Sort stably by track_id so both demuxers emit canonical per-track order
            pkts.sort_by_key(|p| p.0);
            let mut out = String::with_capacity(16384);
            let _ = writeln!(
                out,
                "mode=mp4 iters={} total_samples={} tracks={}",
                iters, total_samples, n_tracks
            );
            for (i, (tid, sz, dur)) in pkts.iter().enumerate() {
                let _ = writeln!(out, "p {} tid={} sz={} dur={}", i, tid, sz, dur);
            }
            print!("{}", out);
        }
        "fmp4" => {
            if args.len() < 5 {
                eprintln!("usage: mp4-bench-rust fmp4 <init> <media> <iters>");
                std::process::exit(1);
            }
            let init_data = fs::read(&args[2]).expect("read init");
            let media_data = fs::read(&args[3]).expect("read media");
            let mut combined = Vec::with_capacity(init_data.len() + media_data.len());
            combined.extend_from_slice(&init_data);
            combined.extend_from_slice(&media_data);
            let iters: usize = args[4].parse().expect("iters");
            let mut total_samples: i64 = 0;
            let mut last = None;
            for r in 0..iters {
                let res = demux_symphonia(&combined).expect("symphonia fmp4");
                total_samples += res.1.len() as i64;
                if r == iters - 1 {
                    last = Some(res);
                }
            }
            let (n_tracks, mut pkts) = last.unwrap();
            pkts.sort_by_key(|p| p.0);
            let mut out = String::with_capacity(16384);
            let _ = writeln!(
                out,
                "mode=fmp4 iters={} total_samples={} tracks={}",
                iters, total_samples, n_tracks
            );
            for (i, (tid, sz, dur)) in pkts.iter().enumerate() {
                let _ = writeln!(out, "p {} tid={} sz={} dur={}", i, tid, sz, dur);
            }
            print!("{}", out);
        }
        other => {
            eprintln!("unknown mode: {}", other);
            std::process::exit(1);
        }
    }
}
