use sqlparser::ast::Statement;
use sqlparser::dialect::PostgreSqlDialect;
use sqlparser::parser::Parser;
use sqlparser::tokenizer::{Token, Tokenizer};
use std::env;
use std::fs;
use std::process;

fn stmt_tag(stmt: &Statement) -> i64 {
    match stmt {
        Statement::Query(_) => 1,
        Statement::Insert(_) => 2,
        Statement::Update { .. } => 3,
        Statement::Delete(_) => 4,
        Statement::CreateTable(_) => 5,
        Statement::CreateIndex(_) => 6,
        Statement::AlterTable { .. } => 7,
        _ => 8,
    }
}

fn run_parse(path: &str, rounds: usize) -> i32 {
    let content = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("failed to read queries: {}", e);
        process::exit(1);
    });
    let queries: Vec<&str> = content.lines().filter(|l| !l.is_empty()).collect();
    let dialect = PostgreSqlDialect {};
    let mut total_stmts: i64 = 0;
    let mut tag_sum: i64 = 0;
    for _ in 0..rounds {
        for q in &queries {
            match Parser::parse_sql(&dialect, q) {
                Ok(stmts) => {
                    total_stmts += stmts.len() as i64;
                    for s in &stmts {
                        tag_sum += stmt_tag(s);
                    }
                }
                Err(e) => {
                    eprintln!("parse error: {}", e);
                    return 1;
                }
            }
        }
    }
    println!("mode=parse");
    println!("rounds={}", rounds);
    println!("total_stmts={}", total_stmts);
    println!("tag_sum={}", tag_sum);
    0
}

fn run_tokenize(path: &str, rounds: usize) -> i32 {
    let content = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("failed to read script: {}", e);
        process::exit(1);
    });
    let dialect = PostgreSqlDialect {};
    let mut total_tokens: i64 = 0;
    for _ in 0..rounds {
        let mut tokenizer = Tokenizer::new(&dialect, &content);
        match tokenizer.tokenize() {
            Ok(toks) => {
                for t in &toks {
                    if !matches!(t, Token::Whitespace(_)) {
                        total_tokens += 1;
                    }
                }
            }
            Err(e) => {
                eprintln!("tokenize error: {}", e);
                return 1;
            }
        }
    }
    println!("mode=tokenize");
    println!("rounds={}", rounds);
    println!("total_tokens={}", total_tokens);
    0
}

fn run_roundtrip(path: &str, rounds: usize) -> i32 {
    let content = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("failed to read queries: {}", e);
        process::exit(1);
    });
    let queries: Vec<&str> = content.lines().filter(|l| !l.is_empty()).collect();
    let dialect = PostgreSqlDialect {};
    let mut total_stmts: i64 = 0;
    let mut tag_sum: i64 = 0;
    let mut non_empty: i64 = 0;
    for _ in 0..rounds {
        for q in &queries {
            match Parser::parse_sql(&dialect, q) {
                Ok(stmts) => {
                    for s in &stmts {
                        let formatted = s.to_string();
                        if !formatted.is_empty() {
                            non_empty += 1;
                        }
                        match Parser::parse_sql(&dialect, &formatted) {
                            Ok(reparsed) => {
                                total_stmts += reparsed.len() as i64;
                                for rs in &reparsed {
                                    tag_sum += stmt_tag(rs);
                                }
                            }
                            Err(e) => {
                                eprintln!("reparse error: {}", e);
                                return 1;
                            }
                        }
                    }
                }
                Err(e) => {
                    eprintln!("parse error: {}", e);
                    return 1;
                }
            }
        }
    }
    println!("mode=roundtrip");
    println!("rounds={}", rounds);
    println!("total_stmts={}", total_stmts);
    println!("non_empty={}", non_empty);
    println!("tag_sum={}", tag_sum);
    0
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: sql_bench_rust <parse|tokenize|roundtrip> <path> <rounds>");
        process::exit(1);
    }
    let rounds: usize = args[3].parse().unwrap_or(1);
    let rc = match args[1].as_str() {
        "parse" => run_parse(&args[2], rounds),
        "tokenize" => run_tokenize(&args[2], rounds),
        "roundtrip" => run_roundtrip(&args[2], rounds),
        other => {
            eprintln!("unknown mode: {}", other);
            1
        }
    };
    process::exit(rc);
}
