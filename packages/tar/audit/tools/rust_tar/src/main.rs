//! Rust `tar` 0.4.46 side of the packages/tar red-team audit.
//!
//!   rust_tar lite <file>             reduced dump: what Rust sees (type, path, link, size, uid, mtime, data)
//!   rust_tar write <out>             write a complex archive with tar::Builder (GNU long names, PAX, links...)
//!   rust_tar readbench <file> <n>    full-payload read benchmark (FNV over every byte)
//!   rust_tar scanbench <file> <n>    header-only scan benchmark
//!   rust_tar writebench <kind> <n>   write benchmark (tiny | big)
use std::io::{Cursor, Read};

fn fnv(mut h: u64, b: &[u8]) -> u64 {
    for &c in b {
        h = (h ^ c as u64).wrapping_mul(1099511628211);
    }
    h
}
const FNV0: u64 = 14695981039346656037;

fn hex(b: &[u8]) -> String {
    b.iter().map(|c| format!("{:02x}", c)).collect()
}

fn lite(data: &[u8]) -> String {
    let mut out = String::new();
    let mut ar = tar::Archive::new(Cursor::new(data));
    let entries = match ar.entries() {
        Ok(e) => e,
        Err(_) => return "ERR next\n".into(),
    };
    for e in entries {
        let mut e = match e {
            Ok(e) => e,
            Err(_) => {
                out.push_str("ERR next\n");
                return out;
            }
        };
        let tf = e.header().entry_type().as_byte();
        let name = hex(&e.path_bytes());
        let link = e.link_name_bytes().map(|l| hex(&l)).unwrap_or_default();
        let size = e.size();
        let uid = e.header().uid().map(|v| v as i64).unwrap_or(-999);
        let mtime = e.header().mtime().map(|v| v as i64).unwrap_or(-999);
        out.push_str(&format!("R tf={} name={} link={} size={} uid={} mtime={}\n", tf, name, link, size, uid, mtime));
        let mut buf = Vec::new();
        match e.read_to_end(&mut buf) {
            Ok(_) => out.push_str(&format!("D len={} fnv={:016x}\n", buf.len(), fnv(FNV0, &buf))),
            Err(_) => {
                out.push_str("ERR data\n");
                return out;
            }
        }
    }
    out.push_str("EOF\n");
    out
}

fn pattern(n: usize, seed: usize) -> Vec<u8> {
    (0..n).map(|i| ((i * 131 + seed) & 255) as u8).collect()
}

fn write_complex() -> Vec<u8> {
    let mut b = tar::Builder::new(Vec::new());
    let mut seed = 0;
    let mut add_file = |b: &mut tar::Builder<Vec<u8>>, path: &str, len: usize, gnu: bool, uid: u64, mtime: u64| {
        let mut h = if gnu { tar::Header::new_gnu() } else { tar::Header::new_ustar() };
        h.set_size(len as u64);
        h.set_mode(0o644);
        h.set_uid(uid);
        h.set_gid(uid);
        h.set_mtime(mtime);
        h.set_entry_type(tar::EntryType::Regular);
        seed += 1;
        b.append_data(&mut h, path, &pattern(len, seed)[..]).unwrap();
    };
    for n in [1usize, 99, 100, 101, 155, 156, 255, 256, 257, 400] {
        let name: String = "r".repeat(n);
        add_file(&mut b, &name, n % 700, true, 1000, 1_700_000_000);
        let nested = format!("{}/{}", "d".repeat(n / 2 + 1), "f".repeat(n - n / 2));
        add_file(&mut b, &nested, 513, true, 1000, 1_700_000_000);
        let ustar = format!("{}/{}", "u".repeat(n.min(150)), "x".repeat(n.min(99)));
        add_file(&mut b, &ustar, 7, false, 2097151, 8_589_934_591);
    }
    add_file(&mut b, "big-uid", 3, true, 1 << 40, 1 << 34); // base-256 numbers
    add_file(&mut b, "日本語/ファイル.txt", 11, true, 0, 0);
    // directories, links, devices
    for (ty, path, link) in [
        (tar::EntryType::Directory, "dir-only/", ""),
        (tar::EntryType::Symlink, "sym-long", &*"t".repeat(300)),
        (tar::EntryType::Link, &*"h".repeat(150), "dir-only/x"),
        (tar::EntryType::Char, "dev/null", ""),
        (tar::EntryType::Fifo, "fifo", ""),
    ] {
        let mut h = tar::Header::new_gnu();
        h.set_entry_type(ty);
        h.set_size(0);
        h.set_mode(0o755);
        h.set_mtime(1_600_000_000);
        if link.is_empty() {
            b.append_data(&mut h, path, &[][..]).unwrap();
        } else {
            b.append_link(&mut h, path, link).unwrap();
        }
    }
    // PAX extensions: path override, xattrs, sub-second mtime, custom keys
    b.append_pax_extensions([
        ("path", &b"pax/override/\xe6\x97\xa5\xe6\x9c\xac"[..]),
        ("mtime", &b"1700000000.123456789"[..]),
        ("SCHILY.xattr.user.k", &b"v\x00bin"[..]),
        ("comment", &b"rust wrote this"[..]),
    ])
    .unwrap();
    add_file(&mut b, "raw-name-replaced-by-pax", 33, false, 5, 5);
    b.append_pax_extensions([("uid", &b"4294967296"[..]), ("size", &b"9"[..])]).unwrap();
    add_file(&mut b, "pax-size-wins", 9, false, 1, 1);
    b.into_inner().unwrap()
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    match a[1].as_str() {
        "lite" => print!("{}", lite(&std::fs::read(&a[2]).unwrap())),
        "write" => std::fs::write(&a[2], write_complex()).unwrap(),
        "readbench" => {
            let data = std::fs::read(&a[2]).unwrap();
            let rounds: usize = a[3].parse().unwrap();
            let (mut entries, mut payload, mut h) = (0u64, 0u64, FNV0);
            let mut buf = Vec::new();
            for _ in 0..rounds {
                let mut ar = tar::Archive::new(Cursor::new(&data[..]));
                for e in ar.entries().unwrap() {
                    let mut e = e.unwrap();
                    entries += 1;
                    h = fnv(h, &e.path_bytes());
                    buf.clear();
                    e.read_to_end(&mut buf).unwrap();
                    payload += buf.len() as u64;
                    h = fnv(h, &buf);
                }
            }
            println!("entries={} payload={} fnv={:016x}", entries, payload, h);
        }
        "scanbench" => {
            let data = std::fs::read(&a[2]).unwrap();
            let rounds: usize = a[3].parse().unwrap();
            let (mut entries, mut sizes, mut h) = (0u64, 0u64, FNV0);
            for _ in 0..rounds {
                let mut ar = tar::Archive::new(Cursor::new(&data[..]));
                for e in ar.entries().unwrap() {
                    let e = e.unwrap();
                    entries += 1;
                    sizes += e.size();
                    h = fnv(h, &e.path_bytes());
                }
            }
            println!("entries={} sizes={} fnv={:016x}", entries, sizes, h);
        }
        "writebench" => {
            let rounds: usize = a[3].parse().unwrap();
            let mut total = 0usize;
            let tiny = pattern(16, 1);
            let big = pattern(64 << 20, 1);
            for _ in 0..rounds {
                let mut b = tar::Builder::new(Vec::new());
                match a[2].as_str() {
                    "tiny" => {
                        let d = &tiny;
                        for i in 0..100_000 {
                            let mut h = tar::Header::new_ustar();
                            h.set_size(16);
                            h.set_mode(0o644);
                            h.set_mtime(1_700_000_000);
                            b.append_data(&mut h, format!("tiny/{:06}.txt", i), &d[..]).unwrap();
                        }
                    }
                    "big" => {
                        let d = &big;
                        let mut h = tar::Header::new_ustar();
                        h.set_size(d.len() as u64);
                        h.set_mode(0o644);
                        h.set_mtime(1_700_000_000);
                        b.append_data(&mut h, "big.bin", &d[..]).unwrap();
                    }
                    _ => panic!("kind"),
                }
                total += b.into_inner().unwrap().len();
            }
            println!("bytes={}", total);
        }
        _ => panic!("mode"),
    }
}
