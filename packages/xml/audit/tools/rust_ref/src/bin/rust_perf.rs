//! Rust side of the `packages/xml` red-team adversarial benchmarks (see tools/pion_perf).
//!
//! usage: rust_perf MODE FILE ROUNDS
//!   dom | dom_api   roxmltree 0.21.2 parse + public-API walk (roxmltree has only one API)
//!   dom_dtd         same with allow_dtd = true
//!   rd              quick-xml 0.42.0 Reader, text/attrs unescaped + EOL-normalised
use quick_xml::events::Event;
use quick_xml::XmlVersion;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let mode = a[1].as_str();
    let src = std::fs::read_to_string(&a[2]).expect("read input");
    let rounds: usize = a[3].parse().unwrap();
    let (mut elements, mut attrs, mut texts, mut text_bytes, mut attr_bytes) = (0i64, 0i64, 0i64, 0i64, 0i64);
    for _ in 0..rounds {
        if mode == "rd" {
            let mut r = quick_xml::Reader::from_str(&src);
            r.config_mut().check_end_names = true;
            let mut in_text = false;
            loop {
                match r.read_event() {
                    Ok(Event::Start(e)) | Ok(Event::Empty(e)) => {
                        in_text = false;
                        elements += 1;
                        for at in e.attributes() {
                            let at = at.expect("attr");
                            let k = at.key.as_ref();
                            if k == "xmlns" || k.starts_with("xmlns:") {
                                continue;
                            }
                            attrs += 1;
                            attr_bytes += at.normalized_value(XmlVersion::Implicit1_0).expect("attr value").len() as i64;
                        }
                    }
                    Ok(Event::Text(t)) => {
                        let s = t.xml_content(XmlVersion::Implicit1_0);
                        if !in_text && !s.is_empty() {
                            texts += 1;
                            in_text = true;
                        }
                        text_bytes += s.len() as i64;
                    }
                    Ok(Event::CData(t)) => {
                        let s = t.xml_content(XmlVersion::Implicit1_0);
                        if !in_text && !s.is_empty() {
                            texts += 1;
                            in_text = true;
                        }
                        text_bytes += s.len() as i64;
                    }
                    Ok(Event::GeneralRef(g)) => {
                        let n = if let Ok(Some(ch)) = g.resolve_char_ref() {
                            ch.len_utf8()
                        } else {
                            quick_xml::escape::resolve_xml_entity(&g).expect("entity").len()
                        };
                        if !in_text && n > 0 {
                            texts += 1;
                            in_text = true;
                        }
                        text_bytes += n as i64;
                    }
                    Ok(Event::Eof) => break,
                    Ok(Event::End(_)) | Ok(Event::Comment(_)) | Ok(Event::PI(_)) => in_text = false,
                    Ok(_) => {}
                    Err(e) => {
                        println!("error: {e}");
                        std::process::exit(1);
                    }
                }
            }
        } else {
            let opt = roxmltree::ParsingOptions { allow_dtd: mode == "dom_dtd", ..Default::default() };
            let doc = match roxmltree::Document::parse_with_options(&src, opt) {
                Ok(d) => d,
                Err(e) => {
                    println!("error: {e}");
                    std::process::exit(1);
                }
            };
            for n in doc.descendants() {
                if n.is_element() {
                    elements += 1;
                    for at in n.attributes() {
                        attrs += 1;
                        attr_bytes += at.value().len() as i64;
                    }
                } else if n.is_text() {
                    texts += 1;
                    text_bytes += n.text().map(|t| t.len()).unwrap_or(0) as i64;
                }
            }
        }
    }
    println!("rounds={rounds}");
    println!("elements={elements}");
    println!("attributes={attrs}");
    println!("text_nodes={texts}");
    println!("text_bytes={text_bytes}");
    println!("attr_val_bytes={attr_bytes}");
}
