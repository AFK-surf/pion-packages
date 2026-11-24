//! Differential / fairness oracle for the packages/icc red-team audit: Rust qcms 0.3.0 and moxcms 0.9.2.
//!   grid <icc> <in.rgb> <out_prefix>     -> <out_prefix>.qcms / .moxcms (RGB8 -> sRGB RGB8), "FAIL" on error
//!   gray <icc> <out_prefix>              -> 256-level Gray8 ramp -> sRGB, R channel, same files
//!   verdict <listfile>                   -> `<path> qcms=<ok|parse|tf> moxcms=<ok|parse|tf>` per line
//!   build <qcms|qcms_pre|moxcms> <icc> <iters>
//!                                        -> same loop and stdout as pion_bench `parse` (parse + transform + probe);
//!                                           qcms_pre = sRGB destination precached once, as Firefox does
//!   rgba <qcms|qcms_pre|moxcms> <icc> <rgba> <frames> [dump]
//!                                        -> same loop as bench/rust_bench `rgba`, plus a full-frame FNV-64
use std::env;
use std::fs;
use std::time::Instant;

fn fnv(data: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &b in data {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

fn qcms_dst(pre: bool) -> Box<qcms::Profile> {
    let mut d = qcms::Profile::new_sRGB();
    if pre {
        d.precache_output_transform();
    }
    d
}

fn qcms_rgb(icc: &[u8], data: &[u8], ty: qcms::DataType) -> Option<Vec<u8>> {
    let src = qcms::Profile::new_from_slice(icc, false)?;
    let dst = qcms_dst(false);
    let tf = qcms::Transform::new(&src, &dst, ty, qcms::Intent::RelativeColorimetric)?;
    let mut v = data.to_vec();
    tf.apply(&mut v);
    Some(v)
}

fn mox_rgb(icc: &[u8], data: &[u8], layout: moxcms::Layout) -> Option<Vec<u8>> {
    let src = moxcms::ColorProfile::new_from_slice(icc).ok()?;
    let dst = moxcms::ColorProfile::new_srgb();
    let opts = moxcms::TransformOptions {
        rendering_intent: moxcms::RenderingIntent::RelativeColorimetric,
        ..Default::default()
    };
    let tf = src.create_transform_8bit(layout, &dst, moxcms::Layout::Rgb, opts).ok()?;
    let n = match layout {
        moxcms::Layout::Gray => data.len() * 3,
        _ => data.len(),
    };
    let mut out = vec![0u8; n];
    tf.transform(data, &mut out).ok()?;
    Some(out)
}

fn write_or_fail(path: String, v: Option<Vec<u8>>) {
    match v {
        Some(b) => fs::write(path, b).expect("write"),
        None => fs::write(path, b"FAIL").expect("write"),
    }
}

fn verdict(icc: &[u8]) -> (String, String) {
    let q = std::panic::catch_unwind(|| match qcms::Profile::new_from_slice(icc, false) {
        None => "parse".to_string(),
        Some(src) => {
            let dst = qcms_dst(false);
            let ty = if src.is_sRGB() { qcms::DataType::RGB8 } else { qcms::DataType::RGB8 };
            match qcms::Transform::new(&src, &dst, ty, qcms::Intent::RelativeColorimetric) {
                Some(_) => "ok".to_string(),
                None => "tf".to_string(),
            }
        }
    })
    .unwrap_or_else(|_| "panic".to_string());
    let m = std::panic::catch_unwind(|| match moxcms::ColorProfile::new_from_slice(icc) {
        Err(_) => "parse".to_string(),
        Ok(src) => {
            let dst = moxcms::ColorProfile::new_srgb();
            match src.create_transform_8bit(
                moxcms::Layout::Rgb,
                &dst,
                moxcms::Layout::Rgb,
                moxcms::TransformOptions::default(),
            ) {
                Ok(_) => "ok".to_string(),
                Err(_) => "tf".to_string(),
            }
        }
    })
    .unwrap_or_else(|_| "panic".to_string());
    (q, m)
}

fn main() {
    let a: Vec<String> = env::args().collect();
    let mode = a.get(1).map(|s| s.as_str()).unwrap_or("");
    match mode {
        "grid" => {
            let icc = fs::read(&a[2]).expect("icc");
            let inp = fs::read(&a[3]).expect("in");
            write_or_fail(format!("{}.qcms", a[4]), qcms_rgb(&icc, &inp, qcms::DataType::RGB8));
            write_or_fail(format!("{}.moxcms", a[4]), mox_rgb(&icc, &inp, moxcms::Layout::Rgb));
        }
        "gray" => {
            let icc = fs::read(&a[2]).expect("icc");
            let ramp: Vec<u8> = (0..=255u8).collect();
            // qcms: Gray8 -> RGB8
            let q = (|| {
                let src = qcms::Profile::new_from_slice(&icc, false)?;
                let dst = qcms_dst(false);
                let tf = qcms::Transform::new_to(
                    &src,
                    &dst,
                    qcms::DataType::Gray8,
                    qcms::DataType::RGB8,
                    qcms::Intent::RelativeColorimetric,
                )?;
                let mut out = vec![0u8; 256 * 3];
                tf.convert(&ramp, &mut out);
                Some(out.chunks(3).map(|c| c[0]).collect::<Vec<u8>>())
            })();
            write_or_fail(format!("{}.qcms", a[3]), q);
            let m = mox_rgb(&icc, &ramp, moxcms::Layout::Gray).map(|v| v.chunks(3).map(|c| c[0]).collect());
            write_or_fail(format!("{}.moxcms", a[3]), m);
        }
        "verdict" => {
            let lst = fs::read_to_string(&a[2]).expect("list");
            std::panic::set_hook(Box::new(|_| {}));
            for p in lst.lines().filter(|l| !l.is_empty()) {
                let d = fs::read(p).unwrap_or_default();
                let (q, m) = verdict(&d);
                println!("{} qcms={} moxcms={}", p, q, m);
            }
        }
        "build" => {
            let engine = a[2].as_str();
            let icc = fs::read(&a[3]).expect("icc");
            let iters: usize = a[4].parse().expect("iters");
            let probe = [128u8, 128u8, 128u8];
            let mut acc: i64 = 0;
            let t0 = Instant::now();
            match engine {
                "qcms" | "qcms_pre" => {
                    let dst = qcms_dst(engine == "qcms_pre");
                    for _ in 0..iters {
                        let src = qcms::Profile::new_from_slice(&icc, false).expect("qcms parse");
                        let tf = qcms::Transform::new(&src, &dst, qcms::DataType::RGB8, qcms::Intent::default())
                            .expect("qcms tf");
                        let mut px = probe;
                        tf.apply(&mut px);
                        acc += px[0] as i64 + px[1] as i64 + px[2] as i64;
                    }
                }
                _ => {
                    let dst = moxcms::ColorProfile::new_srgb();
                    let mut out = [0u8; 3];
                    for _ in 0..iters {
                        let src = moxcms::ColorProfile::new_from_slice(&icc).expect("moxcms parse");
                        let tf = src
                            .create_transform_8bit(
                                moxcms::Layout::Rgb,
                                &dst,
                                moxcms::Layout::Rgb,
                                moxcms::TransformOptions::default(),
                            )
                            .expect("moxcms tf");
                        tf.transform(&probe, &mut out).expect("moxcms run");
                        acc += out[0] as i64 + out[1] as i64 + out[2] as i64;
                    }
                }
            }
            eprintln!("inproc_ns_per_op={}", t0.elapsed().as_nanos() / iters.max(1) as u128);
            println!("PARSE_OK iters={} probe_sum={}", iters, acc);
        }
        "rgba" => {
            let engine = a[2].as_str();
            let icc = fs::read(&a[3]).expect("icc");
            let mut work = fs::read(&a[4]).expect("rgba");
            let frames: usize = a[5].parse().expect("frames");
            let n = work.len();
            let mut alpha_sum: i64 = 0;
            match engine {
                "qcms" | "qcms_pre" => {
                    let src = qcms::Profile::new_from_slice(&icc, false).expect("qcms parse");
                    let dst = qcms_dst(engine == "qcms_pre");
                    let tf = qcms::Transform::new(&src, &dst, qcms::DataType::RGBA8, qcms::Intent::default())
                        .expect("qcms tf");
                    for _ in 0..frames {
                        tf.apply(&mut work);
                        alpha_sum += work[3] as i64 + work[n - 1] as i64;
                    }
                }
                _ => {
                    let src = moxcms::ColorProfile::new_from_slice(&icc).expect("moxcms parse");
                    let dst = moxcms::ColorProfile::new_srgb();
                    let tf = src
                        .create_transform_8bit(
                            moxcms::Layout::Rgba,
                            &dst,
                            moxcms::Layout::Rgba,
                            moxcms::TransformOptions::default(),
                        )
                        .expect("moxcms tf");
                    let mut out = vec![0u8; n];
                    for _ in 0..frames {
                        tf.transform(&work, &mut out).expect("moxcms run");
                        std::mem::swap(&mut work, &mut out);
                        alpha_sum += work[3] as i64 + work[n - 1] as i64;
                    }
                }
            }
            if a.len() >= 7 {
                fs::write(&a[6], &work).expect("dump");
            }
            eprintln!("frame_fnv64={:016x}", fnv(&work));
            println!("RGBA_OK frames={} pixels={} alpha_check={}", frames, n / 4, alpha_sum);
        }
        _ => {
            eprintln!("usage: see src/main.rs");
            std::process::exit(2);
        }
    }
}
