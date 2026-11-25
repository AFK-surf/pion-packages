fn main {
  let mut a = 0xdeadbeefcafebabe0123456789abcdef112233445566778899aabbccddeeff01N
  let mut b = 0x80000000ffffffff123456789abcdef0fedcba9876543210N
  a = a * a + 17N
  b = b * b + 31N
  let mut acc = 0N
  let mut i = 0
  while i < 2000 {
    let prod = a * b
    let div = b + BigInt::from_int(i + 1)
    let q = prod / div
    let r = prod % div
    acc = acc + q - r
    if (i & 7) == 0 {
      a = a + BigInt::from_int(i * 13 + 7)
      b = b + BigInt::from_int(i * 7 + 3)
    }
    i = i + 1
  }
  println(acc.to_string())
}
