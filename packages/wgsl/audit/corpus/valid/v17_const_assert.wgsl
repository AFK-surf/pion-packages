// const_assert at module and function scope.
const N = 4;
const_assert N > 2;
@compute @workgroup_size(1)
fn cs_main() {
  const_assert N == 4;
}
