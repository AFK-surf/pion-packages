use std::env;
use std::fs;
use std::process;

fn fnv_byte(h: u64, v: u8) -> u64 {
    (h ^ (v as u64)).wrapping_mul(1099511628211)
}

fn fnv_slice(mut h: u64, b: &[u8]) -> u64 {
    for &v in b {
        h = (h ^ (v as u64)).wrapping_mul(1099511628211);
    }
    h
}

fn read_u16_be(b: &[u8], off: usize) -> usize {
    u16::from_be_bytes([b[off], b[off + 1]]) as usize
}

fn read_u32_be(b: &[u8], off: usize) -> u32 {
    u32::from_be_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]])
}

fn summarize_sfnt(sfnt: &[u8]) -> (u32, usize, u64, usize, usize, u64) {
    let flavor = read_u32_be(sfnt, 0);
    let num_tables = read_u16_be(sfnt, 4);
    let mut tables_h: u64 = 14695981039346656037;
    let mut glyf_off: Option<usize> = None;
    let mut loca_off: Option<usize> = None;
    let mut head_off: Option<usize> = None;
    let mut maxp_off: Option<usize> = None;

    for i in 0..num_tables {
        let rec = 12 + i * 16;
        let tag = read_u32_be(sfnt, rec);
        let off = read_u32_be(sfnt, rec + 8) as usize;
        let len = read_u32_be(sfnt, rec + 12) as usize;
        tables_h = fnv_slice(tables_h, &sfnt[rec..rec + 4]);
        if tag == 0x676C7966 {
            glyf_off = Some(off);
        } else if tag == 0x6C6F6361 {
            loca_off = Some(off);
        } else if tag == 0x68656164 {
            head_off = Some(off);
            if len >= 12 {
                tables_h = fnv_slice(tables_h, &sfnt[off..off + 8]);
                tables_h = fnv_slice(tables_h, &sfnt[off + 12..off + len]);
            }
        } else {
            if tag == 0x6D617870 {
                maxp_off = Some(off);
            }
            tables_h = fnv_slice(tables_h, &sfnt[off..off + len]);
        }
    }

    let mut num_glyphs = 0usize;
    let mut non_empty = 0usize;
    let mut glyf_h: u64 = 14695981039346656037;
    if let (Some(go), Some(lo), Some(ho), Some(mo)) = (glyf_off, loca_off, head_off, maxp_off) {
        num_glyphs = read_u16_be(sfnt, mo + 4);
        let idx_fmt = read_u16_be(sfnt, ho + 50);
        for g in 0..num_glyphs {
            let (g0, g1) = if idx_fmt == 0 {
                (
                    read_u16_be(sfnt, lo + g * 2) * 2,
                    read_u16_be(sfnt, lo + (g + 1) * 2) * 2,
                )
            } else {
                (
                    read_u32_be(sfnt, lo + g * 4) as usize,
                    read_u32_be(sfnt, lo + (g + 1) * 4) as usize,
                )
            };
            if g1 > g0 {
                non_empty += 1;
                glyf_h = fnv_slice(glyf_h, &sfnt[go + g0..go + g0 + 10]);
            } else {
                glyf_h = fnv_byte(glyf_h, 0);
            }
        }
    }
    (flavor, num_tables, tables_h, num_glyphs, non_empty, glyf_h)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: woff2-bench-rust <woff_file> <iters> [dump_path]");
        process::exit(1);
    }
    let path = &args[1];
    let iters: usize = args[2].parse().unwrap_or(1);
    let data = fs::read(path).expect("failed to read input");
    let is_woff2 = data.len() >= 4 && &data[0..4] == b"wOF2";

    let mut last_out = Vec::new();
    for _ in 0..iters {
        let out = if is_woff2 {
            wuff::decompress_woff2(&data).expect("wuff woff2 decode failed")
        } else {
            wuff::decompress_woff1(&data).expect("wuff woff1 decode failed")
        };
        last_out = out;
    }

    if args.len() >= 4 {
        fs::write(&args[3], &last_out).expect("failed to write dump");
    }

    let (flavor, num_tables, tables_h, num_glyphs, non_empty, glyf_h) = summarize_sfnt(&last_out);
    println!(
        "iters={} flavor={:08x} tables={} tables_fnv64={:016x} glyphs={} non_empty={} glyf_hdr_fnv64={:016x}",
        iters, flavor, num_tables, tables_h, num_glyphs, non_empty, glyf_h
    );
}
