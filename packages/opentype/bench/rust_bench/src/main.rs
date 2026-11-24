use std::env;
use std::fs;
use ttf_parser::{Face, GlyphId, OutlineBuilder};

const FNV_OFFSET: u64 = 14695981039346656037;
const FNV_PRIME: u64 = 1099511628211;

#[inline]
fn fnv1a_i64(h: u64, v: i64) -> u64 {
    (h ^ (v as u64)).wrapping_mul(FNV_PRIME)
}

#[inline]
fn q4(v: f32) -> i64 {
    let vd = v as f64;
    if vd >= 0.0 {
        (vd * 16.0 + 0.5) as i64
    } else {
        (vd * 16.0 - 0.5) as i64
    }
}

struct HashOutline {
    h: u64,
    cmds: usize,
}

impl OutlineBuilder for HashOutline {
    fn move_to(&mut self, x: f32, y: f32) {
        self.cmds += 1;
        self.h = fnv1a_i64(self.h, 1);
        self.h = fnv1a_i64(self.h, q4(x));
        self.h = fnv1a_i64(self.h, q4(y));
    }
    fn line_to(&mut self, x: f32, y: f32) {
        self.cmds += 1;
        self.h = fnv1a_i64(self.h, 2);
        self.h = fnv1a_i64(self.h, q4(x));
        self.h = fnv1a_i64(self.h, q4(y));
    }
    fn quad_to(&mut self, x1: f32, y1: f32, x: f32, y: f32) {
        self.cmds += 1;
        self.h = fnv1a_i64(self.h, 3);
        self.h = fnv1a_i64(self.h, q4(x1));
        self.h = fnv1a_i64(self.h, q4(y1));
        self.h = fnv1a_i64(self.h, q4(x));
        self.h = fnv1a_i64(self.h, q4(y));
    }
    fn curve_to(&mut self, _x1: f32, _y1: f32, _x2: f32, _y2: f32, _x: f32, _y: f32) {}
    fn close(&mut self) {
        self.cmds += 1;
        self.h = fnv1a_i64(self.h, 4);
    }
}

fn f32_to_fixed16_16(v: f32) -> i64 {
    let vd = v as f64;
    if vd >= 0.0 {
        (vd * 65536.0 + 0.5) as i64
    } else {
        (vd * 65536.0 - 0.5) as i64
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: opentype_rust_bench <diff|bench> <font_path> <face_index> [iters]");
        std::process::exit(1);
    }
    let mode = &args[1];
    let data = fs::read(&args[2]).expect("failed to read font");
    let face_idx: u32 = args[3].parse().expect("invalid face_index");

    if mode == "diff" {
        let ttc_cnt = ttf_parser::fonts_in_collection(&data).unwrap_or(0);
        let face = Face::parse(&data, face_idx).expect("Face::parse failed");
        let ng = face.number_of_glyphs() as usize;
        let bb = face.global_bounding_box();
        let h = face.tables().hhea;
        let (h_asc, h_desc, h_gap) = (h.ascender as i32, h.descender as i32, h.line_gap as i32);
        let (w_cls, wd_cls, t_asc, t_desc, t_gap, xh, ch) = match face.tables().os2 {
            Some(o) => (
                o.weight().to_number() as i32,
                o.width().to_number() as i32,
                o.typographic_ascender() as i32,
                o.typographic_descender() as i32,
                o.typographic_line_gap() as i32,
                o.x_height().map(|v| v as i32).unwrap_or(-99999),
                o.capital_height().map(|v| v as i32).unwrap_or(-99999),
            ),
            None => (0, 0, 0, 0, 0, -99999, -99999),
        };
        let (u_pos, u_thick, fixed_p) = match face.tables().post {
            Some(p) => (
                p.underline_metrics.position as i32,
                p.underline_metrics.thickness as i32,
                if p.is_monospaced { 1 } else { 0 },
            ),
            None => (0, 0, 0),
        };

        // 1. Full Unicode cmap sweep
        let mut cmap_h = FNV_OFFSET;
        let mut cmap_cnt = 0usize;
        for cp in 0u32..=0x10FFFF {
            if let Some(c) = char::from_u32(cp) {
                if let Some(gid) = face.glyph_index(c) {
                    cmap_cnt += 1;
                    cmap_h = fnv1a_i64(cmap_h, cp as i64);
                    cmap_h = fnv1a_i64(cmap_h, gid.0 as i64);
                }
            }
        }

        // 2. Full hmtx sweep
        let mut hmtx_h = FNV_OFFSET;
        for gid in 0..ng {
            let g = GlyphId(gid as u16);
            let adv = face.glyph_hor_advance(g).map(|v| v as i32).unwrap_or(-1);
            let lsb = face
                .glyph_hor_side_bearing(g)
                .map(|v| v as i32)
                .unwrap_or(-99999);
            hmtx_h = fnv1a_i64(hmtx_h, adv as i64);
            hmtx_h = fnv1a_i64(hmtx_h, lsb as i64);
        }

        // 3. kern sweep (horizontal format 0 subtables)
        let kern_lim = ng.min(256);
        let mut kern_h = FNV_OFFSET;
        let mut kern_nz = 0usize;
        if let Some(kern) = face.tables().kern {
            for l in 0..kern_lim {
                for r in 0..kern_lim {
                    let mut total: i32 = 0;
                    for sub in kern.subtables {
                        if sub.horizontal && !sub.variable && !sub.has_cross_stream {
                            if let Some(v) = sub.glyphs_kerning(GlyphId(l as u16), GlyphId(r as u16)) {
                                total += v as i32;
                            }
                        }
                    }
                    if total != 0 {
                        kern_nz += 1;
                        kern_h = fnv1a_i64(kern_h, l as i64);
                        kern_h = fnv1a_i64(kern_h, r as i64);
                        kern_h = fnv1a_i64(kern_h, total as i64);
                    }
                }
            }
        }

        // 4. Full glyf bbox + outline sweep (only for TrueType glyf fonts)
        let mut bbox_h = FNV_OFFSET;
        let mut bbox_cnt = 0usize;
        let mut out_h = FNV_OFFSET;
        let mut out_cmds = 0usize;
        let out_lim = ng.min(512);
        if let Some(glyf) = face.tables().glyf {
            for gid in 0..ng {
                let g = GlyphId(gid as u16);
                if let Some(r) = glyf.bbox(g) {
                    bbox_cnt += 1;
                    bbox_h = fnv1a_i64(bbox_h, gid as i64);
                    bbox_h = fnv1a_i64(bbox_h, r.x_min as i64);
                    bbox_h = fnv1a_i64(bbox_h, r.y_min as i64);
                    bbox_h = fnv1a_i64(bbox_h, r.x_max as i64);
                    bbox_h = fnv1a_i64(bbox_h, r.y_max as i64);
                }
                if gid < out_lim {
                    let mut ob = HashOutline {
                        h: fnv1a_i64(out_h, gid as i64),
                        cmds: 0,
                    };
                    if glyf.outline(g, &mut ob).is_some() {
                        out_cmds += ob.cmds;
                        out_h = ob.h;
                    }
                }
            }
        }

        // 5. fvar axes hash
        let mut fvar_h = FNV_OFFSET;
        let mut fvar_n = 0usize;
        for ax in face.variation_axes() {
            fvar_n += 1;
            fvar_h = fnv1a_i64(fvar_h, ax.tag.0 as i64);
            fvar_h = fnv1a_i64(fvar_h, f32_to_fixed16_16(ax.min_value));
            fvar_h = fnv1a_i64(fvar_h, f32_to_fixed16_16(ax.def_value));
            fvar_h = fnv1a_i64(fvar_h, f32_to_fixed16_16(ax.max_value));
            fvar_h = fnv1a_i64(fvar_h, ax.name_id as i64);
        }

        println!(
            "ttc={} upem={} ng={} bbox={},{},{},{}",
            ttc_cnt,
            face.units_per_em(),
            ng,
            bb.x_min,
            bb.y_min,
            bb.x_max,
            bb.y_max
        );
        println!(
            "hhea={},{},{} os2={},{},{},{},{},{},{} post={},{},{}",
            h_asc, h_desc, h_gap, w_cls, wd_cls, t_asc, t_desc, t_gap, xh, ch, u_pos, u_thick, fixed_p
        );
        println!(
            "cmap_cnt={} cmap_h={} hmtx_h={} kern_nz={} kern_h={}",
            cmap_cnt, cmap_h, hmtx_h, kern_nz, kern_h
        );
        println!(
            "bbox_cnt={} bbox_h={} out_cmds={} out_h={} fvar_n={} fvar_h={}",
            bbox_cnt, bbox_h, out_cmds, out_h, fvar_n, fvar_h
        );
        return;
    }

    if mode == "bench" {
        let iters: usize = args[4].parse().expect("invalid iters");
        let mut h = FNV_OFFSET;
        for _ in 0..iters {
            let face = Face::parse(&data, face_idx).expect("Face::parse failed");
            let ng = face.number_of_glyphs() as usize;
            h = fnv1a_i64(h, face.units_per_em() as i64);
            for cp in 32u32..288 {
                if let Some(c) = char::from_u32(cp) {
                    if let Some(gid) = face.glyph_index(c) {
                        h = fnv1a_i64(h, gid.0 as i64);
                        if let Some(adv) = face.glyph_hor_advance(gid) {
                            h = fnv1a_i64(h, adv as i64);
                        }
                    }
                }
            }
            let out_lim = ng.min(64);
            for g in 0..out_lim {
                let mut ob = HashOutline { h, cmds: 0 };
                if face.outline_glyph(GlyphId(g as u16), &mut ob).is_some() {
                    h = ob.h;
                }
            }
        }
        println!("BENCH_OK iters={} hash={}", iters, h);
        return;
    }

    eprintln!("unknown mode: {}", mode);
    std::process::exit(1);
}
