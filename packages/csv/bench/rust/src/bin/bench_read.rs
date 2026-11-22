use std::env;
use std::fs;

fn main() {
    let args: Vec<String> = env::args().collect();
    let path = if args.len() > 1 {
        args[1].as_str()
    } else {
        "/tmp/pion-csv-bench/mixed_200k.csv"
    };
    let content = fs::read_to_string(path).expect("failed to read input file");

    let mut total_records: i64 = 0;
    let mut total_fields: i64 = 0;
    let mut total_bytes: i64 = 0;
    let mut hash: i64 = 0;
    let mut first_sample = String::new();
    let mut last_sample = String::new();

    let mut rec = csv::StringRecord::new();
    for _round in 0..2 {
        let mut rdr = csv::ReaderBuilder::new().from_reader(content.as_bytes());
        while rdr.read_record(&mut rec).expect("parse error") {
            let nf = rec.len();
            total_records += 1;
            total_fields += nf as i64;
            for f in 0..nf {
                let b = rec.get(f).unwrap().as_bytes();
                total_bytes += b.len() as i64;
                for &byte in b {
                    hash = (hash * 131 + byte as i64) & 0x7FFF_FFFF;
                }
            }
            if total_records == 1 {
                first_sample = format!(
                    "{}|{}|{}",
                    rec.get(0).unwrap_or(""),
                    rec.get(3).unwrap_or(""),
                    rec.get(7).unwrap_or("")
                );
            }
            if total_records == 400_000 {
                last_sample = format!(
                    "{}|{}|{}",
                    rec.get(0).unwrap_or(""),
                    rec.get(3).unwrap_or(""),
                    rec.get(7).unwrap_or("")
                );
            }
        }
    }

    println!("records={}", total_records);
    println!("fields={}", total_fields);
    println!("bytes={}", total_bytes);
    println!("hash={}", hash);
    println!("first={}", first_sample);
    println!("last={}", last_sample);
}
