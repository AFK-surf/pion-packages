use roxmltree::{Document, NodeType};
use std::env;
use std::fs;

fn main() {
    let path = env::args()
        .nth(1)
        .unwrap_or_else(|| "/tmp/pion-xml-bench/mixed_corpus.xml".to_string());
    let src = fs::read_to_string(&path).expect("failed to read input");

    let rounds = 10usize;
    let mut elements: i64 = 0;
    let mut text_nodes: i64 = 0;
    let mut comments: i64 = 0;
    let mut pis: i64 = 0;
    let mut attrs: i64 = 0;
    let mut ns_elems: i64 = 0;
    let mut tag_bytes: i64 = 0;
    let mut attr_val_bytes: i64 = 0;
    let mut text_bytes: i64 = 0;

    for _ in 0..rounds {
        let doc = Document::parse(&src).expect("roxmltree parse error");
        for node in doc.descendants() {
            match node.node_type() {
                NodeType::Element => {
                    elements += 1;
                    let tn = node.tag_name();
                    tag_bytes += tn.name().len() as i64;
                    if tn.namespace().is_some() {
                        ns_elems += 1;
                    }
                    for a in node.attributes() {
                        attrs += 1;
                        attr_val_bytes += a.value().len() as i64;
                    }
                }
                NodeType::Text => {
                    text_nodes += 1;
                    if let Some(t) = node.text() {
                        text_bytes += t.len() as i64;
                    }
                }
                NodeType::Comment => comments += 1,
                NodeType::PI => pis += 1,
                NodeType::Root => {}
            }
        }
    }

    println!("rounds={}", rounds);
    println!("elements={}", elements);
    println!("text_nodes={}", text_nodes);
    println!("comments={}", comments);
    println!("pis={}", pis);
    println!("attributes={}", attrs);
    println!("ns_elements={}", ns_elems);
    println!("tag_name_bytes={}", tag_bytes);
    println!("attr_val_bytes={}", attr_val_bytes);
    println!("text_bytes={}", text_bytes);
}
