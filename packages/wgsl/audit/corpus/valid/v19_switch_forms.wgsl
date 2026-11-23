// switch with `case x, default`, braces-only cases and `break` inside a loop inside a case.
@group(0) @binding(0) var<storage, read_write> o : array<i32>;
@compute @workgroup_size(1)
fn cs_main() {
  let x = o[0];
  switch x {
    case 1, 2 { o[1] = 12; }
    case 3, default { o[1] = 99; }
  }
  switch (x) {
    case 0: { o[2] = 0; }
    default: { o[2] = -1; }
  }
}
