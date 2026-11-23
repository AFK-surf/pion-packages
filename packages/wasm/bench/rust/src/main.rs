use std::env;
use std::fs;
use std::process;
use wasm_encoder::reencode::{Reencode, RoundtripReencoder};
use wasmparser::{Parser, Payload, Validator};

fn run_decode(raw: &[u8], rounds: usize) {
    let mut types: i64 = 0;
    let mut imports: i64 = 0;
    let mut funcs: i64 = 0;
    let mut globals: i64 = 0;
    let mut exports: i64 = 0;
    let mut data_segs: i64 = 0;
    let mut total_locals: i64 = 0;
    let mut total_instrs: i64 = 0;

    for _ in 0..rounds {
        for payload in Parser::new(0).parse_all(raw) {
            match payload.expect("parse payload") {
                Payload::TypeSection(reader) => {
                    for rec in reader {
                        let rec = rec.expect("type rec");
                        types += rec.types().len() as i64;
                    }
                }
                Payload::ImportSection(reader) => {
                    for imp in reader {
                        let _ = imp.expect("import");
                        imports += 1;
                    }
                }
                Payload::GlobalSection(reader) => {
                    for g in reader {
                        let _ = g.expect("global");
                        globals += 1;
                    }
                }
                Payload::ExportSection(reader) => {
                    for ex in reader {
                        let _ = ex.expect("export");
                        exports += 1;
                    }
                }
                Payload::DataSection(reader) => {
                    for d in reader {
                        let _ = d.expect("data");
                        data_segs += 1;
                    }
                }
                Payload::CodeSectionEntry(body) => {
                    funcs += 1;
                    let locals = body.get_locals_reader().expect("locals reader");
                    for loc in locals {
                        let (cnt, _vt) = loc.expect("local");
                        total_locals += cnt as i64;
                    }
                    let ops = body.get_operators_reader().expect("ops reader");
                    for op in ops {
                        let _ = op.expect("op");
                        total_instrs += 1;
                    }
                }
                _ => {}
            }
        }
    }

    println!("mode=decode");
    println!("rounds={}", rounds);
    println!("types={}", types);
    println!("imports={}", imports);
    println!("funcs={}", funcs);
    println!("globals={}", globals);
    println!("exports={}", exports);
    println!("data_segs={}", data_segs);
    println!("total_locals={}", total_locals);
    println!("total_instrs={}", total_instrs);
}

fn run_validate(raw: &[u8], rounds: usize) {
    let mut valid_count = 0usize;
    for _ in 0..rounds {
        let mut validator = Validator::new();
        validator.validate_all(raw).expect("validate_all");
        valid_count += 1;
    }
    println!("mode=validate");
    println!("rounds={}", rounds);
    println!("bytes={}", raw.len());
    println!("valid_count={}", valid_count);
}

fn run_roundtrip_wat(raw: &[u8], rounds: usize) {
    let mut reencoded_ok = 0usize;
    let mut wat_ok = 0usize;
    for _ in 0..rounds {
        let mut module = wasm_encoder::Module::new();
        RoundtripReencoder
            .parse_core_module(&mut module, Parser::new(0), raw)
            .expect("reencode module");
        let reenc = module.finish();
        if reenc.len() >= 8 && reenc[0] == 0 && reenc[1] == b'a' {
            reencoded_ok += 1;
        }
        let wat = wasmprinter::print_bytes(&reenc).expect("wasmprinter");
        if wat.len() > 7 && wat.starts_with("(module") {
            wat_ok += 1;
        }
    }
    println!("mode=roundtrip_wat");
    println!("rounds={}", rounds);
    println!("orig_bytes={}", raw.len());
    println!("reencoded_ok={}", reencoded_ok);
    println!("wat_ok={}", wat_ok);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: wasm_bench_rust <decode|validate|roundtrip_wat> <file.wasm> <rounds>");
        process::exit(1);
    }
    let mode = &args[1];
    let path = &args[2];
    let rounds: usize = args[3].parse().unwrap_or(1).max(1);
    let raw = fs::read(path).expect("read wasm corpus");
    match mode.as_str() {
        "decode" => run_decode(&raw, rounds),
        "validate" => run_validate(&raw, rounds),
        "roundtrip_wat" => run_roundtrip_wat(&raw, rounds),
        _ => {
            eprintln!("unknown mode: {}", mode);
            process::exit(1);
        }
    }
}
