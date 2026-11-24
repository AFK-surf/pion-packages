use std::env;
use std::fs;
use std::io::{self, Write};
use m3u8_rs::{AlternativeMediaType, KeyMethod, MediaPlaylistType, Playlist};

fn opt_str(o: &Option<String>) -> &str {
    match o {
        Some(s) => s.as_str(),
        None => "-",
    }
}

fn opt_u64(o: Option<u64>) -> String {
    match o {
        Some(v) => v.to_string(),
        None => "-".to_string(),
    }
}

fn bool_bit(b: bool) -> &'static str {
    if b { "1" } else { "0" }
}

fn key_method_str(m: &KeyMethod) -> &'static str {
    match m {
        KeyMethod::None => "NONE",
        KeyMethod::AES128 => "AES-128",
        KeyMethod::SampleAES => "SAMPLE-AES",
        KeyMethod::Other(s) if s == "SAMPLE-AES-CTR" => "SAMPLE-AES-CTR",
        KeyMethod::Other(_) => "OTHER",
    }
}

fn media_type_str(t: &AlternativeMediaType) -> &'static str {
    match t {
        AlternativeMediaType::Audio => "AUDIO",
        AlternativeMediaType::Video => "VIDEO",
        AlternativeMediaType::Subtitles => "SUBTITLES",
        AlternativeMediaType::ClosedCaptions => "CLOSED-CAPTIONS",
        AlternativeMediaType::Other(_) => "OTHER",
    }
}

fn run_diff(corpus_path: &str) {
    let content = fs::read_to_string(corpus_path).expect("read corpus");
    let cases: Vec<&str> = content.split("\n===HLS_CASE_SEP===\n").collect();
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());

    for c in cases {
        match m3u8_rs::parse_playlist_res(c.as_bytes()) {
            Err(e) => {
                writeln!(out, "ERR|{:?}", e).unwrap();
            }
            Ok(Playlist::MasterPlaylist(m)) => {
                let ver = match m.version {
                    Some(v) => v.to_string(),
                    None => "-".to_string(),
                };
                let mut normal_variants = Vec::new();
                let mut iframe_count = 0usize;
                for v in &m.variants {
                    if v.is_i_frame {
                        iframe_count += 1;
                    } else {
                        normal_variants.push(v);
                    }
                }
                writeln!(
                    out,
                    "MASTER|ver={}|indep={}|variants={}|iframes={}|media={}|sdata={}|skeys={}",
                    ver,
                    bool_bit(m.independent_segments),
                    normal_variants.len(),
                    iframe_count,
                    m.alternatives.len(),
                    m.session_data.len(),
                    m.session_key.len(),
                )
                .unwrap();

                for v in normal_variants {
                    let res_s = match v.resolution {
                        Some(r) => format!("{}x{}", r.width, r.height),
                        None => "-".to_string(),
                    };
                    writeln!(
                        out,
                        "V|{}|{}|{}|{}|{}|{}|{}",
                        v.uri,
                        v.bandwidth,
                        opt_u64(v.average_bandwidth),
                        opt_str(&v.codecs),
                        res_s,
                        opt_str(&v.audio),
                        opt_str(&v.subtitles),
                    )
                    .unwrap();
                }
                for md in &m.alternatives {
                    writeln!(
                        out,
                        "M|{}|{}|{}|{}|{}|{}|{}",
                        media_type_str(&md.media_type),
                        md.group_id,
                        md.name,
                        opt_str(&md.language),
                        bool_bit(md.default),
                        bool_bit(md.autoselect),
                        opt_str(&md.uri),
                    )
                    .unwrap();
                }
            }
            Ok(Playlist::MediaPlaylist(m)) => {
                let ver = match m.version {
                    Some(v) => v.to_string(),
                    None => "-".to_string(),
                };
                let pt_s = match &m.playlist_type {
                    Some(MediaPlaylistType::Event) => "EVENT",
                    Some(MediaPlaylistType::Vod) => "VOD",
                    _ => "-",
                };
                writeln!(
                    out,
                    "MEDIA|ver={}|td={}|msn={}|dsn={}|type={}|end={}|segs={}",
                    ver,
                    m.target_duration,
                    m.media_sequence,
                    m.discontinuity_sequence,
                    pt_s,
                    bool_bit(m.end_list),
                    m.segments.len(),
                )
                .unwrap();

                let mut prev_uri: Option<&str> = None;
                let mut prev_br_end: Option<u64> = None;

                for seg in &m.segments {
                    let dur_ms = ((seg.duration as f64) * 1000.0).round() as i64;
                    let br_s = match &seg.byte_range {
                        Some(br) => {
                            let off = match br.offset {
                                Some(o) => o,
                                None => {
                                    if prev_uri == Some(seg.uri.as_str()) {
                                        prev_br_end.unwrap_or(0)
                                    } else {
                                        0
                                    }
                                }
                            };
                            prev_uri = Some(seg.uri.as_str());
                            prev_br_end = Some(off + br.length);
                            format!("{}@{}", br.length, off)
                        }
                        None => {
                            prev_uri = Some(seg.uri.as_str());
                            prev_br_end = None;
                            "-".to_string()
                        }
                    };
                    let (km_s, ku_s) = match &seg.key {
                        Some(k) => (key_method_str(&k.method), opt_str(&k.uri)),
                        None => ("-", "-"),
                    };
                    let mu_s = match &seg.map {
                        Some(mp) => mp.uri.as_str(),
                        None => "-",
                    };
                    writeln!(
                        out,
                        "S|{}|{}|{}|{}|{}|{}|{}",
                        seg.uri,
                        dur_ms,
                        br_s,
                        bool_bit(seg.discontinuity),
                        km_s,
                        ku_s,
                        mu_s,
                    )
                    .unwrap();
                }
            }
        }
    }
}

fn run_bench(corpus_path: &str, iters: usize) {
    let content = fs::read_to_string(corpus_path).expect("read corpus");
    let cases: Vec<&[u8]> = content
        .split("\n===HLS_CASE_SEP===\n")
        .map(|s| s.as_bytes())
        .collect();

    let mut total_playlists: i64 = 0;
    let mut total_variants: i64 = 0;
    let mut total_segments: i64 = 0;
    let mut total_dur_ms: i64 = 0;

    for _ in 0..iters {
        for c in &cases {
            match m3u8_rs::parse_playlist_res(c) {
                Ok(Playlist::MasterPlaylist(m)) => {
                    total_playlists += 1;
                    let normal = m.variants.iter().filter(|v| !v.is_i_frame).count() as i64;
                    total_variants += normal;
                }
                Ok(Playlist::MediaPlaylist(m)) => {
                    total_playlists += 1;
                    total_segments += m.segments.len() as i64;
                    let mut sum_us: i64 = 0;
                    for seg in &m.segments {
                        sum_us += ((seg.duration as f64) * 1000.0).round() as i64 * 1000;
                    }
                    total_dur_ms += sum_us / 1000;
                }
                Err(_) => {}
            }
        }
    }

    println!(
        "bench playlists={} variants={} segments={} total_ms={}",
        total_playlists, total_variants, total_segments, total_dur_ms
    );
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: hls_rust_bench <diff|bench> <corpus> [iters]");
        std::process::exit(1);
    }
    match args[1].as_str() {
        "diff" => run_diff(&args[2]),
        "bench" if args.len() >= 4 => {
            let iters: usize = args[3].parse().expect("iters");
            run_bench(&args[2], iters);
        }
        other => {
            eprintln!("unknown command: {}", other);
            std::process::exit(1);
        }
    }
}
