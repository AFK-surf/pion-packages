//! Reference oracles for the packages/webm red-team audit.
//!   dump  <file>          matroska-demuxer 0.6.1, canonical lines shared with the Pion harness
//!   symph <file>          symphonia-format-mkv 0.5.5 packets (audio tracks)
//!   batch <cases.bin>     matroska-demuxer verdict per `[u32 LE len][payload]` record (panics caught)
//!   bench <file> <iters>  matroska-demuxer full demux timing (parse + frame copy)
use matroska_demuxer::{Frame, MatroskaFile, TrackType};
use std::io::Cursor;
use std::{env, fs, panic, process, time::Instant};

fn fnv(mut h: u64, d: &[u8]) -> u64 {
    for &b in d {
        h = (h ^ b as u64).wrapping_mul(1099511628211);
    }
    h
}
const FNV0: u64 = 14695981039346656037;

fn tt(t: TrackType) -> i32 {
    match t {
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

fn dump(data: &[u8]) -> Result<String, String> {
    let mut out = String::new();
    let mut mkv = MatroskaFile::open(Cursor::new(data)).map_err(|e| format!("{e:?}"))?;
    let scale = mkv.info().timestamp_scale().get() as i64;
    out.push_str(&format!("OK scale={} tracks={}\n", scale, mkv.tracks().len()));
    for t in mkv.tracks() {
        let cp = t.codec_private().unwrap_or(&[]);
        out.push_str(&format!(
            "T {} {} {} {} {:016x} dd={}\n",
            t.track_number().get(),
            tt(t.track_type()),
            t.codec_id(),
            cp.len(),
            fnv(FNV0, cp),
            t.default_duration().map(|d| d.get()).unwrap_or(0)
        ));
    }
    let mut f = Frame::default();
    loop {
        match mkv.next_frame(&mut f) {
            Ok(true) => {}
            Ok(false) => break,
            Err(e) => {
                out.push_str(&format!("ERR next_frame {e:?}\n"));
                break;
            }
        }
        let pts_ns = (f.timestamp as i64).wrapping_mul(scale);
        out.push_str(&format!(
            "F {} {} {} {} {} {} {:016x}\n",
            f.track,
            f.data.len(),
            pts_ns,
            pts_ns / 1_000_000,
            f.duration.map(|d| (d as i64 * scale).to_string()).unwrap_or("?".into()),
            match f.is_keyframe {
                Some(true) => "1",
                Some(false) => "0",
                None => "?",
            },
            fnv(FNV0, &f.data)
        ));
    }
    Ok(out)
}

fn symph(data: Vec<u8>) -> Result<String, String> {
    use symphonia_core::formats::{FormatOptions, FormatReader};
    use symphonia_core::io::{MediaSourceStream, MediaSourceStreamOptions};
    let mss = MediaSourceStream::new(Box::new(Cursor::new(data)), MediaSourceStreamOptions::default());
    let mut r = symphonia_format_mkv::MkvReader::try_new(mss, &FormatOptions::default())
        .map_err(|e| format!("{e:?}"))?;
    let mut out = String::new();
    for t in r.tracks() {
        out.push_str(&format!("T {} tb={:?}\n", t.id, t.codec_params.time_base));
    }
    loop {
        match r.next_packet() {
            Ok(p) => out.push_str(&format!(
                "P {} {} {} {} {:016x}\n",
                p.track_id(),
                p.ts(),
                p.dur(),
                p.data.len(),
                fnv(FNV0, &p.data)
            )),
            Err(e) => {
                out.push_str(&format!("END {e:?}\n"));
                break;
            }
        }
    }
    Ok(out)
}

fn verdict(data: &[u8]) -> String {
    let r = panic::catch_unwind(|| -> Result<(usize, usize, u64), String> {
        let mut mkv = MatroskaFile::open(Cursor::new(data)).map_err(|e| format!("{e:?}"))?;
        let nt = mkv.tracks().len();
        let mut f = Frame::default();
        let mut n = 0usize;
        let mut h = FNV0;
        loop {
            match mkv.next_frame(&mut f) {
                Ok(true) => {
                    n += 1;
                    h = fnv(h, &f.data);
                    if n > 2_000_000 {
                        break;
                    }
                }
                Ok(false) => break,
                Err(e) => return Err(format!("frame#{n} {e:?}")),
            }
        }
        Ok((nt, n, h))
    });
    match r {
        Ok(Ok((nt, n, h))) => format!("OK t={nt} f={n} ph={h:016x}"),
        Ok(Err(e)) => {
            let k: String = e.chars().take_while(|c| c.is_alphanumeric()).collect();
            format!("ERR {k}")
        }
        Err(_) => "PANIC".into(),
    }
}

fn main() {
    panic::set_hook(Box::new(|_| {}));
    let a: Vec<String> = env::args().collect();
    if a.len() < 3 {
        eprintln!("usage: webm-audit-rust dump|symph|batch|bench <file> [iters]");
        process::exit(2);
    }
    let data = fs::read(&a[2]).expect("read");
    match a[1].as_str() {
        "dump" => match dump(&data) {
            Ok(s) => print!("{s}"),
            Err(e) => println!("ERR {e}"),
        },
        "symph" => match symph(data) {
            Ok(s) => print!("{s}"),
            Err(e) => println!("ERR {e}"),
        },
        "batch" => {
            // one flushed line per case; an allocation-failure abort inside matroska-demuxer kills the process,
            // so the driver resumes at `start` (argv[3]) after the last printed case
            use std::io::Write;
            let start: usize = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(0);
            let mut p = 0usize;
            let mut i = 0usize;
            let so = std::io::stdout();
            let mut so = so.lock();
            while p + 4 <= data.len() {
                let n = u32::from_le_bytes([data[p], data[p + 1], data[p + 2], data[p + 3]]) as usize;
                let rec = &data[p + 4..p + 4 + n];
                p += 4 + n;
                if i >= start {
                    writeln!(so, "{i} R:{}", verdict(rec)).unwrap();
                    so.flush().unwrap();
                }
                i += 1;
            }
        }
        "bench" => {
            let iters: usize = a[3].parse().unwrap();
            let t0 = Instant::now();
            let mut acc = 0usize;
            for _ in 0..iters {
                let mut mkv = MatroskaFile::open(Cursor::new(&data[..])).unwrap();
                let mut f = Frame::default();
                while mkv.next_frame(&mut f).unwrap() {
                    acc += 1;
                }
            }
            println!("BENCH rust iters={iters} ms={} acc={acc}", t0.elapsed().as_millis());
        }
        m => {
            eprintln!("unknown mode {m}");
            process::exit(2);
        }
    }
}
