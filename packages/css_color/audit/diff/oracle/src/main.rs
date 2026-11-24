//! Locked Rust oracle for the css_color red-team audit: Linebender `color =0.3.3` (f32 math).
//!   oracle run <casefile>  -> `<target>\t<input>` lines: `ERR <e>` | `OK <space> c0 c1 c2 a <mask> T <target> t0 t1 t2 ta <mask> C r,g,b,a`
//!   oracle mix <casefile>  -> `<space>|<hue>|<c1>|<p1>|<c2>|<p2>` lines: `OK <space> c0 c1 c2 a <mask> T srgb ... C r,g,b,a`
//! `color` parses neither color-mix() nor relative colors nor calc(); those lines answer `ERR`.
use color::{parse_color, ColorSpaceTag, DynamicColor, HueDirection, Srgb};
use std::{env, fs};

fn tag(name: &str) -> Option<ColorSpaceTag> {
    Some(match name {
        "srgb" => ColorSpaceTag::Srgb,
        "srgb-linear" => ColorSpaceTag::LinearSrgb,
        "display-p3" => ColorSpaceTag::DisplayP3,
        "a98-rgb" => ColorSpaceTag::A98Rgb,
        "prophoto-rgb" => ColorSpaceTag::ProphotoRgb,
        "rec2020" => ColorSpaceTag::Rec2020,
        "xyz-d50" => ColorSpaceTag::XyzD50,
        "xyz" | "xyz-d65" => ColorSpaceTag::XyzD65,
        "hsl" => ColorSpaceTag::Hsl,
        "hwb" => ColorSpaceTag::Hwb,
        "lab" => ColorSpaceTag::Lab,
        "lch" => ColorSpaceTag::Lch,
        "oklab" => ColorSpaceTag::Oklab,
        "oklch" => ColorSpaceTag::Oklch,
        _ => return None,
    })
}

fn name(t: ColorSpaceTag) -> &'static str {
    match t {
        ColorSpaceTag::Srgb => "srgb",
        ColorSpaceTag::LinearSrgb => "srgb-linear",
        ColorSpaceTag::DisplayP3 => "display-p3",
        ColorSpaceTag::A98Rgb => "a98-rgb",
        ColorSpaceTag::ProphotoRgb => "prophoto-rgb",
        ColorSpaceTag::Rec2020 => "rec2020",
        ColorSpaceTag::XyzD50 => "xyz-d50",
        ColorSpaceTag::XyzD65 => "xyz-d65",
        ColorSpaceTag::Hsl => "hsl",
        ColorSpaceTag::Hwb => "hwb",
        ColorSpaceTag::Lab => "lab",
        ColorSpaceTag::Lch => "lch",
        ColorSpaceTag::Oklab => "oklab",
        ColorSpaceTag::Oklch => "oklch",
        _ => "other",
    }
}

fn coords(c: &DynamicColor) -> String {
    let m = c.flags.missing();
    let b = |i: usize| if m.contains(i) { '1' } else { '0' };
    format!(
        "{} {} {} {} {} {}{}{}{}",
        name(c.cs),
        c.components[0],
        c.components[1],
        c.components[2],
        c.components[3],
        b(0),
        b(1),
        b(2),
        b(3)
    )
}

fn unhex(s: &str) -> String {
    match s.strip_prefix("hex:") {
        None => s.to_string(),
        Some(h) => {
            let bytes: Vec<u8> = (0..h.len() / 2).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap_or(0)).collect();
            String::from_utf8_lossy(&bytes).into_owned()
        }
    }
}

fn result(c: DynamicColor, target: Option<ColorSpaceTag>) -> String {
    let t = match target {
        Some(t) => c.convert(t),
        None => c,
    };
    let q = c.to_alpha_color::<Srgb>().to_rgba8();
    format!("OK {} T {} C {},{},{},{}", coords(&c), coords(&t), q.r, q.g, q.b, q.a)
}

fn hue(s: &str) -> HueDirection {
    match s {
        "longer" => HueDirection::Longer,
        "increasing" => HueDirection::Increasing,
        "decreasing" => HueDirection::Decreasing,
        _ => HueDirection::Shorter,
    }
}

fn mix_line(line: &str) -> String {
    let p: Vec<&str> = line.split('|').collect();
    if p.len() != 6 {
        return "ERR fields".into();
    }
    let (Some(sp), Ok(c1), Ok(c2)) = (tag(p[0]), parse_color(p[2]), parse_color(p[4])) else {
        return "ERR parse".into();
    };
    let (p1, p2): (f32, f32) = match (p[3].parse::<f32>().ok(), p[5].parse::<f32>().ok()) {
        (None, None) => (50.0, 50.0),
        (Some(a), None) => (a, 100.0 - a),
        (None, Some(b)) => (100.0 - b, b),
        (Some(a), Some(b)) => (a, b),
    };
    let sum = p1 + p2;
    if sum <= 0.0 {
        return "ERR sum".into();
    }
    let mut m = c1.interpolate(c2, sp, hue(p[1])).eval(p2 / sum);
    if sum < 100.0 {
        m.components[3] *= sum / 100.0;
    }
    result(m, Some(ColorSpaceTag::Srgb))
}

fn main() {
    let a: Vec<String> = env::args().collect();
    if a.len() < 3 {
        eprintln!("usage: oracle run|mix <casefile>");
        std::process::exit(2);
    }
    let text = fs::read_to_string(&a[2]).expect("read casefile");
    let mut out = String::new();
    for line in text.lines() {
        let r = if a[1] == "mix" {
            mix_line(line)
        } else {
            let (t, input) = match line.split_once('\t') {
                Some((t, i)) => (tag(t), unhex(i)),
                None => (None, unhex(line)),
            };
            match parse_color(&input) {
                Ok(c) => result(c, t),
                Err(e) => format!("ERR {e:?}"),
            }
        };
        out.push_str(&r);
        out.push('\n');
    }
    print!("{out}");
}
