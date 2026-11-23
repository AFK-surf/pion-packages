use scraper::{Html, Node};
use std::env;
use std::fs;

fn main() {
    let path = env::args()
        .nth(1)
        .unwrap_or_else(|| "/private/tmp/pion-html-bench/mixed_pages.html".to_string());
    let src = fs::read_to_string(&path).expect("failed to read input");

    let rounds = 20usize;
    let mut elements: i64 = 0;
    let mut links: i64 = 0;
    let mut href_bytes: i64 = 0;
    let mut text_bytes: i64 = 0;

    for _ in 0..rounds {
        let doc = Html::parse_document(&src);
        for node in doc.tree.nodes() {
            match node.value() {
                Node::Element(el) => {
                    elements += 1;
                    if el.name() == "a" {
                        if let Some(h) = el.attr("href") {
                            links += 1;
                            href_bytes += h.len() as i64;
                        }
                    }
                }
                Node::Text(t) => {
                    text_bytes += t.text.len() as i64;
                }
                _ => {}
            }
        }
    }

    println!("rounds={}", rounds);
    println!("elements={}", elements);
    println!("links={}", links);
    println!("href_bytes={}", href_bytes);
    println!("text_bytes={}", text_bytes);
}
