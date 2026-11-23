use std::env;
use std::fs;
use std::io::{Cursor, Read, Write};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: rust_bench <read|write|lookup> <file> <iters>");
        std::process::exit(1);
    }
    let mode = &args[1];
    let path = &args[2];
    let iters: usize = args[3].parse().expect("valid iters");
    let data = fs::read(path).expect("read input");

    match mode.as_str() {
        "read" => {
            let mut total_files: u64 = 0;
            let mut total_bytes: u64 = 0;
            let mut xor_crc: u32 = 0;
            let mut buf = Vec::new();
            for _ in 0..iters {
                let mut archive = ZipArchive::new(Cursor::new(&data)).expect("open zip");
                for i in 0..archive.len() {
                    let mut file = archive.by_index(i).expect("by_index");
                    let crc = file.crc32();
                    buf.clear();
                    file.read_to_end(&mut buf).expect("read_to_end");
                    total_files += 1;
                    total_bytes += buf.len() as u64;
                    xor_crc ^= crc;
                }
            }
            println!(
                "mode=read files={} total_bytes={} xor_crc={}",
                total_files, total_bytes, xor_crc
            );
        }
        "write" => {
            let count = u32::from_le_bytes(data[0..4].try_into().unwrap()) as usize;
            let mut names = Vec::with_capacity(count);
            let mut payloads: Vec<&[u8]> = Vec::with_capacity(count);
            let mut pos = 4usize;
            for _ in 0..count {
                let nlen = u16::from_le_bytes(data[pos..pos + 2].try_into().unwrap()) as usize;
                pos += 2;
                names.push(std::str::from_utf8(&data[pos..pos + nlen]).unwrap().to_string());
                pos += nlen;
                let dlen = u32::from_le_bytes(data[pos..pos + 4].try_into().unwrap()) as usize;
                pos += 4;
                payloads.push(&data[pos..pos + dlen]);
                pos += dlen;
            }

            let opts = SimpleFileOptions::default()
                .compression_method(CompressionMethod::Deflated)
                .compression_level(Some(6));
            let mut last_zip = Vec::new();
            for _ in 0..iters {
                let mut cursor = Cursor::new(Vec::new());
                {
                    let mut zw = ZipWriter::new(&mut cursor);
                    for i in 0..count {
                        zw.start_file(&names[i], opts).expect("start_file");
                        zw.write_all(payloads[i]).expect("write_all");
                    }
                    zw.finish().expect("finish");
                }
                last_zip = cursor.into_inner();
            }
            let mut archive = ZipArchive::new(Cursor::new(&last_zip)).expect("verify open");
            let mut total_uncomp: u64 = 0;
            let mut xor_crc: u32 = 0;
            for i in 0..archive.len() {
                let f = archive.by_index_raw(i).expect("by_index_raw");
                total_uncomp += f.size();
                xor_crc ^= f.crc32();
            }
            println!(
                "mode=write files={} total_uncomp={} xor_crc={}",
                archive.len(),
                total_uncomp,
                xor_crc
            );
        }
        "lookup" => {
            let mut queries = Vec::with_capacity(20000);
            let mut rng: i64 = 123456789;
            for _ in 0..20000 {
                rng = (rng.wrapping_mul(1103515245).wrapping_add(12345)) & 0x7FFFFFFF;
                let idx = (rng % 20000) as usize;
                queries.push(format!("dir_{:02}/file_{:05}.txt", idx % 100, idx));
            }
            let mut total_lookups: u64 = 0;
            let mut total_bytes: u64 = 0;
            let mut acc: u64 = 0;
            let mut buf = Vec::with_capacity(128);
            for _ in 0..iters {
                let mut archive = ZipArchive::new(Cursor::new(&data)).expect("open zip");
                for q in &queries {
                    let mut f = archive.by_name(q).expect("by_name");
                    buf.clear();
                    f.read_to_end(&mut buf).expect("read");
                    total_lookups += 1;
                    total_bytes += buf.len() as u64;
                    acc += buf[6] as u64;
                }
            }
            println!(
                "mode=lookup lookups={} total_bytes={} checksum={}",
                total_lookups, total_bytes, acc
            );
        }
        _ => {
            eprintln!("unknown mode: {}", mode);
            std::process::exit(1);
        }
    }
}
