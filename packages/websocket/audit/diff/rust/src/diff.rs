//! Red-team differential runner: tungstenite 0.26.2 over the shared corpus.
use std::collections::VecDeque;
use std::io::{self, Read, Write};
use tungstenite::error::Error;
use tungstenite::protocol::{Role, WebSocket, WebSocketConfig};
use tungstenite::Message;

struct Chunks(VecDeque<Vec<u8>>);
impl Read for Chunks {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self.0.front_mut() {
            None => Err(io::ErrorKind::WouldBlock.into()),
            Some(c) => {
                let n = c.len().min(buf.len());
                buf[..n].copy_from_slice(&c[..n]);
                c.drain(..n);
                if c.is_empty() {
                    self.0.pop_front();
                }
                Ok(n)
            }
        }
    }
}
impl Write for Chunks {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> { Ok(b.len()) }
    fn flush(&mut self) -> io::Result<()> { Ok(()) }
}

fn fnv32(b: &[u8]) -> u32 {
    let mut h: u32 = 2166136261;
    for &x in b { h = (h ^ x as u32).wrapping_mul(16777619); }
    h
}

fn hex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect()
}

fn main() {
    let path = std::env::args().nth(1).expect("corpus");
    let text = std::fs::read_to_string(path).unwrap();
    let mut out = String::new();
    for line in text.lines().filter(|l| !l.is_empty()) {
        let p: Vec<&str> = line.split(' ').collect();
        let role = if p[1] == "s" { Role::Server } else { Role::Client };
        let max: usize = p[2].parse().unwrap();
        let chunk: usize = p[3].parse().unwrap();
        let wire = hex(p[4]);
        let step = if chunk == 0 { wire.len().max(1) } else { chunk };
        let chunks: VecDeque<Vec<u8>> = wire.chunks(step).map(|c| c.to_vec()).collect();
        let cfg = WebSocketConfig::default().max_message_size(Some(max)).max_frame_size(Some(max));
        let mut ws = WebSocket::from_raw_socket(Chunks(chunks), role, Some(cfg));
        out.push_str(p[0]);
        loop {
            match ws.read() {
                Ok(Message::Text(t)) => out.push_str(&format!(" T{}:{}", t.len(), fnv32(t.as_bytes()))),
                Ok(Message::Binary(b)) => out.push_str(&format!(" B{}:{}", b.len(), fnv32(&b))),
                Ok(Message::Close(Some(cf))) => out.push_str(&format!(" C{}", u16::from(cf.code))),
                Ok(Message::Close(None)) => out.push_str(" C-"),
                Ok(_) => {}
                Err(Error::Io(e)) if e.kind() == io::ErrorKind::WouldBlock => { out.push_str(" END"); break; }
                Err(Error::ConnectionClosed) | Err(Error::AlreadyClosed) => { out.push_str(" END"); break; }
                Err(Error::Utf8) => { out.push_str(" ERR1007"); break; }
                Err(Error::Capacity(_)) => { out.push_str(" ERR1009"); break; }
                Err(Error::Protocol(_)) => { out.push_str(" ERR1002"); break; }
                Err(e) => { out.push_str(&format!(" ERRX({e})")); break; }
            }
        }
        out.push('\n');
    }
    print!("{out}");
}
