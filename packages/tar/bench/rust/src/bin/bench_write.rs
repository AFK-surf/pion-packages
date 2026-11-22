use std::io::{Cursor, Read};
use tar::{Archive, Builder, EntryType, Header};

struct BenchEntry {
    kind: u8, // 0=ustar reg, 1=dir, 2=symlink, 3=pax, 4=gnu
    name: String,
    linkname: String,
    uid: u64,
    gid: u64,
    uname: String,
    gname: String,
    mode: u32,
    mtime: u64,
    data: Vec<u8>,
}

fn make_payload(idx: usize, size: usize) -> Vec<u8> {
    let mut out = vec![0u8; size];
    let mut s = (idx * 31 + 17) & 0xFF;
    for b in out.iter_mut() {
        *b = s as u8;
        s = (s * 73 + 19) & 0xFF;
    }
    out
}

fn build_entries(count: usize) -> Vec<BenchEntry> {
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let m = i % 20;
        if m < 12 {
            if m == 11 {
                out.push(BenchEntry {
                    kind: 1,
                    name: format!("pkg/mod_{}/dir_{}/", i / 20, i),
                    linkname: String::new(),
                    uid: 1000,
                    gid: 1000,
                    uname: "builder".to_string(),
                    gname: "staff".to_string(),
                    mode: 0o755,
                    mtime: 1700000000 + i as u64,
                    data: Vec::new(),
                });
            } else if m == 10 {
                out.push(BenchEntry {
                    kind: 2,
                    name: format!("pkg/mod_{}/link_{}", i / 20, i),
                    linkname: format!("file_{}.dat", i - 1),
                    uid: 1000,
                    gid: 1000,
                    uname: "builder".to_string(),
                    gname: "staff".to_string(),
                    mode: 0o777,
                    mtime: 1700000000 + i as u64,
                    data: Vec::new(),
                });
            } else {
                let sz = 256 + ((i * 397) % 3072);
                out.push(BenchEntry {
                    kind: 0,
                    name: format!("pkg/mod_{}/src/file_{}.dat", i / 20, i),
                    linkname: String::new(),
                    uid: 1000,
                    gid: 1000,
                    uname: "builder".to_string(),
                    gname: "staff".to_string(),
                    mode: 0o644,
                    mtime: 1700000000 + i as u64,
                    data: make_payload(i, sz),
                });
            }
        } else if m < 17 {
            let sz = 512 + ((i * 613) % 4096);
            let long_name = format!(
                "workspace/services/telemetry_cluster_v4/shards/region_ap_northeast_1/partition_{}/sub_component_alpha_beta_gamma/artifact_item_{}.bin",
                i / 10,
                i
            );
            out.push(BenchEntry {
                kind: 3,
                name: long_name,
                linkname: String::new(),
                uid: 2500000 + i as u64,
                gid: 1000,
                uname: "pax_user".to_string(),
                gname: "pax_group".to_string(),
                mode: 0o644,
                mtime: 1700000000 + i as u64,
                data: make_payload(i, sz),
            });
        } else {
            let sz = 512 + ((i * 521) % 3584);
            let gnu_name = format!(
                "gnu_archive/deep_hierarchy/segment_0001/segment_0002/segment_0003/segment_0004/segment_0005/long_gnu_entry_{}.blob",
                i
            );
            out.push(BenchEntry {
                kind: 4,
                name: gnu_name,
                linkname: String::new(),
                uid: 1000,
                gid: 1000,
                uname: "gnu_user".to_string(),
                gname: "gnu_group".to_string(),
                mode: 0o644,
                mtime: 1700000000 + i as u64,
                data: make_payload(i, sz),
            });
        }
    }
    out
}

fn main() {
    let count = 2000usize;
    let rounds = 20usize;
    let entries = build_entries(count);
    let mut total_archive_bytes: i64 = 0;
    let mut last_archive: Vec<u8> = Vec::new();

    for _ in 0..rounds {
        let mut builder = Builder::new(Vec::with_capacity(6 * 1024 * 1024));
        for e in &entries {
            match e.kind {
                1 => {
                    let mut h = Header::new_ustar();
                    h.set_entry_type(EntryType::Directory);
                    h.set_size(0);
                    h.set_mode(e.mode);
                    h.set_uid(e.uid);
                    h.set_gid(e.gid);
                    h.set_username(&e.uname).unwrap();
                    h.set_groupname(&e.gname).unwrap();
                    h.set_mtime(e.mtime);
                    builder.append_data(&mut h, &e.name, &[][..]).unwrap();
                }
                2 => {
                    let mut h = Header::new_ustar();
                    h.set_entry_type(EntryType::Symlink);
                    h.set_size(0);
                    h.set_mode(e.mode);
                    h.set_uid(e.uid);
                    h.set_gid(e.gid);
                    h.set_username(&e.uname).unwrap();
                    h.set_groupname(&e.gname).unwrap();
                    h.set_mtime(e.mtime);
                    builder.append_link(&mut h, &e.name, &e.linkname).unwrap();
                }
                0 => {
                    let mut h = Header::new_ustar();
                    h.set_entry_type(EntryType::Regular);
                    h.set_size(e.data.len() as u64);
                    h.set_mode(e.mode);
                    h.set_uid(e.uid);
                    h.set_gid(e.gid);
                    h.set_username(&e.uname).unwrap();
                    h.set_groupname(&e.gname).unwrap();
                    h.set_mtime(e.mtime);
                    builder.append_data(&mut h, &e.name, e.data.as_slice()).unwrap();
                }
                _ => {
                    let mut h = Header::new_gnu();
                    h.set_entry_type(EntryType::Regular);
                    h.set_size(e.data.len() as u64);
                    h.set_mode(e.mode);
                    h.set_uid(e.uid);
                    h.set_gid(e.gid);
                    h.set_username(&e.uname).unwrap();
                    h.set_groupname(&e.gname).unwrap();
                    h.set_mtime(e.mtime);
                    builder.append_data(&mut h, &e.name, e.data.as_slice()).unwrap();
                }
            }
        }
        let out = builder.into_inner().unwrap();
        total_archive_bytes += out.len() as i64;
        last_archive = out;
    }

    // Verify encoded archive once
    let mut ar = Archive::new(Cursor::new(last_archive.as_slice()));
    let mut verified_entries: i64 = 0;
    let mut verified_payload: i64 = 0;
    let mut checksum: u64 = 14695981039346656037;
    let mut buf = Vec::new();
    for entry_res in ar.entries().unwrap() {
        let mut entry = entry_res.unwrap();
        verified_entries += 1;
        for &c in entry.path_bytes().as_ref() {
            checksum = (checksum ^ (c as u64)).wrapping_mul(1099511628211);
        }
        let sz = entry.header().size().unwrap();
        if sz > 0 {
            buf.clear();
            entry.read_to_end(&mut buf).unwrap();
            verified_payload += buf.len() as i64;
            checksum = (checksum ^ (buf[0] as u64)).wrapping_mul(1099511628211);
            checksum = (checksum ^ (buf[buf.len() - 1] as u64)).wrapping_mul(1099511628211);
        }
    }

    let block_aligned = if total_archive_bytes % 512 == 0 { 1 } else { 0 };
    println!("rounds={}", rounds);
    println!("entries={}", verified_entries);
    println!("payload_bytes={}", verified_payload);
    println!("block_aligned={}", block_aligned);
    println!("checksum={}", checksum);
}
