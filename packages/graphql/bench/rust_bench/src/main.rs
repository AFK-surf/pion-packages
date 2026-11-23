use apollo_parser::cst::{self, CstNode};
use apollo_parser::{Lexer, Parser, TokenKind};
use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;

fn fnv1a_update(mut hash: u32, bytes: &[u8]) -> u32 {
    for &b in bytes {
        hash ^= b as u32;
        hash = hash.wrapping_mul(16777619);
    }
    hash
}

fn tok_class(k: TokenKind) -> u8 {
    match k {
        TokenKind::Name => 1,
        TokenKind::Int | TokenKind::Float => 2,
        TokenKind::Spread => 3,
        TokenKind::StringValue => 4,
        _ => 0,
    }
}

fn needs_space(prev: u8, cur: u8) -> bool {
    (prev == 1 || prev == 2 || prev == 4) && cur != 0
}

fn minify_apollo(src: &str) -> String {
    let lexer = Lexer::new(src);
    let mut out = String::with_capacity(src.len() / 2);
    let mut prev_cls: u8 = 0;
    for tok_res in lexer {
        let tok = tok_res.expect("lex error");
        let k = tok.kind();
        if matches!(
            k,
            TokenKind::Whitespace | TokenKind::Comment | TokenKind::Comma | TokenKind::Eof
        ) {
            continue;
        }
        let cur_cls = tok_class(k);
        if needs_space(prev_cls, cur_cls) {
            out.push(' ');
        }
        out.push_str(tok.data());
        prev_cls = cur_cls;
    }
    out
}

fn check_value_input_fields(v: &cst::Value, errs: &mut usize) {
    match v {
        cst::Value::ListValue(lv) => {
            for item in lv.values() {
                check_value_input_fields(&item, errs);
            }
        }
        cst::Value::ObjectValue(ov) => {
            let mut seen = HashSet::new();
            for f in ov.object_fields() {
                if let Some(name) = f.name() {
                    if !seen.insert(name.text().to_string()) {
                        *errs += 1;
                    }
                }
                if let Some(val) = f.value() {
                    check_value_input_fields(&val, errs);
                }
            }
        }
        _ => {}
    }
}

fn check_args(args: Option<cst::Arguments>, errs: &mut usize) {
    if let Some(a) = args {
        let mut seen = HashSet::new();
        for arg in a.arguments() {
            if let Some(name) = arg.name() {
                if !seen.insert(name.text().to_string()) {
                    *errs += 1;
                }
            }
            if let Some(v) = arg.value() {
                check_value_input_fields(&v, errs);
            }
        }
    }
}

fn check_dirs(dirs: Option<cst::Directives>, errs: &mut usize) {
    if let Some(ds) = dirs {
        for d in ds.directives() {
            check_args(d.arguments(), errs);
        }
    }
}

fn walk_sel_set(
    ss: cst::SelectionSet,
    frag_map: &HashMap<String, usize>,
    spreads: &mut Vec<usize>,
    errs: &mut usize,
) {
    let mut stack = vec![ss];
    while let Some(cur) = stack.pop() {
        for sel in cur.selections() {
            match sel {
                cst::Selection::Field(f) => {
                    check_args(f.arguments(), errs);
                    check_dirs(f.directives(), errs);
                    if let Some(sub) = f.selection_set() {
                        stack.push(sub);
                    }
                }
                cst::Selection::FragmentSpread(fs) => {
                    check_dirs(fs.directives(), errs);
                    if let Some(fn_node) = fs.fragment_name().and_then(|x| x.name()) {
                        match frag_map.get(fn_node.text().as_str()) {
                            Some(&idx) => spreads.push(idx),
                            None => *errs += 1,
                        }
                    }
                }
                cst::Selection::InlineFragment(inf) => {
                    check_dirs(inf.directives(), errs);
                    if let Some(sub) = inf.selection_set() {
                        stack.push(sub);
                    }
                }
            }
        }
    }
}

fn validate_doc_apollo(doc: &cst::Document) -> (usize, usize, usize) {
    let mut op_count = 0usize;
    let mut anon_ops = 0usize;
    let mut op_names = HashSet::new();
    let mut frag_map: HashMap<String, usize> = HashMap::new();
    let mut frags: Vec<cst::FragmentDefinition> = Vec::new();
    let mut ops: Vec<cst::OperationDefinition> = Vec::new();
    let mut errs = 0usize;

    for def in doc.definitions() {
        match def {
            cst::Definition::OperationDefinition(op) => {
                op_count += 1;
                if let Some(name) = op.name() {
                    if !op_names.insert(name.text().to_string()) {
                        errs += 1;
                    }
                } else {
                    anon_ops += 1;
                }
                if let Some(vdefs) = op.variable_definitions() {
                    let mut vseen = HashSet::new();
                    for vd in vdefs.variable_definitions() {
                        if let Some(vname) = vd.variable().and_then(|v| v.name()) {
                            if !vseen.insert(vname.text().to_string()) {
                                errs += 1;
                            }
                        }
                        if let Some(dv) = vd.default_value().and_then(|d| d.value()) {
                            check_value_input_fields(&dv, &mut errs);
                        }
                        check_dirs(vd.directives(), &mut errs);
                    }
                }
                check_dirs(op.directives(), &mut errs);
                ops.push(op);
            }
            cst::Definition::FragmentDefinition(frag) => {
                if let Some(name) = frag.fragment_name().and_then(|f| f.name()) {
                    let s = name.text().to_string();
                    if frag_map.contains_key(&s) {
                        errs += 1;
                    } else {
                        frag_map.insert(s, frags.len());
                        frags.push(frag);
                    }
                }
            }
            _ => {}
        }
    }
    if anon_ops > 0 && op_count > 1 {
        errs += 1;
    }

    let mut frag_edges: Vec<Vec<usize>> = Vec::with_capacity(frags.len());
    for f in &frags {
        let mut sp = Vec::new();
        check_dirs(f.directives(), &mut errs);
        if let Some(ss) = f.selection_set() {
            walk_sel_set(ss, &frag_map, &mut sp, &mut errs);
        }
        frag_edges.push(sp);
    }
    for op in &ops {
        let mut sp = Vec::new();
        if let Some(ss) = op.selection_set() {
            walk_sel_set(ss, &frag_map, &mut sp, &mut errs);
        }
    }

    // 3-color DFS cycle check
    let mut color = vec![0u8; frags.len()];
    let mut reported = false;
    for i in 0..frags.len() {
        if color[i] == 0 {
            color[i] = 1;
            let mut stack = vec![(i, 0usize)];
            while let Some((u, eidx)) = stack.last_mut() {
                let u_val = *u;
                if *eidx < frag_edges[u_val].len() {
                    let v = frag_edges[u_val][*eidx];
                    *eidx += 1;
                    if color[v] == 1 {
                        if !reported {
                            errs += 1;
                            reported = true;
                        }
                    } else if color[v] == 0 {
                        color[v] = 1;
                        stack.push((v, 0));
                    }
                } else {
                    color[u_val] = 2;
                    stack.pop();
                }
            }
        }
    }

    (op_count, frags.len(), errs)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: graphql_bench_rust <sdl|queries|roundtrip> <file> <iters>");
        std::process::exit(1);
    }
    let mode = &args[1];
    let path = &args[2];
    let iters: usize = args[3].parse().unwrap_or(1);
    let src = fs::read_to_string(path).expect("failed to read input file");

    if mode == "sdl" {
        let mut total_defs = 0u64;
        let mut total_objs = 0u64;
        let mut total_fields = 0u64;
        for _ in 0..iters {
            let parser = Parser::new(&src);
            let cst = parser.parse();
            if cst.errors().len() > 0 {
                eprintln!("sdl parse errors: {}", cst.errors().len());
                std::process::exit(1);
            }
            let doc = cst.document();
            for def in doc.definitions() {
                total_defs += 1;
                match def {
                    cst::Definition::ObjectTypeDefinition(obj) => {
                        total_objs += 1;
                        if let Some(fs) = obj.fields_definition() {
                            total_fields += fs.field_definitions().count() as u64;
                        }
                    }
                    cst::Definition::ObjectTypeExtension(obj) => {
                        if let Some(fs) = obj.fields_definition() {
                            total_fields += fs.field_definitions().count() as u64;
                        }
                    }
                    _ => {}
                }
            }
        }
        println!("mode=sdl");
        println!("iters={}", iters);
        println!("definitions={}", total_defs);
        println!("object_types={}", total_objs);
        println!("fields={}", total_fields);
        return;
    }

    if mode == "queries" {
        let queries: Vec<&str> = src.split("\n###QUERY###\n").collect();
        let mut total_q = 0u64;
        let mut total_ops = 0u64;
        let mut total_frags = 0u64;
        let mut total_errs = 0u64;
        for _ in 0..iters {
            for q in &queries {
                let cst = Parser::new(q).parse();
                if cst.errors().len() > 0 {
                    eprintln!("query parse error");
                    std::process::exit(1);
                }
                let doc = cst.document();
                let (ops, frags, errs) = validate_doc_apollo(&doc);
                total_q += 1;
                total_ops += ops as u64;
                total_frags += frags as u64;
                total_errs += errs as u64;
            }
        }
        println!("mode=queries");
        println!("iters={}", iters);
        println!("queries={}", total_q);
        println!("ops={}", total_ops);
        println!("frags={}", total_frags);
        println!("val_errors={}", total_errs);
        return;
    }

    if mode == "roundtrip" {
        let queries: Vec<&str> = src.split("\n###QUERY###\n").collect();
        let mut total_q = 0u64;
        let mut total_min_bytes = 0u64;
        let mut min_hash: u32 = 2166136261;
        let mut total_defs = 0u64;
        let mut total_printed_ok = 0u64;
        for _ in 0..iters {
            for q in &queries {
                let min = minify_apollo(q);
                total_min_bytes += min.len() as u64;
                min_hash = fnv1a_update(min_hash, min.as_bytes());
                let cst = Parser::new(&min).parse();
                if cst.errors().len() > 0 {
                    eprintln!("re-parse error");
                    std::process::exit(1);
                }
                let doc = cst.document();
                let printed = doc.syntax().to_string();
                if !printed.is_empty() {
                    total_printed_ok += 1;
                }
                total_defs += doc.definitions().count() as u64;
                total_q += 1;
            }
        }
        println!("mode=roundtrip");
        println!("iters={}", iters);
        println!("queries={}", total_q);
        println!("min_bytes={}", total_min_bytes);
        println!("min_fnv1a={}", min_hash);
        println!("defs={}", total_defs);
        println!("printed_ok={}", total_printed_ok);
        return;
    }

    eprintln!("unknown mode: {}", mode);
    std::process::exit(1);
}
