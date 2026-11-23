//! apollo-parser =0.8.4 oracle for the packages/graphql red-team audit.
//!   oracle <tok|parse> <in> <out>        length-framed records (same format as the Pion probe)
//!   oracle one <in> <parse|tok> [reps]  whole-file timing / DoS probe
//! apollo-parser is a lossless, error-resilient CST parser: it never decodes string escapes or
//! dedents block strings, so it is used as an accept/reject + token-boundary oracle only.
use apollo_parser::{Lexer, Parser, TokenKind};
use std::{env, fs};

fn read_records(b: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let j = i + b[i..].iter().position(|&c| c == b'\n').unwrap();
        let n: usize = std::str::from_utf8(&b[i..j]).unwrap().parse().unwrap();
        out.push(b[j + 1..j + 1 + n].to_vec());
        i = j + 1 + n;
    }
    out
}

fn w(s: &str) -> String {
    format!("{}:{}", s.len(), s)
}

fn punct(k: TokenKind) -> Option<&'static str> {
    Some(match k {
        TokenKind::Bang => "!",
        TokenKind::Dollar => "$",
        TokenKind::Amp => "&",
        TokenKind::LParen => "(",
        TokenKind::RParen => ")",
        TokenKind::Spread => "...",
        TokenKind::Colon => ":",
        TokenKind::Eq => "=",
        TokenKind::At => "@",
        TokenKind::LBracket => "[",
        TokenKind::RBracket => "]",
        TokenKind::LCurly => "{",
        TokenKind::Pipe => "|",
        TokenKind::RCurly => "}",
        _ => return None,
    })
}

/// Token kinds + raw token text (apollo does not decode strings): `Name`, `Int`, `Float`, `String`
/// (raw text incl. quotes; block strings start with `"""`), `P` punctuators.
fn tok(src: &str) -> String {
    let (toks, errs) = Lexer::new(src).lex();
    if let Some(e) = errs.first() {
        return format!("ERR {} at {}", e.message(), e.index());
    }
    let mut out = String::new();
    for t in toks {
        let k = t.kind();
        if let Some(p) = punct(k) {
            out.push_str("P ");
            out.push_str(&w(p));
            continue;
        }
        let name = match k {
            TokenKind::Name => "Name",
            TokenKind::Int => "Int",
            TokenKind::Float => "Float",
            TokenKind::StringValue => {
                if t.data().starts_with("\"\"\"") { "BlockStringRaw" } else { "StringRaw" }
            }
            TokenKind::Whitespace | TokenKind::Comment | TokenKind::Comma | TokenKind::Eof => continue,
            _ => "Other",
        };
        out.push_str(name);
        out.push(' ');
        out.push_str(&w(t.data()));
    }
    out
}

fn parse(src: &str) -> String {
    let cst = Parser::new(src).parse();
    match cst.errors().next() {
        Some(e) => format!("ERR {} at {}", e.message(), e.index()),
        None => "OK".to_string(),
    }
}

fn run_one(mode: &str, rec: &[u8]) -> String {
    let src = match std::str::from_utf8(rec) {
        Ok(s) => s,
        Err(_) => return "ERR invalid utf-8 (rust &str)".to_string(),
    };
    match mode {
        "tok" => tok(src),
        "parse" => parse(src),
        _ => "ERR unknown mode".to_string(),
    }
}

fn main() {
    let a: Vec<String> = env::args().collect();
    if a[1] == "one" {
        let src = fs::read_to_string(&a[2]).expect("read");
        let sub = a[3].as_str();
        let reps: usize = a.get(4).map(|x| x.parse().unwrap()).unwrap_or(1);
        let mut total = 0usize;
        for r in 0..reps {
            match sub {
                "parse" => {
                    // limits raised so that DoS probes measure the algorithm (same as the Pion probe)
                    let cst = Parser::new(&src).recursion_limit(usize::MAX).parse();
                    if r == 0 {
                        if let Some(e) = cst.errors().next() {
                            println!("ERR {} at {}", e.message(), e.index());
                            return;
                        }
                    }
                    total += cst.document().definitions().count();
                }
                "parsedef" => {
                    let cst = Parser::new(&src).parse();
                    if let Some(e) = cst.errors().next() {
                        println!("ERR {} at {}", e.message(), e.index());
                        return;
                    }
                    total += 1;
                }
                "tok" => {
                    let (toks, errs) = Lexer::new(&src).lex();
                    if !errs.is_empty() {
                        println!("ERR lex");
                        return;
                    }
                    total += toks.len();
                }
                _ => panic!("unknown sub"),
            }
        }
        println!("ok {}", total);
        return;
    }
    let recs = read_records(&fs::read(&a[2]).expect("read"));
    let mut out: Vec<u8> = Vec::new();
    for r in recs {
        let s = run_one(&a[1], &r);
        out.extend_from_slice(format!("{}\n", s.len()).as_bytes());
        out.extend_from_slice(s.as_bytes());
    }
    fs::write(&a[3], out).expect("write");
}
