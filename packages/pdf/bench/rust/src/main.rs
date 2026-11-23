use flate2::write::ZlibEncoder;
use flate2::Compression;
use pdf_writer::{Content, Filter, Finish, Name, Pdf, Rect, Ref, Str, TextStr};
use std::env;
use std::fs;
use std::io::Write;
use std::process;

const A4_W: f32 = 595.28;
const A4_H: f32 = 841.89;

fn make_synth_rgba(w: usize, h: usize, page_idx: usize) -> Vec<u8> {
    let mut out = vec![0u8; w * h * 4];
    for y in 0..h {
        let band = (y / 32) & 7;
        for x in 0..w {
            let off = (y * w + x) * 4;
            let (r, g, b, a) = if band == 0 || band == 4 {
                // Solid UI header / separator band (compresses well in both RLE and Flate)
                (37u8, 99u8, 235u8, 255u8)
            } else if band == 1 || band == 5 {
                // Clean white page background with occasional dark text blocks
                if (x / 16 + y / 8 + page_idx) % 11 == 0 {
                    (24u8, 24u8, 27u8, 255u8)
                } else {
                    (255u8, 255u8, 255u8, 255u8)
                }
            } else {
                // Smooth gradient + translucent overlay
                let rv = ((x * 255) / (w - 1)) as u8;
                let gv = ((y * 255) / (h - 1)) as u8;
                let bv = ((page_idx * 37 + (x >> 2)) & 0xFF) as u8;
                (rv, gv, bv, 224u8)
            };
            out[off] = r;
            out[off + 1] = g;
            out[off + 2] = b;
            out[off + 3] = a;
        }
    }
    out
}

fn rgba_to_white_rgb(rgba: &[u8], w: usize, h: usize) -> Vec<u8> {
    let count = w * h;
    let mut rgb = vec![0xFFu8; count * 3];
    for p in 0..count {
        let s = p * 4;
        let d = p * 3;
        let a = rgba[s + 3] as u32;
        if a >= 255 {
            rgb[d] = rgba[s];
            rgb[d + 1] = rgba[s + 1];
            rgb[d + 2] = rgba[s + 2];
        } else if a > 0 {
            let inv = 255 - a;
            rgb[d] = ((rgba[s] as u32 * a + 255 * inv) / 255) as u8;
            rgb[d + 1] = ((rgba[s + 1] as u32 * a + 255 * inv) / 255) as u8;
            rgb[d + 2] = ((rgba[s + 2] as u32 * a + 255 * inv) / 255) as u8;
        }
    }
    rgb
}

fn rle_encode(src: &[u8]) -> Vec<u8> {
    let n = src.len();
    let mut out = Vec::with_capacity(n + n / 128 + 16);
    let mut i = 0;
    while i < n {
        let b = src[i];
        let mut run = 1;
        while i + run < n && run < 128 && src[i + run] == b {
            run += 1;
        }
        if run >= 3 {
            out.push((257 - run) as u8);
            out.push(b);
            i += run;
        } else {
            let start = i;
            let mut lit = 0;
            while i < n && lit < 128 {
                if i + 2 < n && src[i] == src[i + 1] && src[i] == src[i + 2] {
                    break;
                }
                i += 1;
                lit += 1;
            }
            if lit == 0 {
                out.push(0);
                out.push(src[i]);
                i += 1;
            } else {
                out.push((lit - 1) as u8);
                out.extend_from_slice(&src[start..start + lit]);
            }
        }
    }
    out.push(0x80);
    out
}

fn zlib_compress_6(src: &[u8]) -> Vec<u8> {
    let mut enc = ZlibEncoder::new(Vec::new(), Compression::new(6));
    enc.write_all(src).unwrap();
    enc.finish().unwrap()
}

fn bench_report100(pages: usize) -> Vec<u8> {
    let mut pdf = Pdf::new();
    let catalog_id = Ref::new(1);
    let pages_id = Ref::new(2);
    let info_id = Ref::new(3);
    let f1_id = Ref::new(4);
    let f2_id = Ref::new(5);
    let f3_id = Ref::new(6);

    pdf.catalog(catalog_id).pages(pages_id);
    pdf.document_info(info_id)
        .title(TextStr("Quarterly Report (100 Pages) \\ Benchmark"))
        .author(TextStr("PDF Benchmark"))
        .creator(TextStr("pdf-writer"));

    pdf.type1_font(f1_id).base_font(Name(b"Helvetica"));
    pdf.type1_font(f2_id).base_font(Name(b"Helvetica-Bold"));
    pdf.type1_font(f3_id).base_font(Name(b"Courier"));

    let mut page_ids = Vec::with_capacity(pages);
    let mut next_id = 7;
    for _ in 0..pages {
        page_ids.push(Ref::new(next_id));
        next_id += 2;
    }
    pdf.pages(pages_id)
        .kids(page_ids.iter().copied())
        .count(pages as i32);

    for p in 0..pages {
        let pid = page_ids[p];
        let cid = Ref::new(pid.get() + 1);

        let mut page = pdf.page(pid);
        page.media_box(Rect::new(0.0, 0.0, A4_W, A4_H));
        page.parent(pages_id);
        page.contents(cid);
        let mut res = page.resources();
        let mut fonts = res.fonts();
        fonts.pair(Name(b"F1"), f1_id);
        fonts.pair(Name(b"F2"), f2_id);
        fonts.pair(Name(b"F3"), f3_id);
        fonts.finish();
        res.finish();
        page.finish();

        let mut c = Content::new();
        c.save_state();
        c.set_fill_rgb(0.12, 0.28, 0.56);
        c.rect(40.0, 760.0, 515.28, 42.0);
        c.fill_nonzero();
        c.set_fill_rgb(1.0, 1.0, 1.0);
        let title = format!("Quarterly Financial Summary (Page {}) \\ Confidential", p + 1);
        c.begin_text();
        c.set_font(Name(b"F2"), 16.0);
        c.set_text_matrix([1.0, 0.0, 0.0, 1.0, 52.0, 776.0]);
        c.show(Str(title.as_bytes()));
        c.end_text();

        c.set_fill_rgb(0.1, 0.1, 0.1);
        c.begin_text();
        c.set_font(Name(b"F1"), 10.0);
        c.set_text_matrix([1.0, 0.0, 0.0, 1.0, 40.0, 742.0]);
        c.show(Str(b"Generated by pure PDF 1.4 engine - ISO 32000-1"));
        c.end_text();

        c.set_stroke_rgb(0.2, 0.45, 0.8);
        c.set_line_width(1.25);
        c.move_to(40.0, 730.0);
        c.line_to(555.28, 730.0);
        c.cubic_to(460.0, 710.0, 160.0, 710.0, 40.0, 695.0);
        c.stroke();

        for r in 0..20 {
            let y = 660.0 - (r as f32) * 28.0;
            if r % 2 == 0 {
                c.set_fill_rgb(0.95, 0.96, 0.98);
                c.rect(40.0, y - 6.0, 515.28, 22.0);
                c.fill_nonzero();
            }
            c.set_fill_rgb(0.1, 0.1, 0.12);
            let label = format!("Line Item #{:02} (Dept {})", r + 1, (p + r) % 7 + 1);
            c.begin_text();
            c.set_font(Name(b"F1"), 9.0);
            c.set_text_matrix([1.0, 0.0, 0.0, 1.0, 48.0, y]);
            c.show(Str(label.as_bytes()));
            c.end_text();

            let val = format!("USD {:>8}.{:02}", (p + 1) * 100 + r * 37, (r * 19) % 100);
            c.begin_text();
            c.set_font(Name(b"F3"), 9.0);
            c.set_text_matrix([1.0, 0.0, 0.0, 1.0, 420.0, y]);
            c.show(Str(val.as_bytes()));
            c.end_text();
        }
        c.restore_state();

        let compressed = zlib_compress_6(&c.finish());
        pdf.stream(cid, &compressed).filter(Filter::FlateDecode);
    }

    pdf.finish()
}

fn bench_images(pages: &[Vec<u8>], w: usize, h: usize, use_flate: bool) -> Vec<u8> {
    let mut pdf = Pdf::new();
    let catalog_id = Ref::new(1);
    let pages_id = Ref::new(2);
    pdf.catalog(catalog_id).pages(pages_id);

    let n = pages.len();
    let mut page_ids = Vec::with_capacity(n);
    let mut next_id = 3;
    for _ in 0..n {
        page_ids.push(Ref::new(next_id));
        next_id += 3;
    }
    pdf.pages(pages_id)
        .kids(page_ids.iter().copied())
        .count(n as i32);

    for (i, rgba) in pages.iter().enumerate() {
        let pid = page_ids[i];
        let cid = Ref::new(pid.get() + 1);
        let iid = Ref::new(pid.get() + 2);

        let mut page = pdf.page(pid);
        page.media_box(Rect::new(0.0, 0.0, A4_W, A4_H));
        page.parent(pages_id);
        page.contents(cid);
        let mut res = page.resources();
        res.x_objects().pair(Name(b"Im0"), iid);
        res.finish();
        page.finish();

        let mut c = Content::new();
        c.save_state();
        c.transform([A4_W, 0.0, 0.0, A4_H, 0.0, 0.0]);
        c.x_object(Name(b"Im0"));
        c.restore_state();
        let raw_c = c.finish();
        pdf.stream(cid, &raw_c);

        let rgb = rgba_to_white_rgb(rgba, w, h);
        let encoded = if use_flate {
            zlib_compress_6(&rgb)
        } else {
            rle_encode(&rgb)
        };
        let mut img = pdf.image_xobject(iid, &encoded);
        img.filter(if use_flate {
            Filter::FlateDecode
        } else {
            Filter::RunLengthDecode
        });
        img.width(w as i32);
        img.height(h as i32);
        img.color_space().device_rgb();
        img.bits_per_component(8);
        img.finish();
    }

    pdf.finish()
}

fn check_pdf_basic(data: &[u8]) -> (u8, u8) {
    let hdr = if data.starts_with(b"%PDF-1.") { 1 } else { 0 };
    let eof = if data.ends_with(b"%%EOF\n") || data.ends_with(b"%%EOF") {
        1
    } else {
        0
    };
    (hdr, eof)
}

fn verify_with_lopdf(path: &str, expected_pages: usize) {
    let doc = lopdf::Document::load(path).unwrap_or_else(|e| {
        eprintln!("lopdf failed to parse {}: {}", path, e);
        process::exit(1);
    });
    let actual_pages = doc.get_pages().len();
    if actual_pages != expected_pages {
        eprintln!(
            "lopdf page count mismatch for {}: expected {}, got {}",
            path, expected_pages, actual_pages
        );
        process::exit(1);
    }
    println!(
        "lopdf OK: {} -> version={} objects={} pages={}",
        path,
        doc.version,
        doc.objects.len(),
        actual_pages
    );
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: pdf-bench-rust <report100|images_flate|images_rle|lopdf_verify> [args...]");
        process::exit(1);
    }
    let mode = args[1].as_str();
    if mode == "lopdf_verify" {
        if args.len() < 4 {
            eprintln!("usage: pdf-bench-rust lopdf_verify <pdf_path> <expected_pages>");
            process::exit(1);
        }
        let expected: usize = args[3].parse().unwrap();
        verify_with_lopdf(&args[2], expected);
        return;
    }

    let dump_path = args.get(2).map(|s| s.as_str());
    match mode {
        "report100" => {
            let pdf = bench_report100(100);
            let (hdr, eof) = check_pdf_basic(&pdf);
            if let Some(p) = dump_path {
                fs::write(p, &pdf).unwrap();
            }
            println!(
                "mode=report100 pages=100 header_ok={} eof_ok={} non_empty={}",
                hdr,
                eof,
                if pdf.len() > 10000 { 1 } else { 0 }
            );
        }
        "images_flate" => {
            let w = 800;
            let h = 600;
            let pages: Vec<Vec<u8>> = (0..10).map(|i| make_synth_rgba(w, h, i)).collect();
            let pdf = bench_images(&pages, w, h, true);
            let (hdr, eof) = check_pdf_basic(&pdf);
            if let Some(p) = dump_path {
                fs::write(p, &pdf).unwrap();
            }
            println!(
                "mode=images_flate pages=10 raw_rgb_bytes={} header_ok={} eof_ok={} non_empty={}",
                10 * w * h * 3,
                hdr,
                eof,
                if pdf.len() > 10000 { 1 } else { 0 }
            );
        }
        "images_rle" => {
            let w = 800;
            let h = 600;
            let pages: Vec<Vec<u8>> = (0..10).map(|i| make_synth_rgba(w, h, i)).collect();
            let pdf = bench_images(&pages, w, h, false);
            let (hdr, eof) = check_pdf_basic(&pdf);
            if let Some(p) = dump_path {
                fs::write(p, &pdf).unwrap();
            }
            println!(
                "mode=images_rle pages=10 raw_rgb_bytes={} header_ok={} eof_ok={} non_empty={}",
                10 * w * h * 3,
                hdr,
                eof,
                if pdf.len() > 10000 { 1 } else { 0 }
            );
        }
        _ => {
            eprintln!("unknown mode: {}", mode);
            process::exit(1);
        }
    }
}
