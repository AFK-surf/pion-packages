//! Reference oracle for the `packages/encoding` red-team audit: Mozilla `encoding_rs` 0.8.44.
//!
//! Reads the line protocol of `diff/gen.py` (one case per line) and writes one result line per case.
//! The Pion driver (`audit/src/main.pion`, mode `run`) implements the same protocol, and
//! `diff/compare.py` diffs the two outputs line by line.
//!
//!   D <enc> <opts> <chunks> <hex>   streaming decode; opts = [n|f][b|i] (fatal, ignore_bom)
//!                                   -> `<hex|-> <E|.>` (output, had_errors) or `ERR` (fatal error)
//!   S <enc> <hex>                   BOM-sniffing one-shot decode (`Encoding::decode`)
//!                                   -> `<hex|-> <encoding name> <E|.>`
//!   E <enc> s <hex utf8>            strict encode -> `OK <hex|->` or `ERR`
//!   E <enc> h <hex utf8>            WHATWG/HTML encode (output encoding + NCR) -> `<hex|-> <U|.>`
//!   L <hex label>                   `<for_label name|-> <for_label_no_replacement name|->`
//!   # ...                           echoed
//!
//! chunks: `w` whole; `k<N>` N-byte chunks then an empty last chunk; `e<N>` like `k<N>` with an empty
//! non-last chunk before every chunk; `x` explicit chunks (hex split on `.`); `r` feed everything with
//! last=false, reset(), decode again whole; `u` decode whole twice with the same decoder. For `r` and
//! `u` the oracle answer is a fresh whole decode (encoding_rs decoders are not reusable).

use encoding_rs::{CoderResult, DecoderResult, Encoding, EncoderResult};
use std::io::{BufRead, BufWriter, Write};

fn unhex(s: &str) -> Vec<u8> {
    if s == "-" {
        return Vec::new();
    }
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len() / 2);
    let v = |c: u8| -> u8 {
        match c {
            b'0'..=b'9' => c - b'0',
            b'a'..=b'f' => c - b'a' + 10,
            b'A'..=b'F' => c - b'A' + 10,
            _ => panic!("bad hex"),
        }
    };
    let mut i = 0;
    while i + 1 < b.len() {
        out.push(v(b[i]) << 4 | v(b[i + 1]));
        i += 2;
    }
    out
}

fn hex(b: &[u8]) -> String {
    if b.is_empty() {
        return "-".to_string();
    }
    const H: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(b.len() * 2);
    for &x in b {
        s.push(H[(x >> 4) as usize] as char);
        s.push(H[(x & 15) as usize] as char);
    }
    s
}

fn enc_of(name: &str) -> &'static Encoding {
    Encoding::for_label(name.as_bytes()).unwrap_or_else(|| panic!("unknown encoding {name}"))
}

fn chunks_of(spec: &str, hx: &str) -> (Vec<Vec<u8>>, bool) {
    // returns (chunks, empty_between)
    if spec == "x" {
        return (hx.split('.').map(unhex).collect(), false);
    }
    let data = unhex(hx);
    match spec.as_bytes()[0] {
        b'w' | b'r' | b'u' => (vec![data], false),
        b'k' | b'e' => {
            let n: usize = spec[1..].parse().unwrap();
            let v: Vec<Vec<u8>> = data.chunks(n).map(|c| c.to_vec()).collect();
            (v, spec.starts_with('e'))
        }
        _ => panic!("bad chunk spec"),
    }
}

fn decode(enc: &'static Encoding, fatal: bool, ignore_bom: bool, spec: &str, hx: &str) -> String {
    let (chunks, empty_between) = chunks_of(spec, hx);
    let mut dec = if ignore_bom { enc.new_decoder_without_bom_handling() } else { enc.new_decoder_with_bom_removal() };
    let mut out = String::new();
    let mut had = false;
    // The Pion side always passes an explicit final call for k/e (empty, last=true) and for x the last
    // piece is the last chunk. Feeding empty chunks never changes encoding_rs output.
    let mut feed: Vec<(Vec<u8>, bool)> = Vec::new();
    let nchunks = chunks.len();
    for (i, c) in chunks.into_iter().enumerate() {
        if empty_between {
            feed.push((Vec::new(), false));
        }
        let last = spec == "w" || spec == "r" || spec == "u" || (spec == "x" && i + 1 == nchunks);
        feed.push((c, last));
    }
    if spec.starts_with('k') || spec.starts_with('e') {
        feed.push((Vec::new(), true));
    }
    for (c, last) in feed {
        let mut src: &[u8] = &c;
        loop {
            if fatal {
                let need = dec.max_utf8_buffer_length_without_replacement(src.len()).unwrap();
                out.reserve(need + 16);
                let (r, read) = dec.decode_to_string_without_replacement(src, &mut out, last);
                src = &src[read..];
                match r {
                    DecoderResult::InputEmpty => break,
                    DecoderResult::OutputFull => continue,
                    DecoderResult::Malformed(_, _) => return "ERR".to_string(),
                }
            } else {
                let need = dec.max_utf8_buffer_length(src.len()).unwrap();
                out.reserve(need + 16);
                let (r, read, h) = dec.decode_to_string(src, &mut out, last);
                had |= h;
                src = &src[read..];
                match r {
                    CoderResult::InputEmpty => break,
                    CoderResult::OutputFull => continue,
                }
            }
        }
    }
    format!("{} {}", hex(out.as_bytes()), if had { "E" } else { "." })
}

fn utf16(s: &str, be: bool) -> Vec<u8> {
    let mut v = Vec::new();
    for u in s.encode_utf16() {
        let [a, b] = if be { u.to_be_bytes() } else { u.to_le_bytes() };
        v.push(a);
        v.push(b);
    }
    v
}

fn encode(enc: &'static Encoding, mode: &str, hx: &str) -> String {
    let raw = unhex(hx);
    let s = match std::str::from_utf8(&raw) {
        Ok(s) => s,
        Err(_) => return "BADINPUT".to_string(),
    };
    if mode == "h" {
        let (b, _, unm) = enc.encode(s);
        return format!("{} {}", hex(&b), if unm { "U" } else { "." });
    }
    // strict: UTF-16 encoders are not WHATWG encoders; the Pion API emits UTF-16 code units for them.
    if enc == encoding_rs::UTF_16LE {
        return format!("OK {}", hex(&utf16(s, false)));
    }
    if enc == encoding_rs::UTF_16BE {
        return format!("OK {}", hex(&utf16(s, true)));
    }
    let mut e = enc.output_encoding().new_encoder();
    let mut out: Vec<u8> = Vec::with_capacity(e.max_buffer_length_from_utf8_without_replacement(s.len()).unwrap() + 16);
    let mut src = s;
    loop {
        let cap = out.capacity();
        let len = out.len();
        out.resize(cap, 0);
        let (r, read, written) = e.encode_from_utf8_without_replacement(src, &mut out[len..], true);
        out.truncate(len + written);
        src = &src[read..];
        match r {
            EncoderResult::InputEmpty => break,
            EncoderResult::OutputFull => out.reserve(out.capacity() + 64),
            EncoderResult::Unmappable(_) => return "ERR".to_string(),
        }
    }
    format!("OK {}", hex(&out))
}

fn label(hx: &str) -> String {
    let l = unhex(hx);
    let a = Encoding::for_label(&l).map(|e| e.name()).unwrap_or("-");
    let b = Encoding::for_label_no_replacement(&l).map(|e| e.name()).unwrap_or("-");
    format!("{a} {b}")
}

fn sniff(enc: &'static Encoding, hx: &str) -> String {
    let data = unhex(hx);
    let (s, used, had) = enc.decode(&data);
    format!("{} {} {}", hex(s.as_bytes()), used.name(), if had { "E" } else { "." })
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() >= 5 && args[1] == "enctime" {
        // enctime <enc> <hex utf8 pattern> <bytes>: WHATWG encode of the repeated pattern
        let pat = String::from_utf8(unhex(&args[3])).unwrap();
        let reps = args[4].parse::<usize>().unwrap() / pat.len();
        let s = pat.repeat(reps);
        let t0 = std::time::Instant::now();
        let (b, _, unm) = enc_of(&args[2]).encode(&s);
        let ms = t0.elapsed().as_millis();
        println!("{} out={} unm={}", ms, b.len(), if unm { "U" } else { "." });
        return;
    }
    if args.len() >= 6 && args[1] == "time" {
        // time <enc> <hex pattern> <bytes> <chunk>: decode (BOM removal, replacement) of the repeated pattern
        let pat = unhex(&args[3]);
        let total: usize = args[4].parse().unwrap();
        let data: Vec<u8> = (0..total).map(|i| pat[i % pat.len()]).collect();
        let chunk: usize = args[5].parse().unwrap();
        let t0 = std::time::Instant::now();
        let mut dec = enc_of(&args[2]).new_decoder_with_bom_removal();
        let mut out = String::with_capacity(dec.max_utf8_buffer_length(total).unwrap());
        let mut had = false;
        let step = if chunk == 0 { total.max(1) } else { chunk };
        for c in data.chunks(step) {
            let (_, _, h) = dec.decode_to_string(c, &mut out, false);
            had |= h;
        }
        let (_, _, h) = dec.decode_to_string(&[], &mut out, true);
        had |= h;
        let ms = t0.elapsed().as_millis();
        println!("{} out={} err={}", ms, out.len(), if had { "E" } else { "." });
        return;
    }
    if args.len() < 3 || args[1] != "run" {
        eprintln!("usage: encoding_audit_oracle run <casefile>");
        std::process::exit(2);
    }
    let f = std::fs::File::open(&args[2]).expect("open case file");
    let stdout = std::io::stdout();
    let mut w = BufWriter::with_capacity(1 << 20, stdout.lock());
    for line in std::io::BufReader::new(f).lines() {
        let line = line.unwrap();
        if line.is_empty() {
            continue;
        }
        let p: Vec<&str> = line.split(' ').collect();
        let r = match p[0] {
            "D" => decode(enc_of(p[1]), p[2].as_bytes()[0] == b'f', p[2].as_bytes()[1] == b'i', p[3], p[4]),
            "S" => sniff(enc_of(p[1]), p[2]),
            "E" => encode(enc_of(p[1]), p[2], p[3]),
            "L" => label(p[1]),
            _ => line.clone(),
        };
        writeln!(w, "{r}").unwrap();
    }
}
