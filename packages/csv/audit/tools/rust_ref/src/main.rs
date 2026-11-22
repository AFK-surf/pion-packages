//! Rust `csv =1.4.0` reference for the red-team differential (see ../../../diff/fuzz_diff.py).
//!
//! Usage: rust_ref CASEFILE  (one case per line, format documented in diff/caseio.py)
//! Output per case:
//!   #<id>
//!   H <fields> | HE <err>          headers()
//!   R <fields> / P <byte> <line> <record>   one per record (read_record into a reused StringRecord)
//!   E <err> [@ <byte> <line> <record>]      error, then reading continues (max 64 errors)
//!   W <hex> | WE <err>              writer output
//!   Z
use std::io::Write;

fn hex(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        s.push_str(&format!("{:02x}", x));
    }
    s
}

fn unhex(s: &str) -> Vec<u8> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len() / 2);
    let mut i = 0;
    while i + 1 < b.len() {
        let h = (b[i] as char).to_digit(16).unwrap() as u8;
        let l = (b[i + 1] as char).to_digit(16).unwrap() as u8;
        out.push(h * 16 + l);
        i += 2;
    }
    out
}

fn fields_str<'a, I: Iterator<Item = &'a [u8]>>(it: I) -> String {
    let parts: Vec<String> = it.map(|f| format!("x{}", hex(f))).collect();
    if parts.is_empty() {
        "~".to_string()
    } else {
        parts.join(".")
    }
}

fn err_str(e: &csv::Error) -> String {
    let pos = |p: Option<&csv::Position>| match p {
        Some(p) => format!(" @ {} {} {}", p.byte(), p.line(), p.record()),
        None => String::new(),
    };
    match e.kind() {
        csv::ErrorKind::Utf8 { pos: p, err } => {
            format!(
                "U8 {} {}{}",
                err.field(),
                err.valid_up_to(),
                pos(p.as_ref())
            )
        }
        csv::ErrorKind::UnequalLengths {
            pos: p,
            expected_len,
            len,
        } => {
            format!("UL {} {}{}", expected_len, len, pos(p.as_ref()))
        }
        other => format!("OTHER {:?}", other).replace('\n', " "),
    }
}

struct Cfg {
    delim: u8,
    quote: u8,
    dq: bool,
    esc: Option<u8>,
    cmt: Option<u8>,
    quoting: bool,
    trim: csv::Trim,
    term: csv::Terminator,
    hdr: bool,
    flex: bool,
    style: csv::QuoteStyle,
}

fn opt(v: i32) -> Option<u8> {
    if v < 0 {
        None
    } else {
        Some(v as u8)
    }
}

fn parse_cfg(t: &[&str]) -> Cfg {
    let n = |i: usize| t[i].parse::<i32>().unwrap();
    Cfg {
        delim: n(0) as u8,
        quote: n(1) as u8,
        dq: n(2) != 0,
        esc: opt(n(3)),
        cmt: opt(n(4)),
        quoting: n(5) != 0,
        trim: match n(6) {
            0 => csv::Trim::None,
            1 => csv::Trim::Headers,
            2 => csv::Trim::Fields,
            _ => csv::Trim::All,
        },
        term: match n(7) {
            -1 => csv::Terminator::CRLF,
            -2 => csv::Terminator::Any(b'\n'),
            b => csv::Terminator::Any(b as u8),
        },
        hdr: n(8) != 0,
        flex: n(9) != 0,
        style: match n(10) {
            0 => csv::QuoteStyle::Necessary,
            1 => csv::QuoteStyle::Always,
            2 => csv::QuoteStyle::NonNumeric,
            _ => csv::QuoteStyle::Never,
        },
    }
}

fn run_read(out: &mut String, c: &Cfg, input: &[u8]) {
    let mut b = csv::ReaderBuilder::new();
    b.delimiter(c.delim)
        .quote(c.quote)
        .double_quote(c.dq)
        .escape(c.esc)
        .comment(c.cmt)
        .quoting(c.quoting)
        .trim(c.trim)
        .terminator(c.term)
        .has_headers(c.hdr)
        .flexible(c.flex);
    let mut rdr = b.from_reader(input);
    match rdr.headers() {
        Ok(h) => out.push_str(&format!(
            "H {}\n",
            fields_str(h.iter().map(|s| s.as_bytes()))
        )),
        Err(e) => out.push_str(&format!("HE {}\n", err_str(&e))),
    }
    let mut rec = csv::StringRecord::new();
    let mut errs = 0;
    let mut n = 0;
    loop {
        match rdr.read_record(&mut rec) {
            Ok(true) => {
                out.push_str(&format!(
                    "R {}\n",
                    fields_str(rec.iter().map(|s| s.as_bytes()))
                ));
                let p = rec.position().unwrap();
                out.push_str(&format!("P {} {} {}\n", p.byte(), p.line(), p.record()));
                n += 1;
                if n > 100000 {
                    break;
                }
            }
            Ok(false) => break,
            Err(e) => {
                out.push_str(&format!("E {}\n", err_str(&e)));
                errs += 1;
                if errs >= 64 {
                    break;
                }
            }
        }
    }
}

fn run_write(out: &mut String, c: &Cfg, payload: &str) {
    let mut b = csv::WriterBuilder::new();
    b.delimiter(c.delim)
        .quote(c.quote)
        .double_quote(c.dq)
        .escape(c.esc.unwrap_or(b'\\'))
        .comment(c.cmt)
        .terminator(c.term)
        .flexible(c.flex)
        .quote_style(c.style)
        .has_headers(false);
    let mut w = b.from_writer(vec![]);
    for r in payload.split('/') {
        let fields: Vec<Vec<u8>> = if r == "~" {
            vec![]
        } else {
            r.split('.').map(|f| unhex(&f[1..])).collect()
        };
        if let Err(e) = w.write_record(&fields) {
            out.push_str(&format!("WE {}\n", err_str(&e)));
            return;
        }
    }
    let v = w.into_inner().unwrap();
    out.push_str(&format!("W {}\n", hex(&v)));
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: rust_ref CASEFILE");
    let data = std::fs::read_to_string(&path).unwrap();
    let mut out = String::new();
    for line in data.lines() {
        if line.is_empty() {
            continue;
        }
        let t: Vec<&str> = line.split(' ').collect();
        out.push_str(&format!("#{}\n", t[0]));
        let cfg = parse_cfg(&t[2..13]);
        let payload = t[13];
        if t[1] == "r" {
            let input = if payload == "-" {
                vec![]
            } else {
                unhex(payload)
            };
            run_read(&mut out, &cfg, &input);
        } else {
            run_write(&mut out, &cfg, payload);
        }
        out.push_str("Z\n");
    }
    std::io::stdout().write_all(out.as_bytes()).unwrap();
}
