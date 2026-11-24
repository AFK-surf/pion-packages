// The full WGSL atomic builtin set.
struct Counters { a : atomic<u32>, b : atomic<i32> }
@group(0) @binding(0) var<storage, read_write> c : Counters;
var<workgroup> wg : atomic<u32>;
@compute @workgroup_size(64)
fn cs_main(@builtin(local_invocation_index) li : u32) {
  atomicStore(&wg, 0u);
  workgroupBarrier();
  let x = atomicAdd(&c.a, 1u);
  let y = atomicSub(&c.a, 1u);
  let z = atomicMax(&c.b, 3);
  let w = atomicMin(&c.b, -3);
  let p = atomicAnd(&c.a, 0xffu);
  let q = atomicOr(&c.a, 1u);
  let r = atomicXor(&c.a, 2u);
  let s = atomicExchange(&wg, li);
  let t = atomicCompareExchangeWeak(&c.a, 0u, 1u);
  let u = atomicLoad(&wg);
}
