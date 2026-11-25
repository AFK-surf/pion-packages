fn main {
  let n = 2500
  let mut num = 1N
  let mut acc = 0N
  let mut den = 1N
  let three = 3N
  let four = 4N
  let ten = 10N
  let mut k = 0
  let mut i = 0
  let mut line = StringBuilder::new()
  let mut col = 0
  while i < n {
    k = k + 1
    let k2 = k * 2 + 1
    acc = (acc + (num << 1)) * BigInt::from_int(k2)
    den = den * BigInt::from_int(k2)
    num = num * BigInt::from_int(k)
    if num > acc {
      continue
    }
    let d3 = ((num * three + acc) / den).to_int()
    let d4 = ((num * four + acc) / den).to_int()
    if d3 != d4 {
      continue
    }
    line.write_char(Int::unsafe_to_char(48 + d3))
    col = col + 1
    i = i + 1
    if col == 10 {
      println(line.to_string() + "\t:" + i.to_string())
      line = StringBuilder::new()
      col = 0
    }
    acc = (acc - den * BigInt::from_int(d3)) * ten
    num = num * ten
  }
  if col > 0 {
    while col < 10 {
      line.write_char(' ')
      col = col + 1
    }
    println(line.to_string() + "\t:" + i.to_string())
  }
}
