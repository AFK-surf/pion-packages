use std::env;
use std::fs;
use std::process;

#[inline(always)]
fn mix(h: i64, v: i64) -> i64 {
    ((h * 131) + v) % 1_000_000_007
}

#[inline(always)]
fn hash_bytes(mut h: i64, b: &[u8]) -> i64 {
    h = mix(h, b.len() as i64);
    for &c in b {
        h = mix(h, c as i64);
    }
    h
}

fn hash_headers_vec(mut h: i64, hs: &[(Vec<u8>, Vec<u8>)]) -> i64 {
    h = mix(h, hs.len() as i64);
    for (n, v) in hs {
        h = hash_bytes(h, n);
        h = hash_bytes(h, v);
    }
    h
}

fn read_u16(b: &[u8], off: usize) -> usize {
    ((b[off] as usize) << 8) | (b[off + 1] as usize)
}

fn read_u32(b: &[u8], off: usize) -> usize {
    ((b[off] as usize) << 24)
        | ((b[off + 1] as usize) << 16)
        | ((b[off + 2] as usize) << 8)
        | (b[off + 3] as usize)
}

fn bench_hpack_decode(data: &[u8]) {
    let count = read_u32(data, 0);
    let mut blocks = Vec::with_capacity(count);
    let mut pos = 4;
    for _ in 0..count {
        let blen = read_u32(data, pos);
        pos += 4;
        blocks.push(&data[pos..pos + blen]);
        pos += blen;
    }

    let mut total_blocks: i64 = 0;
    let mut total_headers: i64 = 0;
    let mut checksum: i64 = 0;

    for _round in 0..100 {
        let mut dec = hpack_patched::Decoder::new();
        for &blk in &blocks {
            let hs = dec.decode(blk).unwrap_or_else(|e| {
                eprintln!("decode error: {:?}", e);
                process::exit(1);
            });
            total_blocks += 1;
            total_headers += hs.len() as i64;
            checksum = hash_headers_vec(checksum, &hs);
        }
    }

    println!("mode=hpack_decode");
    println!("blocks={}", total_blocks);
    println!("headers={}", total_headers);
    println!("checksum={}", checksum);
}

fn bench_hpack_encode(data: &[u8]) {
    let count = read_u32(data, 0);
    let mut lists: Vec<Vec<(Vec<u8>, Vec<u8>)>> = Vec::with_capacity(count);
    let mut pos = 4;
    for _ in 0..count {
        let hcount = read_u16(data, pos);
        pos += 2;
        let mut hs = Vec::with_capacity(hcount);
        for _ in 0..hcount {
            let nlen = read_u16(data, pos);
            pos += 2;
            let name = data[pos..pos + nlen].to_vec();
            pos += nlen;
            let vlen = read_u16(data, pos);
            pos += 2;
            let val = data[pos..pos + vlen].to_vec();
            pos += vlen;
            let _sens = data[pos];
            pos += 1;
            hs.push((name, val));
        }
        lists.push(hs);
    }

    let mut total_blocks: i64 = 0;
    let mut total_headers: i64 = 0;
    let mut encoded_sink: i64 = 0;
    let mut verify_checksum: i64 = 0;

    for round in 0..100 {
        let mut enc = hpack_patched::Encoder::new();
        let verify_round = round == 99;
        let mut dec = hpack_patched::Decoder::new();
        for hs in &lists {
            let pairs: Vec<(&[u8], &[u8])> = hs.iter().map(|(n, v)| (n.as_slice(), v.as_slice())).collect();
            let wire = enc.encode(pairs);
            total_blocks += 1;
            total_headers += hs.len() as i64;
            encoded_sink += wire.len() as i64;
            if verify_round {
                let rt = dec.decode(&wire).unwrap_or_else(|e| {
                    eprintln!("verify decode error: {:?}", e);
                    process::exit(1);
                });
                verify_checksum = hash_headers_vec(verify_checksum, &rt);
            }
        }
    }

    if encoded_sink <= 0 {
        process::exit(1);
    }
    println!("mode=hpack_encode");
    println!("blocks={}", total_blocks);
    println!("headers={}", total_headers);
    println!("verify_checksum={}", verify_checksum);
}

fn bench_frame_stream(data: &[u8]) {
    let mut total_frames: i64 = 0;
    let mut total_events: i64 = 0;
    let mut checksum: i64 = 0;
    let mut pending_buf: Vec<u8> = Vec::with_capacity(256);

    for _round in 0..100 {
        let mut dec = hpack_patched::Decoder::new();
        let mut pos = 0usize;
        let n = data.len();
        let mut pending_sid: i64 = 0;
        let mut pending_es: bool = false;
        pending_buf.clear();

        while pos + 9 <= n {
            let plen = ((data[pos] as usize) << 16)
                | ((data[pos + 1] as usize) << 8)
                | (data[pos + 2] as usize);
            let ftype = data[pos + 3];
            let flags = data[pos + 4];
            let sid = (((data[pos + 5] & 0x7F) as i64) << 24)
                | ((data[pos + 6] as i64) << 16)
                | ((data[pos + 7] as i64) << 8)
                | (data[pos + 8] as i64);
            let payload = &data[pos + 9..pos + 9 + plen];
            pos += 9 + plen;
            total_frames += 1;

            match ftype {
                0x0 => {
                    // DATA
                    let es = (flags & 0x01) != 0;
                    total_events += 1;
                    checksum = mix(checksum, 2);
                    checksum = mix(checksum, sid);
                    checksum = mix(checksum, if es { 1 } else { 0 });
                    checksum = hash_bytes(checksum, payload);
                }
                0x1 => {
                    // HEADERS
                    let es = (flags & 0x01) != 0;
                    let eh = (flags & 0x04) != 0;
                    if eh {
                        let hs = dec.decode(payload).unwrap();
                        total_events += 1;
                        checksum = mix(checksum, 1);
                        checksum = mix(checksum, sid);
                        checksum = mix(checksum, if es { 1 } else { 0 });
                        checksum = hash_headers_vec(checksum, &hs);
                    } else {
                        pending_sid = sid;
                        pending_es = es;
                        pending_buf.clear();
                        pending_buf.extend_from_slice(payload);
                    }
                }
                0x9 => {
                    // CONTINUATION
                    let eh = (flags & 0x04) != 0;
                    pending_buf.extend_from_slice(payload);
                    if eh {
                        let hs = dec.decode(&pending_buf).unwrap();
                        total_events += 1;
                        checksum = mix(checksum, 1);
                        checksum = mix(checksum, pending_sid);
                        checksum = mix(checksum, if pending_es { 1 } else { 0 });
                        checksum = hash_headers_vec(checksum, &hs);
                        pending_sid = 0;
                        pending_buf.clear();
                    }
                }
                0x4 => {
                    // SETTINGS
                    let ack = (flags & 0x01) != 0;
                    total_events += 1;
                    checksum = mix(checksum, 3);
                    checksum = mix(checksum, (plen / 6) as i64);
                    checksum = mix(checksum, if ack { 1 } else { 0 });
                }
                0x8 => {
                    // WINDOW_UPDATE
                    let inc = (((payload[0] & 0x7F) as i64) << 24)
                        | ((payload[1] as i64) << 16)
                        | ((payload[2] as i64) << 8)
                        | (payload[3] as i64);
                    total_events += 1;
                    checksum = mix(checksum, 4);
                    checksum = mix(checksum, sid);
                    checksum = mix(checksum, inc);
                }
                0x6 => {
                    // PING
                    let ack = (flags & 0x01) != 0;
                    total_events += 1;
                    checksum = mix(checksum, 5);
                    checksum = mix(checksum, if ack { 1 } else { 0 });
                    checksum = hash_bytes(checksum, payload);
                }
                0x2 => {
                    // PRIORITY
                    let weight = payload[4] as i64;
                    total_events += 1;
                    checksum = mix(checksum, 6);
                    checksum = mix(checksum, sid);
                    checksum = mix(checksum, weight);
                }
                _ => {}
            }
        }
    }

    println!("mode=frame_stream");
    println!("frames={}", total_frames);
    println!("events={}", total_events);
    println!("checksum={}", checksum);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: http2-bench-rust <hpack_decode|hpack_encode|frame_stream> <corpus.bin>");
        process::exit(1);
    }
    let mode = &args[1];
    let data = fs::read(&args[2]).unwrap_or_else(|e| {
        eprintln!("read error: {}", e);
        process::exit(1);
    });
    match mode.as_str() {
        "hpack_decode" => bench_hpack_decode(&data),
        "hpack_encode" => bench_hpack_encode(&data),
        "frame_stream" => bench_frame_stream(&data),
        _ => {
            eprintln!("unknown mode: {}", mode);
            process::exit(1);
        }
    }
}
