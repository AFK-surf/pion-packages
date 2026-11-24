//! Rust unicode-segmentation oracle for the RT-unicode-segment audit (see ../../../REPORT.md).
//! Input: lines `<name>\t<hex bytes>`. Output per line: `=<name>`, `V <unicode version>`, `G` / `W` / `S`
//! boundary lists and `U` unicode_word spans, in the exact format of audit/src/main.pion.
//! Ill-formed UTF-8 is mapped the way packages/unicode_segment documents it (every byte that does not start a
//! well-formed sequence is one U+FFFD of length 1): the oracle substitutes a 3-byte U+FFFD per such byte and maps
//! the offsets back, so Pion and Rust are compared on the same scalar sequence.
use std::io::{BufRead, Write};
use unicode_segmentation::UnicodeSegmentation;

fn unhex(h: &str) -> Vec<u8> {
    if h == "-" {
        return Vec::new();
    }
    (0..h.len() / 2).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap()).collect()
}

/// Returns (valid string, map from every byte offset of it that starts a char (and its len) to the original offset).
fn lossy(b: &[u8]) -> (String, Vec<usize>) {
    let mut out = String::new();
    let mut map = Vec::new(); // map[new_offset] = orig_offset, defined at char starts and at the end
    let mut i = 0;
    while i < b.len() {
        let mut taken = 0;
        for l in 1..=4 {
            if i + l <= b.len() {
                if let Ok(s) = std::str::from_utf8(&b[i..i + l]) {
                    if s.chars().count() == 1 {
                        taken = l;
                        break;
                    }
                }
            }
        }
        let piece: String = if taken > 0 { String::from_utf8(b[i..i + taken].to_vec()).unwrap() } else { "\u{FFFD}".into() };
        while map.len() < out.len() {
            map.push(usize::MAX);
        }
        map.push(i);
        for _ in 1..piece.len() {
            map.push(usize::MAX);
        }
        out.push_str(&piece);
        i += if taken > 0 { taken } else { 1 };
    }
    map.push(b.len());
    (out, map)
}

fn m(map: &[usize], o: usize) -> usize {
    let v = map[o];
    assert!(v != usize::MAX, "boundary inside a char");
    v
}

fn bounds(tag: &str, starts: Vec<usize>, n: usize, map: &[usize]) -> String {
    let mut s = String::from(tag);
    if !starts.is_empty() {
        for b in starts {
            s.push(' ');
            s.push_str(&m(map, b).to_string());
        }
        s.push(' ');
        s.push_str(&m(map, n).to_string());
    }
    s
}

/// `cursor <hex unit> <units>`: the same next_/prev_ boundary walk as the audit CLI's `cursor` mode, with
/// GraphemeCursor (prints `<bytes> <us> <steps>`).
fn cursor(unit_hex: &str, units: usize) {
    let s = String::from_utf8(unhex(unit_hex)).unwrap().repeat(units);
    let t = std::time::Instant::now();
    let mut steps = 0;
    let mut c = unicode_segmentation::GraphemeCursor::new(0, s.len(), true);
    while let Ok(Some(_)) = c.next_boundary(&s, 0) {
        steps += 1;
    }
    let mut c = unicode_segmentation::GraphemeCursor::new(s.len(), s.len(), true);
    while let Ok(Some(_)) = c.prev_boundary(&s, 0) {
        steps += 1;
    }
    println!("{} {} {}", s.len(), t.elapsed().as_micros(), steps);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() == 4 && args[1] == "cursor" {
        return cursor(&args[2], args[3].parse().unwrap());
    }
    let path = std::env::args().nth(1).expect("usage: useg_oracle <cases> | cursor <hex unit> <units>");
    let f = std::io::BufReader::new(std::fs::File::open(path).unwrap());
    let stdout = std::io::stdout();
    let mut o = std::io::BufWriter::new(stdout.lock());
    let (a, b, c) = unicode_segmentation::UNICODE_VERSION;
    for line in f.lines() {
        let line = line.unwrap();
        let Some((name, hex)) = line.split_once('\t') else { continue };
        let (s, map) = lossy(&unhex(hex));
        let n = s.len();
        writeln!(o, "={}", name).unwrap();
        writeln!(o, "V {}.{}.{}", a, b, c).unwrap();
        writeln!(o, "{}", bounds("G", s.grapheme_indices(true).map(|x| x.0).collect(), n, &map)).unwrap();
        writeln!(o, "{}", bounds("W", s.split_word_bound_indices().map(|x| x.0).collect(), n, &map)).unwrap();
        let mut u = String::from("U");
        for (st, w) in s.unicode_word_indices() {
            u.push_str(&format!(" {}-{}", m(&map, st), m(&map, st + w.len())));
        }
        writeln!(o, "{}", u).unwrap();
        writeln!(o, "{}", bounds("S", s.split_sentence_bound_indices().map(|x| x.0).collect(), n, &map)).unwrap();
    }
}
