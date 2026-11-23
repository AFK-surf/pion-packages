use scraper::{Html, Selector};
use std::env;
use std::fs;

fn main() {
    let path = env::args()
        .nth(1)
        .unwrap_or_else(|| "/private/tmp/pion-html-bench/mixed_pages.html".to_string());
    let src = fs::read_to_string(&path).expect("failed to read input");
    let doc = Html::parse_document(&src);

    let queries = [
        "main > section.articles article.post > h2.title a[href^=\"https://\"]",
        "ul.nav-list > li.item:nth-child(odd) > a",
        "table.metrics tbody tr > td[data-status=\"ok\" i]",
        "div.card:not(.archived) p.summary",
        "header h1, footer a[rel~=\"noopener\"]",
    ];
    let compiled: Vec<Selector> = queries
        .iter()
        .map(|q| Selector::parse(q).expect("valid selector"))
        .collect();

    let rounds = 50usize;
    let mut total_matches: i64 = 0;
    let mut tag_bytes: i64 = 0;

    for _ in 0..rounds {
        for sel in &compiled {
            for el in doc.select(sel) {
                total_matches += 1;
                tag_bytes += el.value().name().len() as i64;
            }
        }
    }

    println!("rounds={}", rounds);
    println!("queries={}", compiled.len());
    println!("matches={}", total_matches);
    println!("tag_bytes={}", tag_bytes);
}
