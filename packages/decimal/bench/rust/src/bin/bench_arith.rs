use rust_decimal::Decimal;

#[inline(always)]
fn lo64(d: Decimal) -> u64 {
    let b = d.serialize();
    u64::from_le_bytes([b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11]])
}

fn main() {
    let n: i64 = 400_000;
    let tax_rate = Decimal::new(825, 4);
    let mut grand_total = Decimal::ZERO;
    let mut last_rounded = Decimal::ZERO;
    let mut checksum: u64 = 14695981039346656037;

    for i in 0..n {
        let price_cents = (i * 7919 + 1003) % 500_000 + 100;
        let qty_val = (i * 17 + 1) % 25 + 1;
        let disc_cents = (i * 31) % 500;

        let price = Decimal::new(price_cents, 2);
        let qty = Decimal::from(qty_val);
        let discount = Decimal::new(disc_cents, 2);

        let subtotal = price.checked_mul(qty).unwrap();
        let tax = subtotal.checked_mul(tax_rate).unwrap();
        let gross = subtotal.checked_add(tax).unwrap();
        let net = gross.checked_sub(discount).unwrap();
        let unit = net.checked_div(qty).unwrap();
        let rounded = unit.round_dp(2);

        grand_total = grand_total.checked_add(rounded).unwrap();
        checksum = (checksum ^ lo64(rounded)).wrapping_mul(1099511628211);
        last_rounded = rounded;
    }

    println!("tx={n}");
    println!("ops={}", n * 5);
    println!("grand_total={grand_total}");
    println!("last_rounded={last_rounded}");
    println!("checksum={checksum}");
}
