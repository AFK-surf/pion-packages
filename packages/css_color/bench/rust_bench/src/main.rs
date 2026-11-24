use color::{parse_color, ColorSpaceTag, DynamicColor, HueDirection, Srgb};
use std::env;
use std::fs;
use std::process;

fn parse_space_tag(name: &str) -> ColorSpaceTag {
    match name {
        "srgb" => ColorSpaceTag::Srgb,
        "srgb-linear" => ColorSpaceTag::LinearSrgb,
        "display-p3" => ColorSpaceTag::DisplayP3,
        "a98-rgb" => ColorSpaceTag::A98Rgb,
        "prophoto-rgb" => ColorSpaceTag::ProphotoRgb,
        "rec2020" => ColorSpaceTag::Rec2020,
        "lab" => ColorSpaceTag::Lab,
        "lch" => ColorSpaceTag::Lch,
        "oklab" => ColorSpaceTag::Oklab,
        "oklch" => ColorSpaceTag::Oklch,
        "hsl" => ColorSpaceTag::Hsl,
        "hwb" => ColorSpaceTag::Hwb,
        "xyz-d50" => ColorSpaceTag::XyzD50,
        "xyz" | "xyz-d65" => ColorSpaceTag::XyzD65,
        _ => panic!("unknown space: {name}"),
    }
}

fn parse_hue_dir(name: &str) -> HueDirection {
    match name {
        "shorter" => HueDirection::Shorter,
        "longer" => HueDirection::Longer,
        "increasing" => HueDirection::Increasing,
        "decreasing" => HueDirection::Decreasing,
        _ => panic!("unknown hue dir: {name}"),
    }
}

fn run_diff(parse_path: &str, mix_path: &str) {
    let parse_text = fs::read_to_string(parse_path).expect("read parse_path");
    for (i, line) in parse_text.lines().filter(|l| !l.is_empty()).enumerate() {
        let c = parse_color(line).unwrap_or_else(|e| panic!("rust parse failed on '{line}': {e}"));
        let srgb = c.convert(ColorSpaceTag::Srgb);
        let ok = c.convert(ColorSpaceTag::Oklab);
        let p3 = c.convert(ColorSpaceTag::DisplayP3);
        let rgba = srgb.to_alpha_color::<Srgb>().to_rgba8();
        println!(
            "P|{}|{:.6}|{:.6}|{:.6}|{:.6}|{:.6}|{:.6}|{:.6}|{:.6}|{:.6}|{:.6}|{}|{}|{}|{}",
            i,
            srgb.components[0],
            srgb.components[1],
            srgb.components[2],
            srgb.components[3],
            ok.components[0],
            ok.components[1],
            ok.components[2],
            p3.components[0],
            p3.components[1],
            p3.components[2],
            rgba.r,
            rgba.g,
            rgba.b,
            rgba.a
        );
    }

    let mix_text = fs::read_to_string(mix_path).expect("read mix_path");
    for (i, line) in mix_text.lines().filter(|l| !l.is_empty()).enumerate() {
        let parts: Vec<&str> = line.split('|').collect();
        let sp = parse_space_tag(parts[0]);
        let hm = parse_hue_dir(parts[1]);
        let c1 = parse_color(parts[2]).expect("parse c1");
        let p1: f32 = parts[3].parse().expect("p1");
        let c2 = parse_color(parts[4]).expect("parse c2");
        let p2: f32 = parts[5].parse().expect("p2");
        let sum = p1 + p2;
        let alpha_mult = if sum < 100.0 { sum / 100.0 } else { 1.0 };
        let t = p2 / sum;
        let mut mixed = c1.interpolate(c2, sp, hm).eval(t);
        mixed.components[3] = (mixed.components[3] * alpha_mult).clamp(0.0, 1.0);
        let srgb = mixed.convert(ColorSpaceTag::Srgb);
        let rgba = srgb.to_alpha_color::<Srgb>().to_rgba8();
        println!(
            "M|{}|{:.6}|{:.6}|{:.6}|{:.6}|{}|{}|{}|{}",
            i,
            srgb.components[0],
            srgb.components[1],
            srgb.components[2],
            srgb.components[3],
            rgba.r,
            rgba.g,
            rgba.b,
            rgba.a
        );
    }
}

fn run_bench_parse(parse_path: &str, iters: usize) {
    let text = fs::read_to_string(parse_path).expect("read parse_path");
    let lines: Vec<&str> = text.lines().filter(|l| !l.is_empty()).collect();
    let mut ok_count: i64 = 0;
    let mut acc: i64 = 0;
    for _ in 0..iters {
        for &line in &lines {
            let c = parse_color(line).expect("parse");
            ok_count += 1;
            let rgba = c.to_alpha_color::<Srgb>().to_rgba8();
            acc += (rgba.r as i64) + (rgba.g as i64) + (rgba.b as i64) + (rgba.a as i64);
        }
    }
    println!("bench_parse ok={} acc={}", ok_count, acc);
}

fn run_bench_convert(parse_path: &str, iters: usize) {
    let text = fs::read_to_string(parse_path).expect("read parse_path");
    let colors: Vec<DynamicColor> = text
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| parse_color(l).expect("parse").convert(ColorSpaceTag::Srgb))
        .collect();
    let mut total: i64 = 0;
    let mut acc: i64 = 0;
    for _ in 0..iters {
        for &c in &colors {
            let c1 = c.convert(ColorSpaceTag::Oklch);
            let c2 = c1.convert(ColorSpaceTag::DisplayP3);
            let c3 = c2.convert(ColorSpaceTag::Lab);
            let c4 = c3.convert(ColorSpaceTag::Srgb);
            let rgba = c4.to_alpha_color::<Srgb>().to_rgba8();
            total += 1;
            acc += ((rgba.r >> 2) as i64) + ((rgba.g >> 2) as i64) + ((rgba.b >> 2) as i64);
        }
    }
    println!("bench_convert ops={} acc={}", total, acc);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: rust_css_color <diff|bench_parse|bench_convert> ...");
        process::exit(1);
    }
    match args[1].as_str() {
        "diff" if args.len() >= 4 => run_diff(&args[2], &args[3]),
        "bench_parse" if args.len() >= 4 => {
            let iters: usize = args[3].parse().expect("iters");
            run_bench_parse(&args[2], iters);
        }
        "bench_convert" if args.len() >= 4 => {
            let iters: usize = args[3].parse().expect("iters");
            run_bench_convert(&args[2], iters);
        }
        other => {
            eprintln!("unknown command: {other}");
            process::exit(1);
        }
    }
}
