//! Oracle for the packages/svg red-team audit: Rust `svgtypes =0.15.3`, `roxmltree =0.20.0`,
//! `kurbo =0.11.3` and the platform libm. Same length-framed record I/O as `audit/probe`.
//!   path  d    -> `OK` + segments, or `ERR <n>` + the n segments svgtypes yielded before the error
//!   geom  d    -> SimplifyingPathParser -> kurbo BezPath: `OK bbox perimeter(1e-9)` / `ERR` / `EMPTY`
//!   color s    -> `OK r g b a` / `ERR`
//!   tf    s    -> `OK a b c d e f` / `ERR`
//!   rot   deg  -> libm: cos(rad) sin(rad) tan(rad) with rad = deg.to_radians()
//!   vb    s    -> `OK x y w h` / `ERR`
//!   par   s    -> `OK align meet|slice` / `ERR`
//!   len   s    -> `OK number unit` / `ERR`
//!   num   s    -> f64::from_str (correctly rounded) bits / `ERR`
//!   xml   doc  -> roxmltree canonical dump / `ERR <error>`
use std::str::FromStr;
use std::{env, fs};
use kurbo::{BezPath, Shape};
use svgtypes::{PathParser, PathSegment, SimplePathSegment, SimplifyingPathParser};

fn read_records(b: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let j = i + b[i..].iter().position(|&c| c == b'\n').unwrap();
        let n: usize = std::str::from_utf8(&b[i..j]).unwrap().parse().unwrap();
        out.push(String::from_utf8_lossy(&b[j + 1..j + 1 + n]).into_owned());
        i = j + 1 + n;
    }
    out
}

fn db(s: &mut String, v: f64) {
    s.push(' ');
    s.push_str(&(v.to_bits() as i64).to_string());
}

fn parse_double(s: &str) -> f64 {
    if let Some(rest) = s.strip_prefix('b') {
        return f64::from_bits(rest.parse::<i64>().unwrap() as u64);
    }
    s.parse().unwrap_or(0.0)
}

fn seg(s: &mut String, p: &PathSegment) {
    s.push('\n');
    let up = |abs: bool, c: char| if abs { c.to_ascii_uppercase() } else { c };
    match *p {
        PathSegment::MoveTo { abs, x, y } => { s.push(up(abs, 'm')); db(s, x); db(s, y); }
        PathSegment::LineTo { abs, x, y } => { s.push(up(abs, 'l')); db(s, x); db(s, y); }
        PathSegment::HorizontalLineTo { abs, x } => { s.push(up(abs, 'h')); db(s, x); }
        PathSegment::VerticalLineTo { abs, y } => { s.push(up(abs, 'v')); db(s, y); }
        PathSegment::CurveTo { abs, x1, y1, x2, y2, x, y } => {
            s.push(up(abs, 'c')); for v in [x1, y1, x2, y2, x, y] { db(s, v) }
        }
        PathSegment::SmoothCurveTo { abs, x2, y2, x, y } => {
            s.push(up(abs, 's')); for v in [x2, y2, x, y] { db(s, v) }
        }
        PathSegment::Quadratic { abs, x1, y1, x, y } => {
            s.push(up(abs, 'q')); for v in [x1, y1, x, y] { db(s, v) }
        }
        PathSegment::SmoothQuadratic { abs, x, y } => { s.push(up(abs, 't')); db(s, x); db(s, y); }
        PathSegment::EllipticalArc { abs, rx, ry, x_axis_rotation, large_arc, sweep, x, y } => {
            s.push(up(abs, 'a'));
            db(s, rx); db(s, ry); db(s, x_axis_rotation);
            s.push_str(if large_arc { " 1" } else { " 0" });
            s.push_str(if sweep { " 1" } else { " 0" });
            db(s, x); db(s, y);
        }
        PathSegment::ClosePath { abs } => s.push(if abs { 'Z' } else { 'z' }),
    }
}

fn esc(v: &str) -> String {
    format!("{}:{}", v.len(), v)
}

fn run(mode: &str, rec: &str) -> String {
    let mut s = String::new();
    match mode {
        "path" => {
            let mut segs = Vec::new();
            let mut err = false;
            for r in PathParser::from(rec) {
                match r { Ok(p) => segs.push(p), Err(_) => { err = true; break; } }
            }
            if err { s.push_str(&format!("ERR {}", segs.len())); } else { s.push_str("OK"); }
            for p in &segs { seg(&mut s, p); }
        }
        "geom" => {
            let mut bp = BezPath::new();
            let mut err = false;
            for r in SimplifyingPathParser::from(rec) {
                match r {
                    Ok(SimplePathSegment::MoveTo { x, y }) => bp.move_to((x, y)),
                    Ok(SimplePathSegment::LineTo { x, y }) => bp.line_to((x, y)),
                    Ok(SimplePathSegment::Quadratic { x1, y1, x, y }) => bp.quad_to((x1, y1), (x, y)),
                    Ok(SimplePathSegment::CurveTo { x1, y1, x2, y2, x, y }) => bp.curve_to((x1, y1), (x2, y2), (x, y)),
                    Ok(SimplePathSegment::ClosePath) => bp.close_path(),
                    Err(_) => { err = true; break; }
                }
            }
            if err { s.push_str("ERR"); }
            else if bp.segments().next().is_none() { s.push_str("EMPTY"); }
            else {
                let r = bp.bounding_box();
                s.push_str("OK");
                for v in [r.x0, r.y0, r.x1, r.y1, bp.perimeter(1e-9)] { db(&mut s, v) }
            }
        }
        "color" => match svgtypes::Color::from_str(rec) {
            Ok(c) => s.push_str(&format!("OK {} {} {} {}", c.red, c.green, c.blue, c.alpha)),
            Err(_) => s.push_str("ERR"),
        },
        "tf" => match svgtypes::Transform::from_str(rec) {
            Ok(t) => { s.push_str("OK"); for v in [t.a, t.b, t.c, t.d, t.e, t.f] { db(&mut s, v) } }
            Err(_) => s.push_str("ERR"),
        },
        "rot" => {
            let rad = parse_double(rec).to_radians();
            s.push_str("OK");
            for v in [rad.cos(), rad.sin(), rad.tan()] { db(&mut s, v) }
        }
        "vb" => match svgtypes::ViewBox::from_str(rec) {
            Ok(v) => { s.push_str("OK"); for x in [v.x, v.y, v.w, v.h] { db(&mut s, x) } }
            Err(_) => s.push_str("ERR"),
        },
        "par" => match svgtypes::AspectRatio::from_str(rec) {
            Ok(a) => {
                let name = format!("{:?}", a.align);
                let mut n = String::new();
                for (i, ch) in name.chars().enumerate() {
                    n.push(if i == 0 { ch.to_ascii_lowercase() } else { ch });
                }
                s.push_str(&format!("OK {} {}", n, if a.slice { "slice" } else { "meet" }));
            }
            Err(_) => s.push_str("ERR"),
        },
        "len" => match svgtypes::Length::from_str(rec) {
            Ok(l) => { s.push_str("OK"); db(&mut s, l.number); s.push_str(&format!(" {:?}", l.unit)); }
            Err(_) => s.push_str("ERR"),
        },
        "num" => match svgtypes::Number::from_str(rec) {
            Ok(n) => { s.push_str("OK"); db(&mut s, n.0); }
            Err(_) => s.push_str("ERR"),
        },
        "xml" => match roxmltree::Document::parse(rec) {
            Ok(doc) => {
                s.push_str(&format!("OK root={}", doc.root_element().tag_name().name()));
                for n in doc.descendants() {
                    if n.is_element() {
                        s.push_str(&format!("\nE {} {}", n.tag_name().namespace().unwrap_or(""), n.tag_name().name()));
                        for a in n.attributes() {
                            s.push_str(&format!(" {}={}", a.name(), esc(a.value())));
                        }
                    } else if n.is_text() {
                        s.push_str(&format!("\nT {}", esc(n.text().unwrap_or(""))));
                    }
                }
            }
            Err(e) => s.push_str(&format!("ERR {}", e)),
        },
        _ => s.push_str("BADMODE"),
    }
    s
}

fn main() {
    let a: Vec<String> = env::args().collect();
    if a.len() < 3 || (a.len() < 4 && !a[1].starts_with("w1")) {
        eprintln!("usage: oracle <mode> <in> <out>");
        std::process::exit(2);
    }
    if a[1] == "w1kurbo" {
        // Idiomatic upstream pipeline for W1: svgtypes SimplifyingPathParser (arcs via kurbo) + kurbo bbox.
        let src = fs::read_to_string(&a[2]).unwrap();
        let (mut n, mut sum) = (0i64, 0f64);
        for line in src.lines().filter(|l| !l.is_empty()) {
            let mut bp = BezPath::new();
            for r in SimplifyingPathParser::from(line) {
                match r {
                    Ok(SimplePathSegment::MoveTo { x, y }) => bp.move_to((x, y)),
                    Ok(SimplePathSegment::LineTo { x, y }) => bp.line_to((x, y)),
                    Ok(SimplePathSegment::Quadratic { x1, y1, x, y }) => bp.quad_to((x1, y1), (x, y)),
                    Ok(SimplePathSegment::CurveTo { x1, y1, x2, y2, x, y }) => bp.curve_to((x1, y1), (x2, y2), (x, y)),
                    Ok(SimplePathSegment::ClosePath) => bp.close_path(),
                    Err(_) => break,
                }
            }
            let r = bp.bounding_box();
            sum += r.x0 + r.y0 + r.x1 + r.y1;
            n += 1;
        }
        println!("w1kurbo paths={} bbox_sum={:.1}", n, sum);
        return;
    }
    if a[1] == "w1parse" {
        // svgtypes PathParser only (W1 stage 1 equivalent)
        let src = fs::read_to_string(&a[2]).unwrap();
        let mut n = 0usize;
        for line in src.lines().filter(|l| !l.is_empty()) {
            n += PathParser::from(line).filter(|r| r.is_ok()).count();
        }
        println!("w1parse segs={}", n);
        return;
    }
    let recs = read_records(&fs::read(&a[2]).unwrap());
    let mut out = Vec::new();
    for r in &recs {
        let o = run(&a[1], r);
        out.extend_from_slice(o.len().to_string().as_bytes());
        out.push(b'\n');
        out.extend_from_slice(o.as_bytes());
    }
    fs::write(&a[3], out).unwrap();
}
