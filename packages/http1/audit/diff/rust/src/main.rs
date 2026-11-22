//! Differential runner (Rust httparse 1.10.1 side). httparse does not compute body
//! framing, so request/response verdicts print `OK -`; chunked bodies are decoded
//! with `parse_chunk_size` + strict CRLF + `parse_headers` for the trailer section.
use std::fs;

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap())
        .collect()
}

fn chunked(raw: &[u8]) -> String {
    let mut pos = 0;
    let mut body = 0usize;
    loop {
        match httparse::parse_chunk_size(&raw[pos..]) {
            Ok(httparse::Status::Complete((c, sz))) => {
                pos += c;
                if sz == 0 {
                    let mut hs = [httparse::EMPTY_HEADER; 64];
                    return match httparse::parse_headers(&raw[pos..], &mut hs) {
                        Ok(httparse::Status::Complete(_)) => format!("OK {}\t", body),
                        Ok(httparse::Status::Partial) => "PARTIAL\t".into(),
                        Err(e) => format!("ERR\ttrailer: {:?}", e),
                    };
                }
                let n = sz as usize;
                if raw.len() < pos || raw.len() - pos < n + 2 {
                    return "PARTIAL\t".into();
                }
                if &raw[pos + n..pos + n + 2] != b"\r\n" {
                    return "ERR\tchunk data not followed by CRLF".into();
                }
                body += n;
                pos += n + 2;
            }
            Ok(httparse::Status::Partial) => return "PARTIAL\t".into(),
            Err(e) => return format!("ERR\t{:?}", e),
        }
    }
}

fn main() {
    let path = std::env::args().nth(1).expect("corpus");
    let data = fs::read_to_string(path).unwrap();
    for line in data.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        let raw = unhex(f[2]);
        let out = match f[1] {
            "req" => {
                let mut hs = [httparse::EMPTY_HEADER; 128];
                let mut r = httparse::Request::new(&mut hs);
                match r.parse(&raw) {
                    Ok(httparse::Status::Complete(_)) => "OK -\t".to_string(),
                    Ok(httparse::Status::Partial) => "PARTIAL\t".to_string(),
                    Err(e) => format!("ERR\t{:?}", e),
                }
            }
            "resp" => {
                let mut hs = [httparse::EMPTY_HEADER; 128];
                let mut r = httparse::Response::new(&mut hs);
                match r.parse(&raw) {
                    Ok(httparse::Status::Complete(_)) => "OK -\t".to_string(),
                    Ok(httparse::Status::Partial) => "PARTIAL\t".to_string(),
                    Err(e) => format!("ERR\t{:?}", e),
                }
            }
            _ => chunked(&raw),
        };
        println!("{}\t{}", f[0], out);
    }
}
