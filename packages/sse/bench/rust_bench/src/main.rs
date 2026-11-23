use eventsource_stream::{Event, Eventsource};
use futures_util::stream::{self, Stream};
use std::env;
use std::fs;
use std::pin::Pin;
use std::task::{Context, Poll, Waker};

fn drain_events<S, E>(mut es: S, mut f: impl FnMut(Event))
where
    S: Stream<Item = Result<Event, E>> + Unpin,
    E: std::fmt::Debug,
{
    let waker = Waker::noop();
    let mut cx = Context::from_waker(waker);
    loop {
        match Pin::new(&mut es).poll_next(&mut cx) {
            Poll::Ready(Some(Ok(ev))) => f(ev),
            Poll::Ready(Some(Err(e))) => panic!("sse parse error: {:?}", e),
            Poll::Ready(None) => break,
            Poll::Pending => panic!("unexpected Pending on in-memory stream"),
        }
    }
}

const MOD_V: i64 = 1_000_000_007;

fn hash_bytes(mut h: i64, s: &str) -> i64 {
    for &b in s.as_bytes() {
        h = (h * 131 + b as i64) % MOD_V;
    }
    h
}

struct Stats {
    events: i64,
    data_bytes: i64,
    id_bytes: i64,
    retry_sum: i64,
    hash: i64,
}

impl Stats {
    fn new() -> Self {
        Self {
            events: 0,
            data_bytes: 0,
            id_bytes: 0,
            retry_sum: 0,
            hash: 17,
        }
    }

    fn record(&mut self, ev: &Event) {
        self.events += 1;
        self.data_bytes += ev.data.len() as i64;
        self.id_bytes += ev.id.len() as i64;
        if let Some(d) = ev.retry {
            self.retry_sum += d.as_millis() as i64;
        }
        self.hash = hash_bytes(self.hash, &ev.event);
        self.hash = hash_bytes(self.hash, &ev.data);
        self.hash = hash_bytes(self.hash, &ev.id);
    }

    fn print(&self, mode: &str, iters: usize) {
        println!("mode={}", mode);
        println!("iters={}", iters);
        println!("events={}", self.events);
        println!("data_bytes={}", self.data_bytes);
        println!("id_bytes={}", self.id_bytes);
        println!("retry_sum={}", self.retry_sum);
        println!("hash={}", self.hash);
    }
}

fn parse_chunked(raw: &[u8], chunk_size: usize) -> Vec<Event> {
    let chunks: Vec<Result<&[u8], std::io::Error>> =
        raw.chunks(chunk_size).map(Ok).collect();
    let es = stream::iter(chunks).eventsource();
    let mut out = Vec::new();
    drain_events(es, |ev| out.push(ev));
    out
}

fn format_event_rust(ev: &Event, out: &mut String) {
    if !ev.event.is_empty() && ev.event != "message" {
        out.push_str("event: ");
        out.push_str(&ev.event);
        out.push('\n');
    }
    if !ev.id.is_empty() {
        out.push_str("id: ");
        out.push_str(&ev.id);
        out.push('\n');
    }
    if let Some(d) = ev.retry {
        out.push_str("retry: ");
        out.push_str(&d.as_millis().to_string());
        out.push('\n');
    }
    for line in ev.data.split('\n') {
        out.push_str("data: ");
        out.push_str(line);
        out.push('\n');
    }
    out.push('\n');
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: sse_bench_rust <w1|w2|w3> <file> <iters>");
        std::process::exit(1);
    }
    let mode = &args[1];
    let path = &args[2];
    let iters: usize = args[3].parse().expect("invalid iters");
    let raw = fs::read(path).expect("failed to read input file");

    match mode.as_str() {
        "w1" => {
            let mut st = Stats::new();
            for _ in 0..iters {
                let chunks: Vec<Result<&[u8], std::io::Error>> =
                    raw.chunks(4096).map(Ok).collect();
                let es = stream::iter(chunks).eventsource();
                drain_events(es, |ev| st.record(&ev));
            }
            st.print("w1_stream_4k", iters);
        }
        "w2" => {
            let mut st = Stats::new();
            for _ in 0..iters {
                let chunks: Vec<Result<&[u8], std::io::Error>> =
                    raw.chunks(64).map(Ok).collect();
                let es = stream::iter(chunks).eventsource();
                drain_events(es, |ev| st.record(&ev));
            }
            st.print("w2_chunked_64b", iters);
        }
        "w3" => {
            let initial = parse_chunked(&raw, 4096);
            let mut st = Stats::new();
            for _ in 0..iters {
                let mut buf = String::with_capacity(raw.len());
                for ev in &initial {
                    format_event_rust(ev, &mut buf);
                }
                let bytes = buf.as_bytes();
                let chunks: Vec<Result<&[u8], std::io::Error>> =
                    bytes.chunks(4096).map(Ok).collect();
                let es = stream::iter(chunks).eventsource();
                drain_events(es, |ev| st.record(&ev));
            }
            st.print("w3_roundtrip", iters);
        }
        other => {
            eprintln!("unknown mode: {}", other);
            std::process::exit(1);
        }
    }
}
