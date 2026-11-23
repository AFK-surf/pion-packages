// Rust zip =2.2.3 reference for the packages/zip red-team audit.
// Modes: batch <cases.bin> | file <zip> | paths <names.bin> | verify <zip>
use std::io::{Cursor, Read};

fn records(b: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    let mut p = 0usize;
    while p + 4 <= b.len() {
        let n = u32::from_le_bytes(b[p..p + 4].try_into().unwrap()) as usize;
        p += 4;
        out.push(&b[p..(p + n).min(b.len())]);
        p += n;
    }
    out
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02x}", x)).collect()
}

fn line(data: &[u8]) -> String {
    let r = std::panic::catch_unwind(|| {
        let mut a = match zip::ZipArchive::new(Cursor::new(data)) {
            Ok(a) => a,
            Err(e) => return format!("ERR {}", e.to_string().replace(' ', "_")),
        };
        let mut s = format!("OK n={}", a.len());
        for i in 0..a.len() {
            let pre = a.name_for_index(i).unwrap_or("").as_bytes().to_vec();
            match a.by_index(i) {
                Err(_) => {
                    let n = pre;
                    s.push_str(&format!(" |{}:ERR:open", hex(&n)));
                }
                Ok(mut f) => {
                    let n = f.name_raw().to_vec();
                    let mut buf = Vec::new();
                    match f.read_to_end(&mut buf) {
                        Ok(_) => s.push_str(&format!(
                            " |{}:OK:{}:{}",
                            hex(&n),
                            buf.len(),
                            crc32fast::hash(&buf)
                        )),
                        Err(_) => s.push_str(&format!(" |{}:ERR:read", hex(&n))),
                    }
                }
            }
        }
        s
    });
    r.unwrap_or_else(|_| "PANIC".to_string())
}

fn verify(data: &[u8]) {
    let mut a = match zip::ZipArchive::new(Cursor::new(data)) {
        Ok(a) => a,
        Err(e) => {
            println!("ERR {}", e);
            return;
        }
    };
    println!("OK n={} comment_len={}", a.len(), a.comment().len());
    for i in 0..a.len() {
        match a.by_index(i) {
            Err(e) => println!("E #{} ERR:{}", i, e),
            Ok(mut f) => {
                let mut n = f.name().to_string();
                if n.len() > 64 {
                    n = format!("{}...({})", &n[..16], n.len());
                }
                let t = f.last_modified().map(|d| format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}", d.year(), d.month(), d.day(), d.hour(), d.minute(), d.second())).unwrap_or_default();
                let mode = f.unix_mode().map(|m| format!("{:o}", m)).unwrap_or_default();
                let mut buf = Vec::new();
                let res = match f.read_to_end(&mut buf) {
                    Ok(_) => format!("OK:{}:{}", buf.len(), crc32fast::hash(&buf)),
                    Err(e) => format!("ERR:{}", e),
                };
                println!("E {:?} method={:?} mtime={} mode={} {}", n, f.compression(), t, mode, res);
            }
        }
    }
}

fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let args: Vec<String> = std::env::args().collect();
    let data = std::fs::read(&args[2]).expect("read");
    let mut out = String::new();
    match args[1].as_str() {
        "batch" => {
            for r in records(&data) {
                out.push_str(&line(r));
                out.push('\n');
            }
        }
        "file" => {
            out.push_str(&line(&data));
            out.push('\n');
        }
        "verify" => verify(&data),
        "paths" => {
            // input is a zip whose entry names are the candidate paths;
            // zip's own notion of a safe extraction path is ZipFile::enclosed_name()
            let mut a = zip::ZipArchive::new(Cursor::new(&data[..])).expect("paths zip");
            for i in 0..a.len() {
                let ok = match a.by_index_raw(i) {
                    Ok(f) => f.enclosed_name().is_some(),
                    Err(_) => false,
                };
                out.push_str(if ok { "OK\n" } else { "ERR\n" });
            }
        }
        _ => std::process::exit(2),
    }
    print!("{}", out);
}
