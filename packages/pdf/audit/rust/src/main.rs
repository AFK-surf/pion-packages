//! Third-party oracle for the `packages/pdf` red-team audit.
//!
//! `oracle check <fixture_dir>` loads every fixture written by `probe gen` with Rust `lopdf =0.35.0`
//! and, independently of lopdf's lenient recovery, re-checks the raw bytes (xref offsets, `/Length`),
//! the decoded content streams (operators, operands, resource references), `/Info` keys and string
//! bytes, image sample counts and JPEG SOF headers. Every line is `CHECK <file> <name> PASS|FAIL <detail>`.
//! `oracle mkvalidate <dir>` writes hostile inputs for `probe validate` / `rle` / `flate`.

use lopdf::content::Content;
use lopdf::{Document, Object, ObjectId};
use std::collections::{BTreeSet, HashMap};
use std::io::Read;

const PAYLOADS: [&str; 10] = [
    ") /JS (app.alert(1)) /S /JavaScript /Z (",
    "\\) /OpenAction 99 0 R /Q (\\",
    "unbalanced ((( no close",
    "unbalanced ))) no open",
    "trailing backslash \\",
    "CR\rLF\nCRLF\r\n>>\nendobj\n9 0 obj\n<</Type /Action>>",
    "NUL\u{0}inside and \u{7F} DEL and \t tab",
    "ET BT /F1 99 Tf (pwn) Tj",
    "héllo — “quotes” €",
    "中文 😀",
];

const STD14: [&str; 14] = [
    "Helvetica",
    "Helvetica-Bold",
    "Helvetica-Oblique",
    "Helvetica-BoldOblique",
    "Times-Roman",
    "Times-Bold",
    "Times-Italic",
    "Times-BoldItalic",
    "Courier",
    "Courier-Bold",
    "Courier-Oblique",
    "Courier-BoldOblique",
    "Symbol",
    "ZapfDingbats",
];

struct Rep {
    file: String,
    fails: usize,
}

impl Rep {
    fn check(&mut self, name: &str, ok: bool, detail: impl AsRef<str>) {
        if !ok {
            self.fails += 1;
        }
        println!(
            "CHECK {} {} {} {}",
            self.file,
            name,
            if ok { "PASS" } else { "FAIL" },
            detail.as_ref()
        );
    }
}

fn find(h: &[u8], n: &[u8], from: usize) -> Option<usize> {
    if n.is_empty() || h.len() < n.len() {
        return None;
    }
    (from..=h.len() - n.len()).find(|&i| &h[i..i + n.len()] == n)
}

fn rfind(h: &[u8], n: &[u8]) -> Option<usize> {
    (0..=h.len().checked_sub(n.len())?)
        .rev()
        .find(|&i| &h[i..i + n.len()] == n)
}

/// Strict raw-byte xref + stream-length check, independent of lopdf's recovery logic.
fn raw_structure(r: &mut Rep, b: &[u8]) {
    let sx = match rfind(b, b"startxref") {
        Some(p) => p,
        None => return r.check("raw_startxref", false, "no startxref"),
    };
    let tail = String::from_utf8_lossy(&b[sx + 9..]);
    let off: usize = tail
        .split_whitespace()
        .next()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    r.check(
        "raw_startxref",
        b[off..].starts_with(b"xref"),
        format!("startxref={off}"),
    );
    let text = String::from_utf8_lossy(&b[off..sx]).to_string();
    let mut lines = text.split('\n');
    lines.next();
    let hdr: Vec<usize> = lines
        .next()
        .unwrap_or("")
        .split_whitespace()
        .filter_map(|s| s.parse().ok())
        .collect();
    let count = *hdr.get(1).unwrap_or(&0);
    let mut bad = vec![];
    let mut entry_len_ok = true;
    let body = &b[off..];
    let first_entry = find(body, b"\n", find(body, b"\n", 0).unwrap() + 1).unwrap() + 1;
    for i in 0..count {
        let e = &body[first_entry + i * 20..first_entry + i * 20 + 20];
        if e[18] != b' ' && e[18] != b'\r' || e[19] != b'\n' {
            entry_len_ok = false;
        }
        let o: usize = std::str::from_utf8(&e[..10]).unwrap().parse().unwrap();
        if e[17] == b'n' {
            let want = format!("{i} 0 obj");
            if !b[o..].starts_with(want.as_bytes()) {
                bad.push(i);
            }
        }
    }
    r.check(
        "raw_xref_20byte_entries",
        entry_len_ok,
        format!("{count} entries"),
    );
    r.check(
        "raw_xref_offsets_exact",
        bad.is_empty(),
        format!("bad objects {bad:?}"),
    );
    // every stream: /Length == bytes between "stream\n" and "\nendstream"
    let mut pos = 0;
    let mut nstreams = 0;
    let mut len_bad = vec![];
    while let Some(s) = find(b, b">>\nstream\n", pos) {
        let dstart = s + 10;
        let dict_start = rfind(&b[..s], b"obj\n").unwrap_or(0);
        let dict = String::from_utf8_lossy(&b[dict_start..s]).to_string();
        let len: usize = dict
            .split("/Length ")
            .nth(1)
            .and_then(|t| t.split(|c: char| !c.is_ascii_digit()).next())
            .and_then(|t| t.parse().ok())
            .unwrap_or(usize::MAX);
        if dstart + len > b.len() || !b[dstart + len..].starts_with(b"\nendstream") {
            len_bad.push(dstart);
        }
        nstreams += 1;
        pos = dstart + len.min(b.len() - dstart);
    }
    r.check(
        "raw_stream_lengths_exact",
        len_bad.is_empty(),
        format!("{nstreams} streams, bad at {len_bad:?}"),
    );
}

fn rle_decode(src: &[u8]) -> Vec<u8> {
    let mut out = vec![];
    let mut i = 0;
    while i < src.len() {
        let c = src[i] as usize;
        i += 1;
        if c == 128 {
            break;
        } else if c < 128 {
            out.extend_from_slice(&src[i..(i + c + 1).min(src.len())]);
            i += c + 1;
        } else if i < src.len() {
            out.extend(std::iter::repeat(src[i]).take(257 - c));
            i += 1;
        }
    }
    out
}

fn decode_stream(s: &lopdf::Stream) -> Result<Vec<u8>, String> {
    match s.dict.get(b"Filter").ok().and_then(|f| f.as_name().ok()) {
        None => Ok(s.content.clone()),
        Some(b"FlateDecode") => {
            let mut out = vec![];
            flate2::read::ZlibDecoder::new(&s.content[..])
                .read_to_end(&mut out)
                .map_err(|e| e.to_string())?;
            Ok(out)
        }
        Some(b"RunLengthDecode") => Ok(rle_decode(&s.content)),
        Some(b"DCTDecode") => Ok(s.content.clone()),
        Some(f) => Err(format!("unknown filter {}", String::from_utf8_lossy(f))),
    }
}

/// (width, height, components, adobe_app14_transform) from the first SOFn of a JPEG.
fn jpeg_sof(j: &[u8]) -> Option<(u32, u32, u8, Option<u8>)> {
    let mut i = 2;
    let mut adobe = None;
    while i + 4 <= j.len() {
        if j[i] != 0xFF {
            return None;
        }
        let m = j[i + 1];
        let len = ((j[i + 2] as usize) << 8) | j[i + 3] as usize;
        if m == 0xEE && j[i + 4..].starts_with(b"Adobe") {
            adobe = Some(j[i + 4 + 11]);
        }
        if (0xC0..=0xCF).contains(&m) && m != 0xC4 && m != 0xC8 && m != 0xCC {
            let h = ((j[i + 5] as u32) << 8) | j[i + 6] as u32;
            let w = ((j[i + 7] as u32) << 8) | j[i + 8] as u32;
            return Some((w, h, j[i + 9], adobe));
        }
        i += 2 + len;
    }
    None
}

fn obj_num(o: &Object) -> f64 {
    match o {
        Object::Integer(i) => *i as f64,
        Object::Real(f) => *f as f64,
        _ => f64::NAN,
    }
}

fn check_file(dir: &str, file: &str) -> usize {
    let path = format!("{dir}/{file}");
    let bytes = match std::fs::read(&path) {
        Ok(b) => b,
        Err(_) => {
            println!("CHECK {file} exists FAIL missing (probe gen error?)");
            return 1;
        }
    };
    let mut r = Rep {
        file: file.to_string(),
        fails: 0,
    };
    raw_structure(&mut r, &bytes);
    let doc = match Document::load_mem(&bytes) {
        Ok(d) => d,
        Err(e) => {
            r.check("lopdf_load", false, format!("{e}"));
            return r.fails;
        }
    };
    r.check("lopdf_load", true, format!("{} objects", doc.objects.len()));
    let pages = doc.get_pages();
    let count = doc
        .catalog()
        .ok()
        .and_then(|c| c.get(b"Pages").ok())
        .and_then(|p| p.as_reference().ok())
        .and_then(|id| doc.get_dictionary(id).ok())
        .and_then(|d| d.get(b"Count").ok())
        .and_then(|c| c.as_i64().ok())
        .unwrap_or(-1);
    r.check(
        "page_count",
        pages.len() as i64 == count,
        format!("lopdf pages={} /Count={count}", pages.len()),
    );
    if file == "empty.pdf" {
        r.check(
            "nonzero_pages",
            count >= 1,
            "encode() emits /Count 0 /Kids [] without error; a PDF with no page has nothing to display and many viewers refuse to open it",
        );
    }

    // /Info
    if let Ok(info_ref) = doc.trailer.get(b"Info").and_then(Object::as_reference) {
        let info = doc.get_dictionary(info_ref).unwrap();
        let keys: BTreeSet<String> = info
            .iter()
            .map(|(k, _)| String::from_utf8_lossy(k).to_string())
            .collect();
        let allowed: BTreeSet<String> = [
            "Title", "Author", "Subject", "Keywords", "Creator", "Producer",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        r.check(
            "info_no_injected_keys",
            keys.is_subset(&allowed),
            format!("keys={keys:?}"),
        );
        if file == "inject.pdf" {
            let want = [
                ("Title", PAYLOADS[0].to_string()),
                ("Author", PAYLOADS[1].to_string()),
                ("Subject", PAYLOADS[5].to_string()),
                ("Keywords", PAYLOADS[6].to_string()),
                (
                    "Creator",
                    format!("{}{}{}", PAYLOADS[2], PAYLOADS[3], PAYLOADS[4]),
                ),
            ];
            for (k, v) in want {
                let got = info
                    .get(k.as_bytes())
                    .and_then(Object::as_str)
                    .unwrap_or(b"");
                r.check(
                    &format!("info_{k}_bytes_roundtrip"),
                    got == v.as_bytes(),
                    format!("{:?}", String::from_utf8_lossy(got)),
                );
            }
            let prod = format!("{} {}", PAYLOADS[8], PAYLOADS[9]);
            let decoded = info.get(b"Producer").map(|o| lopdf::decode_text_string(o));
            let shown = match &decoded {
                Ok(Ok(s)) => s.clone(),
                Ok(Err(e)) => format!("<decode error {e}>"),
                Err(_) => "<missing>".into(),
            };
            r.check(
                "info_non_ascii_text_string",
                shown == prod,
                format!(
                    "want {prod:?}; a conforming reader (PDFDocEncoding, no BOM) shows {shown:?}"
                ),
            );
        }
    }

    // pages
    for (pno, pid) in &pages {
        let page = doc.get_dictionary(*pid).unwrap();
        let mb: Vec<f64> = page
            .get(b"MediaBox")
            .and_then(Object::as_array)
            .map(|a| a.iter().map(obj_num).collect())
            .unwrap_or_default();
        let ok = mb.len() == 4
            && mb[2] - mb[0] >= 3.0
            && mb[3] - mb[1] >= 3.0
            && mb[2] <= 14400.0
            && mb[3] <= 14400.0;
        r.check(
            &format!("page{pno}_mediabox_sane"),
            ok,
            format!("{mb:?} (PDF 1.4 Annex C: 3..14400 units)"),
        );
        let res = page.get(b"Resources").and_then(Object::as_dict).ok();
        let mut fonts: HashMap<Vec<u8>, ObjectId> = HashMap::new();
        let mut xobjs: HashMap<Vec<u8>, ObjectId> = HashMap::new();
        if let Some(res) = res {
            if let Ok(f) = res.get(b"Font").and_then(Object::as_dict) {
                for (k, v) in f.iter() {
                    fonts.insert(k.clone(), v.as_reference().unwrap());
                }
            }
            if let Ok(x) = res.get(b"XObject").and_then(Object::as_dict) {
                for (k, v) in x.iter() {
                    xobjs.insert(k.clone(), v.as_reference().unwrap());
                }
            }
        }
        for (k, id) in &fonts {
            let fd = doc.get_dictionary(*id);
            let base = fd
                .as_ref()
                .ok()
                .and_then(|d| d.get(b"BaseFont").ok())
                .and_then(|o| o.as_name().ok())
                .unwrap_or(b"");
            let ok = STD14.contains(&String::from_utf8_lossy(base).as_ref());
            r.check(
                &format!("page{pno}_font_{}_resolves", String::from_utf8_lossy(k)),
                ok,
                String::from_utf8_lossy(base),
            );
        }
        // content stream
        let cid = page
            .get(b"Contents")
            .and_then(Object::as_reference)
            .unwrap();
        let cs = doc.get_object(cid).unwrap().as_stream().unwrap();
        let data = match decode_stream(cs) {
            Ok(d) => d,
            Err(e) => {
                r.check(&format!("page{pno}_content_decode"), false, e);
                continue;
            }
        };
        let content = match Content::decode(&data) {
            Ok(c) => c,
            Err(e) => {
                r.check(&format!("page{pno}_content_parse"), false, format!("{e}"));
                continue;
            }
        };
        let ops: Vec<&str> = content
            .operations
            .iter()
            .map(|o| o.operator.as_str())
            .collect();
        let allowed = [
            "q", "Q", "cm", "w", "J", "j", "M", "d", "rg", "RG", "g", "G", "m", "l", "c", "re",
            "h", "S", "s", "f", "f*", "B", "W", "W*", "n", "BT", "ET", "Tf", "Tm", "Tj", "Do",
        ];
        let unknown: Vec<&&str> = ops.iter().filter(|o| !allowed.contains(o)).collect();
        r.check(
            &format!("page{pno}_content_ops_whitelisted"),
            unknown.is_empty(),
            format!("{} ops, unknown={unknown:?}", ops.len()),
        );
        let mut bad_refs = vec![];
        let mut tj: Vec<Vec<u8>> = vec![];
        let mut bad_vals = vec![];
        for op in &content.operations {
            match op.operator.as_str() {
                "Tf" => {
                    let n = op.operands[0].as_name().unwrap_or(b"");
                    if !fonts.contains_key(n) {
                        bad_refs.push(format!("Tf /{}", String::from_utf8_lossy(n)));
                    }
                    if obj_num(&op.operands[1]) <= 0.0 {
                        bad_vals.push(format!("Tf size {:?}", op.operands[1]));
                    }
                }
                "Do" => {
                    let n = op.operands[0].as_name().unwrap_or(b"");
                    if !xobjs.contains_key(n) {
                        bad_refs.push(format!("Do /{}", String::from_utf8_lossy(n)));
                    }
                }
                "Tj" => tj.push(op.operands[0].as_str().unwrap_or(b"").to_vec()),
                "J" | "j" => {
                    let v = obj_num(&op.operands[0]);
                    if !(0.0..=2.0).contains(&v) {
                        bad_vals.push(format!("{} {v}", op.operator));
                    }
                }
                "cm" => {
                    let m: Vec<f64> = op.operands.iter().map(obj_num).collect();
                    if (m[0] * m[3] - m[1] * m[2]).abs() < 1e-300 {
                        bad_vals.push(format!("singular cm {m:?}"));
                    }
                }
                "d" => {
                    let arr: Vec<f64> = op.operands[0]
                        .as_array()
                        .map(|a| a.iter().map(obj_num).collect())
                        .unwrap_or_default();
                    if arr.iter().any(|v| *v < 0.0)
                        || (!arr.is_empty() && arr.iter().all(|v| *v == 0.0))
                    {
                        bad_vals.push(format!("dash {arr:?}"));
                    }
                }
                _ => {}
            }
        }
        r.check(
            &format!("page{pno}_resource_refs_resolve"),
            bad_refs.is_empty(),
            format!("{bad_refs:?}"),
        );
        if file == "floats.pdf" {
            r.check(
                &format!("page{pno}_operand_ranges"),
                bad_vals.is_empty(),
                format!("{bad_vals:?}"),
            );
        }
        if file == "inject.pdf" {
            let mut mism = vec![];
            for (i, p) in PAYLOADS.iter().enumerate() {
                if tj.get(i).map(|t| t.as_slice()) != Some(p.as_bytes()) {
                    mism.push(i);
                }
            }
            r.check(
                "tj_strings_exact_bytes",
                mism.is_empty() && tj.len() == PAYLOADS.len(),
                format!("{} Tj, mismatching {mism:?}", tj.len()),
            );
            let text = doc.extract_text(&[*pno]).unwrap_or_default();
            r.check(
                "tj_non_ascii_renders",
                text.contains("héllo") && text.contains("中文"),
                format!(
                    "WinAnsiEncoding shows {:?}",
                    text.lines()
                        .filter(|l| l.contains("llo") || l.contains("\u{80}") || !l.is_ascii())
                        .collect::<Vec<_>>()
                ),
            );
        }
        if file == "aliased_pages.pdf" {
            r.check(
                &format!("page{pno}_content_frozen_at_add_page"),
                tj.len() == 1,
                format!(
                    "{} Tj (page mutated after add_page / shared between pages)",
                    tj.len()
                ),
            );
        }
        // images
        for (k, id) in &xobjs {
            let s = doc.get_object(*id).unwrap().as_stream().unwrap();
            let d = &s.dict;
            let w = d.get(b"Width").and_then(Object::as_i64).unwrap_or(-1);
            let h = d.get(b"Height").and_then(Object::as_i64).unwrap_or(-1);
            let cs = d
                .get(b"ColorSpace")
                .and_then(Object::as_name)
                .map(|n| String::from_utf8_lossy(n).to_string())
                .unwrap_or_default();
            let comps = match cs.as_str() {
                "DeviceGray" => 1,
                "DeviceCMYK" => 4,
                _ => 3,
            };
            let name = format!("page{pno}_img_{}", String::from_utf8_lossy(k));
            let filter = d.get(b"Filter").and_then(Object::as_name).unwrap_or(b"");
            if filter == b"DCTDecode" {
                match jpeg_sof(&s.content) {
                    Some((jw, jh, jc, adobe)) => {
                        r.check(
                            &format!("{name}_dct_dims_match_sof"),
                            jw as i64 == w && jh as i64 == h,
                            format!("dict {w}x{h} vs SOF {jw}x{jh}"),
                        );
                        r.check(
                            &format!("{name}_dct_components_match"),
                            jc as i64 == comps,
                            format!("/{cs} vs SOF components={jc}"),
                        );
                        if jc == 4 && adobe.is_some() {
                            let has_decode = d.get(b"Decode").is_ok();
                            r.check(&format!("{name}_adobe_cmyk_decode_inverted"), has_decode, "Adobe APP14 CMYK JPEG stores inverted samples; needs /Decode [1 0 1 0 1 0 1 0] or colors render as negatives");
                        }
                    }
                    None => r.check(&format!("{name}_dct_sof"), false, "no SOF"),
                }
            } else {
                match decode_stream(s) {
                    Ok(px) => r.check(
                        &format!("{name}_samples"),
                        px.len() as i64 == w * h * comps,
                        format!("{} bytes for {w}x{h}x{comps}", px.len()),
                    ),
                    Err(e) => r.check(&format!("{name}_samples"), false, e),
                }
            }
            if let Ok(sm) = d.get(b"SMask").and_then(Object::as_reference) {
                let ss = doc.get_object(sm).unwrap().as_stream().unwrap();
                let ok = ss.dict.get(b"ColorSpace").and_then(Object::as_name).ok()
                    == Some(b"DeviceGray".as_ref());
                let px = decode_stream(ss).unwrap_or_default();
                r.check(
                    &format!("{name}_smask"),
                    ok && px.len() as i64 == w * h,
                    format!("{} alpha bytes", px.len()),
                );
            }
            let is_img =
                d.get(b"Subtype").and_then(Object::as_name).ok() == Some(b"Image".as_ref());
            r.check(&format!("{name}_is_image"), is_img, "");
        }
        if file == "foreign_image.pdf" {
            let w = xobjs
                .values()
                .next()
                .and_then(|id| doc.get_object(*id).ok())
                .and_then(|o| o.as_stream().ok())
                .and_then(|s| s.dict.get(b"Width").ok())
                .and_then(|o| o.as_i64().ok());
            r.check("foreign_imageid_rejected", w == Some(2), format!("page drew an ImageId(2x2) from another PdfDoc; this doc resolved it to a {w:?}-wide image"));
        }
    }
    r.fails
}

fn mkvalidate(dir: &str) {
    let w = |n: &str, b: &[u8]| std::fs::write(format!("{dir}/{n}"), b).unwrap();
    // 1. tiny file declaring a 2^31-1 entry xref: FixedArray x3 is allocated before any bounds check
    let mut v = b"%PDF-1.4\n".to_vec();
    let x = v.len();
    v.extend_from_slice(b"xref\n0 2147483647\n0000000000 65535 f \ntrailer\n<</Size 2147483647 /Root 1 0 R>>\nstartxref\n");
    v.extend_from_slice(format!("{x}\n%%EOF\n").as_bytes());
    w("v_xref_huge_count.pdf", &v);
    // same, 200M entries (1.6 GB+ of FixedArrays from a 120-byte file)
    for (name, cnt) in [
        ("v_xref_50m.pdf", "50000000"),
        ("v_xref_200m.pdf", "200000000"),
    ] {
        w(
            name,
            &String::from_utf8_lossy(&v)
                .replace("2147483647", cnt)
                .into_bytes(),
        );
    }
    // 2. /Length near i32::MAX -> s_data_start + slen wraps negative -> pdf[negative]
    let build = |len: &str| {
        let mut b = b"%PDF-1.4\n".to_vec();
        let o1 = b.len();
        b.extend_from_slice(b"1 0 obj\n<</Type /Catalog /Pages 2 0 R>>\nendobj\n");
        let o2 = b.len();
        b.extend_from_slice(b"2 0 obj\n<</Type /Pages /Count 0 /Kids []>>\nendobj\n");
        let o3 = b.len();
        b.extend_from_slice(
            format!("3 0 obj\n<</Length {len}>>\nstream\nxx\nendstream\nendobj\n").as_bytes(),
        );
        let xr = b.len();
        b.extend_from_slice(format!("xref\n0 4\n0000000000 65535 f \n{o1:010} 00000 n \n{o2:010} 00000 n \n{o3:010} 00000 n \ntrailer\n<</Size 4 /Root 1 0 R>>\nstartxref\n{xr}\n%%EOF\n").as_bytes());
        b
    };
    w("v_length_ok.pdf", &build("2"));
    w("v_length_wrap.pdf", &build("2147483600"));
    // 3. quadratic: N objects with no ">>" anywhere -> each obj rescans to xref
    for (name, n) in [
        ("v_quadratic_20k.pdf", 20000usize),
        ("v_quadratic_40k.pdf", 40000),
    ] {
        let mut b = b"%PDF-1.4\n".to_vec();
        let mut offs = vec![];
        offs.push(b.len());
        b.extend_from_slice(b"1 0 obj\n<</Type /Catalog /Pages 2 0 R>>\nendobj\n");
        offs.push(b.len());
        b.extend_from_slice(b"2 0 obj\n<</Type /Pages /Count 0 /Kids []>>\nendobj\n");
        // objects 3..n carry no ">>": for each one pdf_find_ascii(">>") scans to the xref
        for i in 3..=n {
            offs.push(b.len());
            b.extend_from_slice(format!("{i} 0 obj\n[1 2 3 4 5 6 7 8]\nendobj\n").as_bytes());
        }
        let xr = b.len();
        b.extend_from_slice(format!("xref\n0 {}\n0000000000 65535 f \n", n + 1).as_bytes());
        for o in offs {
            b.extend_from_slice(format!("{o:010} 00000 n \n").as_bytes());
        }
        b.extend_from_slice(
            format!(
                "trailer\n<</Size {} /Root 1 0 R>>\nstartxref\n{xr}\n%%EOF\n",
                n + 1
            )
            .as_bytes(),
        );
        w(name, &b);
    }
    // 4. xref offsets > 2^32 alias onto valid offsets after .to_int() truncation
    let mut a = build("2");
    let s = String::from_utf8_lossy(&a).to_string();
    let first = s.find("00000 n").unwrap() - 11;
    let off: u64 = s[first..first + 10].parse().unwrap();
    let alias = format!("{:010}", off + (1u64 << 32));
    a.splice(first..first + 10, alias.bytes());
    w("v_offset_alias.pdf", &a);
    // RLE: 64 KiB of "repeat 128x" packets = 8 MiB; and a truncated literal; and EOD-only
    let mut rle = vec![];
    for _ in 0..32768 {
        rle.extend_from_slice(&[129, 0x41]);
    }
    w("r_bomb.bin", &rle);
    // 33 MiB input: ByteBuf starts at n and doubles to 33 MiB * 32 = 1056 MiB; the next doubling
    // overflows Int (`cap * 2` < 0, then 0) and `ensure` spins forever below the 2^31-1 output limit
    let mut big = Vec::with_capacity(33 << 20);
    while big.len() < (33 << 20) {
        big.extend_from_slice(&[129, 0x42]);
    }
    w("r_bomb_2g.bin", &big);
    w("r_trunc_literal.bin", &[5, 1, 2]);
    w("r_trunc_repeat.bin", &[200]);
    w("r_eod_only.bin", &[128, 1, 2, 3]);
    // zlib bomb: 512 MiB of zeros
    let mut e = flate2::write::ZlibEncoder::new(vec![], flate2::Compression::best());
    let zeros = vec![0u8; 1 << 20];
    for _ in 0..512 {
        std::io::Write::write_all(&mut e, &zeros).unwrap();
    }
    w("z_bomb_512m.bin", &e.finish().unwrap());
    w("z_trunc.bin", &[0x78, 0x9c, 0x4b, 0x4c]);
    println!("hostile inputs written to {dir}");
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    match a.get(1).map(String::as_str) {
        Some("check") => {
            let dir = &a[2];
            let files = [
                "inject.pdf",
                "floats.pdf",
                "page_sizes.pdf",
                "images.pdf",
                "vector14.pdf",
                "empty.pdf",
                "foreign_image.pdf",
                "aliased_pages.pdf",
            ];
            let mut total = 0;
            for f in files {
                total += check_file(dir, f);
            }
            println!("ORACLE_FAILS {total}");
        }
        Some("mkvalidate") => mkvalidate(&a[2]),
        _ => {
            eprintln!("usage: oracle check <dir> | mkvalidate <dir>");
            std::process::exit(2);
        }
    }
}
