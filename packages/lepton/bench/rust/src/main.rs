use std::env;
use std::fs;
use std::io::{self, Cursor, Write};
use std::path::Path;
use std::process;

use jpeg_encoder::{ColorType, Encoder};
use lepton_jpeg::{decode_lepton, encode_lepton, EnabledFeatures, DEFAULT_THREAD_POOL};

fn generate_rgb_photo(width: usize, height: usize) -> Vec<u8> {
    let mut rgb = vec![0u8; width * height * 3];
    let mut state: u32 = 0x1234_5678;
    for y in 0..height {
        for x in 0..width {
            // Smooth multi-frequency gradients + deterministic high-frequency texture
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            let noise = ((state >> 24) as i32 - 128) / 14;
            let fx = (x as f64) / (width as f64);
            let fy = (y as f64) / (height as f64);
            let wave1 = ((fx * 19.0 + fy * 11.0).sin() * 48.0) as i32;
            let wave2 = ((fx * 7.0 - fy * 23.0).cos() * 42.0) as i32;
            let r = (128 + wave1 + ((x * 180) / width) as i32 - 90 + noise).clamp(0, 255) as u8;
            let g = (128 + wave2 + ((y * 160) / height) as i32 - 80 + noise).clamp(0, 255) as u8;
            let b = (128 + ((wave1 - wave2) / 2) + (((x ^ y) & 63) as i32) - 32 + noise)
                .clamp(0, 255) as u8;
            let idx = (y * width + x) * 3;
            rgb[idx] = r;
            rgb[idx + 1] = g;
            rgb[idx + 2] = b;
        }
    }
    rgb
}

fn gen_corpus(out_dir: &Path) -> io::Result<()> {
    fs::create_dir_all(out_dir)?;
    let width: u16 = 512;
    let height: u16 = 512;
    let rgb = generate_rgb_photo(width as usize, height as usize);

    // 1. Baseline sequential SOF0 (quality 85)
    let mut base_buf = Vec::new();
    let enc_base = Encoder::new(&mut base_buf, 85);
    enc_base
        .encode(&rgb, width, height, ColorType::Rgb)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("{e:?}")))?;
    fs::write(out_dir.join("photo_512_base.jpg"), &base_buf)?;

    // 2. Progressive SOF2 (512x512 Luma, quality 85: single DC scan, compatible with lepton_jpeg)
    let mut luma = Vec::with_capacity((width as usize) * (height as usize));
    for chunk in rgb.chunks_exact(3) {
        let y = ((77u32 * chunk[0] as u32 + 150u32 * chunk[1] as u32 + 29u32 * chunk[2] as u32) >> 8)
            as u8;
        luma.push(y);
    }
    let mut prog_buf = Vec::new();
    let mut enc_prog = Encoder::new(&mut prog_buf, 85);
    enc_prog.set_progressive(true);
    enc_prog
        .encode(&luma, width, height, ColorType::Luma)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("{e:?}")))?;
    fs::write(out_dir.join("photo_512_prog.jpg"), &prog_buf)?;

    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!(
            "usage:\n  rust_lepton_bench gen <out_dir>\n  rust_lepton_bench roundtrip <jpeg_file> <iters> [out_encoded]\n  rust_lepton_bench decode <encoded_file> <iters>"
        );
        process::exit(1);
    }

    match args[1].as_str() {
        "gen" => {
            if let Err(e) = gen_corpus(Path::new(&args[2])) {
                eprintln!("gen error: {e}");
                process::exit(1);
            }
        }
        "roundtrip" => {
            if args.len() < 4 {
                eprintln!("usage: rust_lepton_bench roundtrip <jpeg_file> <iters> [out_encoded]");
                process::exit(1);
            }
            let input = fs::read(&args[2]).unwrap_or_else(|e| {
                eprintln!("read error: {e}");
                process::exit(1);
            });
            let iters: usize = args[3].parse().unwrap_or(0);
            if iters == 0 {
                eprintln!("iters must be > 0");
                process::exit(1);
            }
            let enc_feat = EnabledFeatures::compat_lepton_vector_write();
            let dec_feat = EnabledFeatures::compat_lepton_vector_read();
            let mut last_enc = Vec::new();
            let mut last_dec = Vec::new();
            for _ in 0..iters {
                last_enc.clear();
                let mut reader = Cursor::new(&input);
                let mut writer = Cursor::new(&mut last_enc);
                if let Err(e) = encode_lepton(&mut reader, &mut writer, &enc_feat, &DEFAULT_THREAD_POOL) {
                    eprintln!("encode error: {e}");
                    process::exit(1);
                }
                last_dec.clear();
                let mut enc_reader = Cursor::new(&last_enc);
                if let Err(e) = decode_lepton(&mut enc_reader, &mut last_dec, &dec_feat, &DEFAULT_THREAD_POOL) {
                    eprintln!("decode error: {e}");
                    process::exit(1);
                }
            }
            if args.len() >= 5 {
                fs::write(&args[4], &last_enc).unwrap_or_else(|e| {
                    eprintln!("write error: {e}");
                    process::exit(1);
                });
            }
            io::stdout().write_all(&last_dec).unwrap_or_else(|e| {
                eprintln!("stdout error: {e}");
                process::exit(1);
            });
        }
        "decode" => {
            if args.len() < 4 {
                eprintln!("usage: rust_lepton_bench decode <encoded_file> <iters>");
                process::exit(1);
            }
            let input = fs::read(&args[2]).unwrap_or_else(|e| {
                eprintln!("read error: {e}");
                process::exit(1);
            });
            let iters: usize = args[3].parse().unwrap_or(0);
            if iters == 0 {
                eprintln!("iters must be > 0");
                process::exit(1);
            }
            let dec_feat = EnabledFeatures::compat_lepton_vector_read();
            let mut last_dec = Vec::new();
            for _ in 0..iters {
                last_dec.clear();
                let mut enc_reader = Cursor::new(&input);
                if let Err(e) = decode_lepton(&mut enc_reader, &mut last_dec, &dec_feat, &DEFAULT_THREAD_POOL) {
                    eprintln!("decode error: {e}");
                    process::exit(1);
                }
            }
            io::stdout().write_all(&last_dec).unwrap_or_else(|e| {
                eprintln!("stdout error: {e}");
                process::exit(1);
            });
        }
        other => {
            eprintln!("unknown mode: {other}");
            process::exit(1);
        }
    }
}
