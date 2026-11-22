//! Red-team adversarial benchmark: tungstenite 0.26.2 server over a chunked wire stream.
//! usage: adv_rust <wire.ws> <chunk_bytes> <msgs_per_round> <rounds>
use std::io::{self, Read, Write};
use tungstenite::protocol::{Role, WebSocket, WebSocketConfig};
use tungstenite::Message;

struct Chunked { data: Vec<u8>, pos: usize, step: usize, rounds: usize }
impl Read for Chunked {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.pos >= self.data.len() {
            if self.rounds <= 1 { return Err(io::ErrorKind::WouldBlock.into()); }
            self.rounds -= 1;
            self.pos = 0;
        }
        let n = (self.data.len() - self.pos).min(self.step).min(buf.len());
        buf[..n].copy_from_slice(&self.data[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}
impl Write for Chunked {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> { Ok(b.len()) }
    fn flush(&mut self) -> io::Result<()> { Ok(()) }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let data = std::fs::read(&a[1]).unwrap();
    let step: usize = a[2].parse().unwrap();
    let cfg = WebSocketConfig::default().max_message_size(Some(32 << 20)).max_frame_size(Some(32 << 20));
    let mut ws = WebSocket::from_raw_socket(Chunked { data, pos: 0, step, rounds: a[4].parse().unwrap() }, Role::Server, Some(cfg));
    let (mut msgs, mut h) = (0u64, 7u64);
    let fold = |h: u64, v: u64| (h.wrapping_mul(31).wrapping_add(v)) & 0x1FFF_FFFF_FFFF_FFFF;
    loop {
        match ws.read() {
            Ok(Message::Binary(b)) => {
                let l = b.len();
                msgs += 1;
                h = fold(h, l as u64 + b[0] as u64 + b[l / 2] as u64 * 256 + b[l - 1] as u64 * 65536);
            }
            Ok(Message::Text(_)) => { msgs += 1; h = fold(h, 1); }
            Ok(_) => {}
            Err(tungstenite::Error::Io(e)) if e.kind() == io::ErrorKind::WouldBlock => break,
            Err(e) => { eprintln!("decode error: {e}"); std::process::exit(1); }
        }
    }
    println!("msgs={msgs}");
    println!("digest={h}");
}
