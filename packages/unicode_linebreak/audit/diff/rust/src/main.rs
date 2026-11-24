//! Rust icu_segmenter =2.4.0 oracle for the RT-unicode-linebreak audit.
//!   oracle <cases>   one line per `<name>\t<hex>` case: break offsets `<off>,...` (`-` when none), using
//!                    `segment_utf8` (ill-formed UTF-8 is read as U+FFFD per maximal subpart), rule-based
//!                    segmenter without dictionaries / LSTM, UAX #14 default strictness and word option.
use icu_segmenter::options::{LineBreakOptions, LineBreakStrictness, LineBreakWordOption};
use icu_segmenter::LineSegmenter;
use std::io::{BufWriter, Write};

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let text = std::fs::read_to_string(&args[1]).expect("read cases");
    let mut opts = LineBreakOptions::default();
    opts.strictness = Some(LineBreakStrictness::Strict);
    opts.word_option = Some(LineBreakWordOption::Normal);
    let seg = LineSegmenter::new_for_non_complex_scripts(opts);
    let out = std::io::stdout();
    let mut w = BufWriter::new(out.lock());
    for line in text.lines() {
        let hx = match line.split_once('\t') {
            Some((_, h)) => h,
            None => continue,
        };
        let b = unhex(hx);
        let offs: Vec<String> = if b.is_empty() {
            vec![]
        } else {
            seg.segment_utf8(&b).skip(1).map(|o| o.to_string()).collect()
        };
        if offs.is_empty() {
            writeln!(w, "-").unwrap();
        } else {
            writeln!(w, "{}", offs.join(",")).unwrap();
        }
    }
}
