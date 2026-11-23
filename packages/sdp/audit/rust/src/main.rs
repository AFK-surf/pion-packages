//! Differential oracle for packages/sdp: reads `name<TAB>hex` lines and prints, per case,
//! `name<TAB>W:<webrtc-rs verdict><TAB>M:<mozilla webrtc-sdp verdict>`.
use std::io::{BufRead, Cursor};

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap_or(0))
        .collect()
}

fn webrtc_rs(bytes: &[u8]) -> String {
    let parse = |b: &[u8]| sdp::SessionDescription::unmarshal(&mut Cursor::new(b.to_vec()));
    match parse(bytes) {
        Err(e) => format!("ERR {}", e.to_string().split_whitespace().take(4).collect::<Vec<_>>().join("_")),
        Ok(d) => {
            let ma: Vec<String> = d.media_descriptions.iter().map(|m| m.attributes.len().to_string()).collect();
            let s1 = d.marshal();
            let rt = match parse(s1.as_bytes()) {
                Err(_) => "rt=reparse_err".to_string(),
                Ok(d2) => if d2.marshal() == s1 { "rt=stable".into() } else { "rt=unstable".into() },
            };
            format!("OK m={} sa={} ma={} {}", d.media_descriptions.len(), d.attributes.len(), ma.join(","), rt)
        }
    }
}

fn sim_ids(v: &[webrtc_sdp::attribute_type::SdpAttributeSimulcastVersion]) -> String {
    v.iter()
        .map(|ver| ver.ids.iter().map(|i| format!("{}{}", if i.paused { "~" } else { "" }, i.id)).collect::<Vec<_>>().join(","))
        .collect::<Vec<_>>()
        .join(";")
}

fn mozilla(bytes: &[u8]) -> String {
    use webrtc_sdp::attribute_type::SdpAttribute as A;
    let s = match std::str::from_utf8(bytes) {
        Ok(s) => s,
        Err(_) => return "ERR not_utf8".into(),
    };
    match webrtc_sdp::parse_sdp(s, false) {
        Err(e) => {
            let msg = format!("{}", e);
            format!("ERR {}", msg.split_whitespace().take(6).collect::<Vec<_>>().join("_"))
        }
        Ok(d) => {
            let mut out = format!("OK m={} warn={}", d.media.len(), d.warnings.len());
            let mut sess_fp = 0;
            for a in &d.attribute {
                if let A::Fingerprint(fp) = a { sess_fp = fp.fingerprint.len(); }
            }
            for m in &d.media {
                let (mut sim, mut ext, mut fp, mut cand) = (String::from("-"), vec![], sess_fp, 0);
                for a in m.get_attributes() {
                    match a {
                        A::Simulcast(s) => sim = format!("send:{}/recv:{}", sim_ids(&s.send), sim_ids(&s.receive)),
                        A::Extmap(e) => ext.push(e.id.to_string()),
                        A::Fingerprint(f) => fp = f.fingerprint.len(),
                        A::Candidate(_) => cand += 1,
                        _ => {}
                    }
                }
                out += &format!(" [fpB={} cand={} ext={} sim={}]", fp, cand, ext.join(","), sim);
            }
            out
        }
    }
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: oracle <corpus.tsv>");
    let f = std::io::BufReader::new(std::fs::File::open(path).expect("open"));
    for line in f.lines() {
        let line = line.expect("line");
        let Some((name, hex)) = line.split_once('\t') else { continue };
        let b = unhex(hex);
        let w = std::panic::catch_unwind(|| webrtc_rs(&b)).unwrap_or_else(|_| "PANIC".into());
        let m = std::panic::catch_unwind(|| mozilla(&b)).unwrap_or_else(|_| "PANIC".into());
        println!("{}\tW:{}\tM:{}", name, w, m);
    }
}
