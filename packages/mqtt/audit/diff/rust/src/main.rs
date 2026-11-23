//! RT-mqtt differential driver: Rust rumqttc 0.25.1 (mqttbytes v4 for MQTT 3.1.1, v5 for MQTT 5.0).
//! Reads vectors.bin ([ver u8][len u32 BE][bytes]...) and prints one verdict line per vector:
//!   id <ok|reject|incomplete|panic> <TYPE|-> <used> <pid>
use bytes::BytesMut;
use rumqttc::mqttbytes::v4 as m4;
use rumqttc::v5::mqttbytes::v5 as m5;
use std::io::Write;

const MAX: usize = 1_048_576;

fn v4(id: usize, pkt: &[u8]) -> String {
    let mut buf = BytesMut::from(pkt);
    let before = buf.len();
    match m4::Packet::read(&mut buf, MAX) {
        Ok(p) => {
            let used = before - buf.len();
            let (n, pid) = match &p {
                m4::Packet::Connect(_) => ("CONNECT", 0),
                m4::Packet::ConnAck(_) => ("CONNACK", 0),
                m4::Packet::Publish(x) => ("PUBLISH", x.pkid),
                m4::Packet::PubAck(x) => ("PUBACK", x.pkid),
                m4::Packet::PubRec(x) => ("PUBREC", x.pkid),
                m4::Packet::PubRel(x) => ("PUBREL", x.pkid),
                m4::Packet::PubComp(x) => ("PUBCOMP", x.pkid),
                m4::Packet::Subscribe(x) => ("SUBSCRIBE", x.pkid),
                m4::Packet::SubAck(x) => ("SUBACK", x.pkid),
                m4::Packet::Unsubscribe(x) => ("UNSUBSCRIBE", x.pkid),
                m4::Packet::UnsubAck(x) => ("UNSUBACK", x.pkid),
                m4::Packet::PingReq => ("PINGREQ", 0),
                m4::Packet::PingResp => ("PINGRESP", 0),
                m4::Packet::Disconnect => ("DISCONNECT", 0),
            };
            format!("{id} ok {n} {used} {pid}")
        }
        Err(rumqttc::mqttbytes::Error::InsufficientBytes(_)) => format!("{id} incomplete - 0 0"),
        Err(e) => format!("{id} reject - 0 0 {e:?}"),
    }
}

fn v5(id: usize, pkt: &[u8]) -> String {
    let mut buf = BytesMut::from(pkt);
    let before = buf.len();
    match m5::Packet::read(&mut buf, Some(MAX as u32)) {
        Ok(p) => {
            let used = before - buf.len();
            let (n, pid) = match &p {
                m5::Packet::Connect(..) => ("CONNECT", 0),
                m5::Packet::ConnAck(_) => ("CONNACK", 0),
                m5::Packet::Publish(x) => ("PUBLISH", x.pkid),
                m5::Packet::PubAck(x) => ("PUBACK", x.pkid),
                m5::Packet::PubRec(x) => ("PUBREC", x.pkid),
                m5::Packet::PubRel(x) => ("PUBREL", x.pkid),
                m5::Packet::PubComp(x) => ("PUBCOMP", x.pkid),
                m5::Packet::Subscribe(x) => ("SUBSCRIBE", x.pkid),
                m5::Packet::SubAck(x) => ("SUBACK", x.pkid),
                m5::Packet::Unsubscribe(x) => ("UNSUBSCRIBE", x.pkid),
                m5::Packet::UnsubAck(x) => ("UNSUBACK", x.pkid),
                m5::Packet::PingReq(_) => ("PINGREQ", 0),
                m5::Packet::PingResp(_) => ("PINGRESP", 0),
                m5::Packet::Disconnect(_) => ("DISCONNECT", 0),
                m5::Packet::Auth(_) => ("AUTH", 0),
            };
            format!("{id} ok {n} {used} {pid}")
        }
        Err(rumqttc::v5::mqttbytes::Error::InsufficientBytes(_)) => format!("{id} incomplete - 0 0"),
        Err(e) => format!("{id} reject - 0 0 {e:?}"),
    }
}

fn main() {
    let path = std::env::args().nth(1).expect("vectors.bin");
    let data = std::fs::read(path).expect("read");
    let out = std::io::stdout();
    let mut w = std::io::BufWriter::new(out.lock());
    let (mut pos, mut id) = (0usize, 0usize);
    while pos + 5 <= data.len() {
        let ver = data[pos];
        let n = u32::from_be_bytes([data[pos + 1], data[pos + 2], data[pos + 3], data[pos + 4]]) as usize;
        let pkt = &data[pos + 5..pos + 5 + n];
        let line = std::panic::catch_unwind(|| if ver == 4 { v4(id, pkt) } else { v5(id, pkt) })
            .unwrap_or_else(|_| format!("{id} panic - 0 0"));
        writeln!(w, "{line}").unwrap();
        pos += 5 + n;
        id += 1;
    }
}
