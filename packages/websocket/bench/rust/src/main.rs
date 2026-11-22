use std::io::{self, Read, Write};
use tungstenite::protocol::frame::coding::{Data, OpCode};
use tungstenite::protocol::frame::Frame;
use tungstenite::protocol::{Role, WebSocket};
use tungstenite::Message;

struct RingStream {
    buf: Vec<u8>,
    pos: usize,
}

impl RingStream {
    fn new() -> Self {
        Self {
            buf: Vec::with_capacity(16384),
            pos: 0,
        }
    }

    fn reset(&mut self) {
        self.buf.clear();
        self.pos = 0;
    }
}

impl Read for RingStream {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let avail = self.buf.len() - self.pos;
        if avail == 0 {
            return Err(io::Error::new(io::ErrorKind::WouldBlock, "empty"));
        }
        let n = avail.min(out.len());
        out[..n].copy_from_slice(&self.buf[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}

impl Write for RingStream {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        // Discard automatic Pong writes from tungstenite Server read()
        Ok(data.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn build_text_pool(size: usize) -> Vec<u8> {
    let unit = "WS:世界🌍123".as_bytes();
    debug_assert_eq!(unit.len(), 16);
    (0..size).map(|i| unit[i & 15]).collect()
}

fn build_bin_pool(size: usize) -> Vec<u8> {
    (0..size).map(|i| ((i * 37 + 13) & 0xFF) as u8).collect()
}

fn build_ping_pool(size: usize) -> Vec<u8> {
    (0..size).map(|i| (65 + (i % 26)) as u8).collect()
}

#[inline]
fn update_digest(mut h: i64, data: &[u8]) -> i64 {
    for &b in data {
        h = ((h & 0x00FF_FFFF_FFFF_FFFFi64) * 31 + (b as i64)) & 0x3FFF_FFFF_FFFF_FFFFi64;
    }
    h
}

fn main() {
    let cycles: usize = 10_000;
    let text_pool = build_text_pool(2048);
    let bin_pool = build_bin_pool(4096);
    let ping_pool = build_ping_pool(32);

    let text_t0: Vec<Vec<u8>> = (0..16).map(|k| text_pool[0..1024 + k * 16].to_vec()).collect();
    let bin_t1: Vec<Vec<u8>> = (0..32).map(|k| bin_pool[0..2048 + k * 16].to_vec()).collect();
    let frag_p1 = text_pool[0..517].to_vec();
    let frag_p2: Vec<Vec<u8>> = (0..8)
        .map(|k| text_pool[517..1536 + k * 16].to_vec())
        .collect();

    let mut ws = WebSocket::from_raw_socket(RingStream::new(), Role::Server, None);
    let mut text_msgs: i64 = 0;
    let mut bin_msgs: i64 = 0;
    let mut ping_msgs: i64 = 0;
    let mut wire_bytes: i64 = 0;
    let mut payload_bytes: i64 = 0;
    let mut digest: i64 = 1_469_598_103;

    for c in 0..cycles {
        let mk = ((c as u64).wrapping_mul(2_654_435_761).wrapping_add(0x37FA_213D) & 0xFFFF_FFFF) as u32;

        ws.get_mut().reset();
        let stream_buf = &mut ws.get_mut().buf;

        let mut f0 = Frame::message(text_t0[c & 15].clone(), OpCode::Data(Data::Text), true);
        f0.header_mut().mask = Some(mk.to_be_bytes());
        f0.format(stream_buf).unwrap();

        let mut f1 = Frame::message(bin_t1[c & 31].clone(), OpCode::Data(Data::Binary), true);
        f1.header_mut().mask = Some((mk ^ 0x1111_1111).to_be_bytes());
        f1.format(stream_buf).unwrap();

        let mut f2 = Frame::message(frag_p1.clone(), OpCode::Data(Data::Text), false);
        f2.header_mut().mask = Some((mk ^ 0x2222_2222).to_be_bytes());
        f2.format(stream_buf).unwrap();

        let mut f3 = Frame::ping(ping_pool.clone());
        f3.header_mut().mask = Some((mk ^ 0x3333_3333).to_be_bytes());
        f3.format(stream_buf).unwrap();

        let mut f4 = Frame::message(frag_p2[c & 7].clone(), OpCode::Data(Data::Continue), true);
        f4.header_mut().mask = Some((mk ^ 0x4444_4444).to_be_bytes());
        f4.format(stream_buf).unwrap();

        wire_bytes += stream_buf.len() as i64;

        for _ in 0..4 {
            match ws.read().unwrap() {
                Message::Text(s) => {
                    text_msgs += 1;
                    payload_bytes += s.len() as i64;
                    digest = update_digest(digest, s.as_bytes());
                }
                Message::Binary(b) => {
                    bin_msgs += 1;
                    payload_bytes += b.len() as i64;
                    digest = update_digest(digest, &b);
                }
                Message::Ping(b) => {
                    ping_msgs += 1;
                    payload_bytes += b.len() as i64;
                    digest = update_digest(digest, &b);
                }
                _ => {}
            }
        }
    }

    println!("frames={}", cycles * 5);
    println!("text_msgs={text_msgs}");
    println!("binary_msgs={bin_msgs}");
    println!("ping_msgs={ping_msgs}");
    println!("wire_bytes={wire_bytes}");
    println!("payload_bytes={payload_bytes}");
    println!("digest={digest}");
}
