use std::env;
use std::fs;
use std::sync::atomic::AtomicBool;

use gix_features::hash::hasher;
use gix_features::zlib;
use gix_hash::Kind;
use gix_object::{Commit, CommitRef, Tree, TreeRef, WriteTo};

fn read_u32_be(b: &[u8], off: usize) -> usize {
    u32::from_be_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]]) as usize
}

fn fnv1a_update(mut h: u32, data: &[u8]) -> u32 {
    for &b in data {
        h = (h ^ (b as u32)).wrapping_mul(16777619);
    }
    h
}

fn oid_u32_xor(raw: &[u8]) -> u32 {
    let a = u32::from_be_bytes([raw[0], raw[1], raw[2], raw[3]]);
    let b = u32::from_be_bytes([raw[16], raw[17], raw[18], raw[19]]);
    a ^ b
}

fn hash_git_object(kind: gix_object::Kind, payload: &[u8]) -> [u8; 20] {
    let mut h = hasher(Kind::Sha1);
    h.update(kind.as_bytes());
    h.update(b" ");
    h.update(payload.len().to_string().as_bytes());
    h.update(b"\0");
    h.update(payload);
    let id = h.digest();
    let mut out = [0u8; 20];
    out.copy_from_slice(&id[..20]);
    out
}

fn run_w1(path: &str, iters: usize) {
    let mut total_objs: i64 = 0;
    let mut total_uncomp: i64 = 0;
    let mut xor_oid: u32 = 0;

    for _ in 0..iters {
        let pack = gix_pack::data::File::at(path, Kind::Sha1).expect("open pack");
        let cancel = AtomicBool::new(false);
        pack.verify_checksum(&mut gix_features::progress::Discard, &cancel)
            .expect("verify pack checksum");

        let mut inflate = zlib::Inflate::default();
        let mut out = Vec::with_capacity(65536);
        let mut cache = gix_pack::cache::lru::MemoryCappedHashmap::new(32 * 1024 * 1024);

        let num_objects = pack.num_objects();
        let mut offset: u64 = 12;
        for _ in 0..num_objects {
            let pack_entry = pack.entry(offset).expect("pack.entry");
            let data_offset = pack_entry.data_offset;
            out.clear();
            let outcome = pack
                .decode_entry(
                    pack_entry,
                    &mut out,
                    &mut inflate,
                    &|_, _| None,
                    &mut cache,
                )
                .expect("decode_entry");
            offset = data_offset + outcome.compressed_size as u64;
            let oid = hash_git_object(outcome.kind, &out);
            total_objs += 1;
            total_uncomp += out.len() as i64;
            xor_oid ^= oid_u32_xor(&oid);
        }
    }

    println!(
        "W1 objs={} uncomp={} xor={}",
        total_objs, total_uncomp, xor_oid
    );
}

fn run_w2(path: &str, iters: usize) {
    let data = fs::read(path).expect("read bundle");
    let mut total_trees: i64 = 0;
    let mut total_commits: i64 = 0;
    let mut total_reencoded: i64 = 0;
    let mut digest: u32 = 2166136261;
    let mut enc_buf: Vec<u8> = Vec::with_capacity(8192);

    for _ in 0..iters {
        let mut pos = 0usize;
        let num_trees = read_u32_be(&data, pos);
        pos += 4;
        for _ in 0..num_trees {
            let tlen = read_u32_be(&data, pos);
            pos += 4;
            let slice = &data[pos..pos + tlen];
            pos += tlen;
            let tref = TreeRef::from_bytes(slice).expect("tree parse");
            let mut tree: Tree = tref.into();
            tree.entries.sort();
            enc_buf.clear();
            tree.write_to(&mut enc_buf).expect("tree write");
            total_trees += 1;
            total_reencoded += enc_buf.len() as i64;
            digest = fnv1a_update(digest, &enc_buf);
        }
        let num_commits = read_u32_be(&data, pos);
        pos += 4;
        for _ in 0..num_commits {
            let clen = read_u32_be(&data, pos);
            pos += 4;
            let slice = &data[pos..pos + clen];
            pos += clen;
            let cref = CommitRef::from_bytes(slice).expect("commit parse");
            let commit: Commit = cref.into();
            enc_buf.clear();
            commit.write_to(&mut enc_buf).expect("commit write");
            total_commits += 1;
            total_reencoded += enc_buf.len() as i64;
            digest = fnv1a_update(digest, &enc_buf);
        }
    }

    println!(
        "W2 trees={} commits={} reencoded={} fnv1a={}",
        total_trees, total_commits, total_reencoded, digest
    );
}

fn run_w3(v2_path: &str, v4_path: &str, pkt_path: &str, iters: usize) {
    let v2_data = fs::read(v2_path).expect("read v2");
    let v4_data = fs::read(v4_path).expect("read v4");
    let pkt_data = fs::read(pkt_path).expect("read pkt");

    let mut total_v2: i64 = 0;
    let mut total_v4: i64 = 0;
    let mut total_pkts: i64 = 0;
    let mut total_path_bytes: i64 = 0;
    let mut total_pkt_bytes: i64 = 0;

    for _ in 0..iters {
        let (st2, _) = gix_index::State::from_bytes(
            &v2_data,
            filetime::FileTime::zero(),
            Kind::Sha1,
            gix_index::decode::Options::default(),
        )
        .expect("index v2");
        for e in st2.entries() {
            total_v2 += 1;
            total_path_bytes += e.path(&st2).len() as i64;
        }
        let (st4, _) = gix_index::State::from_bytes(
            &v4_data,
            filetime::FileTime::zero(),
            Kind::Sha1,
            gix_index::decode::Options::default(),
        )
        .expect("index v4");
        for e in st4.entries() {
            total_v4 += 1;
            total_path_bytes += e.path(&st4).len() as i64;
        }

        let mut pos = 0usize;
        while pos < pkt_data.len() {
            match gix_packetline::decode::streaming(&pkt_data[pos..]).expect("pkt decode") {
                gix_packetline::decode::Stream::Complete {
                    line,
                    bytes_consumed,
                } => {
                    total_pkts += 1;
                    if let gix_packetline::PacketLineRef::Data(d) = line {
                        total_pkt_bytes += d.len() as i64;
                    }
                    pos += bytes_consumed;
                }
                gix_packetline::decode::Stream::Incomplete { .. } => {
                    panic!("incomplete pkt-line");
                }
            }
        }
    }

    println!(
        "W3 v2={} v4={} pkts={} path_bytes={} pkt_bytes={}",
        total_v2, total_v4, total_pkts, total_path_bytes, total_pkt_bytes
    );
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: git_bench_rust <w1|w2|w3> ...");
        std::process::exit(1);
    }
    match args[1].as_str() {
        "w1" => run_w1(&args[2], args[3].parse().unwrap()),
        "w2" => run_w2(&args[2], args[3].parse().unwrap()),
        "w3" => run_w3(&args[2], &args[3], &args[4], args[5].parse().unwrap()),
        other => {
            eprintln!("unknown mode: {}", other);
            std::process::exit(1);
        }
    }
}
