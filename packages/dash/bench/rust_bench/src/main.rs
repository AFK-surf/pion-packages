use std::env;
use std::fmt::Write as _;
use std::fs;
use std::process;
use std::time::Duration;

fn fnv1a_64_bytes(data: &[u8]) -> u64 {
    let mut h: u64 = 14695981039346656037;
    for &b in data {
        h = (h ^ (b as u64)).wrapping_mul(1099511628211);
    }
    h
}

fn opt_s(v: &Option<String>) -> &str {
    match v {
        Some(s) => s.as_str(),
        None => "-",
    }
}

fn opt_dur_us(v: &Option<Duration>) -> String {
    match v {
        Some(d) => d.as_micros().to_string(),
        None => "-".to_string(),
    }
}

fn opt_u64(v: &Option<u64>) -> String {
    match v {
        Some(x) => x.to_string(),
        None => "-".to_string(),
    }
}

fn eval_corpus_once(docs: &[&str]) -> String {
    let mut out = String::with_capacity(docs.len() * 512);
    for &doc in docs {
        match dash_mpd_core::parse(doc) {
            Err(e) => {
                let _ = writeln!(out, "ERR|{e}");
            }
            Ok(m) => {
                let mpd_type = m.mpdtype.as_deref().unwrap_or("static");
                let _ = writeln!(
                    out,
                    "MPD|id={}|type={}|dur={}|mbt={}|mup={}|tsbd={}|spd={}|bu={}|loc={}|utc={}|periods={}",
                    opt_s(&m.id),
                    mpd_type,
                    opt_dur_us(&m.mediaPresentationDuration),
                    opt_dur_us(&m.minBufferTime),
                    opt_dur_us(&m.minimumUpdatePeriod),
                    opt_dur_us(&m.timeShiftBufferDepth),
                    opt_dur_us(&m.suggestedPresentationDelay),
                    m.base_url.len(),
                    m.locations.len(),
                    m.UTCTiming.len(),
                    m.periods.len(),
                );
                for p in &m.periods {
                    let _ = writeln!(
                        out,
                        "  P|id={}|start={}|dur={}|as={}",
                        opt_s(&p.id),
                        opt_dur_us(&p.start),
                        opt_dur_us(&p.duration),
                        p.adaptations.len(),
                    );
                    for a in &p.adaptations {
                        let pssh_cnt: usize = a
                            .ContentProtection
                            .iter()
                            .map(|cp| cp.cenc_pssh.len())
                            .sum();
                        let _ = write!(
                            out,
                            "    AS|id={}|ct={}|mime={}|lang={}|roles={}|cp={}|pssh={}|reps={}",
                            opt_s(&a.id),
                            opt_s(&a.contentType),
                            opt_s(&a.mimeType),
                            opt_s(&a.lang),
                            a.Role.len(),
                            a.ContentProtection.len(),
                            pssh_cnt,
                            a.representations.len(),
                        );
                        if let Some(st) = &a.SegmentTemplate {
                            let tl_len = st
                                .SegmentTimeline
                                .as_ref()
                                .map(|tl| tl.segments.len())
                                .unwrap_or(0);
                            let _ = write!(
                                out,
                                "|st_ts={}|st_tl={}",
                                opt_u64(&st.timescale),
                                tl_len,
                            );
                        }
                        out.push('\n');
                        for r in &a.representations {
                            let _ = write!(
                                out,
                                "      R|id={}|bw={}|w={}|h={}|fr={}|codecs={}",
                                opt_s(&r.id),
                                r.bandwidth.unwrap_or(0),
                                opt_u64(&r.width),
                                opt_u64(&r.height),
                                opt_s(&r.frameRate),
                                opt_s(&r.codecs),
                            );
                            if let Some(sb) = &r.SegmentBase {
                                let init_range = sb
                                    .Initialization
                                    .as_ref()
                                    .and_then(|i| i.range.as_deref())
                                    .unwrap_or("-");
                                let _ = write!(
                                    out,
                                    "|sb_ir={}|sb_init={}",
                                    opt_s(&sb.indexRange),
                                    init_range,
                                );
                            }
                            if let Some(sl) = &r.SegmentList {
                                let _ = write!(out, "|sl_urls={}", sl.segment_urls.len());
                            }
                            out.push('\n');
                        }
                    }
                }
            }
        }
    }
    out
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: rust_dash_bench <corpus_file> <iters>");
        process::exit(1);
    }
    let path = &args[1];
    let iters: usize = args[2].parse().unwrap_or(0);
    let data = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("failed to read {path}: {e}");
        process::exit(1);
    });
    let docs: Vec<&str> = data.split("\n===MPD===\n").filter(|s| !s.is_empty()).collect();
    if iters == 0 {
        println!("{}", eval_corpus_once(&docs));
        return;
    }
    let mut last = String::new();
    for _ in 0..iters {
        last = eval_corpus_once(&docs);
    }
    println!(
        "cases={} iters={} bytes={} fnv64={:016x}",
        docs.len(),
        iters,
        last.len(),
        fnv1a_64_bytes(last.as_bytes()),
    );
}
