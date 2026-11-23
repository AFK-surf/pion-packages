//! Upstream oracle for the `packages/sql` red-team audit: Rust `sqlparser =0.53.0`.
//!
//!   probe <generic|sqlite|postgres> <hexfile>  -> `ERR <msg>` | `OK <n> <hex to_string> <RP_OK|RP_ERR> <ast_eq 0|1>`
//!   same  <generic|sqlite|postgres> <pairs>    -> each line `<hex a> <hex b>`: `EQ` | `NE` | `ERRA` | `ERRB`
//!       (is Pion's to_sql output the same statement as the original, judged by upstream's AST ==, spans ignored)
//!   adv   <workload> <file> <rounds>           -> digest identical to the Pion driver's `adv`
//!   deep  <shape> <n> <stage>                  -> same inputs as the Pion driver's `deep` (default recursion limit)
use sqlparser::dialect::{Dialect, GenericDialect, PostgreSqlDialect, SQLiteDialect};
use sqlparser::parser::Parser;
use sqlparser::tokenizer::{Token, Tokenizer};
use std::{env, fs, process};

#[cfg(feature = "mimalloc")]
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

fn dialect(name: &str) -> Box<dyn Dialect> {
    match name {
        "sqlite" => Box::new(SQLiteDialect {}),
        "postgres" => Box::new(PostgreSqlDialect {}),
        _ => Box::new(GenericDialect {}),
    }
}

fn unhex(h: &str) -> String {
    let b: Vec<u8> = (0..h.len() / 2)
        .map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap_or(0))
        .collect();
    String::from_utf8_lossy(&b).into_owned()
}

fn hex(s: &str) -> String {
    s.bytes().map(|b| format!("{b:02x}")).collect()
}

fn one_line(s: &str) -> String {
    s.replace(['\n', '\r', '\t'], " ")
}

fn parse(d: &dyn Dialect, s: &str) -> Result<Vec<sqlparser::ast::Statement>, String> {
    // generous recursion limit so the oracle never rejects what Pion accepts on depth alone
    Parser::new(d)
        .with_recursion_limit(4096)
        .try_with_sql(s)
        .and_then(|mut p| p.parse_statements())
        .map_err(|e| e.to_string())
}

fn render(stmts: &[sqlparser::ast::Statement]) -> String {
    stmts.iter().map(|s| s.to_string()).collect::<Vec<_>>().join("; ")
}

fn run_probe(d: &dyn Dialect, path: &str) {
    let content = fs::read_to_string(path).unwrap();
    let mut out = String::new();
    for line in content.split('\n').filter(|l| !l.is_empty()) {
        match parse(d, &unhex(line)) {
            Err(e) => out.push_str(&format!("ERR {}\n", one_line(&e))),
            Ok(stmts) => {
                let text = render(&stmts);
                let (rp, eq) = match parse(d, &text) {
                    Ok(re) => ("RP_OK", (re == stmts) as u8),
                    Err(_) => ("RP_ERR", 0),
                };
                out.push_str(&format!("OK {} {} {} {}\n", stmts.len(), hex(&text), rp, eq));
            }
        }
    }
    print!("{out}");
}

fn run_same(d: &dyn Dialect, path: &str) {
    let content = fs::read_to_string(path).unwrap();
    let mut out = String::new();
    for line in content.split('\n').filter(|l| !l.is_empty()) {
        let mut it = line.split(' ');
        let a = unhex(it.next().unwrap_or(""));
        let b = unhex(it.next().unwrap_or(""));
        let r = match (parse(d, &a), parse(d, &b)) {
            (Err(_), _) => "ERRA",
            (_, Err(_)) => "ERRB",
            (Ok(x), Ok(y)) => if x == y { "EQ" } else { "NE" },
        };
        out.push_str(r);
        out.push('\n');
    }
    print!("{out}");
}

/// `split` emulation: upstream has no splitter, so tokenize and cut at depth-0 `;` (same rule Pion documents).
fn split_count(d: &dyn Dialect, src: &str) -> Option<usize> {
    let toks = Tokenizer::new(d, src).tokenize().ok()?;
    let (mut depth, mut n, mut cur) = (0i64, 0usize, false);
    for t in toks {
        match t {
            Token::Whitespace(_) => {}
            Token::SemiColon if depth == 0 => {
                if cur {
                    n += 1;
                }
                cur = false;
            }
            Token::LParen => { depth += 1; cur = true; }
            Token::RParen => { if depth > 0 { depth -= 1; } cur = true; }
            _ => cur = true,
        }
    }
    Some(n + cur as usize)
}

fn run_adv(w: &str, path: &str, rounds: usize) {
    let content = fs::read_to_string(path).unwrap();
    let d = PostgreSqlDialect {};
    let (mut ok, mut err, mut acc) = (0i64, 0i64, 0i64);
    let lines: Vec<&str> = content.split('\n').collect();
    for _ in 0..rounds {
        match w {
            "split" => match split_count(&d, &content) {
                Some(n) => { ok += 1; acc += n as i64; }
                None => err += 1,
            },
            "script" => match Parser::new(&d).with_recursion_limit(128).try_with_sql(&content).and_then(|mut p| p.parse_statements()) {
                Ok(s) => { ok += 1; acc += s.len() as i64; }
                Err(_) => err += 1,
            },
            _ => {
                for l in lines.iter().filter(|l| !l.is_empty()) {
                    match Parser::new(&d).with_recursion_limit(128).try_with_sql(l).and_then(|mut p| p.parse_statements()) {
                        Ok(stmts) => {
                            if w == "rt" {
                                match Parser::parse_sql(&d, &render(&stmts)) {
                                    Ok(re) => { ok += 1; acc += re.len() as i64; }
                                    Err(_) => err += 1,
                                }
                            } else {
                                ok += 1;
                                acc += stmts.len() as i64;
                            }
                        }
                        Err(_) => err += 1,
                    }
                }
            }
        }
    }
    println!("workload={w} ok={ok} err={err} stmts={acc}");
}

fn rep(s: &str, n: usize) -> String {
    s.repeat(n)
}

fn build_shape(shape: &str, n: usize) -> String {
    match shape {
        "plus" => format!("SELECT 1{}", rep(" + 1", n)),
        "or" => format!("SELECT * FROM t WHERE a = 1{}", rep(" OR a = 1", n)),
        "concat" => format!("SELECT 'x'{}", rep(" || 'x'", n)),
        "cast" => format!("SELECT x{}", rep("::INT", n)),
        "subscript" => format!("SELECT x{}", rep("[1]", n)),
        "isnull" => format!("SELECT x{}", rep(" IS NULL", n)),
        "collate" => format!("SELECT x{}", rep(" COLLATE c", n)),
        "union" => format!("SELECT 1{}", rep(" UNION SELECT 1", n)),
        "paren" => format!("SELECT {}1{}", rep("(", n), rep(")", n)),
        "subq" => format!("{}SELECT 1{}", rep("SELECT (", n), rep(")", n)),
        _ => String::new(),
    }
}

/// Upstream behaviour on the same long / deep inputs: default `Parser::parse_sql` (recursion limit 50).
fn run_deep(shape: &str, n: usize, stage: &str) {
    let src = build_shape(shape, n);
    match Parser::parse_sql(&PostgreSqlDialect {}, &src) {
        Err(e) => println!("rejected {}", one_line(&e.to_string())),
        Ok(stmts) => {
            println!("parsed");
            if stage == "sql" {
                println!("sql {}", render(&stmts).len());
            }
        }
    }
}

fn main() {
    let a: Vec<String> = env::args().collect();
    if a.len() < 4 {
        eprintln!("usage: sql_audit_oracle <probe|same|adv> ...");
        process::exit(1);
    }
    match a[1].as_str() {
        "probe" => run_probe(dialect(&a[2]).as_ref(), &a[3]),
        "same" => run_same(dialect(&a[2]).as_ref(), &a[3]),
        "deep" => run_deep(&a[2], a[3].parse().unwrap_or(1), a.get(4).map(|s| s.as_str()).unwrap_or("none")),
        "adv" => run_adv(&a[2], &a[3], a.get(4).and_then(|s| s.parse().ok()).unwrap_or(1)),
        _ => process::exit(1),
    }
}
