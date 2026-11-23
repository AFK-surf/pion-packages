use qrcode::{Color, EcLevel, QrCode};
use std::env;
use std::fmt::Write as _;

fn fnv1a_byte(h: u64, b: u8) -> u64 {
    (h ^ (b as u64)).wrapping_mul(1099511628211u64)
}

fn fnv1a_modules(mut h: u64, qr: &QrCode) -> u64 {
    let size = qr.width();
    h = fnv1a_byte(h, (size & 0xFF) as u8);
    for c in qr.to_colors() {
        let bit = if c == Color::Dark { 1u8 } else { 0u8 };
        h = fnv1a_byte(h, bit);
    }
    h
}

fn fnv1a_str(mut h: u64, s: &str) -> u64 {
    for b in s.as_bytes() {
        h = fnv1a_byte(h, *b);
    }
    fnv1a_byte(h, 0xFF)
}

fn make_lcg_bytes(n: usize, seed: i64) -> Vec<u8> {
    let mut b = Vec::with_capacity(n);
    let mut s = seed;
    for _ in 0..n {
        s = (s.wrapping_mul(6364136223846793005i64).wrapping_add(1442695040888963407i64))
            & 0x7FFFFFFFFFFFFFFFi64;
        b.push(((s >> 24) & 0xFF) as u8);
    }
    b
}

fn render_compact_svg(qr: &QrCode) -> String {
    let size = qr.width();
    let qz = 4usize;
    let dim = size + qz * 2;
    let colors = qr.to_colors();
    let mut s = String::with_capacity(size * size * 4);
    let _ = write!(
        s,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {} {}\" shape-rendering=\"crispEdges\"><rect width=\"100%\" height=\"100%\" fill=\"#ffffff\"/><path d=\"",
        dim, dim
    );
    for y in 0..size {
        let py = y + qz;
        let row = &colors[y * size..(y + 1) * size];
        let mut x = 0usize;
        while x < size {
            if row[x] == Color::Dark {
                let start = x;
                x += 1;
                while x < size && row[x] == Color::Dark {
                    x += 1;
                }
                let rw = x - start;
                let _ = write!(s, "M{},{}h{}v1h-{}z", start + qz, py, rw, rw);
            } else {
                x += 1;
            }
        }
    }
    s.push_str("\" fill=\"#000000\"/></svg>");
    s
}

fn bench_w1() {
    let inputs: [&[u8]; 5] = [
        b"https://still.fail/o/01m3hng540559hjg7h4rcww0te/chat",
        b"otpauth://totp/acme:alice@example.com?secret=jbswy3dpehpk3pxp&issuer=acme",
        b"https://github.com/afk-surf/pion-packages/tree/main/packages/qrcode",
        b"otpauth://totp/stillfail:bob@example.org?secret=mfrggzdfmztwq2lk&digits=6",
        b"https://console.still.fail/device/activate?token=k9x4m2p7q1w8",
    ];
    let ecs = [EcLevel::M, EcLevel::Q, EcLevel::Q, EcLevel::M, EcLevel::M];

    let mut digest = 14695981039346656037u64;
    let mut total_modules: i64 = 0;
    for _ in 0..2000 {
        for i in 0..5 {
            let qr = QrCode::with_error_correction_level(inputs[i], ecs[i]).unwrap();
            let sz = qr.width() as i64;
            total_modules += sz * sz;
            digest = fnv1a_modules(digest, &qr);
        }
    }
    println!("mode=w1");
    println!("ops=10000");
    println!("total_modules={}", total_modules);
    println!("fnv1a64={:016x}", digest);
}

fn bench_w2() {
    let payloads = [
        make_lcg_bytes(210, 101),
        make_lcg_bytes(500, 102),
        make_lcg_bytes(1100, 103),
        make_lcg_bytes(1900, 104),
        make_lcg_bytes(2900, 105),
    ];
    let ecs = [EcLevel::M, EcLevel::M, EcLevel::M, EcLevel::M, EcLevel::L];

    let mut digest = 14695981039346656037u64;
    let mut total_modules: i64 = 0;
    for _ in 0..60 {
        for i in 0..5 {
            let qr = QrCode::with_error_correction_level(&payloads[i], ecs[i]).unwrap();
            let sz = qr.width() as i64;
            total_modules += sz * sz;
            digest = fnv1a_modules(digest, &qr);
        }
    }
    println!("mode=w2");
    println!("ops=300");
    println!("total_modules={}", total_modules);
    println!("fnv1a64={:016x}", digest);
}

fn bench_w3() {
    let inputs: [&[u8]; 5] = [
        b"https://console.still.fail/device/activate?token=k9x4m2p7q1w8",
        b"https://share.still.fail/doc/q4-roadmap?view=compact&theme=dark",
        b"https://still.fail/o/01m3hng540559hjg7h4rcww0te/chat",
        b"otpauth://totp/stillfail:bob@example.org?secret=mfrggzdfmztwq2lk&digits=6",
        b"otpauth://totp/acme:alice@example.com?secret=jbswy3dpehpk3pxp&issuer=acme",
    ];
    let ecs = [EcLevel::M, EcLevel::M, EcLevel::M, EcLevel::M, EcLevel::Q];

    let mut digest = 14695981039346656037u64;
    let mut total_svg_bytes: i64 = 0;
    for _ in 0..1000 {
        for i in 0..5 {
            let qr = QrCode::with_error_correction_level(inputs[i], ecs[i]).unwrap();
            let svg = render_compact_svg(&qr);
            total_svg_bytes += svg.len() as i64;
            digest = fnv1a_str(digest, &svg);
        }
    }
    println!("mode=w3");
    println!("ops=5000");
    println!("total_svg_bytes={}", total_svg_bytes);
    println!("fnv1a64={:016x}", digest);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: qrcode-bench-rust <w1|w2|w3>");
        std::process::exit(1);
    }
    match args[1].as_str() {
        "w1" => bench_w1(),
        "w2" => bench_w2(),
        "w3" => bench_w3(),
        other => {
            eprintln!("unknown mode: {}", other);
            std::process::exit(1);
        }
    }
}
