//! Oracle for packages/dash/audit: Rust `dash-mpd-core` =0.1.0 (the MPD parser crate of `dash-mpd` 0.21).
//! Reads `<name>\t<hex>` lines, prints `=<name>` then either `ERR|<message>`, `PANIC|<message>` or the shared
//! field subset in the format of compare.py `subset_from_model_dump` (esc() identical to src/dump.pion).
use std::env;
use std::fs;
use std::panic;
use std::time::Duration;

fn esc(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for &c in s.as_bytes() {
        if c > 32 && c < 127 && c != 37 && c != 124 && c != 92 && c != 34 && c != 44 {
            o.push(c as char);
        } else {
            o.push_str(&format!("%{:02X}", c));
        }
    }
    o
}
fn os(v: &Option<String>) -> String {
    match v {
        Some(s) => format!("\"{}", esc(s)),
        None => "-".into(),
    }
}
fn ou(v: &Option<u64>) -> String {
    v.map(|x| x.to_string()).unwrap_or_else(|| "-".into())
}
fn od(v: &Option<Duration>) -> String {
    v.map(|d| d.as_micros().to_string()).unwrap_or_else(|| "-".into())
}
fn cps(o: &mut String, v: &[dash_mpd_core::ContentProtection]) {
    for c in v {
        o.push_str(&format!(
            "CP|\"{}|{}|{}|{}\n",
            esc(&c.schemeIdUri),
            os(&c.value),
            os(&c.default_KID),
            c.cenc_pssh.len()
        ));
    }
}
fn tl(o: &mut String, t: &Option<dash_mpd_core::SegmentTemplate>) {
    if let Some(t) = t {
        if let Some(tl) = &t.SegmentTimeline {
            for s in &tl.segments {
                o.push_str(&format!("S|{}|{}|{}\n", ou(&s.t), s.d, s.r.unwrap_or(0)));
            }
        }
    }
}
fn dump(doc: &str) -> String {
    match dash_mpd_core::parse(doc) {
        Err(e) => format!("ERR|{}\n", esc(&e.to_string())),
        Ok(m) => {
            let mut o = format!(
                "MPD|{}|{}|{}|{}|{}\n",
                os(&m.id),
                m.mpdtype.as_deref().unwrap_or("static"),
                od(&m.mediaPresentationDuration),
                od(&m.minBufferTime),
                od(&m.minimumUpdatePeriod)
            );
            for p in &m.periods {
                o.push_str(&format!("P|{}|{}|{}\n", os(&p.id), od(&p.start), od(&p.duration)));
                tl(&mut o, &p.SegmentTemplate);
                for a in &p.adaptations {
                    o.push_str(&format!("A|{}|{}|{}|{}\n", os(&a.id), os(&a.mimeType), os(&a.codecs), os(&a.lang)));
                    cps(&mut o, &a.ContentProtection);
                    tl(&mut o, &a.SegmentTemplate);
                    for r in &a.representations {
                        o.push_str(&format!(
                            "R|{}|{}|{}|{}|{}\n",
                            match &r.id {
                                Some(s) => format!("\"{}", esc(s)),
                                None => "\"".into(),
                            },
                            r.bandwidth.map(|b| b.to_string()).unwrap_or_else(|| "-".into()),
                            ou(&r.width),
                            ou(&r.height),
                            os(&r.codecs)
                        ));
                        cps(&mut o, &r.ContentProtection);
                        tl(&mut o, &r.SegmentTemplate);
                    }
                }
            }
            o
        }
    }
}
fn unhex(h: &str) -> Vec<u8> {
    (0..h.len() / 2).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap()).collect()
}
fn main() {
    let path = env::args().nth(1).expect("usage: dash_audit_oracle <cases>");
    let text = fs::read_to_string(&path).expect("read");
    panic::set_hook(Box::new(|_| {}));
    let mut out = String::new();
    for line in text.lines() {
        let mut it = line.splitn(2, '\t');
        let name = it.next().unwrap();
        let bytes = unhex(it.next().unwrap_or(""));
        out.push_str(&format!("={}\n", name));
        match String::from_utf8(bytes) {
            Err(_) => out.push_str("ERR|invalid UTF-8 (input is not a Rust &str)\n"),
            Ok(doc) => match panic::catch_unwind(|| dump(&doc)) {
                Ok(s) => out.push_str(&s),
                Err(_) => out.push_str("PANIC|dash-mpd-core panicked\n"),
            },
        }
    }
    print!("{}", out);
}
