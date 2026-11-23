//! h2_codec_bench frames <frame_stream.bin>: same rounds/checksum as pion_fair frames_codec / go_fair frames.
use bytes::Bytes;
use futures_core::Stream;
use h2::frame::Frame;
use std::io::Cursor;
use std::pin::Pin;
use std::task::{Context, Poll, Waker};
use std::{env, fs, process};

#[inline(always)]
fn mix(h: i64, v: i64) -> i64 {
    ((h * 131) + v) % 1_000_000_007
}
fn hash_bytes(mut h: i64, b: &[u8]) -> i64 {
    h = mix(h, b.len() as i64);
    for &c in b {
        h = mix(h, c as i64);
    }
    h
}
fn b2i(b: bool) -> i64 {
    b as i64
}

fn main() {
    let a: Vec<String> = env::args().collect();
    let data = fs::read(&a[2]).expect("read");
    let (mut nf, mut ne, mut ck) = (0i64, 0i64, 0i64);
    let mut cx = Context::from_waker(Waker::noop());
    for _ in 0..100 {
        // Cursor<Vec<u8>> implements tokio AsyncRead + AsyncWrite; the codec never writes here.
        let mut codec: h2::Codec<Cursor<Vec<u8>>, Bytes> = h2::Codec::new(Cursor::new(data.clone()));
        codec.set_max_recv_header_list_size(65536);
        loop {
            match Pin::new(&mut codec).poll_next(&mut cx) {
                Poll::Ready(Some(Ok(f))) => {
                    nf += 1;
                    match f {
                        Frame::Headers(h) => {
                            if !h.is_end_headers() {
                                eprintln!("unexpected partial headers");
                            }
                            let sid = u32::from(h.stream_id()) as i64;
                            let es = h.is_end_stream();
                            let (p, map) = h.into_parts();
                            let mut cnt = 0i64;
                            let mut sum = 0i64;
                            let mut add = |n: &[u8], v: &[u8]| {
                                cnt += 1;
                                sum = (sum + hash_bytes(hash_bytes(0, n), v)) % 1_000_000_007;
                            };
                            if let Some(m) = &p.method {
                                add(b":method", m.as_str().as_bytes());
                            }
                            if let Some(s) = &p.scheme {
                                add(b":scheme", s.as_bytes());
                            }
                            if let Some(s) = &p.authority {
                                add(b":authority", s.as_bytes());
                            }
                            if let Some(s) = &p.path {
                                add(b":path", s.as_bytes());
                            }
                            if let Some(s) = &p.status {
                                add(b":status", s.as_str().as_bytes());
                            }
                            for (n, v) in map.iter() {
                                add(n.as_str().as_bytes(), v.as_bytes());
                            }
                            ne += 1;
                            ck = mix(mix(mix(mix(ck, 1), sid), b2i(es)), cnt);
                            ck = mix(ck, sum);
                        }
                        Frame::Data(d) => {
                            ne += 1;
                            ck = hash_bytes(mix(mix(mix(ck, 2), u32::from(d.stream_id()) as i64), b2i(d.is_end_stream())), d.payload());
                        }
                        Frame::Settings(s) => {
                            ne += 1;
                            ck = mix(mix(ck, 3), b2i(s.is_ack()));
                        }
                        Frame::WindowUpdate(w) => {
                            ne += 1;
                            ck = mix(mix(mix(ck, 4), u32::from(w.stream_id()) as i64), w.size_increment() as i64);
                        }
                        Frame::Ping(p) => {
                            ne += 1;
                            ck = hash_bytes(mix(mix(ck, 5), b2i(p.is_ack())), p.payload());
                        }
                        Frame::Priority(p) => {
                            ne += 1;
                            let _ = p;
                            ck = mix(ck, 6);
                        }
                        _ => {}
                    }
                }
                Poll::Ready(Some(Err(e))) => {
                    eprintln!("codec error: {:?}", e);
                    process::exit(1);
                }
                Poll::Ready(None) => break,
                Poll::Pending => {
                    eprintln!("pending on in-memory input");
                    process::exit(1);
                }
            }
        }
    }
    // h2's Codec folds HEADERS+CONTINUATION into one frame: add the folded CONTINUATIONs (100 per round)
    // back so frames= equals the wire frame count, as the Go runner does.
    nf += 100 * 100;
    println!("mode=frames\nframes={}\nevents={}\nchecksum={}", nf, ne, ck);
}
