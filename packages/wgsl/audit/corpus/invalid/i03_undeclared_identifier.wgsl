// Reference to an identifier that is declared nowhere.
@group(0) @binding(0) var<storage, read_write> o : array<f32>;
@compute @workgroup_size(1) fn cs_main() { o[0] = not_declared; }
