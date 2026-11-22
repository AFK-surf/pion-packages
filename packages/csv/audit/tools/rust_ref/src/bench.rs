//! Adversarial read benchmark (Rust `csv =1.4.0` side). Usage: rust_bench <mode> <record-kind> FILE
//!   mode        default | bytes | fields | semicolon | trim_comment | escape | read_all  (same meaning as bench/pion_adv)
//!   record-kind str  -> StringRecord (UTF-8 validated, what packages/csv/bench uses)
//!               byte -> ByteRecord   (no UTF-8 validation, same work as Pion `from_string`)
use std::io::Write;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (mode, kind, path) = (a[1].as_str(), a[2].as_str(), a[3].as_str());
    let data = std::fs::read(path).unwrap();
    let mut b = csv::ReaderBuilder::new();
    match mode {
        "semicolon" => {
            b.delimiter(b';');
        }
        "trim_comment" => {
            b.trim(csv::Trim::All).comment(Some(b'#'));
        }
        "escape" => {
            b.escape(Some(b'\\')).double_quote(false);
        }
        _ => {}
    }
    let mut rdr = b.from_reader(&data[..]);
    let (mut records, mut fields, mut total, mut hash) = (0i64, 0i64, 0i64, 0i64);
    let eat = |f: &[u8], total: &mut i64, hash: &mut i64| {
        *total += f.len() as i64;
        for &x in f {
            *hash = (*hash * 131 + x as i64) & 0x7FFF_FFFF;
        }
    };
    if mode == "read_all" {
        let all: Vec<csv::StringRecord> = rdr.records().collect::<Result<_, _>>().unwrap();
        for rec in &all {
            records += 1;
            fields += rec.len() as i64;
            for f in rec.iter() {
                eat(f.as_bytes(), &mut total, &mut hash);
            }
        }
    } else if kind == "byte" {
        let mut rec = csv::ByteRecord::new();
        while rdr.read_byte_record(&mut rec).unwrap() {
            records += 1;
            fields += rec.len() as i64;
            for f in rec.iter() {
                eat(f, &mut total, &mut hash);
            }
        }
    } else {
        let mut rec = csv::StringRecord::new();
        while rdr.read_record(&mut rec).unwrap() {
            records += 1;
            fields += rec.len() as i64;
            if mode == "fields" {
                let owned: Vec<String> = rec.iter().map(String::from).collect();
                for f in &owned {
                    eat(f.as_bytes(), &mut total, &mut hash);
                }
            } else {
                for f in rec.iter() {
                    eat(f.as_bytes(), &mut total, &mut hash);
                }
            }
        }
    }
    let mut o = std::io::stdout();
    writeln!(
        o,
        "records={}\nfields={}\nbytes={}\nhash={}",
        records, fields, total, hash
    )
    .unwrap();
}
