// arrayLength on a top-level runtime array and on a struct's trailing runtime array.
struct Data { count : u32, values : array<f32> }
@group(0) @binding(0) var<storage, read_write> data : Data;
@group(0) @binding(1) var<storage, read_write> flat : array<u32>;
@group(0) @binding(2) var<storage, read_write> o : array<u32>;
@compute @workgroup_size(1)
fn cs_main() {
  o[0] = arrayLength(&data.values);
  o[1] = arrayLength(&flat);
}
