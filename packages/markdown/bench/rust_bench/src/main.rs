use pulldown_cmark::{html, Options, Parser};
use std::env;
use std::fs;
use std::io::{self, Write};
use std::process;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: rust_markdown_bench <input.md> [commonmark|gfm]");
        process::exit(2);
    }
    let src = fs::read_to_string(&args[1]).unwrap_or_else(|e| {
        eprintln!("error: failed to read {}: {}", args[1], e);
        process::exit(1);
    });
    let mode = args.get(2).map(|s| s.as_str()).unwrap_or("commonmark");
    let mut opts = Options::empty();
    if mode == "gfm" {
        opts.insert(Options::ENABLE_TABLES);
        opts.insert(Options::ENABLE_STRIKETHROUGH);
        opts.insert(Options::ENABLE_TASKLISTS);
    }
    let parser = Parser::new_ext(&src, opts);
    let mut out = String::with_capacity(src.len() * 3 / 2);
    html::push_html(&mut out, parser);
    io::stdout().write_all(out.as_bytes()).unwrap();
}
