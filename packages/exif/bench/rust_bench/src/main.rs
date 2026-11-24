use exif::{Context, In, Reader, Tag, Value};
use std::env;
use std::fs;
use std::io::Cursor;

fn ifd_rank_and_name(ctx: Context, ifd_num: In) -> (i32, &'static str) {
    match (ctx, ifd_num) {
        (Context::Tiff, In::PRIMARY) => (0, "IFD0"),
        (Context::Exif, In::PRIMARY) => (1, "ExifIFD"),
        (Context::Gps, In::PRIMARY) => (2, "GPSIFD"),
        (Context::Interop, In::PRIMARY) => (3, "InteropIFD"),
        (Context::Tiff, In::THUMBNAIL) => (4, "IFD1"),
        _ => (99, "OTHER"),
    }
}

fn format_value(v: &Value) -> (&'static str, String) {
    match v {
        Value::Byte(a) => (
            "BYTE",
            a.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(","),
        ),
        Value::Ascii(a) => (
            "ASCII",
            a.iter()
                .map(|s| String::from_utf8_lossy(s).into_owned())
                .collect::<Vec<_>>()
                .join("|"),
        ),
        Value::Short(a) => (
            "SHORT",
            a.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(","),
        ),
        Value::Long(a) => (
            "LONG",
            a.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(","),
        ),
        Value::Rational(a) => (
            "RATIONAL",
            a.iter()
                .map(|r| format!("{}/{}", r.num, r.denom))
                .collect::<Vec<_>>()
                .join(","),
        ),
        Value::SByte(a) => (
            "SBYTE",
            a.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(","),
        ),
        Value::Undefined(b, _) => {
            let mut s = String::with_capacity(b.len() * 2);
            for byte in b {
                s.push_str(&format!("{:02x}", byte));
            }
            ("UNDEFINED", s)
        }
        Value::SShort(a) => (
            "SSHORT",
            a.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(","),
        ),
        Value::SLong(a) => (
            "SLONG",
            a.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(","),
        ),
        Value::SRational(a) => (
            "SRATIONAL",
            a.iter()
                .map(|r| format!("{}/{}", r.num, r.denom))
                .collect::<Vec<_>>()
                .join(","),
        ),
        Value::Float(a) => (
            "FLOAT",
            a.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(","),
        ),
        Value::Double(a) => (
            "DOUBLE",
            a.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(","),
        ),
        Value::Unknown(_, _, _) => ("UNKNOWN", String::new()),
    }
}

fn format_canonical(ex: &exif::Exif) -> String {
    let mut rows: Vec<(i32, u16, &'static str, &'static str, String)> = Vec::new();
    for f in ex.fields() {
        let (rank, ifd_name) = ifd_rank_and_name(f.tag.0, f.ifd_num);
        let (tname, val_str) = format_value(&f.value);
        rows.push((rank, f.tag.1, ifd_name, tname, val_str));
    }
    rows.sort_by_key(|r| (r.0, r.1));
    let mut out = String::new();
    out.push_str("BO=");
    out.push_str(if ex.little_endian() { "II\n" } else { "MM\n" });
    for (_, tag, ifd_name, tname, val_str) in rows {
        out.push_str(&format!("{} 0x{:04x} {} {}\n", ifd_name, tag, tname, val_str));
    }
    out
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: exif_bench_kamadak <corpus_dir> <iters>");
        std::process::exit(1);
    }
    let dir = &args[1];
    let iters: usize = args[2].parse().expect("iters");
    let names = [
        "camera_iphone.jpg",
        "camera_be.tiff",
        "photo_webp.webp",
        "photo_png.png",
    ];
    let blobs: Vec<Vec<u8>> = names
        .iter()
        .map(|n| fs::read(format!("{}/{}", dir, n)).expect("read corpus"))
        .collect();

    let reader = Reader::new();
    let mut checksum: i64 = 0;
    for _ in 0..iters {
        for blob in &blobs {
            let mut cur = Cursor::new(blob.as_slice());
            let ex = reader.read_from_container(&mut cur).expect("parse");
            let ori = ex
                .get_field(Tag::Orientation, In::PRIMARY)
                .and_then(|f| f.value.get_uint(0))
                .unwrap_or(0) as i64;
            let cs = ex
                .get_field(Tag::ColorSpace, In::PRIMARY)
                .and_then(|f| f.value.get_uint(0))
                .unwrap_or(0) as i64;
            let cnt = ex.fields().count() as i64;
            checksum += ori + cs + cnt;
        }
    }

    let mut out = format!("CHECKSUM={}\n", checksum);
    for (name, blob) in names.iter().zip(blobs.iter()) {
        let mut cur = Cursor::new(blob.as_slice());
        let ex = reader.read_from_container(&mut cur).expect("final parse");
        out.push_str(&format!("=== {} ===\n", name));
        out.push_str(&format_canonical(&ex));
    }
    print!("{}", out);
}
