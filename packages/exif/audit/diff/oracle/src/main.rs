//! Independent oracle for packages/exif/audit: Rust kamadak-exif 0.6.2 (`Reader::read_from_container`).
//! Prints the same record format as audit/src/dump.pion (see there). FLOAT is printed as the binary64 bits
//! of the hardware f32->f64 widening (`as f64`), DOUBLE as its own bits, ASCII/UNDEFINED as hex.
//! ASCII count is printed as `?` because kamadak does not keep the raw byte count of ASCII fields.
//!   oracle dump <file>... | oracle dumplist <listfile>
use exif::{Context, Error, Reader, Value};
use std::fmt::Write as _;
use std::io::{Cursor, Write};

fn ifd_name(ctx: Context, n: u16) -> String {
    let p = match ctx {
        Context::Tiff => return format!("T{}", n),
        Context::Exif => "E",
        Context::Gps => "G",
        Context::Interop => "I",
        _ => "X",
    };
    if n == 0 { p.to_string() } else { format!("{}{}", p, n) }
}

fn join<T: ToString>(a: &[T]) -> String {
    a.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(",")
}

fn hex(b: &[u8]) -> String {
    let mut s = String::with_capacity(b.len() * 2);
    for x in b {
        let _ = write!(s, "{:02x}", x);
    }
    s
}

fn value(v: &Value) -> (u16, String, String) {
    match v {
        Value::Byte(a) => (1, a.len().to_string(), join(a)),
        Value::Ascii(a) => (2, "?".into(), format!("{}:{}", a.len(), a.iter().map(|s| hex(s)).collect::<Vec<_>>().join(","))),
        Value::Short(a) => (3, a.len().to_string(), join(a)),
        Value::Long(a) => (4, a.len().to_string(), join(a)),
        Value::Rational(a) => (5, a.len().to_string(), a.iter().map(|r| format!("{}/{}", r.num, r.denom)).collect::<Vec<_>>().join(",")),
        Value::SByte(a) => (6, a.len().to_string(), join(a)),
        Value::Undefined(b, _) => (7, b.len().to_string(), hex(b)),
        Value::SShort(a) => (8, a.len().to_string(), join(a)),
        Value::SLong(a) => (9, a.len().to_string(), join(a)),
        Value::SRational(a) => (10, a.len().to_string(), a.iter().map(|r| format!("{}/{}", r.num, r.denom)).collect::<Vec<_>>().join(",")),
        Value::Float(a) => (11, a.len().to_string(), a.iter().map(|x| format!("{:016x}", (*x as f64).to_bits())).collect::<Vec<_>>().join(",")),
        Value::Double(a) => (12, a.len().to_string(), a.iter().map(|x| format!("{:016x}", x.to_bits())).collect::<Vec<_>>().join(",")),
        Value::Unknown(t, c, _) => (*t, c.to_string(), "UNKNOWN".into()),
    }
}

fn err_name(e: &Error) -> &'static str {
    match e {
        Error::InvalidFormat(_) => "InvalidFormat",
        Error::Io(_) => "Io",
        Error::NotFound(_) => "NotFound",
        Error::BlankValue(_) => "BlankValue",
        Error::TooBig(_) => "TooBig",
        Error::NotSupported(_) => "NotSupported",
        Error::UnexpectedValue(_) => "UnexpectedValue",
        Error::PartialResult(_) => "PartialResult",
        _ => "Other",
    }
}

fn dump(path: &str, out: &mut String) {
    let _ = writeln!(out, "== {}", path);
    let data = match std::fs::read(path) {
        Ok(d) => d,
        Err(_) => {
            out.push_str("READFAIL\n");
            return;
        }
    };
    match Reader::new().read_from_container(&mut Cursor::new(&data[..])) {
        Err(e) => {
            let _ = writeln!(out, "ERR {} {}", err_name(&e), e);
        }
        Ok(ex) => {
            let _ = writeln!(out, "OK {} {}", if ex.little_endian() { "II" } else { "MM" }, ex.fields().len());
            for f in ex.fields() {
                let (t, c, v) = value(&f.value);
                let _ = writeln!(out, "F {} {:04x} {} {} {}", ifd_name(f.tag.0, f.ifd_num.0), f.tag.1, t, c, v);
            }
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut paths: Vec<String> = Vec::new();
    match args.get(1).map(|s| s.as_str()) {
        Some("dump") => paths.extend(args[2..].iter().cloned()),
        Some("dumplist") if args.len() >= 3 => {
            let l = std::fs::read_to_string(&args[2]).expect("list");
            paths.extend(l.lines().filter(|x| !x.is_empty()).map(|x| x.to_string()));
        }
        _ => {
            eprintln!("usage: oracle dump <file>... | oracle dumplist <list>");
            std::process::exit(2);
        }
    }
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    for p in &paths {
        let mut s = String::new();
        dump(p, &mut s);
        let _ = lock.write_all(s.as_bytes());
    }
}
