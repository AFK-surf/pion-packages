use quick_xml::events::Event;
use quick_xml::reader::Reader;
use quick_xml::XmlVersion;
use std::env;
use std::fs;

fn main() {
    let path = env::args()
        .nth(1)
        .unwrap_or_else(|| "/tmp/pion-xml-bench/mixed_corpus.xml".to_string());
    let src = fs::read_to_string(&path).expect("failed to read input");

    let rounds = 10usize;
    let mut starts: i64 = 0;
    let mut empties: i64 = 0;
    let mut ends: i64 = 0;
    let mut texts: i64 = 0;
    let mut cdatas: i64 = 0;
    let mut comments: i64 = 0;
    let mut pis: i64 = 0;
    let mut decls: i64 = 0;
    let mut attrs: i64 = 0;
    let mut name_bytes: i64 = 0;
    let mut text_bytes: i64 = 0;

    for _ in 0..rounds {
        let mut reader = Reader::from_str(&src);
        let mut in_text = false;
        loop {
            match reader.read_event() {
                Ok(Event::Start(e)) => {
                    in_text = false;
                    starts += 1;
                    name_bytes += e.name().as_ref().len() as i64;
                    for a in e.attributes() {
                        let a = a.expect("attr error");
                        let _ = a.normalized_value(XmlVersion::Implicit1_0).expect("attr unescape");
                        attrs += 1;
                    }
                }
                Ok(Event::Empty(e)) => {
                    in_text = false;
                    empties += 1;
                    name_bytes += e.name().as_ref().len() as i64;
                    for a in e.attributes() {
                        let a = a.expect("attr error");
                        let _ = a.normalized_value(XmlVersion::Implicit1_0).expect("attr unescape");
                        attrs += 1;
                    }
                }
                Ok(Event::End(e)) => {
                    in_text = false;
                    ends += 1;
                    name_bytes += e.name().as_ref().len() as i64;
                }
                Ok(Event::Text(e)) => {
                    if !in_text {
                        texts += 1;
                        in_text = true;
                    }
                    let raw = e.xml_content(XmlVersion::Implicit1_0);
                    text_bytes += raw.len() as i64;
                }
                Ok(Event::GeneralRef(e)) => {
                    if !in_text {
                        texts += 1;
                        in_text = true;
                    }
                    if let Ok(Some(ch)) = e.resolve_char_ref() {
                        text_bytes += ch.len_utf8() as i64;
                    } else if let Some(s) = quick_xml::escape::resolve_xml_entity(e.as_ref()) {
                        text_bytes += s.len() as i64;
                    }
                }
                Ok(Event::CData(e)) => {
                    in_text = false;
                    cdatas += 1;
                    text_bytes += e.as_ref().len() as i64;
                }
                Ok(Event::Comment(_)) => {
                    in_text = false;
                    comments += 1;
                }
                Ok(Event::PI(_)) => {
                    in_text = false;
                    pis += 1;
                }
                Ok(Event::Decl(_)) => {
                    in_text = false;
                    decls += 1;
                }
                Ok(Event::DocType(_)) => {
                    in_text = false;
                }
                Ok(Event::Eof) => break,
                Err(e) => panic!("quick-xml error: {:?}", e),
            }
        }
    }

    println!("rounds={}", rounds);
    println!("starts={}", starts);
    println!("empties={}", empties);
    println!("ends={}", ends);
    println!("texts={}", texts);
    println!("cdatas={}", cdatas);
    println!("comments={}", comments);
    println!("pis={}", pis);
    println!("decls={}", decls);
    println!("attrs={}", attrs);
    println!("name_bytes={}", name_bytes);
    println!("text_bytes={}", text_bytes);
}
