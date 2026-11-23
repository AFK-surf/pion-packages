use cssparser::{
    AtRuleParser, CowRcStr, DeclarationParser, ParseError, Parser, ParserInput,
    QualifiedRuleParser, RuleBodyItemParser, RuleBodyParser, StyleSheetParser, Token,
};
use std::env;
use std::fs;

fn count_tokens_recursive(parser: &mut Parser<'_, '_>) -> u64 {
    let mut count: u64 = 0;
    while let Ok(tok) = parser.next() {
        count += 1;
        match tok {
            Token::CurlyBracketBlock
            | Token::ParenthesisBlock
            | Token::SquareBracketBlock
            | Token::Function(_) => {
                let inner: Result<u64, ParseError<'_, ()>> = parser.parse_nested_block(|p| {
                    Ok(count_tokens_recursive(p))
                });
                if let Ok(c) = inner {
                    count += c;
                }
                // Closing delimiter token ('}', ')', ']')
                count += 1;
            }
            _ => {}
        }
    }
    count
}

#[derive(Default)]
struct Stats {
    qualified_rules: u64,
    at_rules: u64,
    declarations: u64,
    important: u64,
}

struct BenchDeclParser<'a> {
    stats: &'a mut Stats,
}

impl<'i> DeclarationParser<'i> for BenchDeclParser<'_> {
    type Declaration = ();
    type Error = ();

    fn parse_value<'t>(
        &mut self,
        _name: CowRcStr<'i>,
        input: &mut Parser<'i, 't>,
        _state: &cssparser::ParserState,
    ) -> Result<(), ParseError<'i, ()>> {
        let mut important = false;
        while let Ok(tok) = input.next() {
            if matches!(tok, Token::Delim('!')) {
                if let Ok(Token::Ident(ref id)) = input.next() {
                    if id.eq_ignore_ascii_case("important") {
                        important = true;
                    }
                }
            }
        }
        self.stats.declarations += 1;
        if important {
            self.stats.important += 1;
        }
        Ok(())
    }
}

impl<'i> AtRuleParser<'i> for BenchDeclParser<'_> {
    type Prelude = ();
    type AtRule = ();
    type Error = ();
}

impl<'i> QualifiedRuleParser<'i> for BenchDeclParser<'_> {
    type Prelude = ();
    type QualifiedRule = ();
    type Error = ();
}

impl<'i> RuleBodyItemParser<'i, (), ()> for BenchDeclParser<'_> {
    fn parse_declarations(&self) -> bool {
        true
    }
    fn parse_qualified(&self) -> bool {
        false
    }
}

struct BenchSheetParser<'a> {
    stats: &'a mut Stats,
}

impl<'i> QualifiedRuleParser<'i> for BenchSheetParser<'_> {
    type Prelude = ();
    type QualifiedRule = ();
    type Error = ();

    fn parse_prelude<'t>(
        &mut self,
        input: &mut Parser<'i, 't>,
    ) -> Result<(), ParseError<'i, ()>> {
        while input.next().is_ok() {}
        Ok(())
    }

    fn parse_block<'t>(
        &mut self,
        _prelude: (),
        _start: &cssparser::ParserState,
        input: &mut Parser<'i, 't>,
    ) -> Result<(), ParseError<'i, ()>> {
        self.stats.qualified_rules += 1;
        let mut dp = BenchDeclParser { stats: self.stats };
        let iter = RuleBodyParser::new(input, &mut dp);
        for _ in iter {}
        Ok(())
    }
}

impl<'i> AtRuleParser<'i> for BenchSheetParser<'_> {
    type Prelude = String;
    type AtRule = ();
    type Error = ();

    fn parse_prelude<'t>(
        &mut self,
        name: CowRcStr<'i>,
        input: &mut Parser<'i, 't>,
    ) -> Result<String, ParseError<'i, ()>> {
        while input.next().is_ok() {}
        Ok(name.to_ascii_lowercase())
    }

    fn rule_without_block(
        &mut self,
        _prelude: String,
        _start: &cssparser::ParserState,
    ) -> Result<(), ()> {
        self.stats.at_rules += 1;
        Ok(())
    }

    fn parse_block<'t>(
        &mut self,
        prelude: String,
        _start: &cssparser::ParserState,
        input: &mut Parser<'i, 't>,
    ) -> Result<(), ParseError<'i, ()>> {
        self.stats.at_rules += 1;
        if prelude == "font-face" {
            let mut dp = BenchDeclParser { stats: self.stats };
            let iter = RuleBodyParser::new(input, &mut dp);
            for _ in iter {}
        } else {
            let mut nested = BenchSheetParser { stats: self.stats };
            let iter = StyleSheetParser::new(input, &mut nested);
            for _ in iter {}
        }
        Ok(())
    }
}

fn minify_cssparser(src: &str) -> String {
    let mut pi = ParserInput::new(src);
    let mut p = Parser::new(&mut pi);
    let mut out = String::with_capacity(src.len());
    minify_stream(&mut p, &mut out, false);
    out
}

fn minify_stream(parser: &mut Parser<'_, '_>, out: &mut String, in_calc: bool) {
    let mut prev_needs_space = false;
    let mut prev_was_delim_pm = false;
    let mut prev_was_custom_prop = false;
    let mut keep_custom_ws = false;
    while let Ok(tok) = parser.next_including_whitespace() {
        match tok {
            Token::WhiteSpace(ws) => {
                if keep_custom_ws {
                    out.push_str(ws);
                    keep_custom_ws = false;
                    prev_needs_space = false;
                } else if !out.is_empty() {
                    let last = out.as_bytes()[out.len() - 1];
                    if in_calc && prev_was_delim_pm {
                        out.push(' ');
                        prev_needs_space = false;
                    } else if !matches!(last, b'{' | b'}' | b':' | b';' | b',' | b'>' | b'(' | b' ') {
                        prev_needs_space = true;
                    }
                }
            }
            Token::CurlyBracketBlock => {
                prev_needs_space = false;
                prev_was_delim_pm = false;
                prev_was_custom_prop = false;
                keep_custom_ws = false;
                out.push('{');
                let _ = parser.parse_nested_block(|p| -> Result<(), ParseError<'_, ()>> {
                    minify_stream(p, out, false);
                    Ok(())
                });
                if out.ends_with(';') {
                    out.pop();
                }
                out.push('}');
            }
            Token::ParenthesisBlock => {
                if prev_needs_space {
                    out.push(' ');
                    prev_needs_space = false;
                }
                prev_was_delim_pm = false;
                prev_was_custom_prop = false;
                keep_custom_ws = false;
                out.push('(');
                let _ = parser.parse_nested_block(|p| -> Result<(), ParseError<'_, ()>> {
                    minify_stream(p, out, in_calc);
                    Ok(())
                });
                out.push(')');
            }
            Token::SquareBracketBlock => {
                if prev_needs_space {
                    out.push(' ');
                    prev_needs_space = false;
                }
                prev_was_delim_pm = false;
                prev_was_custom_prop = false;
                keep_custom_ws = false;
                out.push('[');
                let _ = parser.parse_nested_block(|p| -> Result<(), ParseError<'_, ()>> {
                    minify_stream(p, out, false);
                    Ok(())
                });
                out.push(']');
            }
            Token::Function(ref name) => {
                if prev_needs_space {
                    out.push(' ');
                    prev_needs_space = false;
                }
                prev_was_delim_pm = false;
                prev_was_custom_prop = false;
                keep_custom_ws = false;
                let is_math = name.eq_ignore_ascii_case("calc")
                    || name.eq_ignore_ascii_case("min")
                    || name.eq_ignore_ascii_case("max")
                    || name.eq_ignore_ascii_case("clamp");
                out.push_str(name);
                out.push('(');
                let _ = parser.parse_nested_block(|p| -> Result<(), ParseError<'_, ()>> {
                    minify_stream(p, out, is_math);
                    Ok(())
                });
                out.push(')');
            }
            Token::Colon => {
                prev_needs_space = false;
                prev_was_delim_pm = false;
                keep_custom_ws = prev_was_custom_prop;
                prev_was_custom_prop = false;
                out.push(':');
            }
            Token::Semicolon => {
                prev_needs_space = false;
                prev_was_delim_pm = false;
                prev_was_custom_prop = false;
                keep_custom_ws = false;
                out.push(';');
            }
            Token::Comma => {
                prev_needs_space = false;
                prev_was_delim_pm = false;
                prev_was_custom_prop = false;
                keep_custom_ws = false;
                out.push(',');
            }
            Token::Delim(c) => {
                let c = *c;
                prev_was_custom_prop = false;
                keep_custom_ws = false;
                if c == '>' {
                    prev_needs_space = false;
                    prev_was_delim_pm = false;
                    out.push('>');
                } else if c == '!' {
                    prev_needs_space = false;
                    prev_was_delim_pm = false;
                    out.push('!');
                } else if in_calc && (c == '+' || c == '-') {
                    if !out.ends_with(' ') {
                        out.push(' ');
                    }
                    prev_needs_space = false;
                    prev_was_delim_pm = true;
                    out.push(c);
                } else {
                    if prev_needs_space {
                        out.push(' ');
                        prev_needs_space = false;
                    }
                    prev_was_delim_pm = false;
                    out.push(c);
                }
            }
            Token::Ident(ref s) => {
                if prev_needs_space {
                    out.push(' ');
                    prev_needs_space = false;
                }
                prev_was_delim_pm = false;
                prev_was_custom_prop = s.starts_with("--");
                keep_custom_ws = false;
                out.push_str(s);
            }
            Token::AtKeyword(ref s) => {
                prev_needs_space = false;
                prev_was_delim_pm = false;
                prev_was_custom_prop = false;
                keep_custom_ws = false;
                out.push('@');
                out.push_str(s);
            }
            Token::IDHash(ref s) | Token::Hash(ref s) => {
                if prev_needs_space {
                    out.push(' ');
                    prev_needs_space = false;
                }
                prev_was_delim_pm = false;
                out.push('#');
                out.push_str(s);
            }
            Token::QuotedString(ref s) => {
                if prev_needs_space {
                    out.push(' ');
                    prev_needs_space = false;
                }
                prev_was_delim_pm = false;
                out.push('"');
                out.push_str(s);
                out.push('"');
            }
            Token::UnquotedUrl(ref s) => {
                if prev_needs_space {
                    out.push(' ');
                    prev_needs_space = false;
                }
                prev_was_delim_pm = false;
                out.push_str("url(");
                out.push_str(s);
                out.push(')');
            }
            Token::Number {
                value,
                int_value,
                ..
            } => {
                if prev_needs_space {
                    out.push(' ');
                    prev_needs_space = false;
                }
                prev_was_delim_pm = false;
                if let Some(iv) = int_value {
                    out.push_str(&iv.to_string());
                } else {
                    out.push_str(&value.to_string());
                }
            }
            Token::Percentage {
                unit_value,
                int_value,
                ..
            } => {
                if prev_needs_space {
                    out.push(' ');
                    prev_needs_space = false;
                }
                prev_was_delim_pm = false;
                if let Some(iv) = int_value {
                    out.push_str(&iv.to_string());
                } else {
                    out.push_str(&(unit_value * 100.0).to_string());
                }
                out.push('%');
            }
            Token::Dimension {
                value,
                int_value,
                ref unit,
                ..
            } => {
                if prev_needs_space {
                    out.push(' ');
                    prev_needs_space = false;
                }
                prev_was_delim_pm = false;
                if let Some(iv) = int_value {
                    out.push_str(&iv.to_string());
                } else {
                    out.push_str(&value.to_string());
                }
                out.push_str(unit);
            }
            _ => {}
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: css_bench_rust <tokenize|parse|minify> <file> <iters>");
        std::process::exit(1);
    }
    let mode = &args[1];
    let path = &args[2];
    let iters: usize = args[3].parse().unwrap_or(1);
    let src = fs::read_to_string(path).expect("failed to read input file");

    match mode.as_str() {
        "tokenize" => {
            let mut total: u64 = 0;
            for _ in 0..iters {
                let mut pi = ParserInput::new(&src);
                let mut p = Parser::new(&mut pi);
                total += count_tokens_recursive(&mut p);
            }
            println!("mode=tokenize");
            println!("iters={iters}");
            println!("non_ws_tokens={total}");
        }
        "parse" => {
            let mut total = Stats::default();
            for _ in 0..iters {
                let mut pi = ParserInput::new(&src);
                let mut p = Parser::new(&mut pi);
                let mut sp = BenchSheetParser { stats: &mut total };
                let iter = StyleSheetParser::new(&mut p, &mut sp);
                for _ in iter {}
            }
            println!("mode=parse");
            println!("iters={iters}");
            println!("qualified_rules={}", total.qualified_rules);
            println!("at_rules={}", total.at_rules);
            println!("declarations={}", total.declarations);
            println!("important={}", total.important);
        }
        "minify" => {
            let mut total_bytes: u64 = 0;
            let mut last_out = String::new();
            for _ in 0..iters {
                let out = minify_cssparser(&src);
                total_bytes += out.len() as u64;
                last_out = out;
            }
            println!("mode=minify");
            println!("iters={iters}");
            println!("total_bytes={total_bytes}");
            println!("sample_head={}", &last_out[..120.min(last_out.len())]);
        }
        other => {
            eprintln!("unknown mode: {other}");
            std::process::exit(1);
        }
    }
}
