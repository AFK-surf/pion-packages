//! RT-sfv oracle: Rust `sfv` =0.16.1 printing the shared dump format of ../model.py (see its docstring).
//!   sfv_audit_oracle dump <cases>   parse field lines (joined with ", "), typed dump + canonical serialization
//!   sfv_audit_oracle ser <vectors>  build the hand-written AST with sfv's validating constructors, serialize
use sfv::{
    BareItem, Date, Decimal, Dictionary, FieldType, InnerList, Integer, Item, Key, List, ListEntry, Parameters,
    Parser, Token,
};
use std::io::Write;

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect()
}

fn t_bare(b: &BareItem) -> String {
    match b {
        BareItem::Integer(v) => format!("i{}", i64::from(*v)),
        BareItem::Decimal(d) => format!("d{}", i64::from(d.as_integer_scaled_1000())),
        BareItem::String(s) => format!("s{}", hex(s.as_str().as_bytes())),
        BareItem::Token(t) => format!("t{}", hex(t.as_str().as_bytes())),
        BareItem::ByteSequence(v) => format!("b{}", hex(v)),
        BareItem::Boolean(v) => (if *v { "?1" } else { "?0" }).to_string(),
        BareItem::Date(d) => format!("@{}", i64::from(d.unix_seconds())),
        BareItem::DisplayString(s) => format!("%{}", hex(s.as_bytes())),
    }
}
fn t_params(p: &Parameters) -> String {
    p.iter().map(|(k, v)| format!(";{}={}", hex(k.as_str().as_bytes()), t_bare(v))).collect()
}
fn t_item(i: &Item) -> String {
    t_bare(&i.bare_item) + &t_params(&i.params)
}
fn t_entry(e: &ListEntry) -> String {
    match e {
        ListEntry::Item(i) => t_item(i),
        ListEntry::InnerList(il) => {
            let v: Vec<String> = il.items.iter().map(t_item).collect();
            format!("({}){}", v.join(" "), t_params(&il.params))
        }
    }
}

fn dump(typ: &str, raw: &[u8]) -> String {
    let p = Parser::new(raw);
    match typ {
        "item" => match p.parse::<Item>() {
            Ok(i) => format!("P {}\nS {}\n", t_item(&i), hex(i.serialize().as_bytes())),
            Err(_) => "ERR\n".into(),
        },
        "list" => match p.parse::<List>() {
            Ok(l) => {
                let v: Vec<String> = l.iter().map(t_entry).collect();
                format!("P {}\nS {}\n", v.join(","), hex(l.serialize().unwrap_or_default().as_bytes()))
            }
            Err(_) => "ERR\n".into(),
        },
        _ => match p.parse::<Dictionary>() {
            Ok(d) => {
                let v: Vec<String> =
                    d.iter().map(|(k, e)| format!("{}={}", hex(k.as_str().as_bytes()), t_entry(e))).collect();
                format!("P {}\nS {}\n", v.join(","), hex(d.serialize().unwrap_or_default().as_bytes()))
            }
            Err(_) => "ERR\n".into(),
        },
    }
}

// ---------------------------------------------------------------- typed AST -> sfv values (validating)
struct Tp<'a> {
    s: &'a [u8],
    i: usize,
}
type R<T> = Result<T, ()>;
impl Tp<'_> {
    fn peek(&self) -> u8 {
        *self.s.get(self.i).unwrap_or(&0)
    }
    fn hexrun(&mut self) -> Vec<u8> {
        let j = self.i;
        while matches!(self.peek(), b'0'..=b'9' | b'a'..=b'f') {
            self.i += 1;
        }
        unhex(std::str::from_utf8(&self.s[j..self.i]).unwrap())
    }
    fn intrun(&mut self) -> i64 {
        let j = self.i;
        if self.peek() == b'-' {
            self.i += 1;
        }
        while self.peek().is_ascii_digit() {
            self.i += 1;
        }
        std::str::from_utf8(&self.s[j..self.i]).unwrap().parse().unwrap()
    }
    fn int(&mut self) -> R<Integer> {
        Integer::try_from(self.intrun()).map_err(|_| ())
    }
    fn key(&mut self) -> R<Key> {
        let b = self.hexrun();
        Key::from_string(String::from_utf8(b).map_err(|_| ())?).map_err(|_| ())
    }
    fn bare(&mut self) -> R<BareItem> {
        let c = self.peek();
        self.i += 1;
        Ok(match c {
            b'i' => BareItem::Integer(self.int()?),
            b'd' => BareItem::Decimal(Decimal::from_integer_scaled_1000(self.int()?)),
            b'@' => BareItem::Date(Date::from_unix_seconds(self.int()?)),
            b'?' => {
                let v = self.peek() == b'1';
                self.i += 1;
                BareItem::Boolean(v)
            }
            b's' => {
                let b = self.hexrun();
                BareItem::String(sfv::String::from_string(String::from_utf8(b).map_err(|_| ())?).map_err(|_| ())?)
            }
            b't' => {
                let b = self.hexrun();
                BareItem::Token(Token::from_string(String::from_utf8(b).map_err(|_| ())?).map_err(|_| ())?)
            }
            b'b' => BareItem::ByteSequence(self.hexrun()),
            _ => BareItem::DisplayString(String::from_utf8(self.hexrun()).map_err(|_| ())?),
        })
    }
    fn params(&mut self) -> R<Parameters> {
        let mut p = Parameters::new();
        while self.peek() == b';' {
            self.i += 1;
            let k = self.key();
            self.i += 1; // '='
            let v = self.bare();
            p.insert(k?, v?); // IndexMap: a duplicate key keeps its first position, takes the last value
        }
        Ok(p)
    }
    fn item(&mut self) -> R<Item> {
        let b = self.bare();
        let p = self.params();
        Ok(Item { bare_item: b?, params: p? })
    }
    fn entry(&mut self) -> R<ListEntry> {
        if self.peek() == b'(' {
            self.i += 1;
            let mut items = Vec::new();
            let mut bad = false;
            while self.peek() != b')' {
                if !items.is_empty() || bad {
                    self.i += 1;
                }
                match self.item() {
                    Ok(it) => items.push(it),
                    Err(()) => bad = true,
                }
            }
            self.i += 1;
            let p = self.params()?;
            if bad {
                return Err(());
            }
            let mut il = InnerList::new(items);
            il.params = p;
            return Ok(ListEntry::InnerList(il));
        }
        Ok(ListEntry::Item(self.item()?))
    }
}

fn ser(typ: &str, t: &str) -> String {
    let mut p = Tp { s: t.as_bytes(), i: 0 };
    let out: R<String> = (|| match typ {
        "item" => Ok(p.item()?.serialize()),
        "list" => {
            let mut l = List::new();
            while p.i < p.s.len() {
                if !l.is_empty() {
                    p.i += 1;
                }
                l.push(p.entry()?);
            }
            Ok(l.serialize().unwrap_or_default())
        }
        _ => {
            let mut d = Dictionary::new();
            let mut first = true;
            while p.i < p.s.len() {
                if !first {
                    p.i += 1;
                }
                first = false;
                let k = p.key();
                p.i += 1;
                let e = p.entry();
                d.insert(k?, e?);
            }
            Ok(d.serialize().unwrap_or_default())
        }
    })();
    match out {
        Ok(s) => format!("S {}\n", hex(s.as_bytes())),
        Err(()) => "S ERR\n".into(),
    }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let data = std::fs::read(&a[2]).expect("read");
    let text = String::from_utf8(data).expect("utf-8 corpus");
    let mut o = std::io::BufWriter::new(std::io::stdout().lock());
    for line in text.split('\n') {
        if line.is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        write!(o, "={}\n", f[0]).unwrap();
        if a[1] == "dump" {
            let raw: Vec<Vec<u8>> = if f[2].is_empty() { vec![] } else { f[2].split(',').map(unhex).collect() };
            o.write_all(dump(f[1], &raw.join(&b", "[..])).as_bytes()).unwrap();
        } else {
            o.write_all(ser(f[1], f[2]).as_bytes()).unwrap();
        }
    }
}
