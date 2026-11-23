//! RT-git differential oracle backed by Rust `gix` (same batch format as `../src/main.pion`).
//! Usage: git_audit_gix <mode> <batch_file>
use std::env;
use std::fs;
use std::io::Write;
use std::sync::atomic::AtomicBool;

use gix_hash::Kind;
use gix_object::{bstr::ByteSlice, CommitRef, TagRef, TreeRef, WriteTo};

fn rd_u32(b: &[u8], off: usize) -> usize {
    u32::from_be_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]]) as usize
}

fn sha1_hex(b: &[u8]) -> String {
    sha1_smol::Sha1::from(b).digest().to_string()
}

fn obj_hash(kind: gix_object::Kind, payload: &[u8]) -> String {
    let mut h = sha1_smol::Sha1::new();
    h.update(kind.as_bytes());
    h.update(b" ");
    h.update(payload.len().to_string().as_bytes());
    h.update(b"\0");
    h.update(payload);
    h.digest().to_string()
}

fn inflate_all(input: &[u8]) -> Result<(Vec<u8>, usize), String> {
    let mut d = flate2::Decompress::new(true);
    let mut out = Vec::with_capacity(input.len() * 4 + 64);
    loop {
        if out.len() == out.capacity() {
            out.reserve(out.capacity().max(64));
        }
        if out.len() > 256 << 20 {
            return Err("too_large".into());
        }
        let consumed = d.total_in() as usize;
        let st = d
            .decompress_vec(&input[consumed..], &mut out, flate2::FlushDecompress::Finish)
            .map_err(|_| "zlib".to_string())?;
        match st {
            flate2::Status::StreamEnd => return Ok((out, d.total_in() as usize)),
            flate2::Status::Ok | flate2::Status::BufError => {
                if d.total_in() as usize >= input.len() && out.len() < out.capacity() {
                    return Err("zlib_truncated".into());
                }
            }
        }
    }
}

fn run_one(mode: &str, rec: &[u8], tmp: &str) -> String {
    match mode {
        "loose" => match inflate_all(rec) {
            Ok((raw, used)) => match gix_object::decode::loose_header(&raw) {
                Ok((kind, size, hlen)) => {
                    let payload = &raw[hlen..];
                    if size as usize != payload.len() {
                        return "ERR size_mismatch".into();
                    }
                    format!(
                        "OK {} {} {} trailing={}",
                        kind,
                        payload.len(),
                        obj_hash(kind, payload),
                        rec.len() - used
                    )
                }
                Err(_) => "ERR header".into(),
            },
            Err(e) => format!("ERR {}", e),
        },
        "tree" => match TreeRef::from_bytes(rec) {
            Ok(t) => {
                let n = t.entries.len();
                let owned: gix_object::Tree = t.into();
                let mut buf = Vec::new();
                let rt = match owned.write_to(&mut buf) {
                    Ok(_) => if buf == rec { "same" } else { "diff" },
                    Err(_) => "err",
                };
                format!("OK n={} rt={}", n, rt)
            }
            Err(_) => "ERR parse".into(),
        },
        "commit" => match CommitRef::from_bytes(rec) {
            Ok(c) => {
                let np = c.parents.len();
                let owned: gix_object::Commit = match c.try_into() {
                    Ok(o) => o,
                    Err(_) => return format!("OK parents={} rt=err", np),
                };
                let mut buf = Vec::new();
                let rt = match owned.write_to(&mut buf) {
                    Ok(_) => if buf == rec { "same" } else { "diff" },
                    Err(_) => "err",
                };
                format!("OK parents={} rt={}", np, rt)
            }
            Err(_) => "ERR parse".into(),
        },
        "tag" => match TagRef::from_bytes(rec) {
            Ok(t) => {
                let owned: gix_object::Tag = match t.try_into() {
                    Ok(o) => o,
                    Err(_) => return "OK rt=err".into(),
                };
                let mut buf = Vec::new();
                let rt = match owned.write_to(&mut buf) {
                    Ok(_) => if buf == rec { "same" } else { "diff" },
                    Err(_) => "err",
                };
                format!("OK rt={}", rt)
            }
            Err(_) => "ERR parse".into(),
        },
        "pack" => {
            let p = format!("{}/v.pack", tmp);
            fs::write(&p, rec).unwrap();
            let pack = match gix_pack::data::File::at(&p, Kind::Sha1) {
                Ok(f) => f,
                Err(_) => return "ERR open".into(),
            };
            let cancel = AtomicBool::new(false);
            if pack.verify_checksum(&mut gix_features::progress::Discard, &cancel).is_err() {
                return "ERR checksum".into();
            }
            let iter = match pack.streaming_iter() {
                Ok(i) => i,
                Err(_) => return "ERR iter".into(),
            };
            let mut inflate = gix_features::zlib::Inflate::default();
            let mut cache = gix_pack::cache::Never;
            let mut lines = Vec::new();
            let mut out = Vec::new();
            for e in iter {
                let e = match e {
                    Ok(e) => e,
                    Err(_) => return "ERR entry".into(),
                };
                let pe = pack.entry(e.pack_offset);
                let pe = match pe {
                    Ok(pe) => pe,
                    Err(_) => return "ERR entry".into(),
                };
                out.clear();
                match pack.decode_entry(pe, &mut out, &mut inflate, &|_, _| None, &mut cache) {
                    Ok(o) => lines.push(format!("{} {} {}", obj_hash(o.kind, &out), o.kind, out.len())),
                    Err(_) => return "ERR decode".into(),
                }
            }
            lines.sort();
            lines.dedup();
            let mut s = String::new();
            for l in &lines {
                s.push_str(l);
                s.push('\n');
            }
            format!("OK n={} h={}", lines.len(), sha1_hex(s.as_bytes()))
        }
        "idx" => {
            let p = format!("{}/v.idx", tmp);
            fs::write(&p, rec).unwrap();
            let ix = match gix_pack::index::File::at(&p, Kind::Sha1) {
                Ok(f) => f,
                Err(_) => return "ERR open".into(),
            };
            if ix.verify_checksum(&mut gix_features::progress::Discard, &AtomicBool::new(false)).is_err() {
                return "ERR checksum".into();
            }
            let mut s = String::new();
            let mut miss = 0;
            for e in ix.iter() {
                s.push_str(&format!("{} {}\n", e.oid, e.pack_offset));
                match ix.lookup(e.oid) {
                    Some(i) => {
                        if ix.pack_offset_at_index(i) != e.pack_offset {
                            miss += 1
                        }
                    }
                    None => miss += 1,
                }
            }
            format!("OK n={} lookup_miss={} h={}", ix.num_objects(), miss, sha1_hex(s.as_bytes()))
        }
        "index" => {
            let r = std::panic::catch_unwind(|| {
                gix_index::State::from_bytes(
                    rec,
                    filetime::FileTime::zero(),
                    Kind::Sha1,
                    gix_index::decode::Options::default(),
                )
            });
            match r {
                Ok(Ok((st, _))) => {
                    let mut s = String::new();
                    for e in st.entries() {
                        let stage = e.flags.stage() as u32;
                        s.push_str(&format!("{} {} {}\n", e.id, stage, hex(e.path(&st))));
                    }
                    format!("OK v={} n={} h={}", st.version() as u8, st.entries().len(), sha1_hex(s.as_bytes()))
                }
                Ok(Err(_)) => "ERR decode".into(),
                Err(_) => "PANIC".into(),
            }
        }
        "pkt" => {
            let mut pos = 0usize;
            let mut s = String::new();
            let mut n = 0;
            while pos < rec.len() {
                match gix_packetline::decode::streaming(&rec[pos..]) {
                    Ok(gix_packetline::decode::Stream::Complete { line, bytes_consumed }) => {
                        n += 1;
                        match line {
                            gix_packetline::PacketLineRef::Flush => s.push_str("F\n"),
                            gix_packetline::PacketLineRef::Delimiter => s.push_str("D\n"),
                            gix_packetline::PacketLineRef::ResponseEnd => s.push_str("R\n"),
                            gix_packetline::PacketLineRef::Data(d) => {
                                s.push('P');
                                s.push_str(&hex(d));
                                s.push('\n');
                            }
                        }
                        pos += bytes_consumed;
                    }
                    Ok(gix_packetline::decode::Stream::Incomplete { .. }) => return "ERR incomplete".into(),
                    Err(_) => return "ERR decode".into(),
                }
            }
            format!("OK n={} h={}", n, sha1_hex(s.as_bytes()))
        }
        "ref" => {
            let onelevel = rec[0] != 0;
            let name = rec[1..].as_bstr();
            let r = if onelevel {
                gix_validate::reference::name_partial(name).map(|_| ())
            } else {
                gix_validate::reference::name(name).map(|_| ())
            };
            match r {
                Ok(_) => "OK".into(),
                Err(_) => "ERR invalid".into(),
            }
        }
        _ => "ERR unsupported_mode".into(),
    }
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02x}", x)).collect()
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mode = &args[1];
    let data = fs::read(&args[2]).expect("read batch");
    let tmp = env::var("RT_GIT_TMP").unwrap_or_else(|_| "/tmp/rt-git-gix".into());
    fs::create_dir_all(&tmp).ok();
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    let mut pos = 0;
    let mut idx = 0;
    while pos + 4 <= data.len() {
        let len = rd_u32(&data, pos);
        let rec = &data[pos + 4..pos + 4 + len];
        pos += 4 + len;
        let r = std::panic::catch_unwind(|| run_one(mode, rec, &tmp)).unwrap_or_else(|_| "PANIC".into());
        writeln!(out, "{} {}", idx, r).unwrap();
        idx += 1;
    }
}
