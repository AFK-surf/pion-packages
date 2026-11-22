use quick_xml::events::{BytesDecl, BytesEnd, BytesStart, BytesText, Event};
use quick_xml::Writer;
use std::io::Cursor;

fn main() {
    let rounds = 5usize;
    let items = 3000usize;
    let mut total_bytes: i64 = 0;
    let mut hash: i64 = 0;
    let mut sample = String::new();

    for r in 0..rounds {
        let mut writer = Writer::new(Cursor::new(Vec::with_capacity(1024 * 1024)));
        writer
            .write_event(Event::Decl(BytesDecl::new("1.0", Some("UTF-8"), None)))
            .unwrap();
        let mut root = BytesStart::new("catalog");
        root.push_attribute(("xmlns", "urn:pion:catalog"));
        root.push_attribute(("version", "1.0"));
        writer.write_event(Event::Start(root)).unwrap();

        for i in 0..items {
            let id_s = i.to_string();
            let title = format!("Item <{}> \"quoted\"", id_s);
            let mut item = BytesStart::new("item");
            item.push_attribute(("id", id_s.as_str()));
            item.push_attribute(("category", "books & media"));
            item.push_attribute(("title", title.as_str()));
            writer.write_event(Event::Start(item)).unwrap();

            writer
                .write_event(Event::Start(BytesStart::new("summary")))
                .unwrap();
            let text = format!(
                "Fast pure-Pion XML writer & serializer for record #{} <ok>",
                id_s
            );
            writer
                .write_event(Event::Text(BytesText::new(&text)))
                .unwrap();
            writer
                .write_event(Event::End(BytesEnd::new("summary")))
                .unwrap();

            let mut meta = BytesStart::new("meta");
            meta.push_attribute(("rank", id_s.as_str()));
            meta.push_attribute(("active", "true"));
            writer.write_event(Event::Empty(meta)).unwrap();

            let comment = format!(" end item {} ", id_s);
            writer
                .write_event(Event::Comment(BytesText::from_escaped(&comment)))
                .unwrap();

            writer
                .write_event(Event::End(BytesEnd::new("item")))
                .unwrap();
        }
        writer
            .write_event(Event::End(BytesEnd::new("catalog")))
            .unwrap();

        let bytes = writer.into_inner().into_inner();
        total_bytes += bytes.len() as i64;
        if r == 0 {
            sample = String::from_utf8_lossy(&bytes[..160]).into_owned();
        }
        for &b in &bytes {
            hash = (hash * 131 + b as i64) % 1_000_000_007;
        }
    }

    println!("rounds={}", rounds);
    println!("total_bytes={}", total_bytes);
    println!("hash={}", hash);
    println!("sample={}", sample);
}
