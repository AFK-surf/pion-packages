use roxmltree::{Document, Node, NodeType};
use std::env;
use std::f64::consts::{FRAC_PI_2, PI, TAU};
use std::fs;
use svgtypes::{PathParser, PathSegment, TransformListParser, TransformListToken};

#[derive(Clone, Copy)]
enum CubicSeg {
    MoveTo(f64, f64),
    LineTo(f64, f64),
    CurveTo(f64, f64, f64, f64, f64, f64),
    ClosePath,
}

#[derive(Clone, Copy)]
struct Tf {
    a: f64,
    b: f64,
    c: f64,
    d: f64,
    e: f64,
    f: f64,
}

impl Tf {
    fn identity() -> Self {
        Self { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 0.0, f: 0.0 }
    }
    fn mul(self, o: Self) -> Self {
        Self {
            a: self.a * o.a + self.c * o.b,
            b: self.b * o.a + self.d * o.b,
            c: self.a * o.c + self.c * o.d,
            d: self.b * o.c + self.d * o.d,
            e: self.a * o.e + self.c * o.f + self.e,
            f: self.b * o.e + self.d * o.f + self.f,
        }
    }
    fn apply(self, x: f64, y: f64) -> (f64, f64) {
        (self.a * x + self.c * y + self.e, self.b * x + self.d * y + self.f)
    }
}

fn round_tenth(v: f64) -> i64 {
    if v >= 0.0 {
        (v * 10.0 + 0.5).floor() as i64
    } else {
        -((-v * 10.0 + 0.5).floor() as i64)
    }
}

fn vec_angle(ux: f64, uy: f64, vx: f64, vy: f64) -> f64 {
    let dot = ux * vx + uy * vy;
    let len = ((ux * ux + uy * uy) * (vx * vx + vy * vy)).sqrt();
    if len < 1e-24 {
        return 0.0;
    }
    let ang = (dot / len).clamp(-1.0, 1.0).acos();
    if ux * vy - uy * vx < 0.0 { -ang } else { ang }
}

fn arc_to_cubics(
    x1: f64, y1: f64, rx_in: f64, ry_in: f64, rot_deg: f64,
    large_arc: bool, sweep: bool, x2: f64, y2: f64, out: &mut Vec<CubicSeg>,
) {
    if (x1 - x2).abs() < 1e-12 && (y1 - y2).abs() < 1e-12 {
        return;
    }
    let mut rx = rx_in.abs();
    let mut ry = ry_in.abs();
    if rx < 1e-12 || ry < 1e-12 {
        out.push(CubicSeg::LineTo(x2, y2));
        return;
    }
    let phi = rot_deg.to_radians();
    let (sin_phi, cos_phi) = phi.sin_cos();
    let dx2 = (x1 - x2) * 0.5;
    let dy2 = (y1 - y2) * 0.5;
    let x1p = cos_phi * dx2 + sin_phi * dy2;
    let y1p = -sin_phi * dx2 + cos_phi * dy2;
    let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if lambda > 1.0 {
        let s = lambda.sqrt();
        rx *= s;
        ry *= s;
    }
    let rx2 = rx * rx;
    let ry2 = ry * ry;
    let x1p2 = x1p * x1p;
    let y1p2 = y1p * y1p;
    let num = rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2;
    let den = rx2 * y1p2 + ry2 * x1p2;
    let mut factor = if den < 1e-24 { 0.0 } else { (num / den).max(0.0).sqrt() };
    if large_arc == sweep {
        factor = -factor;
    }
    let cxp = factor * (rx * y1p / ry);
    let cyp = factor * (-ry * x1p / rx);
    let cx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) * 0.5;
    let cy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) * 0.5;
    let ux = (x1p - cxp) / rx;
    let uy = (y1p - cyp) / ry;
    let vx = (-x1p - cxp) / rx;
    let vy = (-y1p - cyp) / ry;
    let theta1 = vec_angle(1.0, 0.0, ux, uy);
    let mut dtheta = vec_angle(ux, uy, vx, vy);
    if !sweep && dtheta > 0.0 {
        dtheta -= TAU;
    } else if sweep && dtheta < 0.0 {
        dtheta += TAU;
    }
    let n_segs = (dtheta.abs() / FRAC_PI_2).ceil().clamp(1.0, 4.0) as usize;
    let delta = dtheta / (n_segs as f64);
    let alpha = (4.0 / 3.0) * (delta * 0.25).tan();
    let mut t1 = theta1;
    for k in 0..n_segs {
        let t2 = t1 + delta;
        let (sin1, cos1) = t1.sin_cos();
        let (sin2, cos2) = t2.sin_cos();
        let q1x = cos1 - alpha * sin1;
        let q1y = sin1 + alpha * cos1;
        let q2x = cos2 + alpha * sin2;
        let q2y = sin2 - alpha * cos2;
        let c1x = cx + cos_phi * (rx * q1x) - sin_phi * (ry * q1y);
        let c1y = cy + sin_phi * (rx * q1x) + cos_phi * (ry * q1y);
        let c2x = cx + cos_phi * (rx * q2x) - sin_phi * (ry * q2y);
        let c2y = cy + sin_phi * (rx * q2x) + cos_phi * (ry * q2y);
        let (ex, ey) = if k == n_segs - 1 {
            (x2, y2)
        } else {
            (
                cx + cos_phi * (rx * cos2) - sin_phi * (ry * sin2),
                cy + sin_phi * (rx * cos2) + cos_phi * (ry * sin2),
            )
        };
        out.push(CubicSeg::CurveTo(c1x, c1y, c2x, c2y, ex, ey));
        t1 = t2;
    }
}

fn path_to_cubics(d: &str, out: &mut Vec<CubicSeg>) {
    out.clear();
    let (mut cx, mut cy, mut sx, mut sy) = (0.0, 0.0, 0.0, 0.0);
    let (mut lcx, mut lcy) = (0.0, 0.0);
    let mut last_kind = 0u8;
    for seg in PathParser::from(d) {
        let seg = seg.expect("valid path");
        match seg {
            PathSegment::MoveTo { abs, x, y } => {
                let (nx, ny) = if abs { (x, y) } else { (cx + x, cy + y) };
                cx = nx; cy = ny; sx = nx; sy = ny; last_kind = 0;
                out.push(CubicSeg::MoveTo(nx, ny));
            }
            PathSegment::LineTo { abs, x, y } => {
                let (nx, ny) = if abs { (x, y) } else { (cx + x, cy + y) };
                cx = nx; cy = ny; last_kind = 0;
                out.push(CubicSeg::LineTo(nx, ny));
            }
            PathSegment::HorizontalLineTo { abs, x } => {
                let nx = if abs { x } else { cx + x };
                cx = nx; last_kind = 0;
                out.push(CubicSeg::LineTo(nx, cy));
            }
            PathSegment::VerticalLineTo { abs, y } => {
                let ny = if abs { y } else { cy + y };
                cy = ny; last_kind = 0;
                out.push(CubicSeg::LineTo(cx, ny));
            }
            PathSegment::CurveTo { abs, x1, y1, x2, y2, x, y } => {
                let (ax1, ay1) = if abs { (x1, y1) } else { (cx + x1, cy + y1) };
                let (ax2, ay2) = if abs { (x2, y2) } else { (cx + x2, cy + y2) };
                let (ax, ay) = if abs { (x, y) } else { (cx + x, cy + y) };
                out.push(CubicSeg::CurveTo(ax1, ay1, ax2, ay2, ax, ay));
                lcx = ax2; lcy = ay2; last_kind = 1; cx = ax; cy = ay;
            }
            PathSegment::SmoothCurveTo { abs, x2, y2, x, y } => {
                let (ax1, ay1) = if last_kind == 1 { (2.0 * cx - lcx, 2.0 * cy - lcy) } else { (cx, cy) };
                let (ax2, ay2) = if abs { (x2, y2) } else { (cx + x2, cy + y2) };
                let (ax, ay) = if abs { (x, y) } else { (cx + x, cy + y) };
                out.push(CubicSeg::CurveTo(ax1, ay1, ax2, ay2, ax, ay));
                lcx = ax2; lcy = ay2; last_kind = 1; cx = ax; cy = ay;
            }
            PathSegment::Quadratic { abs, x1, y1, x, y } => {
                let (qx, qy) = if abs { (x1, y1) } else { (cx + x1, cy + y1) };
                let (ax, ay) = if abs { (x, y) } else { (cx + x, cy + y) };
                let c1x = cx + (2.0 / 3.0) * (qx - cx);
                let c1y = cy + (2.0 / 3.0) * (qy - cy);
                let c2x = ax + (2.0 / 3.0) * (qx - ax);
                let c2y = ay + (2.0 / 3.0) * (qy - ay);
                out.push(CubicSeg::CurveTo(c1x, c1y, c2x, c2y, ax, ay));
                lcx = qx; lcy = qy; last_kind = 2; cx = ax; cy = ay;
            }
            PathSegment::SmoothQuadratic { abs, x, y } => {
                let (qx, qy) = if last_kind == 2 { (2.0 * cx - lcx, 2.0 * cy - lcy) } else { (cx, cy) };
                let (ax, ay) = if abs { (x, y) } else { (cx + x, cy + y) };
                let c1x = cx + (2.0 / 3.0) * (qx - cx);
                let c1y = cy + (2.0 / 3.0) * (qy - cy);
                let c2x = ax + (2.0 / 3.0) * (qx - ax);
                let c2y = ay + (2.0 / 3.0) * (qy - ay);
                out.push(CubicSeg::CurveTo(c1x, c1y, c2x, c2y, ax, ay));
                lcx = qx; lcy = qy; last_kind = 2; cx = ax; cy = ay;
            }
            PathSegment::EllipticalArc { abs, rx, ry, x_axis_rotation, large_arc, sweep, x, y } => {
                let (ax, ay) = if abs { (x, y) } else { (cx + x, cy + y) };
                arc_to_cubics(cx, cy, rx, ry, x_axis_rotation, large_arc, sweep, ax, ay, out);
                cx = ax; cy = ay; last_kind = 0;
            }
            PathSegment::ClosePath { .. } => {
                cx = sx; cy = sy; last_kind = 0;
                out.push(CubicSeg::ClosePath);
            }
        }
    }
}

fn eval_cubic(p0: f64, p1: f64, p2: f64, p3: f64, t: f64) -> f64 {
    let mt = 1.0 - t;
    mt * mt * mt * p0 + 3.0 * mt * mt * t * p1 + 3.0 * mt * t * t * p2 + t * t * t * p3
}

fn cubic_1d_bounds(p0: f64, p1: f64, p2: f64, p3: f64) -> (f64, f64) {
    let mut lo = p0.min(p3);
    let mut hi = p0.max(p3);
    let a = -p0 + 3.0 * p1 - 3.0 * p2 + p3;
    let b = 2.0 * (p0 - 2.0 * p1 + p2);
    let c = p1 - p0;
    if a.abs() < 1e-12 {
        if b.abs() >= 1e-12 {
            let t = -c / b;
            if t > 0.0 && t < 1.0 {
                let v = eval_cubic(p0, p1, p2, p3, t);
                lo = lo.min(v); hi = hi.max(v);
            }
        }
    } else {
        let disc = b * b - 4.0 * a * c;
        if disc >= 0.0 {
            let sq = disc.sqrt();
            for t in [(-b + sq) / (2.0 * a), (-b - sq) / (2.0 * a)] {
                if t > 0.0 && t < 1.0 {
                    let v = eval_cubic(p0, p1, p2, p3, t);
                    lo = lo.min(v); hi = hi.max(v);
                }
            }
        }
    }
    (lo, hi)
}

fn cubics_bbox(cubics: &[CubicSeg]) -> Option<(f64, f64, f64, f64)> {
    let mut has = false;
    let (mut min_x, mut min_y, mut max_x, mut max_y) = (0.0, 0.0, 0.0, 0.0);
    let (mut cx, mut cy, mut sx, mut sy) = (0.0, 0.0, 0.0, 0.0);
    for &seg in cubics {
        match seg {
            CubicSeg::MoveTo(x, y) => {
                cx = x; cy = y; sx = x; sy = y;
                if !has { has = true; min_x = x; max_x = x; min_y = y; max_y = y; }
                else { min_x = min_x.min(x); max_x = max_x.max(x); min_y = min_y.min(y); max_y = max_y.max(y); }
            }
            CubicSeg::LineTo(x, y) => {
                if !has { has = true; min_x = x; max_x = x; min_y = y; max_y = y; }
                else { min_x = min_x.min(x); max_x = max_x.max(x); min_y = min_y.min(y); max_y = max_y.max(y); }
                cx = x; cy = y;
            }
            CubicSeg::CurveTo(x1, y1, x2, y2, x, y) => {
                let (xlo, xhi) = cubic_1d_bounds(cx, x1, x2, x);
                let (ylo, yhi) = cubic_1d_bounds(cy, y1, y2, y);
                if !has { has = true; min_x = xlo; max_x = xhi; min_y = ylo; max_y = yhi; }
                else { min_x = min_x.min(xlo); max_x = max_x.max(xhi); min_y = min_y.min(ylo); max_y = max_y.max(yhi); }
                cx = x; cy = y;
            }
            CubicSeg::ClosePath => { cx = sx; cy = sy; }
        }
    }
    if has { Some((min_x, min_y, max_x, max_y)) } else { None }
}

fn parse_tf(s: &str) -> Tf {
    let mut acc = Tf::identity();
    for tok in TransformListParser::from(s) {
        let t = match tok.expect("valid transform") {
            TransformListToken::Matrix { a, b, c, d, e, f } => Tf { a, b, c, d, e, f },
            TransformListToken::Translate { tx, ty } => Tf { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: tx, f: ty },
            TransformListToken::Scale { sx, sy } => Tf { a: sx, b: 0.0, c: 0.0, d: sy, e: 0.0, f: 0.0 },
            TransformListToken::Rotate { angle } => {
                let (s, c) = (angle * PI / 180.0).sin_cos();
                Tf { a: c, b: s, c: -s, d: c, e: 0.0, f: 0.0 }
            }
            TransformListToken::SkewX { angle } => Tf { a: 1.0, b: 0.0, c: (angle * PI / 180.0).tan(), d: 1.0, e: 0.0, f: 0.0 },
            TransformListToken::SkewY { angle } => Tf { a: 1.0, b: (angle * PI / 180.0).tan(), c: 0.0, d: 1.0, e: 0.0, f: 0.0 },
        };
        acc = acc.mul(t);
    }
    acc
}

fn attr_f64(node: Node, name: &str) -> f64 {
    node.attribute(name).and_then(|v| v.trim().parse::<f64>().ok()).unwrap_or(0.0)
}

fn shape_cubics(node: Node, out: &mut Vec<CubicSeg>) {
    out.clear();
    match node.tag_name().name() {
        "path" => {
            if let Some(d) = node.attribute("d") {
                path_to_cubics(d, out);
            }
        }
        "rect" => {
            let (x, y, w, h) = (attr_f64(node, "x"), attr_f64(node, "y"), attr_f64(node, "width"), attr_f64(node, "height"));
            if w <= 0.0 || h <= 0.0 { return; }
            let has_rx = node.attribute("rx").is_some();
            let has_ry = node.attribute("ry").is_some();
            let mut rx = if has_rx { attr_f64(node, "rx") } else { 0.0 };
            let mut ry = if has_ry { attr_f64(node, "ry") } else { 0.0 };
            if has_rx && !has_ry { ry = rx; } else if !has_rx && has_ry { rx = ry; }
            rx = rx.clamp(0.0, w * 0.5);
            ry = ry.clamp(0.0, h * 0.5);
            if rx == 0.0 || ry == 0.0 {
                out.push(CubicSeg::MoveTo(x, y));
                out.push(CubicSeg::LineTo(x + w, y));
                out.push(CubicSeg::LineTo(x + w, y + h));
                out.push(CubicSeg::LineTo(x, y + h));
                out.push(CubicSeg::ClosePath);
            } else {
                out.push(CubicSeg::MoveTo(x + rx, y));
                out.push(CubicSeg::LineTo(x + w - rx, y));
                arc_to_cubics(x + w - rx, y, rx, ry, 0.0, false, true, x + w, y + ry, out);
                out.push(CubicSeg::LineTo(x + w, y + h - ry));
                arc_to_cubics(x + w, y + h - ry, rx, ry, 0.0, false, true, x + w - rx, y + h, out);
                out.push(CubicSeg::LineTo(x + rx, y + h));
                arc_to_cubics(x + rx, y + h, rx, ry, 0.0, false, true, x, y + h - ry, out);
                out.push(CubicSeg::LineTo(x, y + ry));
                arc_to_cubics(x, y + ry, rx, ry, 0.0, false, true, x + rx, y, out);
                out.push(CubicSeg::ClosePath);
            }
        }
        "circle" => {
            let (cx, cy, r) = (attr_f64(node, "cx"), attr_f64(node, "cy"), attr_f64(node, "r"));
            if r <= 0.0 { return; }
            out.push(CubicSeg::MoveTo(cx - r, cy));
            arc_to_cubics(cx - r, cy, r, r, 0.0, true, false, cx + r, cy, out);
            arc_to_cubics(cx + r, cy, r, r, 0.0, true, false, cx - r, cy, out);
            out.push(CubicSeg::ClosePath);
        }
        "ellipse" => {
            let (cx, cy, rx, ry) = (attr_f64(node, "cx"), attr_f64(node, "cy"), attr_f64(node, "rx"), attr_f64(node, "ry"));
            if rx <= 0.0 || ry <= 0.0 { return; }
            out.push(CubicSeg::MoveTo(cx - rx, cy));
            arc_to_cubics(cx - rx, cy, rx, ry, 0.0, true, false, cx + rx, cy, out);
            arc_to_cubics(cx + rx, cy, rx, ry, 0.0, true, false, cx - rx, cy, out);
            out.push(CubicSeg::ClosePath);
        }
        "line" => {
            out.push(CubicSeg::MoveTo(attr_f64(node, "x1"), attr_f64(node, "y1")));
            out.push(CubicSeg::LineTo(attr_f64(node, "x2"), attr_f64(node, "y2")));
        }
        "polyline" | "polygon" => {
            if let Some(pts) = node.attribute("points") {
                let nums: Vec<f64> = pts.split(|c: char| c.is_ascii_whitespace() || c == ',')
                    .filter(|s| !s.is_empty())
                    .filter_map(|s| s.parse::<f64>().ok())
                    .collect();
                for (idx, pair) in nums.chunks_exact(2).enumerate() {
                    if idx == 0 { out.push(CubicSeg::MoveTo(pair[0], pair[1])); }
                    else { out.push(CubicSeg::LineTo(pair[0], pair[1])); }
                }
                if node.tag_name().name() == "polygon" && nums.len() >= 2 {
                    out.push(CubicSeg::ClosePath);
                }
            }
        }
        _ => {}
    }
}

fn format_compact_num(v: f64, precision: i32) -> String {
    let scale = 10f64.powi(precision);
    let scaled = if v >= 0.0 { (v * scale + 0.5).floor() } else { -((-v * scale + 0.5).floor()) };
    if scaled == 0.0 { return "0".to_string(); }
    let neg = scaled < 0.0;
    let n = scaled.abs() as i64;
    let scale_i = scale as i64;
    let ipart = n / scale_i;
    let mut fpart = n % scale_i;
    if fpart == 0 {
        return if neg { format!("-{}", ipart) } else { ipart.to_string() };
    }
    let mut digits = precision as usize;
    while digits > 0 && fpart % 10 == 0 {
        fpart /= 10;
        digits -= 1;
    }
    let fstr = fpart.to_string();
    let mut out = String::new();
    if neg { out.push('-'); }
    if ipart > 0 { out.push_str(&ipart.to_string()); }
    out.push('.');
    for _ in 0..(digits - fstr.len()) { out.push('0'); }
    out.push_str(&fstr);
    out
}

fn write_path_num(out: &mut String, v: f64, precision: i32, after_cmd: bool, prev_dot: bool) -> bool {
    let s = format_compact_num(v, precision);
    if !after_cmd && !s.is_empty() {
        let first = s.as_bytes()[0];
        if first != b'-' && !(first == b'.' && prev_dot) {
            out.push(' ');
        }
    }
    let has_dot = s.contains('.');
    out.push_str(&s);
    has_dot
}

fn format_path_compact(d: &str, precision: i32) -> String {
    let mut out = String::new();
    let mut prev_cmd: u8 = 0;
    let mut prev_dot = false;
    for seg in PathParser::from(d) {
        let seg = seg.expect("valid path");
        match seg {
            PathSegment::MoveTo { abs, x, y } => {
                let cmd = if abs { b'M' } else { b'm' };
                out.push(cmd as char);
                let d1 = write_path_num(&mut out, x, precision, true, false);
                prev_dot = write_path_num(&mut out, y, precision, false, d1);
                prev_cmd = if abs { b'L' } else { b'l' };
            }
            PathSegment::LineTo { abs, x, y } => {
                let cmd = if abs { b'L' } else { b'l' };
                let wrote = prev_cmd != cmd;
                if wrote { out.push(cmd as char); }
                let d1 = write_path_num(&mut out, x, precision, wrote, prev_dot);
                prev_dot = write_path_num(&mut out, y, precision, false, d1);
                prev_cmd = cmd;
            }
            PathSegment::HorizontalLineTo { abs, x } => {
                let cmd = if abs { b'H' } else { b'h' };
                let wrote = prev_cmd != cmd;
                if wrote { out.push(cmd as char); }
                prev_dot = write_path_num(&mut out, x, precision, wrote, prev_dot);
                prev_cmd = cmd;
            }
            PathSegment::VerticalLineTo { abs, y } => {
                let cmd = if abs { b'V' } else { b'v' };
                let wrote = prev_cmd != cmd;
                if wrote { out.push(cmd as char); }
                prev_dot = write_path_num(&mut out, y, precision, wrote, prev_dot);
                prev_cmd = cmd;
            }
            PathSegment::CurveTo { abs, x1, y1, x2, y2, x, y } => {
                let cmd = if abs { b'C' } else { b'c' };
                let wrote = prev_cmd != cmd;
                if wrote { out.push(cmd as char); }
                let d1 = write_path_num(&mut out, x1, precision, wrote, prev_dot);
                let d2 = write_path_num(&mut out, y1, precision, false, d1);
                let d3 = write_path_num(&mut out, x2, precision, false, d2);
                let d4 = write_path_num(&mut out, y2, precision, false, d3);
                let d5 = write_path_num(&mut out, x, precision, false, d4);
                prev_dot = write_path_num(&mut out, y, precision, false, d5);
                prev_cmd = cmd;
            }
            PathSegment::EllipticalArc { abs, rx, ry, x_axis_rotation, large_arc, sweep, x, y } => {
                let cmd = if abs { b'A' } else { b'a' };
                let wrote = prev_cmd != cmd;
                if wrote { out.push(cmd as char); }
                let d1 = write_path_num(&mut out, rx, precision, wrote, prev_dot);
                let d2 = write_path_num(&mut out, ry, precision, false, d1);
                let _ = write_path_num(&mut out, x_axis_rotation, precision, false, d2);
                out.push(' ');
                out.push(if large_arc { '1' } else { '0' });
                out.push(if sweep { '1' } else { '0' });
                let d5 = write_path_num(&mut out, x, precision, true, false);
                prev_dot = write_path_num(&mut out, y, precision, false, d5);
                prev_cmd = cmd;
            }
            PathSegment::ClosePath { abs } => {
                out.push(if abs { 'Z' } else { 'z' });
                prev_cmd = 0;
                prev_dot = false;
            }
            _ => {}
        }
    }
    out
}

fn minify_color(val: &str) -> String {
    let t = val.trim();
    if t.starts_with('#') && t.len() == 7 {
        let b = t.as_bytes();
        let lo = t.to_ascii_lowercase();
        let lb = lo.as_bytes();
        if lb[1] == lb[2] && lb[3] == lb[4] && lb[5] == lb[6] {
            return format!("#{}{}{}", lb[1] as char, lb[3] as char, lb[5] as char);
        }
        let _ = b;
        return lo;
    }
    t.to_string()
}

fn is_empty_g(node: Node) -> bool {
    if node.tag_name().name() != "g" { return false; }
    for ch in node.children() {
        match ch.node_type() {
            NodeType::Comment | NodeType::PI => continue,
            NodeType::Text => { if !ch.text().unwrap_or("").trim().is_empty() { return false; } }
            NodeType::Element => {
                if ch.tag_name().name() == "metadata" { continue; }
                if ch.tag_name().name() == "g" && is_empty_g(ch) { continue; }
                return false;
            }
            _ => {}
        }
    }
    true
}

fn emit_opt(node: Node, out: &mut String) {
    match node.node_type() {
        NodeType::Comment | NodeType::PI => return,
        NodeType::Text => {
            let t = node.text().unwrap_or("").trim();
            if !t.is_empty() { out.push_str(t); }
            return;
        }
        NodeType::Element => {
            let tag = node.tag_name().name();
            if tag == "metadata" { return; }
            if tag == "g" && is_empty_g(node) { return; }
            if tag == "g" && node.attributes().len() == 0 {
                for ch in node.children() { emit_opt(ch, out); }
                return;
            }
            out.push('<');
            out.push_str(tag);
            if tag == "svg" {
                if let Some(ns) = node.default_namespace() {
                    out.push_str(" xmlns=\"");
                    out.push_str(ns);
                    out.push('"');
                }
            }
            for a in node.attributes() {
                let name = a.name();
                let val = if tag == "path" && name == "d" {
                    format_path_compact(a.value(), 3)
                } else if name == "fill" || name == "stroke" {
                    minify_color(a.value())
                } else {
                    a.value().to_string()
                };
                out.push(' ');
                out.push_str(name);
                out.push_str("=\"");
                out.push_str(&val);
                out.push('"');
            }
            let has_child = node.children().any(|ch| match ch.node_type() {
                NodeType::Comment | NodeType::PI => false,
                NodeType::Text => !ch.text().unwrap_or("").trim().is_empty(),
                NodeType::Element => ch.tag_name().name() != "metadata" && !is_empty_g(ch),
                _ => false,
            });
            if !has_child {
                out.push_str("/>");
            } else {
                out.push('>');
                for ch in node.children() { emit_opt(ch, out); }
                out.push_str("</");
                out.push_str(tag);
                out.push('>');
            }
        }
        _ => {}
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: svg_bench_rust <w1_paths|w2_dom|w3_opt> <file>");
        std::process::exit(1);
    }
    let mode = &args[1];
    let src = fs::read_to_string(&args[2]).expect("read input");

    if mode == "w1_paths" {
        let mut path_cnt: i64 = 0;
        let mut cubic_cnt: i64 = 0;
        let mut bbox_sum: i64 = 0;
        let mut cubics = Vec::with_capacity(32);
        for line in src.lines() {
            if line.is_empty() { continue; }
            path_to_cubics(line, &mut cubics);
            path_cnt += 1;
            cubic_cnt += cubics.len() as i64;
            if let Some((x0, y0, x1, y1)) = cubics_bbox(&cubics) {
                bbox_sum += round_tenth(x0) + round_tenth(y0) + round_tenth(x1) + round_tenth(y1);
            }
        }
        println!("mode=w1_paths");
        println!("paths={}", path_cnt);
        println!("cubics={}", cubic_cnt);
        println!("bbox_sum_10={}", bbox_sum);
        return;
    }

    if mode == "w2_dom" {
        let mut doc_cnt: i64 = 0;
        let mut rpath_cnt: i64 = 0;
        let mut seg_cnt: i64 = 0;
        let mut bbox_sum: i64 = 0;
        let mut cubics = Vec::with_capacity(32);
        for icon in src.split("\n---SVG---\n") {
            if icon.is_empty() { continue; }
            let doc = Document::parse(icon).expect("parse svg");
            doc_cnt += 1;
            let mut stack = vec![(doc.root_element(), Tf::identity())];
            while let Some((node, tf)) = stack.pop() {
                if node.node_type() != NodeType::Element { continue; }
                let tag = node.tag_name().name();
                if matches!(tag, "defs" | "metadata" | "title" | "desc" | "style" | "clipPath" | "mask" | "pattern" | "symbol") {
                    continue;
                }
                let cur_tf = match node.attribute("transform") {
                    Some(t) => tf.mul(parse_tf(t)),
                    None => tf,
                };
                if matches!(tag, "path" | "rect" | "circle" | "ellipse" | "line" | "polyline" | "polygon") {
                    shape_cubics(node, &mut cubics);
                    if !cubics.is_empty() {
                        rpath_cnt += 1;
                        for seg in &mut cubics {
                            match seg {
                                CubicSeg::MoveTo(x, y) => { let (nx, ny) = cur_tf.apply(*x, *y); *x = nx; *y = ny; }
                                CubicSeg::LineTo(x, y) => { let (nx, ny) = cur_tf.apply(*x, *y); *x = nx; *y = ny; }
                                CubicSeg::CurveTo(x1, y1, x2, y2, x, y) => {
                                    let (nx1, ny1) = cur_tf.apply(*x1, *y1);
                                    let (nx2, ny2) = cur_tf.apply(*x2, *y2);
                                    let (nx, ny) = cur_tf.apply(*x, *y);
                                    *x1 = nx1; *y1 = ny1; *x2 = nx2; *y2 = ny2; *x = nx; *y = ny;
                                }
                                CubicSeg::ClosePath => {}
                            }
                        }
                        seg_cnt += cubics.len() as i64;
                        if let Some((x0, y0, x1, y1)) = cubics_bbox(&cubics) {
                            bbox_sum += round_tenth(x0) + round_tenth(y0) + round_tenth(x1) + round_tenth(y1);
                        }
                    }
                }
                let children: Vec<Node> = node.children().collect();
                for ch in children.into_iter().rev() {
                    stack.push((ch, cur_tf));
                }
            }
        }
        println!("mode=w2_dom");
        println!("icons={}", doc_cnt);
        println!("render_paths={}", rpath_cnt);
        println!("cubics={}", seg_cnt);
        println!("bbox_sum_10={}", bbox_sum);
        return;
    }

    if mode == "w3_opt" {
        let mut icons_cnt: i64 = 0;
        let mut total_in: i64 = 0;
        let mut total_out: i64 = 0;
        let mut fnv: i64 = 1469598103934665603;
        let mut buf = String::with_capacity(1024);
        for icon in src.split("\n---SVG---\n") {
            if icon.is_empty() { continue; }
            icons_cnt += 1;
            total_in += icon.len() as i64;
            let doc = Document::parse(icon).expect("parse svg");
            buf.clear();
            emit_opt(doc.root_element(), &mut buf);
            total_out += buf.len() as i64;
            for &b in buf.as_bytes() {
                fnv = (fnv ^ (b as i64)).wrapping_mul(1099511628211);
            }
        }
        println!("mode=w3_opt");
        println!("icons={}", icons_cnt);
        println!("in_bytes={}", total_in);
        println!("out_bytes={}", total_out);
        println!("fnv64={}", fnv);
        return;
    }

    eprintln!("unknown mode: {}", mode);
    std::process::exit(1);
}
