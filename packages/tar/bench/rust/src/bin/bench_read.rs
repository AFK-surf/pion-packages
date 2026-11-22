use std::env;
use std::fs;
use std::io::{Cursor, Read};
use tar::Archive;

#[inline]
fn fnv1a_bytes(mut h: u64, b: &[u8]) -> u64 {
    for &c in b {
        h = (h ^ (c as u64)).wrapping_mul(1099511628211);
    }
    h
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: rust_read <corpus.tar>");
        std::process::exit(1);
    }
    let data = fs::read(&args[1]).expect("read corpus");

    let rounds = 20usize;
    let mut total_entries: i64 = 0;
    let mut total_name_bytes: i64 = 0;
    let mut total_payload_bytes: i64 = 0;
    let mut checksum: u64 = 14695981039346656037;
    let mut buf: Vec<u8> = Vec::with_capacity(8192);

    for _ in 0..rounds {
        let mut ar = Archive::new(Cursor::new(data.as_slice()));
        for entry_res in ar.entries().expect("entries") {
            let mut entry = entry_res.expect("entry");
            total_entries += 1;
            let name_bytes = entry.path_bytes();
            total_name_bytes += name_bytes.len() as i64;
            checksum = fnv1a_bytes(checksum, &name_bytes);
            let sz = entry.header().size().expect("size");
            let tf = entry.header().entry_type().as_byte();
            checksum = (checksum ^ sz).wrapping_mul(1099511628211);
            checksum = (checksum ^ (tf as u64)).wrapping_mul(1099511628211);

            buf.clear();
            if sz > 0 {
                entry.read_to_end(&mut buf).expect("read body");
                total_payload_bytes += buf.len() as i64;
                checksum = (checksum ^ (buf[0] as u64)).wrapping_mul(1099511628211);
                checksum = (checksum ^ (buf[buf.len() - 1] as u64)).wrapping_mul(1099511628211);
            }
        }
    }

    println!("rounds={}", rounds);
    println!("entries={}", total_entries);
    println!("name_bytes={}", total_name_bytes);
    println!("payload_bytes={}", total_payload_bytes);
    println!("checksum={}", checksum);
}
