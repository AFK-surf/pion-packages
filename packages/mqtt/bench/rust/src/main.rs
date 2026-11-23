use bytes::{Bytes, BytesMut};
use rumqttc::mqttbytes::v4 as m4;
use rumqttc::v5::mqttbytes::v5 as m5;
use rumqttc::v5::mqttbytes::QoS as QoS5;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::process;

#[inline]
fn mix(h: i64, v: i64) -> i64 {
    ((h * 131) + v) % 1_000_000_007
}

fn bench_w1() -> i32 {
    let mut topics = Vec::with_capacity(16);
    let mut resp_topics = Vec::with_capacity(16);
    let mut payloads = Vec::with_capacity(16);
    for k in 0..16 {
        let z = k / 4;
        let d = k % 4;
        topics.push(format!("iot/zone{z}/dev{d}/telemetry"));
        resp_topics.push(format!("iot/reply/zone{z}/dev{d}"));
        payloads.push(Bytes::from(format!(
            "{{\"zone\":{z},\"dev\":{d},\"temp\":24.75,\"hum\":58,\"status\":\"ok\"}}"
        )));
    }

    let mut buf = BytesMut::with_capacity(512);
    let mut total_wire: i64 = 0;
    let mut total_payload: i64 = 0;
    let mut total_uprops: i64 = 0;
    let mut checksum: i64 = 0;

    for i in 0..200_000usize {
        let idx = i & 15;
        let pid = ((i % 65000) + 1) as u16;
        let props = m5::PublishProperties {
            payload_format_indicator: None,
            message_expiry_interval: Some(300),
            topic_alias: None,
            response_topic: Some(resp_topics[idx].clone()),
            correlation_data: None,
            user_properties: vec![
                ("region".to_string(), "ap-northeast-1".to_string()),
                ("tier".to_string(), "edge".to_string()),
            ],
            subscription_identifiers: Vec::new(),
            content_type: Some("application/json".to_string()),
        };
        let mut p = m5::Publish::new(
            topics[idx].clone(),
            QoS5::AtLeastOnce,
            payloads[idx].clone(),
            Some(props),
        );
        p.pkid = pid;
        buf.clear();
        p.write(&mut buf).expect("w1 encode");
        total_wire += buf.len() as i64;
        match m5::Packet::read(&mut buf, Some(1_048_576)).expect("w1 decode") {
            m5::Packet::Publish(d) => {
                total_payload += d.payload.len() as i64;
                if let Some(pr) = &d.properties {
                    total_uprops += pr.user_properties.len() as i64;
                }
                checksum = mix(checksum, d.pkid as i64);
                checksum = mix(checksum, d.topic.len() as i64);
                checksum = mix(checksum, d.payload.len() as i64);
            }
            _ => panic!("unexpected packet"),
        }
    }

    println!("mode=w1");
    println!("packets=200000");
    println!("wire_bytes={total_wire}");
    println!("payload_bytes={total_payload}");
    println!("user_props={total_uprops}");
    println!("checksum={checksum}");
    0
}

fn digest_v5(h0: i64, pkt: &m5::Packet) -> i64 {
    match pkt {
        m5::Packet::Connect(c, ..) => mix(mix(h0, 1), c.client_id.len() as i64),
        m5::Packet::ConnAck(ca) => mix(mix(h0, 2), ca.code as i64),
        m5::Packet::Publish(p) => mix(mix(mix(h0, 3), p.pkid as i64), p.payload.len() as i64),
        m5::Packet::PubAck(a) => mix(mix(h0, 4), a.pkid as i64),
        m5::Packet::PubRec(a) => mix(mix(h0, 5), a.pkid as i64),
        m5::Packet::PubRel(a) => mix(mix(h0, 6), a.pkid as i64),
        m5::Packet::PubComp(a) => mix(mix(h0, 7), a.pkid as i64),
        m5::Packet::Subscribe(s) => mix(mix(h0, 8), s.pkid as i64),
        m5::Packet::SubAck(sa) => mix(mix(h0, 9), sa.pkid as i64),
        m5::Packet::Unsubscribe(u) => mix(mix(h0, 10), u.pkid as i64),
        m5::Packet::UnsubAck(ua) => mix(mix(h0, 11), ua.pkid as i64),
        m5::Packet::PingReq(_) => mix(h0, 12),
        m5::Packet::PingResp(_) => mix(h0, 13),
        m5::Packet::Disconnect(d) => mix(mix(h0, 14), d.reason_code as i64),
        m5::Packet::Auth(a) => mix(mix(h0, 15), a.code.clone() as i64),
    }
}

fn digest_v4(h0: i64, pkt: &m4::Packet) -> i64 {
    match pkt {
        m4::Packet::Connect(c) => mix(mix(h0, 1), c.client_id.len() as i64),
        m4::Packet::ConnAck(ca) => mix(mix(h0, 2), ca.code as i64),
        m4::Packet::Publish(p) => mix(mix(mix(h0, 3), p.pkid as i64), p.payload.len() as i64),
        m4::Packet::PubAck(a) => mix(mix(h0, 4), a.pkid as i64),
        m4::Packet::PubRec(a) => mix(mix(h0, 5), a.pkid as i64),
        m4::Packet::PubRel(a) => mix(mix(h0, 6), a.pkid as i64),
        m4::Packet::PubComp(a) => mix(mix(h0, 7), a.pkid as i64),
        m4::Packet::Subscribe(s) => mix(mix(h0, 8), s.pkid as i64),
        m4::Packet::SubAck(sa) => mix(mix(h0, 9), sa.pkid as i64),
        m4::Packet::Unsubscribe(u) => mix(mix(h0, 10), u.pkid as i64),
        m4::Packet::UnsubAck(ua) => mix(mix(h0, 11), ua.pkid as i64),
        m4::Packet::PingReq => mix(h0, 12),
        m4::Packet::PingResp => mix(h0, 13),
        m4::Packet::Disconnect => mix(mix(h0, 14), 0),
    }
}

fn parse_v5_rounds(data: &[u8], rounds: usize) -> (i64, i64) {
    let mut buf = BytesMut::with_capacity(4096);
    let mut count: i64 = 0;
    let mut checksum: i64 = 0;
    for _ in 0..rounds {
        let mut pos = 0;
        while pos < data.len() {
            let end = (pos + 137).min(data.len());
            buf.extend_from_slice(&data[pos..end]);
            loop {
                match m5::Packet::read(&mut buf, Some(1_048_576)) {
                    Ok(pkt) => {
                        count += 1;
                        checksum = digest_v5(checksum, &pkt);
                    }
                    Err(rumqttc::v5::mqttbytes::Error::InsufficientBytes(_)) => break,
                    Err(e) => panic!("v5 decode error: {e:?}"),
                }
            }
            pos = end;
        }
    }
    (count, checksum)
}

fn parse_v4_rounds(data: &[u8], rounds: usize) -> (i64, i64) {
    let mut buf = BytesMut::with_capacity(4096);
    let mut count: i64 = 0;
    let mut checksum: i64 = 0;
    for _ in 0..rounds {
        let mut pos = 0;
        while pos < data.len() {
            let end = (pos + 137).min(data.len());
            buf.extend_from_slice(&data[pos..end]);
            loop {
                match m4::Packet::read(&mut buf, 1_048_576) {
                    Ok(pkt) => {
                        count += 1;
                        checksum = digest_v4(checksum, &pkt);
                    }
                    Err(rumqttc::mqttbytes::Error::InsufficientBytes(_)) => break,
                    Err(e) => panic!("v4 decode error: {e:?}"),
                }
            }
            pos = end;
        }
    }
    (count, checksum)
}

#[derive(Default)]
struct TrieNode {
    children: HashMap<String, usize>,
    plus: Option<usize>,
    hash: Vec<(i32, i32)>,
    exact: Vec<(i32, i32)>,
}

struct TopicTrie {
    nodes: Vec<TrieNode>,
    count: usize,
    seen_gen: HashMap<i32, u32>,
    gen: u32,
}

impl TopicTrie {
    fn new() -> Self {
        Self {
            nodes: vec![TrieNode::default()],
            count: 0,
            seen_gen: HashMap::with_capacity(64),
            gen: 0,
        }
    }

    fn insert(&mut self, filter: &str, key: i32, val: i32) {
        let mut cur = 0usize;
        for seg in filter.split('/') {
            if seg == "#" {
                self.nodes[cur].hash.push((key, val));
                self.count += 1;
                return;
            } else if seg == "+" {
                let nxt = match self.nodes[cur].plus {
                    Some(x) => x,
                    None => {
                        let x = self.nodes.len();
                        self.nodes.push(TrieNode::default());
                        self.nodes[cur].plus = Some(x);
                        x
                    }
                };
                cur = nxt;
            } else {
                let nxt = if let Some(&x) = self.nodes[cur].children.get(seg) {
                    x
                } else {
                    let x = self.nodes.len();
                    self.nodes.push(TrieNode::default());
                    self.nodes[cur].children.insert(seg.to_string(), x);
                    x
                };
                cur = nxt;
            }
        }
        self.nodes[cur].exact.push((key, val));
        self.count += 1;
    }

    fn match_topic(&mut self, topic: &str) -> Vec<i32> {
        self.gen += 1;
        let g = self.gen;
        let is_dollar = topic.starts_with('$');
        let levels: Vec<&str> = topic.split('/').collect();
        let mut out = Vec::with_capacity(8);
        let mut stack: Vec<(usize, usize)> = Vec::with_capacity(16);
        stack.push((0, 0));
        while let Some((node_idx, idx)) = stack.pop() {
            let node = &self.nodes[node_idx];
            if !(node_idx == 0 && is_dollar) {
                for &(k, v) in &node.hash {
                    if k >= 0 {
                        if self.seen_gen.get(&k).copied() == Some(g) {
                            continue;
                        }
                        self.seen_gen.insert(k, g);
                    }
                    out.push(v);
                }
            }
            if idx == levels.len() {
                for &(k, v) in &node.exact {
                    if k >= 0 {
                        if self.seen_gen.get(&k).copied() == Some(g) {
                            continue;
                        }
                        self.seen_gen.insert(k, g);
                    }
                    out.push(v);
                }
                continue;
            }
            if !(node_idx == 0 && is_dollar) {
                if let Some(p) = node.plus {
                    stack.push((p, idx + 1));
                }
            }
            if let Some(&ch) = node.children.get(levels[idx]) {
                stack.push((ch, idx + 1));
            }
        }
        out
    }
}

fn bench_w3() -> i32 {
    let mut trie = TopicTrie::new();
    for i in 0..10_000i32 {
        let sub = match i % 10 {
            0 => format!("factory/site{}/+/telemetry", i % 50),
            1 => format!("factory/site{}/line{}/#", i % 50, i % 20),
            2 => format!("iot/+/sensor{}/temp", i % 200),
            3 => format!("fleet/region{}/+/+/gps", i % 10),
            4 => format!("$SYS/broker/node{}/#", i % 25),
            _ => format!("iot/site{}/dev{}/metric", i % 100, i % 500),
        };
        trie.insert(&sub, i, i + 1);
    }
    let mut topics = Vec::with_capacity(1000);
    for t in 0..1000usize {
        let s = match t % 10 {
            0 | 1 => format!("factory/site{}/line{}/telemetry", t % 50, t % 20),
            2 => format!("iot/zone{}/sensor{}/temp", t % 10, t % 200),
            3 => format!("fleet/region{}/city{}/truck{}/gps", t % 10, t % 8, t % 30),
            4 => format!("$SYS/broker/node{}/load/1m", t % 25),
            _ => format!("iot/site{}/dev{}/metric", t % 100, t % 500),
        };
        topics.push(s);
    }
    let mut total_matches: i64 = 0;
    let mut id_sum: i64 = 0;
    for _ in 0..100 {
        for topic in &topics {
            let hits = trie.match_topic(topic);
            total_matches += hits.len() as i64;
            for v in hits {
                id_sum = (id_sum + v as i64) % 1_000_000_007;
            }
        }
    }
    println!("mode=w3");
    println!("subs={}", trie.count);
    println!("publishes=100000");
    println!("matches={total_matches}");
    println!("id_sum={id_sum}");
    0
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: rust_mqtt_bench <w1|w2|w2_v5|w3> [args...]");
        process::exit(1);
    }
    let code = match args[1].as_str() {
        "w1" => bench_w1(),
        "w2" => {
            let v5 = fs::read(&args[2]).expect("read v5");
            let v4 = fs::read(&args[3]).expect("read v4");
            let (c5, h5) = parse_v5_rounds(&v5, 500);
            let (c4, h4) = parse_v4_rounds(&v4, 500);
            println!("mode=w2");
            println!("packets={}", c5 + c4);
            println!("checksum={}", mix(h5, h4));
            0
        }
        "w2_v5" => {
            let v5 = fs::read(&args[2]).expect("read v5");
            let (c5, h5) = parse_v5_rounds(&v5, 1000);
            println!("mode=w2_v5");
            println!("packets={c5}");
            println!("checksum={h5}");
            0
        }
        "w3" => bench_w3(),
        other => {
            eprintln!("unknown mode: {other}");
            1
        }
    };
    process::exit(code);
}
