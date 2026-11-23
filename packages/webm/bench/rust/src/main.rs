use matroska_demuxer::{Frame, MatroskaFile, TrackType};
use std::env;
use std::fmt::Write as _;
use std::fs;
use std::io::Cursor;
use std::process;

fn fnv1a_slice(mut h: u64, data: &[u8]) -> u64 {
    for &b in data {
        h = (h ^ (b as u64)).wrapping_mul(1099511628211u64);
    }
    h
}

fn track_type_code(tt: TrackType) -> i32 {
    match tt {
        TrackType::Video => 1,
        TrackType::Audio => 2,
        TrackType::Complex => 3,
        TrackType::Logo => 16,
        TrackType::Subtitle => 17,
        TrackType::Buttons => 18,
        TrackType::Control => 32,
        _ => 0,
    }
}

fn run_demux(mode: &str, data: &[u8], iters: usize) {
    let mut last_doc = String::new();
    let mut last_scale: u64 = 1_000_000;
    let mut last_tracks: Vec<String> = Vec::new();
    let mut last_frames_out = String::new();
    let mut last_frame_count: usize = 0;
    let mut last_payload_hash: u64 = 14695981039346656037u64;

    for iter in 0..iters {
        let mut mkv = MatroskaFile::open(Cursor::new(data)).unwrap_or_else(|e| {
            eprintln!("matroska-demuxer open error: {e:?}");
            process::exit(1);
        });
        let scale = mkv.info().timestamp_scale().get();
        let is_last = iter + 1 == iters;
        if is_last {
            last_doc = "webm".to_string();
            last_scale = scale;
            last_tracks.clear();
            for t in mkv.tracks() {
                let extra = if let Some(v) = t.video() {
                    format!(" video={}x{}", v.pixel_width().get(), v.pixel_height().get())
                } else if let Some(a) = t.audio() {
                    format!(
                        " audio={}Hz/{}ch",
                        a.sampling_frequency() as i64,
                        a.channels().get()
                    )
                } else {
                    String::new()
                };
                let cp_len = t.codec_private().map(|b| b.len()).unwrap_or(0);
                last_tracks.push(format!(
                    "track num={} type={} codec={} cp={}{}",
                    t.track_number().get(),
                    track_type_code(t.track_type()),
                    t.codec_id(),
                    cp_len,
                    extra
                ));
            }
            last_frames_out.clear();
            last_frame_count = 0;
            last_payload_hash = 14695981039346656037u64;
        }

        let mut frame = Frame::default();
        while mkv.next_frame(&mut frame).unwrap_or_else(|e| {
            eprintln!("matroska-demuxer next_frame error: {e:?}");
            process::exit(1);
        }) {
            if is_last {
                let fhash = fnv1a_slice(14695981039346656037u64, &frame.data);
                last_payload_hash = fnv1a_slice(last_payload_hash, &frame.data);
                let pts_ns = (frame.timestamp as i64) * (scale as i64);
                let pts_ms = pts_ns / 1_000_000i64;
                let kf = if frame.is_keyframe.unwrap_or(true) { 1 } else { 0 };
                let _ = writeln!(
                    last_frames_out,
                    "f {} {} {} {} {} {:016x}",
                    frame.track,
                    frame.data.len(),
                    pts_ns,
                    pts_ms,
                    kf,
                    fhash
                );
                last_frame_count += 1;
            }
        }
    }

    println!(
        "mode={} iters={} doc={} scale={} tracks={}",
        mode,
        iters,
        last_doc,
        last_scale,
        last_tracks.len()
    );
    for t in &last_tracks {
        println!("{}", t);
    }
    println!(
        "frames={} payload_fnv64={:016x}",
        last_frame_count, last_payload_hash
    );
    print!("{}", last_frames_out);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: webm-bench-rust full <file> <iters> | mse <init> <media> <iters>");
        process::exit(1);
    }
    match args[1].as_str() {
        "full" => {
            let data = fs::read(&args[2]).expect("read webm file");
            let iters: usize = args[3].parse().expect("parse iters");
            run_demux("full", &data, iters);
        }
        "mse" => {
            if args.len() < 5 {
                eprintln!("usage: webm-bench-rust mse <init> <media> <iters>");
                process::exit(1);
            }
            let init_data = fs::read(&args[2]).expect("read init file");
            let media_data = fs::read(&args[3]).expect("read media file");
            let iters: usize = args[4].parse().expect("parse iters");
            let mut combined = Vec::with_capacity(init_data.len() + media_data.len());
            combined.extend_from_slice(&init_data);
            combined.extend_from_slice(&media_data);
            run_demux("mse", &combined, iters);
        }
        other => {
            eprintln!("unknown mode: {other}");
            process::exit(1);
        }
    }
}
