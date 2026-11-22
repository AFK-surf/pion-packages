//! Reference oracle for the red-team audit: real Rust pulldown-cmark 0.13.1.
//!
//! batch <in> : records `<mask>\t<len>\n<bytes>` -> `<len>\n<html>` per record
//! html <in> <mask> : render one file
//! events <in> <mask> : Debug-dump the event stream with source offsets
use pulldown_cmark::{html, Options, Parser};
use std::io::{self, Write};

fn opts(mask: u32) -> Options {
    let mut o = Options::empty();
    let map = [
        (1, Options::ENABLE_TABLES),
        (2, Options::ENABLE_STRIKETHROUGH),
        (4, Options::ENABLE_TASKLISTS),
        // 8 = GFM autolink literals: pulldown-cmark 0.13.1 has no such option
        (16, Options::ENABLE_SMART_PUNCTUATION),
        // 32 = CJK-friendly emphasis: not in pulldown-cmark 0.13.1
        (64, Options::ENABLE_FOOTNOTES),
        (128, Options::ENABLE_HEADING_ATTRIBUTES),
        (256, Options::ENABLE_YAML_STYLE_METADATA_BLOCKS),
        (512, Options::ENABLE_PLUSES_DELIMITED_METADATA_BLOCKS),
        (1024, Options::ENABLE_MATH),
        (2048, Options::ENABLE_GFM),
        (4096, Options::ENABLE_DEFINITION_LIST),
        (8192, Options::ENABLE_SUPERSCRIPT),
        (16384, Options::ENABLE_SUBSCRIPT),
        (32768, Options::ENABLE_WIKILINKS),
        (65536, Options::ENABLE_OLD_FOOTNOTES),
    ];
    for (bit, f) in map {
        if mask & bit != 0 {
            o.insert(f);
        }
    }
    o
}

fn render(src: &str, mask: u32) -> String {
    let mut out = String::with_capacity(src.len() * 3 / 2);
    html::push_html(&mut out, Parser::new_ext(src, opts(mask)));
    out
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let data = std::fs::read(&a[2]).expect("read");
    let mut so = io::BufWriter::new(io::stdout().lock());
    match a[1].as_str() {
        "batch" => {
            let mut i = 0;
            while i < data.len() {
                let nl = i + data[i..].iter().position(|&b| b == b'\n').unwrap();
                let hdr = std::str::from_utf8(&data[i..nl]).unwrap();
                let (m, l) = hdr.split_once('\t').unwrap();
                let (mask, len): (u32, usize) = (m.parse().unwrap(), l.parse().unwrap());
                let body = &data[nl + 1..nl + 1 + len];
                let src = String::from_utf8_lossy(body);
                let h = render(&src, mask);
                write!(so, "{}\n", h.len()).unwrap();
                so.write_all(h.as_bytes()).unwrap();
                i = nl + 1 + len;
            }
        }
        "html" => {
            let src = String::from_utf8_lossy(&data);
            so.write_all(render(&src, a[3].parse().unwrap()).as_bytes()).unwrap();
        }
        "events" => {
            let src = String::from_utf8_lossy(&data);
            for (ev, r) in Parser::new_ext(&src, opts(a[3].parse().unwrap())).into_offset_iter() {
                writeln!(so, "{:?} {:?}", r, ev).unwrap();
            }
        }
        _ => panic!("mode"),
    }
}
