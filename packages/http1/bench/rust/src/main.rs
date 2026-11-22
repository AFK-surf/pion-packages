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

fn bench_req(data: &[u8]) {
    let mut count: i64 = 0;
    let mut total_headers: i64 = 0;
    let mut total_bytes: i64 = 0;
    let mut hash: i64 = 0;
    for _ in 0..4 {
        let mut pos = 0;
        while pos < data.len() {
            let mut headers = [httparse::EMPTY_HEADER; 64];
            let mut req = httparse::Request::new(&mut headers);
            match req.parse(&data[pos..]) {
                Ok(httparse::Status::Complete(consumed)) => {
                    count += 1;
                    total_headers += req.headers.len() as i64;
                    total_bytes += consumed as i64;
                    hash = hash_bytes(hash, req.method.unwrap().as_bytes());
                    hash = hash_bytes(hash, req.path.unwrap().as_bytes());
                    for h in req.headers.iter() {
                        if h.name.eq_ignore_ascii_case("host") {
                            hash = hash_bytes(hash, h.value);
                            break;
                        }
                    }
                    for h in req.headers.iter() {
                        if h.name.eq_ignore_ascii_case("x-request-id") {
                            hash = hash_bytes(hash, h.value);
                            break;
                        }
                    }
                    pos += consumed;
                }
                _ => {
                    eprintln!("req parse error at {}", pos);
                    process::exit(1);
                }
            }
        }
    }
    println!("mode=req");
    println!("count={}", count);
    println!("headers={}", total_headers);
    println!("bytes={}", total_bytes);
    println!("hash={}", hash);
}

fn bench_resp_chunked(data: &[u8]) {
    let mut count: i64 = 0;
    let mut total_body: i64 = 0;
    let mut hash: i64 = 0;
    for _ in 0..4 {
        let mut pos = 0;
        while pos < data.len() {
            let mut headers = [httparse::EMPTY_HEADER; 64];
            let mut resp = httparse::Response::new(&mut headers);
            match resp.parse(&data[pos..]) {
                Ok(httparse::Status::Complete(consumed)) => {
                    count += 1;
                    hash = (hash * 131 + resp.code.unwrap() as i64) % MOD;
                    for h in resp.headers.iter() {
                        if h.name.eq_ignore_ascii_case("content-type") {
                            hash = hash_bytes(hash, h.value);
                            break;
                        }
                    }
                    pos += consumed;
                    loop {
                        match httparse::parse_chunk_size(&data[pos..]) {
                            Ok(httparse::Status::Complete((sz_consumed, sz))) => {
                                pos += sz_consumed;
                                if sz == 0 {
                                    if pos + 2 <= data.len()
                                        && data[pos] == b'\r'
                                        && data[pos + 1] == b'\n'
                                    {
                                        pos += 2;
                                        break;
                                    } else {
                                        eprintln!("chunked final crlf error");
                                        process::exit(1);
                                    }
                                }
                                let n = sz as usize;
                                total_body += sz as i64;
                                hash = hash_bytes(hash, &data[pos..pos + n]);
                                pos += n;
                                if pos + 2 <= data.len()
                                    && data[pos] == b'\r'
                                    && data[pos + 1] == b'\n'
                                {
                                    pos += 2;
                                } else {
                                    eprintln!("chunked data crlf error");
                                    process::exit(1);
                                }
                            }
                            _ => {
                                eprintln!("chunk size error at {}", pos);
                                process::exit(1);
                            }
                        }
                    }
                }
                _ => {
                    eprintln!("resp parse error at {}", pos);
                    process::exit(1);
                }
            }
        }
    }
    println!("mode=resp_chunked");
    println!("count={}", count);
    println!("body_bytes={}", total_body);
    println!("hash={}", hash);
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
    let mut events: i64 = 0;
    let mut data_bytes: i64 = 0;
    let mut hash: i64 = 0;
    for _ in 0..2 {
        let mut dec = SseDecoder::new();
        for chunk in data.chunks(4096) {
            dec.feed(chunk, &mut events, &mut data_bytes, &mut hash);
        }
    }
    println!("mode=sse");
    println!("events={}", events);
    println!("data_bytes={}", data_bytes);
    println!("hash={}", hash);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: http1-bench-rust <req|resp_chunked|sse> <file>");
        process::exit(1);
    }
    let data = fs::read(&args[2]).expect("failed to read input");
    match args[1].as_str() {
        "req" => bench_req(&data),
        "resp_chunked" => bench_resp_chunked(&data),
        "sse" => bench_sse(&data),
        other => {
            eprintln!("unknown mode: {}", other);
            process::exit(1);
        }
    }
}
