//! RT-qrcode reference oracle: same TSV protocol as audit/oracle (Pion).
use qrcodegen::{Mask, QrCode, QrCodeEcc, QrSegment, QrSegmentMode, Version};
use std::fmt::Write as _;
use std::io::Write as _;

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect()
}
fn tohex(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        let _ = write!(s, "{:02x}", x);
    }
    s
}
fn ecc(s: &str) -> QrCodeEcc {
    match s {
        "L" => QrCodeEcc::Low,
        "Q" => QrCodeEcc::Quartile,
        "H" => QrCodeEcc::High,
        _ => QrCodeEcc::Medium,
    }
}
fn ecc_name(e: QrCodeEcc) -> &'static str {
    match e {
        QrCodeEcc::Low => "L",
        QrCodeEcc::Medium => "M",
        QrCodeEcc::Quartile => "Q",
        QrCodeEcc::High => "H",
    }
}
fn kanji_value(b0: u32, b1: u32) -> Option<u32> {
    if !(0x40..=0xFC).contains(&b1) || b1 == 0x7F {
        return None;
    }
    let w = (b0 << 8) | b1;
    let d = if (0x8140..=0x9FFC).contains(&w) {
        w - 0x8140
    } else if (0xE040..=0xEBBF).contains(&w) {
        w - 0xC140
    } else {
        return None;
    };
    Some((d >> 8) * 0xC0 + (d & 0xFF))
}
fn segs_for(kind: &str, data: &[u8]) -> Option<Vec<QrSegment>> {
    let text = || std::str::from_utf8(data).ok();
    Some(match kind {
        "byte" => vec![QrSegment::make_bytes(data)],
        "num" => {
            let t = text()?;
            if !QrSegment::is_numeric(t) {
                return None;
            }
            vec![QrSegment::make_numeric(t)]
        }
        "alnum" => {
            let t = text()?;
            if !QrSegment::is_alphanumeric(t) {
                return None;
            }
            vec![QrSegment::make_alphanumeric(t)]
        }
        "kanji" => {
            if data.len() % 2 != 0 {
                return None;
            }
            let mut bits = Vec::new();
            for p in data.chunks(2) {
                let v = kanji_value(p[0] as u32, p[1] as u32)?;
                for i in (0..13).rev() {
                    bits.push((v >> i) & 1 != 0);
                }
            }
            vec![QrSegment::new(QrSegmentMode::Kanji, data.len() / 2, bits)]
        }
        "auto" | "auto_noopt" => match std::str::from_utf8(data) {
            Ok(t) => QrSegment::make_segments(t),
            Err(_) => vec![QrSegment::make_bytes(data)],
        },
        k if k.starts_with("eci") => {
            let d: u32 = k[3..].parse().ok()?;
            if d > 999_999 {
                return None;
            }
            vec![QrSegment::make_eci(d), QrSegment::make_bytes(data)]
        }
        _ => return None,
    })
}

fn rows(path: &str) -> Vec<Vec<String>> {
    std::fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|l| l.split('\t').map(|s| s.to_string()).collect())
        .collect()
}

fn cmd_enc(path: &str) {
    let mut out = std::io::BufWriter::new(std::io::stdout().lock());
    for r in rows(path) {
        if r.len() < 7 {
            continue;
        }
        let data = unhex(&r[6]);
        let (minv, maxv, mask): (i32, i32, i32) =
            (r[2].parse().unwrap(), r[3].parse().unwrap(), r[4].parse().unwrap());
        let res = match segs_for(&r[5], &data) {
            None => Err("InvalidCharacter"),
            Some(_) if !(1..=40).contains(&minv) || !(1..=40).contains(&maxv) || minv > maxv => {
                Err("InvalidVersion")
            }
            Some(_) if !(-1..=7).contains(&mask) => Err("InvalidMask"),
            Some(segs) => QrCode::encode_segments_advanced(
                &segs,
                ecc(&r[1]),
                Version::new(minv as u8),
                Version::new(maxv as u8),
                if mask < 0 { None } else { Some(Mask::new(mask as u8)) },
                false,
            )
            .map_err(|_| "DataTooLong"),
        };
        match res {
            Ok(q) => {
                let n = q.size();
                let mut bits = String::with_capacity((n * n) as usize);
                for y in 0..n {
                    for x in 0..n {
                        bits.push(if q.get_module(x, y) { '1' } else { '0' });
                    }
                }
                let _ = writeln!(
                    out,
                    "{}\tOK\t{}\t{}\t{}\t{}",
                    r[0],
                    q.version().value(),
                    ecc_name(q.error_correction_level()),
                    q.mask().value(),
                    bits
                );
            }
            Err(e) => {
                let _ = writeln!(out, "{}\tERR\t{}", r[0], e);
            }
        }
    }
}

fn cmd_dec(path: &str) {
    let mut out = std::io::BufWriter::new(std::io::stdout().lock());
    for r in rows(path) {
        if r.len() < 3 {
            continue;
        }
        let size: usize = r[1].parse().unwrap();
        let bits = r[2].as_bytes();
        if bits.len() != size * size || size == 0 {
            let _ = writeln!(out, "{}\tERR\tInvalidMatrixSize", r[0]);
            continue;
        }
        let g = rqrr::SimpleGrid::from_func(size, |x, y| bits[y * size + x] == b'1');
        let grid = rqrr::Grid::new(g);
        let mut buf = Vec::new();
        let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| grid.decode_to(&mut buf)));
        match res {
            Ok(Ok(m)) => {
                let ec = ["M", "L", "H", "Q"][m.ecc_level as usize & 3];
                let _ = writeln!(out, "{}\tOK\t{}\t{}\t{}\t-\t{}", r[0], m.version.0, ec, m.mask, tohex(&buf));
            }
            Ok(Err(e)) => {
                let _ = writeln!(out, "{}\tERR\t{:?}", r[0], e);
            }
            Err(_) => {
                let _ = writeln!(out, "{}\tERR\tPANIC", r[0]);
            }
        }
    }
}

/// Build a symbol from raw data codewords (qrcodegen::encode_codewords): lets the driver hand the
/// decoders hostile-but-RS-valid bitstreams (unknown modes, truncated counts, bad ECI, ...).
fn cmd_cw(path: &str) {
    let mut out = std::io::BufWriter::new(std::io::stdout().lock());
    for r in rows(path) {
        if r.len() < 5 {
            continue;
        }
        let v: u8 = r[2].parse().unwrap();
        let q = QrCode::encode_codewords(Version::new(v), ecc(&r[1]), &unhex(&r[4]), Some(Mask::new(r[3].parse().unwrap())));
        let n = q.size();
        let mut bits = String::with_capacity((n * n) as usize);
        for y in 0..n {
            for x in 0..n {
                bits.push(if q.get_module(x, y) { '1' } else { '0' });
            }
        }
        let _ = writeln!(out, "{}\t{}\t{}", r[0], n, bits);
    }
}

fn lcg(n: usize, seed: i64) -> Vec<u8> {
    let mut s = seed;
    (0..n)
        .map(|_| {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407) & 0x7FFF_FFFF_FFFF_FFFF;
            ((s >> 24) & 0xFF) as u8
        })
        .collect()
}

/// Encode with one of the three Rust encoders; returns the symbol width.
fn enc_width(imp: &str, data: &[u8], ec: char) -> Result<usize, ()> {
    match imp {
        "qrcode014" => {
            let l = match ec {
                'L' => qrcode::EcLevel::L,
                'Q' => qrcode::EcLevel::Q,
                'H' => qrcode::EcLevel::H,
                _ => qrcode::EcLevel::M,
            };
            qrcode::QrCode::with_error_correction_level(data, l).map(|q| q.width()).map_err(|_| ())
        }
        "qrcodegen" => {
            let segs = match std::str::from_utf8(data) {
                Ok(t) => QrSegment::make_segments(t),
                Err(_) => vec![QrSegment::make_bytes(data)],
            };
            QrCode::encode_segments(&segs, ecc(&ec.to_string())).map(|q| q.size() as usize).map_err(|_| ())
        }
        "fast_qr" => {
            let l = match ec {
                'L' => fast_qr::ECL::L,
                'Q' => fast_qr::ECL::Q,
                'H' => fast_qr::ECL::H,
                _ => fast_qr::ECL::M,
            };
            fast_qr::QRBuilder::new(data.to_vec()).ecl(l).build().map(|q| q.size).map_err(|_| ())
        }
        _ => panic!("unknown impl {imp}"),
    }
}

fn cmd_bench(mode: &str, imp: &str, arg: usize) {
    let s = |x: &str| x.as_bytes().to_vec();
    let (inputs, ecs, rounds): (Vec<Vec<u8>>, &str, usize) = match mode {
        "w1" | "w3" => (
            vec![
                s("https://still.fail/o/01m3hng540559hjg7h4rcww0te/chat"),
                s("otpauth://totp/acme:alice@example.com?secret=jbswy3dpehpk3pxp&issuer=acme"),
                s("https://github.com/afk-surf/pion-packages/tree/main/packages/qrcode"),
                s("otpauth://totp/stillfail:bob@example.org?secret=mfrggzdfmztwq2lk&digits=6"),
                s("https://console.still.fail/device/activate?token=k9x4m2p7q1w8"),
            ],
            "MQQMM",
            2000,
        ),
        "w2" => (
            vec![lcg(210, 101), lcg(500, 102), lcg(1100, 103), lcg(1900, 104), lcg(2900, 105)],
            "MMMML",
            60,
        ),
        "real" => (
            vec![
                s("otpauth://totp/ACME:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME"),
                s("WIFI:T:WPA;S:Office-5G;P:correct horse battery staple;;"),
                s("BEGIN:VCARD\nVERSION:3.0\nN:Doe;John\nTEL:+1-202-555-0143\nEMAIL:john@example.com\nEND:VCARD"),
                s("HTTPS://EXAMPLE.COM/P/0123456789012345678901234567890123456789"),
                s("4006381333931"),
            ],
            "MMQLH",
            2000,
        ),
        "dp" => {
            let b: Vec<u8> = (0..arg)
                .map(|i| match (i / 7) % 3 {
                    0 => 48 + (i % 10) as u8,
                    1 => 65 + (i % 26) as u8,
                    _ => 97 + (i % 26) as u8,
                })
                .collect();
            (vec![b], "L", 1)
        }
        _ => panic!("unknown bench"),
    };
    let ecv: Vec<char> = ecs.chars().collect();
    let mut total: i64 = 0;
    let mut last = String::new();
    for _ in 0..rounds {
        for (i, d) in inputs.iter().enumerate() {
            match enc_width(imp, d, ecv[i]) {
                Ok(w) => total += (w * w) as i64,
                Err(_) => last = "DataTooLong".into(),
            }
        }
    }
    println!("mode={} total_modules={} err={}", mode, total, last);
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    match a.get(1).map(|s| s.as_str()) {
        Some("enc") => cmd_enc(&a[2]),
        Some("dec") => cmd_dec(&a[2]),
        Some("cw") => cmd_cw(&a[2]),
        Some("bench") => cmd_bench(&a[2], &a[3], a.get(4).map(|x| x.parse().unwrap()).unwrap_or(0)),
        _ => {
            eprintln!("usage: oracle_rust enc|dec <tsv> | bench <w1|w2|w3|real|dp> <qrcode014|qrcodegen|fast_qr> [n]");
            std::process::exit(2)
        }
    }
    let _ = std::io::stdout().flush();
}
