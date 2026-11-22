//! Red-team handshake differential runner: tungstenite 0.26.2 server accept / client verify.
use std::io::{self, Read, Write};
use tungstenite::client::IntoClientRequest;
use tungstenite::handshake::client::generate_key;

struct Mock { inp: Vec<u8>, pos: usize }
impl Read for Mock {
    fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
        if self.pos >= self.inp.len() { return Err(io::ErrorKind::WouldBlock.into()); }
        let n = (self.inp.len() - self.pos).min(b.len());
        b[..n].copy_from_slice(&self.inp[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}
impl Write for Mock {
    fn write(&mut self, b: &[u8]) -> io::Result<usize> { Ok(b.len()) }
    fn flush(&mut self) -> io::Result<()> { Ok(()) }
}

fn hex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect()
}

fn main() {
    let path = std::env::args().nth(1).expect("corpus");
    let text = std::fs::read_to_string(path).unwrap();
    let key = "dGhlIHNhbXBsZSBub25jZQ==";
    let accept = tungstenite::handshake::derive_accept_key(key.as_bytes());
    let _ = generate_key;
    for line in text.lines().filter(|l| !l.is_empty()) {
        let p: Vec<&str> = line.split(' ').collect();
        let raw = String::from_utf8_lossy(&hex(p[2])).replace("{ACCEPT}", &accept);
        let res = if p[1] == "req" {
            let mut got_key = String::new();
            let r = tungstenite::accept_hdr(Mock { inp: raw.into_bytes(), pos: 0 },
                |req: &tungstenite::handshake::server::Request, resp| {
                    got_key = req.headers().get("Sec-WebSocket-Key").map(|v| v.to_str().unwrap_or("?").to_string()).unwrap_or_default();
                    Ok(resp)
                });
            match r { Ok(_) => format!("OK key={got_key}"), Err(_) => "ERR".to_string() }
        } else {
            let mut req = "ws://example.com/ws".into_client_request().unwrap();
            req.headers_mut().insert("Sec-WebSocket-Key", key.parse().unwrap());
            match tungstenite::client(req, Mock { inp: raw.into_bytes(), pos: 0 }) {
                Ok(_) => "OK".to_string(),
                Err(_) => "ERR".to_string(),
            }
        };
        println!("{} {}", p[0], res);
    }
    // Builder: a subprotocol carrying CRLF must not reach the wire as an extra header.
    let mut req = "ws://example.com/ws".into_client_request().unwrap();
    match "chat\r\nX-Evil: 1".parse::<tungstenite::http::HeaderValue>() {
        Ok(v) => { req.headers_mut().insert("Sec-WebSocket-Protocol", v); println!("builder_crlf_subprotocol INJECTED"); }
        Err(_) => println!("builder_crlf_subprotocol REJECTED"),
    }
}
