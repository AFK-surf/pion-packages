#!/usr/bin/env python3
"""Run WGSL compute shaders on the local Metal GPU twice: compiled by packages/wgsl and by Rust naga =24.0.0,
with identical buffers bound at `group * 8 + binding`. Each case also carries the result the WGSL spec
mandates; naga must reproduce it (control) and packages/wgsl must match it (finding when it does not).

usage: gpu_judge.py <corpus_valid_dir> <pion_driver> <naga_oracle> <gpurun> <out_dir>
Exit 1 when a control fails or packages/wgsl deviates from the spec on any case."""
import os
import struct
import subprocess
import sys

corpus, pion, naga, gpurun, out = sys.argv[1:6]
os.makedirs(out, exist_ok=True)


def i32(*v):
    return struct.pack("<%di" % len(v), *v)


def u32(*v):
    return struct.pack("<%dI" % len(v), *v)


def f32(*v):
    return struct.pack("<%df" % len(v), *v)


# name, wgsl file, threads, {slot: initial bytes}, runtime-array sizes (buffer 30), {slot: expected bytes}, what
CASES = [
    ("double_negation", "v07_double_negation.wgsl", 1, {0: i32(5, 0, 0)}, [12], {0: i32(5, 5, 5)},
     "`- -x` must equal x and leave x unchanged"),
    ("array_length", "v10_array_length.wgsl", 1,
     {0: u32(0) + f32(*([0.0] * 16)), 1: u32(*([0] * 8)), 2: u32(0, 0)}, [68, 32, 8],
     {2: u32(16, 8)}, "arrayLength of a 16-element struct tail array and an 8-element array"),
    ("loop_continue_runs_continuing", "v18_loop_continuing_continue.wgsl", 1, {0: u32(0, 0)}, [8], {0: u32(3, 4)},
     "`continue` in `loop` must execute the `continuing` block"),
    ("vec3_struct_layout", "v21_vec3_layout.wgsl", 1, {0: f32(*([0.0] * 8))}, [32],
     {0: f32(0, 0, 0, 7, 1, 2, 3, 0)}, "struct { a: vec3<f32>, b: f32 } is 16 bytes with b at offset 12"),
    ("size_attribute_layout", "v22_size_align_attrs.wgsl", 1, {0: f32(*([0.0] * 6))}, [24],
     {0: f32(0, 0, 0, 0, 0, 5)}, "@size(20) on the first field puts b at byte 20"),
    ("round_half_to_even", "v42_round_half_even.wgsl", 1, {0: f32(2.5, 0, 0, 0)}, [16],
     {0: f32(2.5, 2.0, -2.0, 0.0)}, "round(2.5) == 2, round(0.5) == 0"),
    ("select_order_control", "v14_select_vector.wgsl", 1, {0: f32(0, 0, 0, 0)}, [16], {0: f32(10, 2, 5, 0)},
     "select(f, t, c) picks t where c is true"),
    ("ptr_params_control", "v20_ptr_params.wgsl", 1, {0: f32(0)}, [4], {0: f32(4)},
     "writes through ptr<function>/ptr<private> parameters are visible to the caller"),
    ("matrix_control", "v24_matrix.wgsl", 1, {0: f32(0, 9)}, [8], {0: f32(15, 0)},
     "column-major matrix indexing / transpose / mat*vec"),
    ("workgroup_zero_init", "v34_uninitialized_vars.wgsl", 1, {0: u32(0xDEAD)}, [4], {0: u32(0)},
     "function/private/workgroup variables start at zero"),
]


def run(metal, sizes, bufs):
    args = [gpurun, metal, "cs_main", "1"]
    for slot, data in sorted(bufs.items()):
        args.append("%d=%s" % (slot, data.hex()))
    args.append("30=%s" % u32(*sizes).hex())
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        return None, "TIMEOUT"
    if r.returncode != 0 or r.stdout.startswith("ERROR"):
        return None, (r.stdout + r.stderr).strip().splitlines()[0][:160]
    res = {}
    for line in r.stdout.split():
        k, v = line.split("=")
        res[int(k)] = bytes.fromhex(v)
    return res, ""


def fmt(b, like):
    n = len(b) // 4
    code = "f" if isinstance(like, float) else "i"
    return list(struct.unpack("<%d%s" % (n, code), b))


bad = 0
for name, wgsl, _threads, bufs, sizes, expect, what in CASES:
    src = os.path.join(corpus, wgsl)
    pm, nm = os.path.join(out, name + ".pion.metal"), os.path.join(out, name + ".naga.metal")
    rp = subprocess.run([pion, "msl", src, pm], capture_output=True, text=True)
    rn = subprocess.run([naga, "msl", src, nm], capture_output=True, text=True)
    nres, nerr = run(nm, sizes, bufs) if rn.returncode == 0 else (None, rn.stdout.strip())
    pres, perr = run(pm, sizes, bufs) if rp.returncode == 0 else (None, "pion " + rp.stdout.strip())
    ctrl_ok = nres is not None and all(nres[s] == e for s, e in expect.items())
    pion_ok = pres is not None and all(pres[s] == e for s, e in expect.items())
    is_float = name in ("vec3_struct_layout", "size_attribute_layout", "round_half_to_even",
                                                  "select_order_control", "ptr_params_control", "matrix_control")
    like = 0.0 if is_float else 0
    if not ctrl_ok:
        bad += 1
        print("  CONTROL-FAIL %-32s naga: %s" % (name, nerr or {s: fmt(nres[s], like) for s in expect}))
    if pion_ok:
        print("  PASS %-32s %s" % (name, what))
    else:
        bad += 1
        got = perr or "; ".join("slot%d=%s" % (s, fmt(pres[s], like)) for s in expect)
        want = "; ".join("slot%d=%s" % (s, fmt(e, like)) for s, e in expect.items())
        print("  FAIL %-32s %s\n       expected %s\n       pion     %s" % (name, what, want, got))
sys.exit(1 if bad else 0)
