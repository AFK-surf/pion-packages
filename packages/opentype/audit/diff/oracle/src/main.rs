//! Independent oracles for packages/opentype/audit: the same `key = value` dump protocol as
//! audit/src/main.pion, produced by ttf-parser 0.25.1 and by skrifa 0.44.0 / read-fonts 0.41.0.
//!   opentype_audit_oracle ttf|skrifa <font> <face> <queries|-> <full 0|1>
//! A line `unsupported <prefix>` tells the comparer that this oracle has no equivalent API.
use std::fmt::Write as _;
use std::{env, fs};

const FNV_OFFSET: u64 = 14695981039346656037;
fn fnv(h: u64, v: i64) -> u64 {
    (h ^ (v as u64)).wrapping_mul(1099511628211)
}
fn q4(v: f32) -> i64 {
    let v = v as f64;
    if v >= 0.0 {
        (v * 16.0 + 0.5) as i64
    } else {
        (v * 16.0 - 0.5) as i64
    }
}

#[derive(Default)]
struct Pen {
    dx: f32,
    pts: Vec<(i64, i64)>,
    moves: usize,
    full: bool,
    n: usize,
    h: u64,
    s: String,
}
impl Pen {
    fn new(full: bool) -> Self {
        Pen { dx: 0.0, pts: Vec::new(), moves: 0, full, n: 0, h: FNV_OFFSET, s: String::new() }
    }
    fn pt(&mut self, x: f32, y: f32) {
        self.pts.push((q4(x + self.dx), q4(y)));
    }
    /// Start-point / closing-segment / translation independent signature: number of contours and
    /// the sorted set of all on- and off-curve points (FreeType-style pens start contours elsewhere).
    fn geom(&self) -> String {
        let mut p = self.pts.clone();
        p.sort();
        p.dedup();
        let mut h = FNV_OFFSET;
        for (x, y) in &p {
            h = fnv(fnv(h, *x), *y);
        }
        format!("c={} p={} h={}", self.moves, p.len(), h)
    }
    fn mv(&mut self, x: f32, y: f32) {
        self.moves += 1;
        self.pt(x, y);
        self.n += 1;
        self.h = fnv(fnv(fnv(self.h, 1), q4(x)), q4(y));
        if self.full {
            let _ = write!(self.s, " M {} {}", q4(x), q4(y));
        }
    }
    fn ln(&mut self, x: f32, y: f32) {
        self.pt(x, y);
        self.n += 1;
        self.h = fnv(fnv(fnv(self.h, 2), q4(x)), q4(y));
        if self.full {
            let _ = write!(self.s, " L {} {}", q4(x), q4(y));
        }
    }
    fn qd(&mut self, cx: f32, cy: f32, x: f32, y: f32) {
        self.pt(cx, cy);
        self.pt(x, y);
        self.n += 1;
        self.h = fnv(fnv(fnv(fnv(fnv(self.h, 3), q4(cx)), q4(cy)), q4(x)), q4(y));
        if self.full {
            let _ = write!(self.s, " Q {} {} {} {}", q4(cx), q4(cy), q4(x), q4(y));
        }
    }
    fn cl(&mut self) {
        self.n += 1;
        self.h = fnv(self.h, 4);
        if self.full {
            self.s.push_str(" Z");
        }
    }
    fn text(&self) -> String {
        if self.full {
            format!("n={}{}", self.n, self.s)
        } else {
            format!("n={} h={}", self.n, self.h)
        }
    }
}
impl ttf_parser::OutlineBuilder for Pen {
    fn move_to(&mut self, x: f32, y: f32) {
        self.mv(x, y)
    }
    fn line_to(&mut self, x: f32, y: f32) {
        self.ln(x, y)
    }
    fn quad_to(&mut self, x1: f32, y1: f32, x: f32, y: f32) {
        self.qd(x1, y1, x, y)
    }
    fn curve_to(&mut self, _: f32, _: f32, _: f32, _: f32, _: f32, _: f32) {
        self.s.push_str(" C?");
    }
    fn close(&mut self) {
        self.cl()
    }
}
impl skrifa::outline::OutlinePen for Pen {
    fn move_to(&mut self, x: f32, y: f32) {
        self.mv(x, y)
    }
    fn line_to(&mut self, x: f32, y: f32) {
        self.ln(x, y)
    }
    fn quad_to(&mut self, cx0: f32, cy0: f32, x: f32, y: f32) {
        self.qd(cx0, cy0, x, y)
    }
    fn curve_to(&mut self, _: f32, _: f32, _: f32, _: f32, _: f32, _: f32) {
        self.s.push_str(" C?");
    }
    fn close(&mut self) {
        self.cl()
    }
}

fn kv(o: &mut String, k: &str, v: &str) {
    o.push_str(k);
    o.push_str(" = ");
    o.push_str(v);
    o.push('\n');
}
fn opt<T: std::fmt::Display>(v: Option<T>) -> String {
    v.map(|x| x.to_string()).unwrap_or_else(|| "-".into())
}
fn hexs(s: &str) -> String {
    if s.is_empty() {
        return "-".into();
    }
    s.bytes().map(|b| format!("{:02x}", b)).collect()
}
fn scalars() -> impl Iterator<Item = char> {
    (0u32..=0x10FFFF).filter_map(char::from_u32)
}

// --------------------------------------------------------------------------------- ttf-parser
fn dump_ttf(o: &mut String, data: &[u8], idx: u32, queries: &[String], full: bool) {
    use ttf_parser::{GlyphId, Tag};
    match ttf_parser::fonts_in_collection(data) {
        Some(n) => kv(o, "ttc", &n.to_string()),
        None => kv(o, "ttc", "none"),
    }
    let mut face = match ttf_parser::Face::parse(data, idx) {
        Ok(f) => f,
        Err(e) => {
            kv(o, "parse", "err");
            let _ = writeln!(o, "# {:?}", e);
            return;
        }
    };
    kv(o, "parse", "ok");
    o.push_str("unsupported os2f\nunsupported inst\nunsupported norm\n");
    let t = face.tables();
    let hd = t.head;
    let fmt = match hd.index_to_location_format {
        ttf_parser::head::IndexToLocationFormat::Short => 0,
        ttf_parser::head::IndexToLocationFormat::Long => 1,
    };
    kv(o, "head", &format!("{} {} {} {} {} {}", hd.units_per_em, hd.global_bbox.x_min, hd.global_bbox.y_min,
                            hd.global_bbox.x_max, hd.global_bbox.y_max, fmt));
    let ng = face.number_of_glyphs();
    kv(o, "maxp", &ng.to_string());
    let h = t.hhea;
    kv(o, "hhea", &format!("{} {} {} {}", h.ascender, h.descender, h.line_gap, h.number_of_metrics));
    match t.vhea {
        Some(v) => kv(o, "vhea", &format!("{} {} {} {}", v.ascender, v.descender, v.line_gap, v.number_of_metrics)),
        None => kv(o, "vhea", "none"),
    }
    match t.os2 {
        Some(s) => {
            kv(o, "os2a", &format!("{} {} {}", s.version, s.weight().to_number(), s.width().to_number()));
            kv(o, "os2t", &format!("{} {} {} {} {}", s.typographic_ascender(), s.typographic_descender(),
                                   s.typographic_line_gap(), s.windows_ascender() as u16, (-s.windows_descender()) as u16));
            let (a, b, c) = (s.subscript_metrics(), s.superscript_metrics(), s.strikeout_metrics());
            kv(o, "os2s", &format!("{} {} {} {} {} {} {} {} {} {}", a.x_size, a.y_size, a.x_offset, a.y_offset,
                                   b.x_size, b.y_size, b.x_offset, b.y_offset, c.thickness, c.position));
            kv(o, "os2x", &format!("{} {}", opt(s.x_height()), opt(s.capital_height())));
        }
        None => kv(o, "os2a", "none"),
    }
    match t.post {
        Some(p) => kv(o, "post", &format!("{} {} {} {}", (p.italic_angle as f64 * 65536.0).round() as i64,
                                          p.underline_metrics.position, p.underline_metrics.thickness,
                                          if p.is_monospaced { 1 } else { 0 })),
        None => kv(o, "post", "none"),
    }
    for c in scalars() {
        if let Some(g) = face.glyph_index(c) {
            kv(o, &format!("cmap {:x}", c as u32), &g.0.to_string());
        }
    }
    for g in 0..ng {
        let gid = GlyphId(g);
        let (a, b) = (t.hmtx.and_then(|m| m.advance(gid)), t.hmtx.and_then(|m| m.side_bearing(gid)));
        if a.is_some() || b.is_some() {
            kv(o, &format!("hmtx {}", g), &format!("{} {}", opt(a), opt(b)));
        }
        let (a, b) = (t.vmtx.and_then(|m| m.advance(gid)), t.vmtx.and_then(|m| m.side_bearing(gid)));
        if a.is_some() || b.is_some() {
            kv(o, &format!("vmtx {}", g), &format!("{} {}", opt(a), opt(b)));
        }
    }
    if let Some(glyf) = t.glyf {
        for g in 0..ng {
            let gid = GlyphId(g);
            if let Some(r) = glyf.bbox(gid) {
                kv(o, &format!("gbox {}", g), &format!("{} {} {} {}", r.x_min, r.y_min, r.x_max, r.y_max));
            }
            let mut pen = Pen::new(full);
            if glyf.outline(gid, &mut pen).is_some() && pen.n > 0 {
                kv(o, &format!("outl {}", g), &pen.text());
                kv(o, &format!("geom {}", g), &pen.geom());
            }
        }
    }
    for (i, n) in face.names().into_iter().enumerate() {
        let v = match n.to_string() {
            Some(s) => hexs(&s),
            None => "none".into(),
        };
        kv(o, &format!("name {}", i), &format!("{} {} {} {} {}", n.platform_id as u16, n.encoding_id, n.language_id, n.name_id, v));
    }
    for (i, a) in face.variation_axes().into_iter().enumerate() {
        let fx = |v: f32| (v as f64 * 65536.0).round() as i64;
        kv(o, &format!("axis {}", i), &format!("{:x} {} {} {} {} {}", a.tag.0, fx(a.min_value), fx(a.def_value),
                                                fx(a.max_value), if a.hidden { 1 } else { 0 }, a.name_id));
    }
    for q in queries {
        let p: Vec<&str> = q.split(' ').collect();
        match p[0] {
            "kern" => {
                let (l, r): (u16, u16) = (p[1].parse().unwrap(), p[2].parse().unwrap());
                let mut total = 0i32;
                if let Some(k) = face.tables().kern {
                    for sub in k.subtables {
                        if sub.horizontal && !sub.variable && !sub.has_cross_stream {
                            if let Some(v) = sub.glyphs_kerning(GlyphId(l), GlyphId(r)) {
                                total += v as i32;
                            }
                        }
                    }
                }
                kv(o, &format!("kern {} {}", l, r), &total.to_string());
            }
            "uvs" => {
                let (c, vs) = (u32::from_str_radix(p[1], 16).unwrap(), u32::from_str_radix(p[2], 16).unwrap());
                let mut res = "none".to_string();
                if let Some(cm) = face.tables().cmap {
                    for st in cm.subtables {
                        if let ttf_parser::cmap::Format::UnicodeVariationSequences(ref tb) = st.format {
                            res = match tb.glyph_index(c, vs) {
                                Some(ttf_parser::cmap::GlyphVariationResult::Found(g)) => g.0.to_string(),
                                Some(ttf_parser::cmap::GlyphVariationResult::UseDefault) => "default".into(),
                                None => "none".into(),
                            };
                            break;
                        }
                    }
                }
                kv(o, &format!("uvs {:x} {:x}", c, vs), &res);
            }
            "glyph" => {
                let g: u16 = p[1].parse().unwrap();
                let mut pen = Pen::new(true);
                let ok = face.tables().glyf.and_then(|gl| gl.outline(GlyphId(g), &mut pen)).is_some() && pen.n > 0;
                kv(o, &format!("ofull {}", g), &if ok { pen.text() } else { "none".to_string() });
            }
            "norm" => {
                // ttf-parser truncates (`as i16`) instead of rounding: reported as unsupported above.
                let _ = &mut face;
                let _ = Tag(0);
            }
            _ => {}
        }
    }
}

// --------------------------------------------------------------------------------- skrifa / read-fonts
fn dump_skrifa(o: &mut String, data: &[u8], idx: u32, queries: &[String], full: bool) {
    use skrifa::instance::{LocationRef, Size};
    use skrifa::outline::DrawSettings;
    use skrifa::raw::types::{GlyphId, Tag};
    use skrifa::raw::{FileRef, TableProvider};
    use skrifa::MetadataProvider;
    match FileRef::new(data) {
        Ok(FileRef::Collection(c)) => kv(o, "ttc", &c.len().to_string()),
        _ => kv(o, "ttc", "none"),
    }
    let font = match skrifa::FontRef::from_index(data, idx) {
        Ok(f) => f,
        Err(e) => {
            kv(o, "parse", "err");
            let _ = writeln!(o, "# {:?}", e);
            return;
        }
    };
    let (head, maxp) = match (font.head(), font.maxp()) {
        (Ok(h), Ok(m)) => (h, m),
        (h, m) => {
            kv(o, "parse", "err");
            let _ = writeln!(o, "# head {:?} maxp {:?}", h.err(), m.err());
            return;
        }
    };
    kv(o, "parse", "ok");
    kv(o, "head", &format!("{} {} {} {} {} {}", head.units_per_em(), head.x_min(), head.y_min(), head.x_max(),
                            head.y_max(), head.index_to_loc_format()));
    let ng = maxp.num_glyphs();
    kv(o, "maxp", &ng.to_string());
    match font.hhea() {
        Ok(h) => kv(o, "hhea", &format!("{} {} {} {}", h.ascender().to_i16(), h.descender().to_i16(),
                                        h.line_gap().to_i16(), h.number_of_h_metrics())),
        Err(_) => kv(o, "hhea", "none"),
    }
    match font.vhea() {
        Ok(h) => kv(o, "vhea", &format!("{} {} {} {}", h.ascender().to_i16(), h.descender().to_i16(),
                                        h.line_gap().to_i16(), h.number_of_long_ver_metrics())),
        Err(_) => kv(o, "vhea", "none"),
    }
    match font.os2() {
        Ok(s) => {
            kv(o, "os2a", &format!("{} {} {}", s.version(), s.us_weight_class(), s.us_width_class()));
            kv(o, "os2t", &format!("{} {} {} {} {}", s.s_typo_ascender(), s.s_typo_descender(), s.s_typo_line_gap(),
                                   s.us_win_ascent(), s.us_win_descent()));
            kv(o, "os2s", &format!("{} {} {} {} {} {} {} {} {} {}", s.y_subscript_x_size(), s.y_subscript_y_size(),
                                   s.y_subscript_x_offset(), s.y_subscript_y_offset(), s.y_superscript_x_size(),
                                   s.y_superscript_y_size(), s.y_superscript_x_offset(), s.y_superscript_y_offset(),
                                   s.y_strikeout_size(), s.y_strikeout_position()));
            kv(o, "os2x", &format!("{} {}", opt(s.sx_height()), opt(s.s_cap_height())));
            let p: String = s.panose_10().iter().map(|b| format!("{:02x}", b)).collect();
            kv(o, "os2f", &format!("{} {}", s.fs_selection().bits(), p));
        }
        Err(_) => kv(o, "os2a", "none"),
    }
    match font.post() {
        Ok(p) => kv(o, "post", &format!("{} {} {} {}", p.italic_angle().to_bits(), p.underline_position().to_i16(),
                                        p.underline_thickness().to_i16(), if p.is_fixed_pitch() != 0 { 1 } else { 0 })),
        Err(_) => kv(o, "post", "none"),
    }
    let cm = font.charmap();
    for c in scalars() {
        if let Some(g) = cm.map(c) {
            kv(o, &format!("cmap {:x}", c as u32), &g.to_u32().to_string());
        }
    }
    let (hm, vm) = (font.hmtx().ok(), font.vmtx().ok());
    for g in 0..ng {
        let gid = GlyphId::new(g as u32);
        let (a, b) = (hm.as_ref().and_then(|m| m.advance(gid)), hm.as_ref().and_then(|m| m.side_bearing(gid)));
        if a.is_some() || b.is_some() {
            kv(o, &format!("hmtx {}", g), &format!("{} {}", opt(a), opt(b)));
        }
        let (a, b) = (vm.as_ref().and_then(|m| m.advance(gid)), vm.as_ref().and_then(|m| m.side_bearing(gid)));
        if a.is_some() || b.is_some() {
            kv(o, &format!("vmtx {}", g), &format!("{} {}", opt(a), opt(b)));
        }
    }
    o.push_str("unsupported outl\n");
    if let (Ok(glyf), Ok(loca)) = (font.glyf(), font.loca(None)) {
        let og = font.outline_glyphs();
        for g in 0..ng {
            let gid = GlyphId::new(g as u32);
            let mut xmin = None;
            if let Ok(Some(gl)) = loca.get_glyf(gid, &glyf) {
                kv(o, &format!("gbox {}", g), &format!("{} {} {} {}", gl.x_min(), gl.y_min(), gl.x_max(), gl.y_max()));
                xmin = Some(gl.x_min());
            }
            if let Some(og) = og.get(gid) {
                let mut pen = Pen::new(full);
                // FreeType/skrifa translate unhinted outlines so that xMin lands on the hmtx lsb: undo it.
                let lsb = hm.as_ref().and_then(|m| m.side_bearing(gid)).unwrap_or(0);
                pen.dx = (xmin.unwrap_or(lsb) - lsb) as f32;
                let st = DrawSettings::unhinted(Size::unscaled(), LocationRef::default());
                if og.draw(st, &mut pen).is_ok() && pen.n > 0 {
                    kv(o, &format!("geom {}", g), &pen.geom());
                    if full {
                        let _ = writeln!(o, "# skrifa-outl {} dx={} {}", g, pen.dx, pen.text());
                    }
                }
            }
        }
    }
    if let Ok(name) = font.name() {
        let sd = name.string_data();
        for (i, r) in name.name_record().iter().enumerate() {
            let v = match r.string(sd) {
                Ok(s) => {
                    let enc = skrifa::raw::tables::name::Encoding::new(r.platform_id(), r.encoding_id());
                    if enc == skrifa::raw::tables::name::Encoding::Unknown {
                        "none".to_string()
                    } else {
                        hexs(&s.chars().collect::<String>())
                    }
                }
                Err(_) => "none".into(),
            };
            kv(o, &format!("name {}", i), &format!("{} {} {} {} {}", r.platform_id(), r.encoding_id(), r.language_id(),
                                                    r.name_id().to_u16(), v));
        }
    }
    let mut tags: Vec<Tag> = Vec::new();
    if let Ok(fvar) = font.fvar() {
        if let Ok(axes) = fvar.axes() {
            for (i, a) in axes.iter().enumerate() {
                tags.push(a.axis_tag());
                kv(o, &format!("axis {}", i), &format!("{:x} {} {} {} {} {}", u32::from_be_bytes(a.axis_tag().to_be_bytes()),
                                                        a.min_value().to_bits(), a.default_value().to_bits(),
                                                        a.max_value().to_bits(), if a.flags() & 1 != 0 { 1 } else { 0 },
                                                        a.axis_name_id().to_u16()));
            }
        }
        if let Ok(insts) = fvar.instances() {
            for (i, it) in insts.iter().enumerate() {
                if let Ok(it) = it {
                    let cs: Vec<String> = it.coordinates.iter().map(|c| c.get().to_bits().to_string()).collect();
                    kv(o, &format!("inst {}", i), &format!("{} {} {}", it.subfamily_name_id.to_u16(),
                                                            it.post_script_name_id.map(|n| n.to_u16().to_string()).unwrap_or_else(|| "none".into()), cs.join(",")));
                }
            }
        }
    }
    for q in queries {
        let p: Vec<&str> = q.split(' ').collect();
        match p[0] {
            "kern" => {
                let (l, r): (u32, u32) = (p[1].parse().unwrap(), p[2].parse().unwrap());
                let mut total = 0i32;
                if let Ok(k) = font.kern() {
                    for sub in k.subtables().flatten() {
                        if sub.is_horizontal() && !sub.is_cross_stream() && !sub.is_variable() {
                            if let Ok(skrifa::raw::tables::kern::SubtableKind::Format0(s0)) = sub.kind() {
                                if let Some(v) = s0.kerning(GlyphId::new(l), GlyphId::new(r)) {
                                    total += v;
                                }
                            }
                        }
                    }
                }
                kv(o, &format!("kern {} {}", l, r), &total.to_string());
            }
            "uvs" => {
                let (c, vs) = (u32::from_str_radix(p[1], 16).unwrap(), u32::from_str_radix(p[2], 16).unwrap());
                let res = match cm.map_variant(c, vs) {
                    Some(skrifa::charmap::MapVariant::UseDefault) => "default".to_string(),
                    Some(skrifa::charmap::MapVariant::Variant(g)) => g.to_u32().to_string(),
                    None => "none".into(),
                };
                kv(o, &format!("uvs {:x} {:x}", c, vs), &res);
            }
            "norm" => {
                let vals: Vec<f32> = if p[1] == "-" { vec![] } else { p[1].split(',').map(|x| x.parse().unwrap()).collect() };
                let settings: Vec<(Tag, f32)> = tags.iter().zip(vals.iter()).map(|(t, v)| (*t, *v)).collect();
                let loc = font.axes().location(settings);
                let cs: Vec<String> = loc.coords().iter().map(|c| c.to_bits().to_string()).collect();
                kv(o, &format!("norm {}", p[1]), &if cs.is_empty() { "-".to_string() } else { cs.join(",") });
            }
            _ => {}
        }
    }
}

/// Counting-only pen: constant memory, so a compound-glyph bomb costs time but never memory.
struct Count(u64);
impl ttf_parser::OutlineBuilder for Count {
    fn move_to(&mut self, _: f32, _: f32) {
        self.0 += 1
    }
    fn line_to(&mut self, _: f32, _: f32) {
        self.0 += 1
    }
    fn quad_to(&mut self, _: f32, _: f32, _: f32, _: f32) {
        self.0 += 1
    }
    fn curve_to(&mut self, _: f32, _: f32, _: f32, _: f32, _: f32, _: f32) {
        self.0 += 1
    }
    fn close(&mut self) {
        self.0 += 1
    }
}

/// `stress <font>`: the same API surface as the pion `stress` mode, timed (for DoS comparison).
fn stress_ttf(data: &[u8]) -> String {
    let t0 = std::time::Instant::now();
    let mut n = 0u64;
    if let Ok(face) = ttf_parser::Face::parse(data, 0) {
        for c in scalars() {
            if face.glyph_index(c).is_some() {
                n += 1;
            }
        }
        for g in 0..face.number_of_glyphs() {
            let mut p = Count(0);
            let _ = face.outline_glyph(ttf_parser::GlyphId(g), &mut p);
            n += p.0;
        }
        for nm in face.names() {
            n += nm.to_string().map(|s| s.len() as u64).unwrap_or(0);
        }
    }
    format!("ms={} n={}", t0.elapsed().as_millis(), n)
}

fn main() {
    let a: Vec<String> = env::args().collect();
    if a.len() == 3 && a[1] == "stress" {
        println!("{}", stress_ttf(&fs::read(&a[2]).expect("read font")));
        return;
    }
    if a.len() < 6 {
        eprintln!("usage: opentype_audit_oracle ttf|skrifa <font> <face> <queries|-> <full 0|1>");
        std::process::exit(2);
    }
    let data = fs::read(&a[2]).expect("read font");
    let idx: u32 = a[3].parse().unwrap();
    let queries: Vec<String> = if a[4] == "-" {
        vec![]
    } else {
        fs::read_to_string(&a[4]).unwrap().lines().filter(|l| !l.is_empty()).map(String::from).collect()
    };
    let full = a[5] == "1";
    let mut o = String::new();
    match a[1].as_str() {
        "ttf" => dump_ttf(&mut o, &data, idx, &queries, full),
        "skrifa" => dump_skrifa(&mut o, &data, idx, &queries, full),
        _ => std::process::exit(2),
    }
    print!("{}", o);
}
