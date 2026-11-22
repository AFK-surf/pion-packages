//! Adversarial head-to-head runner (Rust httparse 1.10.1 side) for the http1 red-team audit.
//! The SSE decoder is copied verbatim from packages/http1/bench/rust (a hand port: no
//! upstream Rust SSE crate is used by the package bench either).
use std::env;
use std::fs;
use std::process;

const MOD: i64 = 1_000_000_007;

#[inline]
fn hash_bytes(mut h: i64, bytes: &[u8]) -> i64 {
    for &b in bytes {
        h = (h * 131 + b as i64) % MOD;
    }
    h
}

fn bench_req64(data: &[u8]) {
    let (mut count, mut headers, mut hash) = (0i64, 0i64, 0i64);
    for _ in 0..4 {
        let mut pos = 0;
        while pos < data.len() {
            let mut hs = [httparse::EMPTY_HEADER; 100];
            let mut req = httparse::Request::new(&mut hs);
            match req.parse(&data[pos..]) {
                Ok(httparse::Status::Complete(n)) => {
                    count += 1;
                    headers += req.headers.len() as i64;
                    hash = hash_bytes(hash, req.method.unwrap().as_bytes());
                    hash = hash_bytes(hash, req.path.unwrap().as_bytes());
                    for name in ["host", "x-request-id"] {
                        if let Some(h) = req
                            .headers
                            .iter()
                            .find(|h| h.name.eq_ignore_ascii_case(name))
                        {
                            hash = hash_bytes(hash, h.value);
                        }
                    }
                    pos += n;
                }
                _ => {
                    eprintln!("req parse error at {}", pos);
                    process::exit(1);
                }
            }
        }
    }
    println!(
        "mode=req64\ncount={}\nheaders={}\nhash={}",
        count, headers, hash
    );
}

/// httparse has no streaming chunked decoder: best case for Rust (contiguous buffer,
/// zero-copy `parse_chunk_size` + slice hashing), identical sampling to the Pion side.
fn bench_chunk1m(data: &[u8]) {
    let (mut count, mut body, mut hash) = (0i64, 0i64, 0i64);
    for _ in 0..16 {
        let mut pos = 0;
        while pos < data.len() {
            let mut hs = [httparse::EMPTY_HEADER; 100];
            let mut resp = httparse::Response::new(&mut hs);
            let n = match resp.parse(&data[pos..]) {
                Ok(httparse::Status::Complete(n)) => n,
                _ => {
                    eprintln!("resp parse error");
                    process::exit(1)
                }
            };
            count += 1;
            pos += n;
            let mut off: i64 = 0;
            loop {
                let (c, sz) = match httparse::parse_chunk_size(&data[pos..]) {
                    Ok(httparse::Status::Complete(x)) => x,
                    _ => {
                        eprintln!("chunk size error");
                        process::exit(1)
                    }
                };
                pos += c;
                if sz == 0 {
                    // trailer section: expect the empty line
                    let mut ths = [httparse::EMPTY_HEADER; 64];
                    match httparse::parse_headers(&data[pos..], &mut ths) {
                        Ok(httparse::Status::Complete((t, _))) => pos += t,
                        _ => {
                            eprintln!("trailer error");
                            process::exit(1)
                        }
                    }
                    break;
                }
                let n = sz as usize;
                let d = &data[pos..pos + n];
                let mut k = ((off + 4095) / 4096 * 4096 - off) as usize;
                while k < n {
                    hash = (hash * 131 + d[k] as i64) % MOD;
                    k += 4096;
                }
                off += n as i64;
                pos += n + 2;
            }
            body += off;
        }
    }
    println!(
        "mode=chunk1m\ncount={}\nbody_bytes={}\nhash={}",
        count, body, hash
    );
}

struct SseDecoder {
    bom_state: u8,
    skip_next_lf: bool,
    line_buf: Vec<u8>,
    event_type: String,
    data_buf: String,
    has_data: bool,
    last_id: String,
}

impl SseDecoder {
    fn new() -> Self {
        Self {
            bom_state: 0,
            skip_next_lf: false,
            line_buf: Vec::with_capacity(256),
            event_type: String::new(),
            data_buf: String::new(),
            has_data: false,
            last_id: String::new(),
        }
    }

    fn process_line(
        &mut self,
        line: &[u8],
        events: &mut i64,
        data_bytes: &mut i64,
        hash: &mut i64,
    ) {
        if line.is_empty() {
            if self.has_data {
                let etype = if self.event_type.is_empty() {
                    "message"
                } else {
                    self.event_type.as_str()
                };
                *events += 1;
                *data_bytes += self.data_buf.len() as i64;
                *hash = hash_bytes(*hash, etype.as_bytes());
                *hash = hash_bytes(*hash, self.last_id.as_bytes());
                *hash = hash_bytes(*hash, self.data_buf.as_bytes());
                self.data_buf.clear();
                self.has_data = false;
                self.event_type.clear();
            } else {
                self.event_type.clear();
            }
            return;
        }
        if line[0] == b':' {
            return;
        }
        let (field, val) = match line.iter().position(|&b| b == b':') {
            Some(c) => {
                let mut vs = c + 1;
                if vs < line.len() && line[vs] == b' ' {
                    vs += 1;
                }
                (&line[..c], &line[vs..])
            }
            None => (line, &[][..]),
        };
        match field {
            b"data" => {
                if self.has_data {
                    self.data_buf.push('\n');
                }
                self.data_buf.push_str(std::str::from_utf8(val).unwrap());
                self.has_data = true;
            }
            b"event" => {
                self.event_type.clear();
                self.event_type.push_str(std::str::from_utf8(val).unwrap());
            }
            b"id" => {
                if !val.contains(&0) {
                    self.last_id.clear();
                    self.last_id.push_str(std::str::from_utf8(val).unwrap());
                }
            }
            _ => {}
        }
    }

    fn feed(&mut self, chunk: &[u8], events: &mut i64, data_bytes: &mut i64, hash: &mut i64) {
        let mut pos = 0;
        while pos < chunk.len() && self.bom_state < 3 {
            let b = chunk[pos];
            match self.bom_state {
                0 => {
                    if b == 0xEF {
                        self.bom_state = 1;
                        pos += 1;
                    } else {
                        self.bom_state = 3;
                    }
                }
                1 => {
                    if b == 0xBB {
                        self.bom_state = 2;
                        pos += 1;
                    } else {
                        self.bom_state = 3;
                        self.line_buf.push(0xEF);
                    }
                }
                2 => {
                    if b == 0xBF {
                        self.bom_state = 3;
                        pos += 1;
                    } else {
                        self.bom_state = 3;
                        self.line_buf.push(0xEF);
                        self.line_buf.push(0xBB);
                    }
                }
                _ => {}
            }
        }
        while pos < chunk.len() {
            if self.skip_next_lf {
                self.skip_next_lf = false;
                if chunk[pos] == b'\n' {
                    pos += 1;
                    continue;
                }
            }
            let seg_start = pos;
            while pos < chunk.len() && chunk[pos] != b'\n' && chunk[pos] != b'\r' {
                pos += 1;
            }
            if pos < chunk.len() {
                let nl = chunk[pos];
                if self.line_buf.is_empty() {
                    self.process_line(&chunk[seg_start..pos], events, data_bytes, hash);
                } else {
                    self.line_buf.extend_from_slice(&chunk[seg_start..pos]);
                    let line = std::mem::take(&mut self.line_buf);
                    self.process_line(&line, events, data_bytes, hash);
                    self.line_buf = line;
                    self.line_buf.clear();
                }
                if nl == b'\r' {
                    if pos + 1 < chunk.len() && chunk[pos + 1] == b'\n' {
                        pos += 2;
                    } else if pos + 1 >= chunk.len() {
                        self.skip_next_lf = true;
                        pos += 1;
                    } else {
                        pos += 1;
                    }
                } else {
                    pos += 1;
                }
            } else {
                self.line_buf.extend_from_slice(&chunk[seg_start..]);
            }
        }
    }
}

fn bench_sse(data: &[u8]) {
    let (mut events, mut data_bytes, mut hash) = (0i64, 0i64, 0i64);
    for _ in 0..2 {
        let mut dec = SseDecoder::new();
        for chunk in data.chunks(4096) {
            dec.feed(chunk, &mut events, &mut data_bytes, &mut hash);
        }
    }
    println!(
        "mode=sse_multiline\nevents={}\ndata_bytes={}\nhash={}",
        events, data_bytes, hash
    );
}

/// Same Sans-IO drip usage as the Pion side: re-parse the buffered prefix per byte.
fn bench_drip(data: &[u8]) {
    let mut complete = 0;
    for _ in 0..4 {
        for k in 1..=data.len() {
            let mut hs = [httparse::EMPTY_HEADER; 100];
            let mut req = httparse::Request::new(&mut hs);
            match req.parse(&data[..k]) {
                Ok(httparse::Status::Complete(_)) => complete += 1,
                Ok(httparse::Status::Partial) => {}
                Err(e) => {
                    eprintln!("drip error at {}: {:?}", k, e);
                    process::exit(1);
                }
            }
        }
    }
    println!("mode=drip\nbytes={}\ncomplete={}", data.len(), complete);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: adv_rust <req64|chunk1m|sse_multiline|drip> <file>");
        process::exit(1);
    }
    let data = fs::read(&args[2]).expect("read");
    match args[1].as_str() {
        "req64" => bench_req64(&data),
        "chunk1m" => bench_chunk1m(&data),
        "sse_multiline" => bench_sse(&data),
        "drip" => bench_drip(&data),
        m => {
            eprintln!("unknown mode {}", m);
            process::exit(1)
        }
    }
}
