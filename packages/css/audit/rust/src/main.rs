//! Red-team oracle for `packages/css`: Rust `cssparser =0.35.0`, `cssparser-color =0.3.0` and
//! `lightningcss =1.0.0-alpha.72` (its `parcel_selectors` fork of Servo `selectors`).
//!
//! Batch modes (length-framed records `<len>\n<bytes>`, same as the Pion probe):
//!   tok    <in> <out> : cssparser token dump (`KIND len:value`, comments dropped, `~=` etc. split
//!                       into two DELIMs, closing tokens emitted only when present in the source)
//!   sheet  <in> <out> : CSS Syntax 3 / CSS Nesting generic AST dump built on cssparser's
//!                       StyleSheetParser + RuleBodyParser (same dump format as the Pion probe)
//!   decls  <in> <out> : declaration-list dump (inline `style` attribute grammar)
//!   color  <in> <out> : cssparser-color -> `r g b a` / `currentcolor` / `OTHER` / `ERR`
//!   spec   <in> <out> : lightningcss/parcel_selectors specificity list `a,b,c;...` / `ERR`
//!   mq     <in> <out> : lightningcss media list -> `<n> <n_not_all>` / `ERR`
//!   lnorm  <in> <out> : lightningcss parse (error recovery) + minified print: semantic normal form
//!   lstrict <in> <out>: lightningcss strict parse -> `OK` / `ERR ...`
//! Single-file timing modes (print a summary line):
//!   one <file> tokcount|tokdump|sheet|lmin|lparse [reps]

use cssparser::{
    AtRuleParser, CowRcStr, DeclarationParser, ParseError, Parser, ParserInput, ParserState,
    QualifiedRuleParser, RuleBodyItemParser, RuleBodyParser, StyleSheetParser, Token,
};
use std::env;
use std::fmt::Write as _;
use std::fs;

// ---------------------------------------------------------------- record I/O

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

fn emit(out: &mut Vec<u8>, s: &str) {
    out.extend_from_slice(s.len().to_string().as_bytes());
    out.push(b'\n');
    out.extend_from_slice(s.as_bytes());
}

fn item(sb: &mut String, kind: &str, v: &str) {
    let _ = write!(sb, "{} {}:{}", kind, v.len(), v);
}

// ---------------------------------------------------------------- tokens

fn num(sb: &mut String, kind: &str, has_sign: bool, is_int: bool, v: f32, unit: Option<&str>) {
    let mut s = format!(
        "{}{} {}",
        if has_sign { 1 } else { 0 },
        if is_int { 1 } else { 0 },
        v as f64
    );
    if let Some(u) = unit {
        s.push(' ');
        s.push_str(u);
    }
    item(sb, kind, &s);
}

fn dump_tokens(p: &mut Parser<'_, '_>, sb: &mut String, count_only: &mut u64, dump: bool) {
    loop {
        let tok = match p.next_including_whitespace_and_comments() {
            Ok(t) => t.clone(),
            Err(_) => break,
        };
        if let Token::Comment(_) = tok {
            continue;
        }
        if !matches!(tok, Token::WhiteSpace(_)) {
            *count_only += 1;
        }
        if !dump {
            if let Token::Function(_)
            | Token::ParenthesisBlock
            | Token::SquareBracketBlock
            | Token::CurlyBracketBlock = tok
            {
                let _ = p.parse_nested_block(|q| -> Result<(), ParseError<'_, ()>> {
                    dump_tokens(q, sb, count_only, dump);
                    Ok(())
                });
            }
            continue;
        }
        let close = match &tok {
            Token::Ident(s) => {
                item(sb, "IDENT", s);
                None
            }
            Token::AtKeyword(s) => {
                item(sb, "AT", s);
                None
            }
            Token::Hash(s) => {
                item(sb, "HASH", s);
                None
            }
            Token::IDHash(s) => {
                item(sb, "IDHASH", s);
                None
            }
            Token::QuotedString(s) => {
                item(sb, "STR", s);
                None
            }
            Token::UnquotedUrl(s) => {
                item(sb, "URL", s);
                None
            }
            Token::Delim(c) => {
                item(sb, "DELIM", &c.to_string());
                None
            }
            Token::Number { has_sign, value, int_value } => {
                num(sb, "NUM", *has_sign, int_value.is_some(), *value, None);
                None
            }
            Token::Percentage { has_sign, unit_value, int_value } => {
                // raw f32 unit_value (0.15 for 15%); the comparer rescales the other implementations
                num(sb, "PCT", *has_sign, int_value.is_some(), *unit_value, None);
                None
            }
            Token::Dimension { has_sign, value, int_value, unit } => {
                num(sb, "DIM", *has_sign, int_value.is_some(), *value, Some(unit));
                None
            }
            Token::WhiteSpace(_) => {
                item(sb, "WS", "");
                None
            }
            Token::Comment(_) => None,
            Token::Colon => {
                item(sb, "COLON", "");
                None
            }
            Token::Semicolon => {
                item(sb, "SEMI", "");
                None
            }
            Token::Comma => {
                item(sb, "COMMA", "");
                None
            }
            Token::IncludeMatch => {
                item(sb, "DELIM", "~");
                item(sb, "DELIM", "=");
                None
            }
            Token::DashMatch => {
                item(sb, "DELIM", "|");
                item(sb, "DELIM", "=");
                None
            }
            Token::PrefixMatch => {
                item(sb, "DELIM", "^");
                item(sb, "DELIM", "=");
                None
            }
            Token::SuffixMatch => {
                item(sb, "DELIM", "$");
                item(sb, "DELIM", "=");
                None
            }
            Token::SubstringMatch => {
                item(sb, "DELIM", "*");
                item(sb, "DELIM", "=");
                None
            }
            Token::CDO => {
                item(sb, "CDO", "");
                None
            }
            Token::CDC => {
                item(sb, "CDC", "");
                None
            }
            Token::Function(s) => {
                item(sb, "FUNC", s);
                Some("RPAR")
            }
            Token::ParenthesisBlock => {
                item(sb, "LPAR", "");
                Some("RPAR")
            }
            Token::SquareBracketBlock => {
                item(sb, "LSQ", "");
                Some("RSQ")
            }
            Token::CurlyBracketBlock => {
                item(sb, "LCUR", "");
                Some("RCUR")
            }
            Token::BadUrl(_) => {
                item(sb, "BADURL", "");
                None
            }
            Token::BadString(_) => {
                item(sb, "BADSTR", "");
                None
            }
            Token::CloseParenthesis => {
                item(sb, "RPAR", "");
                None
            }
            Token::CloseSquareBracket => {
                item(sb, "RSQ", "");
                None
            }
            Token::CloseCurlyBracket => {
                item(sb, "RCUR", "");
                None
            }
        };
        if let Some(c) = close {
            let mut inner_end = 0usize;
            let _ = p.parse_nested_block(|q| -> Result<(), ParseError<'_, ()>> {
                dump_tokens(q, sb, count_only, dump);
                inner_end = q.position().byte_index();
                Ok(())
            });
            // A closing token was consumed iff the outer parser moved past the inner end.
            if p.position().byte_index() > inner_end {
                item(sb, c, "");
            }
        }
    }
}

fn tok_dump(src: &str) -> String {
    let mut pi = ParserInput::new(src);
    let mut p = Parser::new(&mut pi);
    let mut sb = String::new();
    let mut c = 0;
    dump_tokens(&mut p, &mut sb, &mut c, true);
    sb
}

fn tok_count(src: &str) -> u64 {
    let mut pi = ParserInput::new(src);
    let mut p = Parser::new(&mut pi);
    let mut sb = String::new();
    let mut c = 0;
    dump_tokens(&mut p, &mut sb, &mut c, false);
    c
}

// ---------------------------------------------------------------- generic AST (CSS Syntax 3 + Nesting)

enum Node {
    Decl(String, String, bool),
    Qualified(String, Vec<Node>),
    At(String, String, Option<Vec<Node>>),
}

fn is_decl_at_rule(name: &str) -> bool {
    matches!(
        name,
        "font-face"
            | "page"
            | "property"
            | "counter-style"
            | "font-palette-values"
            | "font-feature-values"
            | "viewport"
    )
}

fn is_group_at_rule(name: &str) -> bool {
    matches!(
        name,
        "media" | "supports" | "container" | "layer" | "document" | "scope" | "starting-style"
    )
}

/// Block content modes.
#[derive(Clone, Copy, PartialEq)]
enum Ctx {
    /// Style-rule body (CSS Nesting): declarations + nested rules.
    Body,
    /// Top-level-like rule list (stylesheet, top-level @media / @keyframes): rules only.
    RuleList,
    /// Declaration list only (@font-face, inline style).
    DeclList,
}

struct P {
    ctx: Ctx,
    nested: bool,
}

fn parse_block_items<'i>(input: &mut Parser<'i, '_>, ctx: Ctx, nested: bool) -> Vec<Node> {
    let mut p = P { ctx, nested };
    let mut out = Vec::new();
    for r in RuleBodyParser::new(input, &mut p) {
        if let Ok(n) = r {
            out.push(n);
        }
    }
    out
}

fn trim_ws(s: &str) -> &str {
    s.trim_matches(|c| c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\x0c')
}

impl<'i> DeclarationParser<'i> for P {
    type Declaration = Node;
    type Error = ();
    fn parse_value<'t>(
        &mut self,
        name: CowRcStr<'i>,
        input: &mut Parser<'i, 't>,
        _start: &ParserState,
    ) -> Result<Node, ParseError<'i, ()>> {
        let is_custom = name.starts_with("--");
        input.skip_whitespace();
        let start = input.position();
        let mut end = start;
        let mut important = false;
        let mut saw_block = false;
        let mut saw_other = false;
        loop {
            let st = input.state();
            if input
                .try_parse(|i| -> Result<(), ParseError<'i, ()>> {
                    cssparser::parse_important(i)?;
                    i.expect_exhausted()?;
                    Ok(())
                })
                .is_ok()
            {
                important = true;
                break;
            }
            input.reset(&st);
            let is_block = match input.next() {
                Ok(Token::CurlyBracketBlock) => {
                    saw_block = true;
                    true
                }
                Ok(Token::BadUrl(_)) | Ok(Token::BadString(_)) => return Err(input.new_custom_error(())),
                Ok(Token::Function(_)) | Ok(Token::ParenthesisBlock) | Ok(Token::SquareBracketBlock) => {
                    saw_other = true;
                    true
                }
                Ok(_) => {
                    saw_other = true;
                    false
                }
                Err(_) => break,
            };
            if is_block {
                // consume the block now so that `end` lands after its closing token
                let _ = input.parse_nested_block(|q| -> Result<(), ParseError<'i, ()>> {
                    while q.next_including_whitespace_and_comments().is_ok() {}
                    Ok(())
                });
            }
            end = input.position();
        }
        // CSS Syntax 3 "consume a declaration": a non-custom value mixing a {}-block with
        // other tokens is not a declaration (re-parsed as a nested qualified rule).
        if !is_custom && saw_block && saw_other {
            return Err(input.new_custom_error(()));
        }
        let v = trim_ws(input.slice(start..end)).to_string();
        let n = if is_custom { name.to_string() } else { name.to_ascii_lowercase() };
        Ok(Node::Decl(n, v, important))
    }
}

impl<'i> QualifiedRuleParser<'i> for P {
    type Prelude = String;
    type QualifiedRule = Node;
    type Error = ();
    fn parse_prelude<'t>(&mut self, input: &mut Parser<'i, 't>) -> Result<String, ParseError<'i, ()>> {
        let start = input.position();
        while input.next_including_whitespace_and_comments().is_ok() {}
        Ok(trim_ws(input.slice_from(start)).to_string())
    }
    fn parse_block<'t>(
        &mut self,
        prelude: String,
        _start: &ParserState,
        input: &mut Parser<'i, 't>,
    ) -> Result<Node, ParseError<'i, ()>> {
        Ok(Node::Qualified(prelude, parse_block_items(input, Ctx::Body, true)))
    }
}

impl<'i> AtRuleParser<'i> for P {
    type Prelude = (String, String);
    type AtRule = Node;
    type Error = ();
    fn parse_prelude<'t>(
        &mut self,
        name: CowRcStr<'i>,
        input: &mut Parser<'i, 't>,
    ) -> Result<(String, String), ParseError<'i, ()>> {
        let start = input.position();
        while input.next_including_whitespace_and_comments().is_ok() {}
        Ok((name.to_ascii_lowercase(), trim_ws(input.slice_from(start)).to_string()))
    }
    fn rule_without_block(&mut self, p: (String, String), _s: &ParserState) -> Result<Node, ()> {
        Ok(Node::At(p.0, p.1, None))
    }
    fn parse_block<'t>(
        &mut self,
        p: (String, String),
        _start: &ParserState,
        input: &mut Parser<'i, 't>,
    ) -> Result<Node, ParseError<'i, ()>> {
        let name = p.0.as_str();
        let ctx = if is_decl_at_rule(name) {
            Ctx::DeclList
        } else if name == "keyframes" || name.ends_with("-keyframes") {
            Ctx::RuleList
        } else if is_group_at_rule(name) {
            if self.nested { Ctx::Body } else { Ctx::RuleList }
        } else {
            Ctx::Body
        };
        let nested = self.nested;
        let items = parse_block_items(input, ctx, nested || ctx == Ctx::Body);
        Ok(Node::At(p.0, p.1, Some(items)))
    }
}

impl<'i> RuleBodyItemParser<'i, Node, ()> for P {
    fn parse_declarations(&self) -> bool {
        self.ctx != Ctx::RuleList
    }
    fn parse_qualified(&self) -> bool {
        self.ctx != Ctx::DeclList
    }
}

fn dump_nodes(sb: &mut String, nodes: &[Node]) {
    // Pion's AST keeps declarations and child rules in two separate arrays, so the oracle dump
    // lists a block's declarations first, then its child rules (ordering loss is audited apart).
    for n in nodes {
        if let Node::Decl(name, v, imp) = n {
            item(sb, "DECL", name);
            item(sb, "VAL", v);
            if *imp {
                item(sb, "IMP", "");
            }
        }
    }
    for n in nodes {
        match n {
            Node::Decl(..) => {}
            Node::Qualified(pre, kids) => {
                item(sb, "QR", pre);
                dump_nodes(sb, kids);
                item(sb, "END", "");
            }
            Node::At(name, pre, block) => {
                item(sb, "AT", name);
                item(sb, "PRE", pre);
                match block {
                    Some(kids) => {
                        dump_nodes(sb, kids);
                        item(sb, "END", "");
                    }
                    None => item(sb, "STMT", ""),
                }
            }
        }
    }
}

fn sheet_nodes(src: &str) -> Vec<Node> {
    let mut pi = ParserInput::new(src);
    let mut input = Parser::new(&mut pi);
    let mut p = P { ctx: Ctx::RuleList, nested: false };
    let mut out = Vec::new();
    for r in StyleSheetParser::new(&mut input, &mut p) {
        if let Ok(n) = r {
            out.push(n);
        }
    }
    out
}

fn sheet_dump(src: &str) -> String {
    let mut sb = String::new();
    dump_nodes(&mut sb, &sheet_nodes(src));
    sb
}

fn decls_dump(src: &str) -> String {
    let mut pi = ParserInput::new(src);
    let mut input = Parser::new(&mut pi);
    let nodes = parse_block_items(&mut input, Ctx::DeclList, false);
    let mut sb = String::new();
    dump_nodes(&mut sb, &nodes);
    sb
}

fn count_nodes(nodes: &[Node], acc: &mut [u64; 3]) {
    for n in nodes {
        match n {
            Node::Decl(..) => acc[2] += 1,
            Node::Qualified(_, k) => {
                acc[0] += 1;
                count_nodes(k, acc)
            }
            Node::At(_, _, b) => {
                acc[1] += 1;
                if let Some(k) = b {
                    count_nodes(k, acc)
                }
            }
        }
    }
}

// ---------------------------------------------------------------- color (cssparser-color 0.3.0)

fn color(src: &str) -> String {
    let mut pi = ParserInput::new(src);
    let mut p = Parser::new(&mut pi);
    let c = match p.parse_entirely(|i| cssparser_color::Color::parse(i)) {
        Ok(c) => c,
        Err(_) => return "ERR".into(),
    };
    use cssparser_color::Color as C;
    match c {
        C::CurrentColor => "currentcolor".into(),
        C::Rgba(r) => format!("{} {} {} {}", r.red, r.green, r.blue, r.alpha as f64),
        C::Hsl(h) => {
            let (r, g, b) = cssparser_color::hsl_to_rgb(
                {
                    let x = h.hue.unwrap_or(0.0);
                    (x - 360.0 * (x / 360.0).floor()) / 360.0
                },
                h.saturation.unwrap_or(0.0),
                h.lightness.unwrap_or(0.0),
            );
            let c = cssparser_color::RgbaLegacy::from_floats(r, g, b, h.alpha.unwrap_or(1.0));
            format!("{} {} {} {}", c.red, c.green, c.blue, c.alpha as f64)
        }
        _ => "OTHER".into(),
    }
}

// ---------------------------------------------------------------- lightningcss

fn lopts<'o>(recover: bool) -> lightningcss::stylesheet::ParserOptions<'o> {
    lightningcss::stylesheet::ParserOptions { error_recovery: recover, ..Default::default() }
}

fn lnorm(src: &str) -> String {
    use lightningcss::stylesheet::{PrinterOptions, StyleSheet};
    match StyleSheet::parse(src, lopts(true)) {
        Ok(s) => match s.to_css(PrinterOptions { minify: true, ..Default::default() }) {
            Ok(r) => r.code,
            Err(e) => format!("ERR print {}", e),
        },
        Err(e) => format!("ERR {}", e),
    }
}

fn lstrict(src: &str) -> String {
    use lightningcss::stylesheet::{PrinterOptions, StyleSheet};
    match StyleSheet::parse(src, lopts(false)) {
        Ok(s) => match s.to_css(PrinterOptions { minify: true, ..Default::default() }) {
            Ok(_) => "OK".into(),
            Err(e) => format!("ERR print {}", e),
        },
        Err(e) => format!("ERR {}", e),
    }
}

fn spec(sel: &str) -> String {
    use lightningcss::rules::CssRule;
    use lightningcss::stylesheet::StyleSheet;
    if sel.contains('{') || sel.contains('}') {
        return "ERR".into();
    }
    let src = format!("{}{{}}", sel);
    let s = match StyleSheet::parse(&src, lopts(false)) {
        Ok(s) => s,
        Err(_) => return "ERR".into(),
    };
    if s.rules.0.len() != 1 {
        return "ERR".into();
    }
    match &s.rules.0[0] {
        CssRule::Style(r) => r
            .selectors
            .0
            .iter()
            .map(|x| {
                let v = x.specificity();
                format!("{},{},{}", v >> 20, (v >> 10) & 1023, v & 1023)
            })
            .collect::<Vec<_>>()
            .join(";"),
        _ => "ERR".into(),
    }
}

fn mq(q: &str) -> String {
    use lightningcss::rules::CssRule;
    use lightningcss::stylesheet::StyleSheet;
    use lightningcss::traits::ToCss;
    if q.contains('{') || q.contains('}') || q.contains(';') {
        return "ERR".into();
    }
    let src = format!("@media {}{{}}", q);
    let s = match StyleSheet::parse(&src, lopts(false)) {
        Ok(s) => s,
        Err(_) => return "ERR".into(),
    };
    match s.rules.0.first() {
        Some(CssRule::Media(m)) => {
            let n = m.query.media_queries.len();
            let bad = m
                .query
                .media_queries
                .iter()
                .filter(|x| x.to_css_string(Default::default()).map(|s| s == "not all").unwrap_or(true))
                .count();
            format!("{} {}", n, bad)
        }
        _ => "ERR".into(),
    }
}

// ---------------------------------------------------------------- main

fn run(mode: &str, src: &str) -> String {
    match mode {
        "tok" => tok_dump(src),
        "sheet" => sheet_dump(src),
        "decls" => decls_dump(src),
        "color" => color(src),
        "spec" => spec(src),
        "mq" => mq(src),
        "lnorm" => lnorm(src),
        "lstrict" => lstrict(src),
        _ => "ERR unknown mode".into(),
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: oracle tok|sheet|decls|color|spec|mq|lnorm|lstrict <in> <out> | one <file> <mode> [reps]");
        std::process::exit(2);
    }
    let mode = args[1].as_str();
    let data = fs::read(&args[2]).expect("read");
    if mode == "one" {
        let src = String::from_utf8_lossy(&data).into_owned();
        let sub = args[3].as_str();
        let reps: usize = args.get(4).map(|s| s.parse().unwrap()).unwrap_or(1);
        let mut total: u64 = 0;
        for _ in 0..reps {
            total += match sub {
                "tokcount" => tok_count(&src),
                "tokdump" => tok_dump(&src).len() as u64,
                "sheet" => {
                    let mut acc = [0u64; 3];
                    count_nodes(&sheet_nodes(&src), &mut acc);
                    acc[0] + acc[1] + acc[2]
                }
                "lparse" => {
                    let s = lightningcss::stylesheet::StyleSheet::parse(&src, lopts(true)).expect("lparse");
                    s.rules.0.len() as u64
                }
                "lmin" => lnorm(&src).len() as u64,
                other => run(other, &src).len() as u64,
            };
        }
        println!("ok {}", total);
        return;
    }
    let out_path = &args[3];
    let mut out = Vec::new();
    for r in read_records(&data) {
        let s = String::from_utf8_lossy(&r);
        emit(&mut out, &run(mode, &s));
    }
    fs::write(out_path, out).expect("write");
}
