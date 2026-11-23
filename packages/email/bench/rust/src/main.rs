use mail_parser::MessageParser;
use std::env;
use std::fs;
use std::process;

#[inline]
fn mix(h: i64, v: i64) -> i64 {
    (h.wrapping_mul(131).wrapping_add(v)) % 1_000_000_007
}

fn hash_bytes(h0: i64, b: &[u8]) -> i64 {
    let mut h = mix(h0, b.len() as i64);
    for &x in b {
        h = mix(h, x as i64);
    }
    h
}

fn hash_str(h0: i64, s: &str) -> i64 {
    hash_bytes(h0, s.as_bytes())
}

fn bench_w1_mime(data: &[u8]) {
    let msgs: Vec<&[u8]> = data.split(|&b| b == 0).filter(|s| !s.is_empty()).collect();
    let parser = MessageParser::default();
    let mut total_msgs: i64 = 0;
    let mut total_att: i64 = 0;
    let mut checksum: i64 = 0;

    for _ in 0..20 {
        for raw in &msgs {
            let msg = match parser.parse(*raw) {
                Some(m) => m,
                None => process::exit(2),
            };
            total_msgs += 1;
            if let Some(subj) = msg.subject() {
                checksum = hash_str(checksum, subj);
            }
            if let Some(txt) = msg.body_text(0) {
                checksum = hash_str(checksum, txt.as_ref());
            }
            if let Some(html) = msg.body_html(0) {
                checksum = hash_str(checksum, html.as_ref());
            }
            for att in msg.attachments() {
                total_att += 1;
                checksum = hash_bytes(checksum, att.contents());
            }
        }
    }

    println!("mode=w1_mime");
    println!("msgs={}", total_msgs);
    println!("attachments={}", total_att);
    println!("checksum={}", checksum);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: rust_email_bench <mode> <corpus_path>");
        process::exit(1);
    }
    let data = fs::read(&args[2]).unwrap_or_else(|_| process::exit(1));
    match args[1].as_str() {
        "w1_mime" => bench_w1_mime(&data),
        _ => process::exit(1),
    }
}
