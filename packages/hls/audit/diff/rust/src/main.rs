//! m3u8-rs 6.0.1 dumper for the packages/hls red-team audit (see ../../REPORT.md).
//! Reads `<name>\t<hex>` corpus lines, prints `=<name>` then the field subset that m3u8-rs exposes, in the
//! same escaping as ../../src/dump.pion (compare.py `project()` maps the Pion dump onto these lines).
use m3u8_rs::{AlternativeMediaType, KeyMethod, MediaPlaylistType, Playlist};
use std::io::Write;

fn esc(s: &[u8]) -> String {
    let mut o = String::new();
    for &c in s {
        if c > 32 && c < 127 && !b"%|\\\",".contains(&c) {
            o.push(c as char);
        } else {
            o.push_str(&format!("%{:02X}", c));
        }
    }
    o
}
fn qs(s: &str) -> String {
    format!("\"{}", esc(s.as_bytes()))
}
fn os(o: &Option<String>) -> String {
    o.as_ref().map(|s| qs(s)).unwrap_or_else(|| "-".into())
}
fn ou(o: Option<u64>) -> String {
    o.map(|v| v.to_string()).unwrap_or_else(|| "-".into())
}
fn b01(b: bool) -> &'static str {
    if b { "1" } else { "0" }
}

fn dump(data: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    match m3u8_rs::parse_playlist_res(data) {
        Err(_) => out.push("ERR|m3u8-rs".into()),
        Ok(Playlist::MasterPlaylist(m)) => {
            out.push(format!("MASTER|{}|{}", ou(m.version.map(|v| v as u64)), b01(m.independent_segments)));
            let res = |r: &Option<m3u8_rs::Resolution>| r.map(|r| format!("{}x{}", r.width, r.height)).unwrap_or_else(|| "-".into());
            for v in m.variants.iter().filter(|v| !v.is_i_frame) {
                out.push(format!("V|{}|{}|{}|{}|{}|{}|{}|{}", qs(&v.uri), v.bandwidth, ou(v.average_bandwidth), os(&v.codecs),
                    res(&v.resolution), os(&v.audio), os(&v.video), os(&v.subtitles)));
            }
            for v in m.variants.iter().filter(|v| v.is_i_frame) {
                out.push(format!("I|{}|{}|{}|{}", qs(&v.uri), v.bandwidth, os(&v.codecs), res(&v.resolution)));
            }
            for a in &m.alternatives {
                let t = match &a.media_type {
                    AlternativeMediaType::Audio => "AUDIO",
                    AlternativeMediaType::Video => "VIDEO",
                    AlternativeMediaType::Subtitles => "SUBTITLES",
                    AlternativeMediaType::ClosedCaptions => "CLOSED-CAPTIONS",
                    AlternativeMediaType::Other(_) => "OTHER",
                };
                out.push(format!("M|{}|{}|{}|{}|{}|{}|{}|{}", t, qs(&a.group_id), qs(&a.name), os(&a.uri), os(&a.language),
                    os(&a.assoc_language), b01(a.default), b01(a.autoselect)));
            }
        }
        Ok(Playlist::MediaPlaylist(m)) => {
            let pt = match &m.playlist_type {
                Some(MediaPlaylistType::Event) => "EVENT",
                Some(MediaPlaylistType::Vod) => "VOD",
                Some(_) => "OTHER",
                None => "-",
            };
            out.push(format!("MEDIA|{}|{}|{}|{}|{}|{}|{}", ou(m.version.map(|v| v as u64)), m.target_duration, m.media_sequence,
                m.discontinuity_sequence, pt, b01(m.end_list), b01(m.i_frames_only)));
            for s in &m.segments {
                let km = match &s.key {
                    Some(k) => match &k.method {
                        KeyMethod::None => "NONE".to_string(),
                        KeyMethod::AES128 => "AES-128".to_string(),
                        KeyMethod::SampleAES => "SAMPLE-AES".to_string(),
                        KeyMethod::Other(o) => o.clone(),
                    },
                    None => "-".into(),
                };
                let mu = s.map.as_ref().map(|m| qs(&m.uri)).unwrap_or_else(|| "-".into());
                let br = s.byte_range.as_ref().map(|b| b.length.to_string()).unwrap_or_else(|| "-".into());
                out.push(format!("S|{}|{}|{}|{}|{}|{}", qs(&s.uri), ((s.duration as f64) * 1000.0).round() as i64, br,
                    b01(s.discontinuity), km, mu));
            }
        }
    }
    out
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let text = std::fs::read(&args[1]).expect("read corpus");
    std::panic::set_hook(Box::new(|_| {}));
    let stdout = std::io::stdout();
    let mut w = std::io::BufWriter::new(stdout.lock());
    for line in text.split(|&b| b == b'\n') {
        let Some(t) = line.iter().position(|&b| b == b'\t') else { continue };
        let name = String::from_utf8_lossy(&line[..t]).to_string();
        let hex = &line[t + 1..];
        let data: Vec<u8> = hex.chunks(2).map(|c| u8::from_str_radix(std::str::from_utf8(c).unwrap(), 16).unwrap()).collect();
        writeln!(w, "={}", name).unwrap();
        match std::panic::catch_unwind(|| dump(&data)) {
            Ok(lines) => {
                for l in lines {
                    writeln!(w, "{}", l).unwrap();
                }
            }
            Err(_) => writeln!(w, "PANIC|m3u8-rs").unwrap(),
        }
    }
}
