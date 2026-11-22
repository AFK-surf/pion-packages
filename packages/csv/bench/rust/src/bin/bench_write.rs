fn build_template_rows() -> Vec<[String; 8]> {
    let cities = [
        "Tokyo", "San Francisco", "New York", "London", "Paris",
        "Berlin", "Shanghai", "Zürich", "São Paulo", "München",
    ];
    let depts = [
        "Engineering", "Research & Dev", "Sales, EMEA", "Product \"Core\"",
        "Operations", "Finance", "Security", "Design",
    ];
    let notes = [
        "Active account",
        "VIP, priority support",
        "Quoted \"nickname\" inside",
        "Multi-line\naddress note",
        "UTF-8 备注：东京分部",
        "Standard tier 2026",
        "Needs review, Q4",
        "OK",
    ];
    let mut rows = Vec::with_capacity(2000);
    for i in 0..2000usize {
        let city = cities[i % cities.len()].to_string();
        let dept = depts[(i * 3) % depts.len()].to_string();
        let note = notes[(i * 7) % notes.len()].to_string();
        let salary = (65000 + (i * 37) % 140000).to_string();
        let score = format!("{}.50", (i * 13) % 100);
        let active = if i % 3 != 0 { "true" } else { "false" }.to_string();
        let id = (i + 1).to_string();
        let name = format!("User_{}", id);
        rows.push([id, name, city, dept, salary, score, active, note]);
    }
    rows
}

fn main() {
    let rows = build_template_rows();
    let mut total_bytes: i64 = 0;
    let mut hash: i64 = 0;
    let mut first_line = String::new();

    for round in 0..2 {
        let buf = Vec::with_capacity(18_000_000);
        let mut wtr = csv::WriterBuilder::new().from_writer(buf);
        wtr.write_record(["id", "name", "city", "department", "salary", "score", "active", "note"])
            .unwrap();
        for _rep in 0..100 {
            for row in &rows {
                wtr.write_record(row).unwrap();
            }
        }
        let out = wtr.into_inner().unwrap();
        total_bytes += out.len() as i64;
        if round == 0 {
            first_line = String::from_utf8(out[..80].to_vec()).unwrap();
        }
        for &b in &out {
            hash = (hash * 131 + b as i64) & 0x7FFF_FFFF;
        }
    }

    println!("bytes={}", total_bytes);
    println!("hash={}", hash);
    println!("head={}", first_line);
}
