//! feed-rs =2.4.0 oracle for the packages/feed red-team audit.
//! usage: rt_feed_oracle batch <requests.tsv>   (`<id>\t<op>\t<hex utf-8 input>` per line; op is ignored, always P)
//!        rt_feed_oracle bench <file> <iters>   in-process parse loop (benchmark-fairness step)
//! Prints the same canonical `key\tvalue` dump as the Pion probe (audit/probe), field for field where
//! feed-rs has an equivalent, so diff/diff_feed.py can compare the two on chosen keys.
use feed_rs::model::{Category, Feed, FeedType, Link, Person, Text};
use std::fmt::Write as _;

fn esc(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'\\' => o.push_str("\\\\"),
            b'\n' => o.push_str("\\n"),
            b'\r' => o.push_str("\\r"),
            b'\t' => o.push_str("\\t"),
            0..=0x1f | 0x7f => {
                let _ = write!(o, "\\x{:02x}", b);
            }
            _ => unsafe { o.as_mut_vec().push(b) },
        }
    }
    o
}
fn opt(o: &Option<String>) -> String {
    o.as_deref().map(esc).unwrap_or_else(|| "-".into())
}
fn put(out: &mut String, k: &str, v: &str) {
    out.push_str(k);
    out.push('\t');
    out.push_str(v);
    out.push('\n');
}
fn ttype(mt: &str) -> &'static str {
    if mt.contains("xhtml") {
        "xhtml"
    } else if mt.contains("html") {
        "html"
    } else if mt == "text/plain" {
        "text"
    } else {
        "other"
    }
}
fn put_text(out: &mut String, k: &str, t: &Option<Text>) {
    match t {
        Some(t) => {
            put(out, k, &esc(&t.content));
            put(out, &format!("{k}.t"), ttype(&t.content_type.to_string()));
        }
        None => put(out, k, "-"),
    }
}
fn put_links(out: &mut String, k: &str, ls: &[Link]) {
    put(out, &format!("{k}.n"), &ls.len().to_string());
    for (i, l) in ls.iter().enumerate() {
        let len = l.length.map(|v| v.to_string()).unwrap_or_else(|| "-".into());
        put(out, &format!("{k}.{i}"), &format!("{}|{}|{}|{}", esc(&l.href), opt(&l.rel), opt(&l.media_type), len));
    }
}
fn put_people(out: &mut String, k: &str, ps: &[Person]) {
    put(out, &format!("{k}.n"), &ps.len().to_string());
    for (i, p) in ps.iter().enumerate() {
        put(out, &format!("{k}.{i}"), &format!("{}|{}|{}", esc(&p.name), opt(&p.email), opt(&p.uri)));
    }
}
fn put_cats(out: &mut String, k: &str, cs: &[Category]) {
    put(out, &format!("{k}.n"), &cs.len().to_string());
    for (i, c) in cs.iter().enumerate() {
        put(out, &format!("{k}.{i}"), &format!("{}|{}|{}", esc(&c.term), opt(&c.scheme), opt(&c.label)));
    }
}
fn ts(t: &Option<chrono::DateTime<chrono::Utc>>) -> String {
    t.map(|t| t.timestamp().to_string()).unwrap_or_else(|| "-".into())
}
fn dump(out: &mut String, f: &Feed) {
    let fmt = match f.feed_type {
        FeedType::Atom => "atom",
        FeedType::JSON => "json_feed",
        FeedType::RSS0 | FeedType::RSS2 => "rss2",
        FeedType::RSS1 => "rss1",
    };
    put(out, "fmt", fmt);
    put(out, "feed.id", &esc(&f.id));
    put_text(out, "feed.title", &f.title);
    put_text(out, "feed.desc", &f.description);
    put_text(out, "feed.rights", &f.rights);
    put_links(out, "feed.link", &f.links);
    put_people(out, "feed.author", &f.authors);
    put_people(out, "feed.contrib", &f.contributors);
    put_cats(out, "feed.cat", &f.categories);
    put(out, "feed.logo", &f.logo.as_ref().map(|i| esc(&i.uri)).unwrap_or_else(|| "-".into()));
    put(out, "feed.icon", &f.icon.as_ref().map(|i| esc(&i.uri)).unwrap_or_else(|| "-".into()));
    put(out, "feed.lang", &opt(&f.language));
    put(out, "feed.updated", &ts(&f.updated));
    put(out, "feed.published", &ts(&f.published));
    put(out, "feed.gen", &f.generator.as_ref().map(|g| esc(&g.content)).unwrap_or_else(|| "-".into()));
    put(out, "feed.ttl", &f.ttl.map(|t| t.to_string()).unwrap_or_else(|| "-".into()));
    put(out, "n", &f.entries.len().to_string());
    for (i, e) in f.entries.iter().enumerate() {
        let p = format!("e{i}");
        put(out, &format!("{p}.id"), &esc(&e.id));
        put_text(out, &format!("{p}.title"), &e.title);
        put_text(out, &format!("{p}.summary"), &e.summary);
        match &e.content {
            Some(c) => {
                put(out, &format!("{p}.content"), &c.body.as_deref().map(esc).unwrap_or_else(|| "".into()));
                put(out, &format!("{p}.content.t"), ttype(&c.content_type.to_string()));
                if let Some(s) = &c.src {
                    put(out, &format!("{p}.content.src"), &esc(&s.href));
                }
            }
            None => put(out, &format!("{p}.content"), "-"),
        }
        put_text(out, &format!("{p}.rights"), &e.rights);
        put(out, &format!("{p}.published"), &ts(&e.published));
        put(out, &format!("{p}.updated"), &ts(&e.updated));
        put_links(out, &format!("{p}.link"), &e.links);
        put_people(out, &format!("{p}.author"), &e.authors);
        put_cats(out, &format!("{p}.cat"), &e.categories);
        put(out, &format!("{p}.source"), &opt(&e.source));
        put(out, &format!("{p}.media.n"), &e.media.len().to_string());
        let mut k = 0;
        for m in &e.media {
            for c in &m.content {
                let url = c.url.as_ref().map(|u| esc(u.as_str())).unwrap_or_else(|| "-".into());
                let size = c.size.map(|v| v.to_string()).unwrap_or_else(|| "-".into());
                put(out, &format!("{p}.mc.{k}"), &format!("{url}|{size}"));
                k += 1;
            }
        }
        let dur = e.media.iter().find_map(|m| m.duration).map(|d| d.as_secs().to_string()).unwrap_or_else(|| "-".into());
        put(out, &format!("{p}.itunes.duration"), &dur);
    }
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() >= 4 && args[1] == "bench" {
        // In-process loop, mirrors `feed_audit_probe bench`: parse `iters` times, print the same digest.
        let data = std::fs::read(&args[2]).expect("read corpus");
        let iters: usize = args[3].parse().expect("iters");
        let (mut entries, mut tbytes) = (0usize, 0usize);
        for _ in 0..iters {
            let f = feed_rs::parser::parse(&data[..]).unwrap_or_else(|_| {
                println!("parse error");
                std::process::exit(3)
            });
            entries += f.entries.len();
            tbytes += f.entries.iter().map(|e| e.title.as_ref().map_or(0, |t| t.content.len())).sum::<usize>();
        }
        println!("iters={iters} entries={entries} title_bytes={tbytes}");
        return;
    }
    if args.len() < 3 || args[1] != "batch" {
        eprintln!("usage: rt_feed_oracle batch <requests.tsv> | bench <file> <iters>");
        std::process::exit(2);
    }
    let data = std::fs::read_to_string(&args[2]).expect("read requests");
    let mut out = String::new();
    for line in data.lines() {
        let mut it = line.splitn(3, '\t');
        let (id, _op, hex) = (it.next().unwrap(), it.next().unwrap_or(""), it.next().unwrap_or(""));
        let input = unhex(hex);
        out.push_str(&format!("@@ {id}\n"));
        match feed_rs::parser::parse(&input[..]) {
            Ok(f) => dump(&mut out, &f),
            Err(e) => {
                let kind = match e {
                    feed_rs::parser::ParseFeedError::ParseError(_) => "ParseError",
                    feed_rs::parser::ParseFeedError::IoError(_) => "IoError",
                    feed_rs::parser::ParseFeedError::JsonSerde(_) => "JsonError",
                    feed_rs::parser::ParseFeedError::JsonUnsupportedVersion(_) => "UnknownFormat",
                    feed_rs::parser::ParseFeedError::XmlReader(_) => "XmlError",
                };
                put(&mut out, "err", kind);
            }
        }
        out.push_str("@@ end\n");
    }
    print!("{out}");
}
