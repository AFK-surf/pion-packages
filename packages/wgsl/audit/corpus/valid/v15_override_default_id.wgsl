// Pipeline-overridable constants with @id and default values.
@id(0) override scale : f32 = 2.0;
@id(1) override enabled : bool = true;
override bias = 0.5;
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1)
fn cs_main() {
  if enabled {
    o[0] = scale + bias;
  }
}
