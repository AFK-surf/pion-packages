//! Rust `unicode-bidi =0.3.18` oracle with the exact same length-framed I/O and dump format as
//! `audit/probe` (see its header). Panics are caught per record and dumped as `PANIC <msg>`.
use std::{env, fs, panic};
use unicode_bidi::{
    get_base_direction, get_base_direction_full, BidiClass, BidiClass::*, BidiDataSource, BidiInfo,
    HardcodedBidiData, Level, Paragraph,
};

fn tag(c: BidiClass) -> u8 {
    match c {
        AL => 0, AN => 1, B => 2, BN => 3, CS => 4, EN => 5, ES => 6, ET => 7, FSI => 8, L => 9,
        LRE => 10, LRI => 11, LRO => 12, NSM => 13, ON => 14, PDF => 15, PDI => 16, R => 17,
        RLE => 18, RLI => 19, RLO => 20, S => 21, WS => 22,
    }
}

fn read_records(b: &[u8]) -> Vec<Vec<u8>> {
    let mut out = vec![];
    let mut i = 0;
    while i < b.len() {
        let j = i + b[i..].iter().position(|&c| c == b'\n').unwrap();
        let n: usize = std::str::from_utf8(&b[i..j]).unwrap().parse().unwrap();
        out.push(b[j + 1..j + 1 + n].to_vec());
        i = j + 1 + n;
    }
    out
}

fn lv(v: &[Level]) -> String {
    v.iter().map(|l| l.number().to_string()).collect::<Vec<_>>().join(",")
}

fn dump(text: &str, def: Option<Level>) -> Vec<u8> {
    let info = BidiInfo::new(text, def);
    let mut s: Vec<u8> = vec![];
    s.extend(format!(
        "base={:?} full={:?} has_rtl={}\nC ",
        get_base_direction(text),
        get_base_direction_full(text),
        info.has_rtl() as u8
    )
    .bytes());
    s.extend(info.original_classes.iter().map(|&c| b'A' + tag(c)));
    s.extend(format!("\nV {}\n", lv(&info.levels)).bytes());
    for para in &info.paragraphs {
        let (ps, pe) = (para.range.start, para.range.end);
        s.extend(
            format!(
                "P {} {} {} dir={:?}\n",
                ps,
                pe,
                para.level.number(),
                Paragraph::new(&info, para).direction()
            )
            .bytes(),
        );
        let mut lines = vec![ps..pe];
        let mut mid = (ps + pe) / 2;
        while mid < pe && !text.is_char_boundary(mid) {
            mid += 1;
        }
        if mid > ps && mid < pe {
            lines.push(ps..mid);
            lines.push(mid..pe);
        }
        for line in lines {
            let (l1, runs) = info.visual_runs(para, line.clone());
            s.extend(format!(" line {}-{}\n  L1 {}\n  runs", line.start, line.end, lv(&l1)).bytes());
            for r in &runs {
                s.extend(format!(" {}..{}", r.start, r.end).bytes());
            }
            let pc = info.reordered_levels_per_char(para, line.clone());
            let out = info.reorder_line(para, line.clone());
            s.extend(format!("\n  pc {}\n  out {}:", lv(&pc), out.len()).bytes());
            s.extend(out.as_bytes());
            s.push(b'\n');
        }
    }
    s
}

fn pcl(text: &str, def: Option<Level>) -> Vec<u8> {
    let info = BidiInfo::new(text, def);
    let mut s = String::new();
    if let Some(p) = info.paragraphs.first() {
        s += &p.level.number().to_string();
    }
    s.push(';');
    let mut v = vec![];
    for para in &info.paragraphs {
        let lv = info.reordered_levels(para, para.range.clone());
        for i in para.range.clone() {
            if text.is_char_boundary(i) {
                v.push(lv[i].number().to_string());
            }
        }
    }
    s += &v.join(",");
    s.into_bytes()
}

fn main() {
    panic::set_hook(Box::new(|_| {}));
    let args: Vec<String> = env::args().collect();
    let mode = args[1].as_str();
    let mut out: Vec<u8> = vec![];
    match mode {
        "cls" => {
            for cp in 0..=0x10FFFFu32 {
                if let Some(c) = char::from_u32(cp) {
                    out.push(b'A' + tag(unicode_bidi::bidi_class(c)));
                }
            }
        }
        "tab" => {
            for cp in 0..=0x10FFFFu32 {
                if let Some(c) = char::from_u32(cp) {
                    if let Some(m) = HardcodedBidiData.bidi_matched_opening_bracket(c) {
                        let o = if m.is_open { "o" } else { "c" };
                        out.extend(format!("B {} {} {}\n", cp, o, m.opening as u32).bytes());
                    }
                    if let Some(m) = unicode_bidi_mirroring::get_mirrored(c) {
                        out.extend(format!("M {} {}\n", cp, m as u32).bytes());
                    }
                }
            }
        }
        "one" => {
            let src = fs::read_to_string(&args[2]).unwrap();
            let reps: usize = args.get(4).map(|s| s.parse().unwrap()).unwrap_or(1);
            let mut total = 0usize;
            for _ in 0..reps {
                let info = BidiInfo::new(&src, None);
                total += info.levels.len();
                for para in &info.paragraphs {
                    match args[3].as_str() {
                        "lines" => {
                            let (_, runs) = info.visual_runs(para, para.range.clone());
                            total += runs.len();
                            total += info.reorder_line(para, para.range.clone()).len();
                        }
                        "l1" => total += info.reordered_levels(para, para.range.clone()).len(),
                        _ => {}
                    }
                }
            }
            println!("ok {}", total);
            return;
        }
        _ => {
            let b = fs::read(&args[2]).unwrap();
            for rec in read_records(&b) {
                let (d, t) = if rec.is_empty() { (b'-', &rec[..]) } else { (rec[0], &rec[1..]) };
                let def = match d {
                    b'0' => Some(Level::ltr()),
                    b'1' => Some(Level::rtl()),
                    _ => None,
                };
                let text = String::from_utf8(t.to_vec()).expect("oracle needs valid UTF-8");
                let r = panic::catch_unwind(|| if mode == "pcl" { pcl(&text, def) } else { dump(&text, def) });
                let body = match r {
                    Ok(v) => v,
                    Err(e) => {
                        let m = e
                            .downcast_ref::<String>()
                            .cloned()
                            .or_else(|| e.downcast_ref::<&str>().map(|s| s.to_string()))
                            .unwrap_or_default();
                        format!("PANIC {}", m).into_bytes()
                    }
                };
                out.extend(format!("{}\n", body.len()).bytes());
                out.extend(body);
            }
        }
    }
    fs::write(&args[3], out).unwrap();
}
