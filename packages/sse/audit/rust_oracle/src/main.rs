//! Differential oracle: Rust `eventsource-stream =0.2.3` over the audit corpus.
//! usage: sse_audit_rust_oracle <cases.hex>   (prints `<idx> <whole|b1|rnd> <events>[!ERR:kind]`)
use eventsource_stream::{EventStreamError, Eventsource};
use futures_util::stream::{self, Stream};
use std::pin::Pin;
use std::task::{Context, Poll, Waker};

fn hex(s: &str) -> String {
    s.as_bytes().iter().map(|b| format!("{:02x}", b)).collect()
}

fn run(raw: &[u8], chunks: Vec<&[u8]>) -> String {
    let _ = raw;
    let items: Vec<Result<&[u8], std::io::Error>> = chunks.into_iter().map(Ok).collect();
    let mut es = stream::iter(items).eventsource();
    let mut cx = Context::from_waker(Waker::noop());
    let mut out = String::new();
    loop {
        match Pin::new(&mut es).poll_next(&mut cx) {
            Poll::Ready(Some(Ok(ev))) => {
                let r = ev.retry.map(|d| d.as_millis().to_string()).unwrap_or_else(|| "-".into());
                out.push_str(&format!("[t={},d={},i={},r={}]", hex(&ev.event), hex(&ev.data), hex(&ev.id), r));
            }
            Poll::Ready(Some(Err(e))) => {
                out.push_str(match e {
                    EventStreamError::Utf8(_) => "!ERR:Utf8",
                    EventStreamError::Parser(_) => "!ERR:Parser",
                    EventStreamError::Transport(_) => "!ERR:Transport",
                });
                break;
            }
            Poll::Ready(None) => break,
            Poll::Pending => panic!("Pending on in-memory stream"),
        }
    }
    out
}

fn run_guarded(raw: &[u8], chunks: Vec<&[u8]>) -> String {
    // eventsource-stream 0.2.3 panics (`&string[1..]` inside U+FEFF) on a stream that starts with a BOM.
    std::panic::catch_unwind(|| run(raw, chunks)).unwrap_or_else(|_| "!PANIC".to_string())
}

fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let path = std::env::args().nth(1).expect("usage: sse_audit_rust_oracle <cases.hex>");
    let text = std::fs::read_to_string(path).expect("read corpus");
    for (idx, line) in text.split('\n').enumerate() {
        if idx > 0 && line.is_empty() && text.ends_with('\n') && idx == text.split('\n').count() - 1 {
            break;
        }
        let raw: Vec<u8> = (0..line.len() / 2)
            .map(|i| u8::from_str_radix(&line[2 * i..2 * i + 2], 16).unwrap())
            .collect();
        println!("{} whole {}", idx, run_guarded(&raw, vec![&raw[..]]));
        println!("{} b1 {}", idx, run_guarded(&raw, raw.chunks(1).collect()));
        let mut s: u64 = (idx as u64).wrapping_mul(2654435761).wrapping_add(1);
        let mut v = Vec::new();
        let mut pos = 0;
        while pos < raw.len() {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let n = (((s >> 33) & 0x7fff_ffff) % 17 + 1) as usize;
            let end = (pos + n).min(raw.len());
            v.push(&raw[pos..end]);
            pos = end;
        }
        println!("{} rnd {}", idx, run_guarded(&raw, v));
    }
}
