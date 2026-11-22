//! Red-team oracle: real Rust `imara-diff v0.2.0`.
//!
//! usage: imara_oracle cases <cases.bin>              -> per-case canonical dump (see FORMAT below)
//!        imara_oracle bench <before> <after> <algo> <iters> <ctx>
//!        imara_oracle multi <before> <iters> <after>...   (interner reuse via update_after)
//!
//! cases.bin framing: repeated `<before_len> <after_len>\n<before bytes><after bytes>`.
//! FORMAT (identical to the Pion runner, compared byte-for-byte):
//!   `#<i>\n` then for algo in [H, M]:
//!     `<algo>P <hunks>\n`  hunks after `postprocess_lines` (IndentHeuristic)
//!     `<algo>R <hunks>\n`  raw hunks (no postprocess)
//!     `<algo>S <hunks>\n`  postprocessed hunks again (Pion: non-windowed `diff_slices`)
//!     `<algo>U<ctx> <len>\n<unified text>` for ctx in CTXS
//! hunks are `b0-b1:a0-a1` separated by spaces.
use std::env;
use std::fmt::Write as _;
use std::fs;
use std::io::{self, Write};

use imara_diff::{Algorithm, BasicLineDiffPrinter, Diff, InternedInput, UnifiedDiffConfig};

const CTXS: [u32; 4] = [0, 1, 3, 25];

fn hunks_str(d: &Diff) -> String {
    let mut s = String::new();
    for h in d.hunks() {
        if !s.is_empty() {
            s.push(' ');
        }
        write!(s, "{}-{}:{}-{}", h.before.start, h.before.end, h.after.start, h.after.end).unwrap();
    }
    s
}

fn dump_case(out: &mut Vec<u8>, idx: usize, before: &str, after: &str) {
    out.extend_from_slice(format!("#{idx}\n").as_bytes());
    let input = InternedInput::new(before, after);
    for (tag, algo) in [("H", Algorithm::Histogram), ("M", Algorithm::Myers)] {
        let raw = Diff::compute(algo, &input);
        let mut pp = Diff::compute(algo, &input);
        pp.postprocess_lines(&input);
        out.extend_from_slice(format!("{tag}P {}\n", hunks_str(&pp)).as_bytes());
        out.extend_from_slice(format!("{tag}R {}\n", hunks_str(&raw)).as_bytes());
        // `S` = same postprocessed hunks; Pion side uses the non-windowed `diff_slices` path
        out.extend_from_slice(format!("{tag}S {}\n", hunks_str(&pp)).as_bytes());
        for ctx in CTXS {
            let mut cfg = UnifiedDiffConfig::default();
            cfg.context_len(ctx);
            let u = pp
                .unified_diff(&BasicLineDiffPrinter(&input.interner), cfg, &input)
                .to_string();
            out.extend_from_slice(format!("{tag}U{ctx} {}\n", u.len()).as_bytes());
            out.extend_from_slice(u.as_bytes());
        }
    }
}


fn parse_cases(buf: &[u8]) -> Vec<(&[u8], &[u8])> {
    let mut res = Vec::new();
    let mut p = 0;
    while p < buf.len() {
        let nl = p + buf[p..].iter().position(|&c| c == b'\n').expect("header");
        let hdr = std::str::from_utf8(&buf[p..nl]).unwrap();
        let mut it = hdr.split(' ');
        let bl: usize = it.next().unwrap().parse().unwrap();
        let al: usize = it.next().unwrap().parse().unwrap();
        let s = nl + 1;
        res.push((&buf[s..s + bl], &buf[s + bl..s + bl + al]));
        p = s + bl + al;
    }
    res
}

fn main() {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("cases") => {
            let buf = fs::read(&args[2]).expect("read cases");
            let mut out = Vec::new();
            for (i, (b, a)) in parse_cases(&buf).into_iter().enumerate() {
                let b = std::str::from_utf8(b).expect("cases must be UTF-8 for &str oracle");
                let a = std::str::from_utf8(a).expect("cases must be UTF-8 for &str oracle");
                dump_case(&mut out, i, b, a);
            }
            io::stdout().write_all(&out).unwrap();
        }
        Some("bench") => {
            let before = fs::read_to_string(&args[2]).unwrap();
            let after = fs::read_to_string(&args[3]).unwrap();
            let algo = match args[4].as_str() {
                "myers" => Algorithm::Myers,
                _ => Algorithm::Histogram,
            };
            let iters: usize = args[5].parse().unwrap();
            let ctx: u32 = args.get(6).map_or(3, |s| s.parse().unwrap());
            let mut total = 0u64;
            let mut last = String::new();
            for _ in 0..iters {
                let input = InternedInput::new(before.as_str(), after.as_str());
                let mut diff = Diff::compute(algo, &input);
                diff.postprocess_lines(&input);
                let mut cfg = UnifiedDiffConfig::default();
                cfg.context_len(ctx);
                let out = diff
                    .unified_diff(&BasicLineDiffPrinter(&input.interner), cfg, &input)
                    .to_string();
                total += out.len() as u64;
                last = out;
            }
            let mut h = io::stdout().lock();
            writeln!(h, "iters={iters} total_bytes={total}").unwrap();
            h.write_all(last.as_bytes()).unwrap();
        }
        Some("multi") => {
            // One `before` diffed against many `after`s, reusing the interner the way
            // imara-diff allows (`InternedInput::update_after`). Pion has no equivalent API.
            let before = fs::read_to_string(&args[2]).unwrap();
            let iters: usize = args[3].parse().unwrap();
            let afters: Vec<String> = args[4..].iter().map(|p| fs::read_to_string(p).unwrap()).collect();
            let mut input = InternedInput::new(before.as_str(), "");
            let mut diff = Diff::default();
            let mut total = 0u64;
            let mut last = String::new();
            for _ in 0..iters {
                for a in &afters {
                    input.update_after(imara_diff::sources::lines(a.as_str()));
                    diff.compute_with(
                        Algorithm::Histogram,
                        &input.before,
                        &input.after,
                        input.interner.num_tokens(),
                    );
                    diff.postprocess_lines(&input);
                    let out = diff
                        .unified_diff(&BasicLineDiffPrinter(&input.interner), UnifiedDiffConfig::default(), &input)
                        .to_string();
                    total += out.len() as u64;
                    last = out;
                }
            }
            let mut h = io::stdout().lock();
            writeln!(h, "iters={iters} total_bytes={total}").unwrap();
            h.write_all(last.as_bytes()).unwrap();
        }
        _ => {
            eprintln!("usage: imara_oracle cases <file> | bench <before> <after> <algo> <iters> [ctx]");
            std::process::exit(2);
        }
    }
}
