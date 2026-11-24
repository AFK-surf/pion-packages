use std::env;
use std::fs;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 5 {
        eprintln!("usage: icc_rust_bench <qcms_pre|qcms_nopre|moxcms> <parse|rgba> <icc_path> ...");
        std::process::exit(1);
    }
    let engine = &args[1];
    let mode = &args[2];
    let icc_bytes = fs::read(&args[3]).expect("read icc");

    if mode == "parse" {
        let iters: usize = args[4].parse().expect("iters");
        let mut acc: i64 = 0;
        // Saturated non-neutral probe (200, 70, 40): moves significantly under P3/AdobeRGB/Rec.2020
        let probe = [200u8, 70u8, 40u8];
        if engine == "qcms_pre" || engine == "qcms_nopre" || engine == "qcms" {
            let mut dst = qcms::Profile::new_sRGB();
            if engine != "qcms_nopre" {
                dst.precache_output_transform();
            }
            for _ in 0..iters {
                let src = qcms::Profile::new_from_slice(&icc_bytes, false).expect("qcms parse");
                let tf = qcms::Transform::new(&src, &dst, qcms::DataType::RGB8, qcms::Intent::default())
                    .expect("qcms tf");
                let mut px = probe;
                tf.apply(&mut px);
                acc += (((px[0] >> 4) as i64) << 8)
                    | (((px[1] >> 4) as i64) << 4)
                    | ((px[2] >> 4) as i64);
            }
        } else {
            let dst = moxcms::ColorProfile::new_srgb();
            let mut out = [0u8; 3];
            for _ in 0..iters {
                let src = moxcms::ColorProfile::new_from_slice(&icc_bytes).expect("moxcms parse");
                let tf = src
                    .create_transform_8bit(
                        moxcms::Layout::Rgb,
                        &dst,
                        moxcms::Layout::Rgb,
                        moxcms::TransformOptions::default(),
                    )
                    .expect("moxcms tf");
                tf.transform(&probe, &mut out).expect("moxcms run");
                acc += (((out[0] >> 4) as i64) << 8)
                    | (((out[1] >> 4) as i64) << 4)
                    | ((out[2] >> 4) as i64);
            }
        }
        println!("PARSE_OK iters={} probe_qsum={}", iters, acc);
        return;
    }

    if mode == "rgba" {
        let mut work = fs::read(&args[4]).expect("read rgba");
        let frames: usize = args[5].parse().expect("frames");
        let n = work.len();
        let mut alpha_sum: i64 = 0;
        if engine == "qcms_pre" || engine == "qcms_nopre" || engine == "qcms" {
            let src = qcms::Profile::new_from_slice(&icc_bytes, false).expect("qcms parse");
            let mut dst = qcms::Profile::new_sRGB();
            if engine != "qcms_nopre" {
                dst.precache_output_transform();
            }
            let tf = qcms::Transform::new(&src, &dst, qcms::DataType::RGBA8, qcms::Intent::default())
                .expect("qcms tf");
            for _ in 0..frames {
                tf.apply(&mut work);
                alpha_sum += work[3] as i64 + work[n - 1] as i64;
            }
        } else {
            let src = moxcms::ColorProfile::new_from_slice(&icc_bytes).expect("moxcms parse");
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
        let mut sum_r: i64 = 0;
        let mut sum_g: i64 = 0;
        let mut sum_b: i64 = 0;
        for chunk in work.chunks_exact(4) {
            sum_r += chunk[0] as i64;
            sum_g += chunk[1] as i64;
            sum_b += chunk[2] as i64;
        }
        let px_cnt = (n / 4) as i64;
        let avg_r = (sum_r + px_cnt / 2) / px_cnt;
        let avg_g = (sum_g + px_cnt / 2) / px_cnt;
        let avg_b = (sum_b + px_cnt / 2) / px_cnt;
        if args.len() >= 7 {
            fs::write(&args[6], &work).expect("write dump");
        }
        println!(
            "RGBA_OK frames={} pixels={} alpha_check={} avg_rgb={},{},{}",
            frames, px_cnt, alpha_sum, avg_r, avg_g, avg_b
        );
        return;
    }
    panic!("unknown mode");
}
