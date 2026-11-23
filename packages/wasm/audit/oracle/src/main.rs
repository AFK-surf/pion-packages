//! Red-team oracle for packages/wasm: Rust wasmparser 0.221.3 (WASM2 feature set and
//! crate-default feature set), wasmprinter 0.221.3 and wat 1.221.3.
//!
//!   oracle check <dir> <start> <end>
//!     For each `<dir>/<i>.wasm` prints one tab-separated line:
//!       i  wp2(OK|ERR:msg)  wpdef(OK|ERR)  re(...)  wat(...)
//!     re  : Pion `decode -> encode` output (`<i>.pion.re.wasm`) compared with the original:
//!           SAME_BYTES | SAME_SEM (wasmprinter text equal, custom sections stripped) |
//!           SEM_DIFF | RE_INVALID (original valid but re-encoding rejected by wasmparser) | NA
//!     wat : Pion `print_wat` output (`<i>.pion.wat`) fed to `wat::parse_str`:
//!           EQ (parses, validates, same wasmprinter text as original) | PARSE_FAIL:msg |
//!           INVALID:msg | SEM_DIFF | NA   (only judged when the original is WASM2-valid)
use std::{env, fs};
use wasmparser::{Validator, WasmFeatures};

fn wasm2() -> WasmFeatures {
    WasmFeatures::WASM2
}

fn validate(bytes: &[u8], f: WasmFeatures) -> Result<(), String> {
    Validator::new_with_features(f)
        .validate_all(bytes)
        .map(|_| ())
        .map_err(|e| e.to_string().replace(['\n', '\t'], " "))
}

/// Remove custom sections (id 0) so that names / producers do not influence comparison.
fn strip_custom(b: &[u8]) -> Vec<u8> {
    let mut out = b[..8.min(b.len())].to_vec();
    let mut p = 8;
    while p < b.len() {
        let id = b[p];
        let mut q = p + 1;
        let (mut size, mut shift) = (0usize, 0);
        loop {
            if q >= b.len() {
                return b.to_vec();
            }
            let byte = b[q];
            q += 1;
            size |= ((byte & 0x7f) as usize) << shift;
            shift += 7;
            if byte & 0x80 == 0 {
                break;
            }
        }
        let end = q + size;
        if end > b.len() {
            return b.to_vec();
        }
        if id != 0 {
            out.extend_from_slice(&b[p..end]);
        }
        p = end;
    }
    out
}

fn print(b: &[u8]) -> Option<String> {
    wasmprinter::print_bytes(strip_custom(b)).ok()
}

fn short(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(200).collect()
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() >= 4 && args[1] == "time" {
        // oracle time <file> <rounds> : wasmparser WASM2 full validation, prints elapsed ms
        let raw = fs::read(&args[2]).expect("read");
        let rounds: usize = args[3].parse().unwrap();
        let t = std::time::Instant::now();
        let mut last = Ok(());
        for _ in 0..rounds {
            last = validate(&raw, wasm2());
        }
        let ms = t.elapsed().as_millis();
        println!("mode=validate rounds={rounds} ms={ms} result={}", match last { Ok(()) => "OK".into(), Err(e) => format!("ERR:{}", short(&e)) });
        return;
    }
    if args.len() >= 3 && args[1] == "print" {
        // oracle print <file> : wasmprinter text on stdout (W3 output-size comparison)
        let raw = fs::read(&args[2]).expect("read");
        print!("{}", wasmprinter::print_bytes(&raw).expect("print"));
        return;
    }
    if args.len() < 5 || args[1] != "check" {
        eprintln!("usage: oracle check <dir> <start> <end>");
        std::process::exit(2);
    }
    let dir = &args[2];
    let start: usize = args[3].parse().unwrap();
    let end: usize = args[4].parse().unwrap();
    for i in start..end {
        let path = format!("{dir}/{i}.wasm");
        let Ok(orig) = fs::read(&path) else { continue };
        let wp2 = validate(&orig, wasm2());
        let wpdef = validate(&orig, WasmFeatures::default());
        let orig_txt = if wp2.is_ok() { print(&orig) } else { None };

        let re = match fs::read(format!("{dir}/{i}.pion.re.wasm")) {
            Err(_) => "NA".to_string(),
            Ok(re) => {
                if re == orig {
                    "SAME_BYTES".to_string()
                } else if wp2.is_ok() {
                    match validate(&re, wasm2()) {
                        Err(e) => format!("RE_INVALID:{}", short(&e)),
                        Ok(()) => {
                            if print(&re) == orig_txt {
                                "SAME_SEM".to_string()
                            } else {
                                "SEM_DIFF".to_string()
                            }
                        }
                    }
                } else {
                    "NA_INVALID_ORIG".to_string()
                }
            }
        };

        let wat = match fs::read_to_string(format!("{dir}/{i}.pion.wat")) {
            Err(_) => "NA".to_string(),
            Ok(_) if wp2.is_err() => "NA_INVALID_ORIG".to_string(),
            Ok(text) => match wat::parse_str(&text) {
                Err(e) => format!("PARSE_FAIL:{}", short(&e.to_string())),
                Ok(bin) => match validate(&bin, wasm2()) {
                    Err(e) => format!("INVALID:{}", short(&e)),
                    Ok(()) => {
                        if print(&bin) == orig_txt {
                            "EQ".to_string()
                        } else {
                            "SEM_DIFF".to_string()
                        }
                    }
                },
            },
        };
        let fmt = |r: &Result<(), String>| match r {
            Ok(()) => "OK".to_string(),
            Err(e) => format!("ERR:{}", short(e)),
        };
        println!("{i}\t{}\t{}\t{re}\t{wat}", fmt(&wp2), if wpdef.is_ok() { "OK" } else { "ERR" });
    }
}
