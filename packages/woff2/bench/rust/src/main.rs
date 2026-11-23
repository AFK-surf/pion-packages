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

fn sha256_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    let bit_len = (data.len() as u64) * 8;
    let mut padded = Vec::with_capacity(((data.len() + 9 + 63) / 64) * 64);
    padded.extend_from_slice(data);
    padded.push(0x80);
    while (padded.len() % 64) != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_len.to_be_bytes());
    let mut w = [0u32; 64];
    for chunk in padded.chunks_exact(64) {
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                chunk[4 * i],
                chunk[4 * i + 1],
                chunk[4 * i + 2],
                chunk[4 * i + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = hh.wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }
    let mut out = String::with_capacity(64);
    for &word in &h {
        out.push_str(&format!("{:08x}", word));
    }
    out
}

fn canonical_sfnt_sha256(sfnt: &[u8]) -> String {
    let mut buf = Vec::with_capacity(sfnt.len());
    buf.extend_from_slice(&sfnt[0..6]);
    let num_tables = read_u16_be(sfnt, 4);
    for i in 0..num_tables {
        let rec = 12 + i * 16;
        let tag = read_u32_be(sfnt, rec);
        let off = read_u32_be(sfnt, rec + 8) as usize;
        let len = read_u32_be(sfnt, rec + 12) as usize;
        buf.extend_from_slice(&sfnt[rec..rec + 4]);
        buf.extend_from_slice(&sfnt[rec + 12..rec + 16]);
        if tag == 0x68656164 && len >= 12 {
            buf.extend_from_slice(&sfnt[off..off + 8]);
            buf.extend_from_slice(&[0u8; 4]);
            buf.extend_from_slice(&sfnt[off + 12..off + len]);
        } else {
            buf.extend_from_slice(&sfnt[off..off + len]);
        }
    }
    sha256_hex(&buf)
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
    let sfnt_sha256 = canonical_sfnt_sha256(&last_out);
    println!(
        "iters={} flavor={:08x} tables={} tables_fnv64={:016x} glyphs={} non_empty={} glyf_hdr_fnv64={:016x} sfnt_bytes={} full_sfnt_sha256={}",
        iters, flavor, num_tables, tables_h, num_glyphs, non_empty, glyf_h, last_out.len(), sfnt_sha256
    );
}
