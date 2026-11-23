"""Hand-written red-team vectors for packages/wasm.

Each case: (name, spec_expectation, bytes, note)
  spec_expectation: "valid" | "invalid"  -- per the WebAssembly 2.0 specification
  (the oracles -- wasmparser 0.221.3 with WasmFeatures::WASM2 and V8 -- are recorded
  next to Pion's verdict by run_audit.sh, so every expectation below is cross-checked).
"""
from wasmgen import *  # noqa: F401,F403

V = v128c()


def simd_body(*ops):
    return b"".join(ops) + b"\x0b"


def cases():
    out = []

    def add(name, expect, data, note):
        out.append((name, expect, data, note))

    # ---------------------------------------------------------------- ref.func declaration (C.refs)
    add("ref_func_undeclared", "invalid",
        single_func(b"\xd2\x00\x0b", results=[FUNCREF]),
        "ref.func 0 in a body without any elem/global/export declaring func 0")
    add("ref_func_declared_by_elem", "valid",
        single_func(b"\xd2\x00\x0b", results=[FUNCREF],
                    elems=[u32(3) + b"\x00" + vec([u32(0)])]),
        "control: `(elem declare func 0)` declares func 0")
    add("ref_func_declared_by_export", "valid",
        single_func(b"\xd2\x00\x0b", results=[FUNCREF], exports=[export("f", 0, 0)]),
        "control: exporting func 0 declares it")

    # ---------------------------------------------------------------- table.init element type
    tinit = i32c(0) + i32c(0) + i32c(0) + b"\xfc\x0c\x00\x00" + b"\x0b"
    passive_funcref = [u32(1) + b"\x00" + vec([u32(0)])]
    add("table_init_externref_table_from_funcref_elem", "invalid",
        single_func(tinit, tables=[table_type(EXTERNREF, 1)], elems=passive_funcref),
        "table.init copies funcref elements into an externref table (type confusion)")
    add("table_init_funcref_ok", "valid",
        single_func(tinit, tables=[table_type(FUNCREF, 1)], elems=passive_funcref),
        "control: same with funcref table")

    # ---------------------------------------------------------------- SIMD operator arity table
    add("simd_avgr_u_one_operand", "invalid",
        single_func(simd_body(V, simd(0x7B), b"\x1a")),
        "i8x16.avgr_u is binary [v128 v128]->[v128]; one operand must be rejected")
    add("simd_avgr_u_two_operands", "valid",
        single_func(simd_body(V, V, simd(0x7B), b"\x1a")),
        "control: i8x16.avgr_u with two operands")
    add("simd_f64x2_nearest_one_operand", "valid",
        single_func(simd_body(V, simd(0x94), b"\x1a")),
        "f64x2.nearest is unary [v128]->[v128]")
    add("simd_f64x2_nearest_two_operands", "invalid",
        single_func(simd_body(V, V, simd(0x94), b"\x1a")),
        "f64x2.nearest consumes one operand; the second one is left on the stack")
    for op in (0x9A, 0xA2, 0xA5, 0xA6, 0xAF, 0xB0, 0xB2, 0xB3, 0xB4, 0xBB,
               0xC2, 0xC5, 0xC6, 0xCF, 0xD0, 0xD2, 0xD3, 0xD4, 0xE2, 0xEE):
        add(f"simd_unassigned_0x{op:02x}", "invalid",
            single_func(simd_body(V, V, simd(op), b"\x1a")),
            f"0xFD {op:#x} is not an assigned SIMD opcode")

    # ---------------------------------------------------------------- limits flags outside 2.0
    add("memory64_flag", "invalid",
        module(mems=[b"\x04" + u32(1)]),
        "limits flag 0x04 (memory64 proposal) is not WebAssembly 2.0")
    add("memory64_huge_min", "invalid",
        module(mems=[b"\x04" + s64(1 << 40)]),
        "memory64 with 2^40 pages: Pion skips the page-count check entirely for memory64")
    add("memory_shared_flag", "invalid",
        module(mems=[b"\x03" + u32(1) + u32(1)]),
        "limits flag 0x03 (threads shared memory) is not WebAssembly 2.0")
    add("table_shared_flag", "invalid",
        module(tables=[bytes([FUNCREF]) + b"\x03" + u32(1) + u32(1)]),
        "shared *table* -- not in any shipped proposal")
    add("import_table_shared_flag", "invalid",
        module(imports=[import_table("m", "t", bytes([FUNCREF]) + b"\x03" + u32(1) + u32(1))]),
        "imported shared table")
    add("memarg_multimemory_bit", "invalid",
        single_func(i32c(0) + b"\x28" + u32(0x42) + u32(0) + u32(0) + b"\x1a\x0b", mem=True),
        "memarg align field with bit 6 (multi-memory encoding) is invalid alignment in 2.0")
    add("memory_size_nonzero_reserved_leb", "invalid",
        single_func(b"\x3f\x80\x00\x1a\x0b", mem=True),
        "memory.size reserved byte must be the single byte 0x00 in 2.0")
    add("memory_fill_nonzero_reserved_leb", "valid",
        single_func(i32c(0) + i32c(0) + i32c(0) + b"\xfc\x0b\x80\x00\x0b", mem=True),
        "fairness: wasmparser and V8 accept a LEB memory index on bulk-memory ops; Pion agrees")

    # ---------------------------------------------------------------- polymorphic stack
    meet_bottom = (b"\x02\x7c"            # block (result f64)
                   b"\x02\x7d"            #   block (result f32)
                   b"\x00"                #     unreachable
                   + i32c(1) +
                   b"\x0e\x02\x00\x01\x01"  # br_table 0 1 1
                   b"\x0b\x1a"            #   end drop
                   + f64c(0) +
                   b"\x0b\x1a\x0b")
    add("br_table_meet_bottom", "valid", single_func(meet_bottom),
        "spec test unreached-valid.wast `meet-bottom`: br_table to f32 and f64 labels on a bottom stack")
    add("br_table_mixed_types_reachable", "invalid",
        single_func(b"\x02\x7c\x02\x7d" + f32c(0) + i32c(1) + b"\x0e\x01\x00\x01\x0b\x1a" + f64c(0) +
                    b"\x0b\x1a\x0b"),
        "control: same br_table with a concrete f32 operand")
    add("select_untyped_funcref_after_unreachable", "invalid",
        single_func(b"\x00\xd0\x70\xd0\x70" + i32c(0) + b"\x1b\x1a\x0b"),
        "control: untyped select on funcref operands")
    add("select_untyped_bottom_valid", "valid",
        single_func(b"\x00\x1b\x1a\x0b"),
        "control: untyped select on fully polymorphic stack")
    add("if_no_else_params", "valid",
        module(types=[([], []), ([I32], [I32])], funcs=[0],
               codes=[code_entry(i32c(7) + i32c(1) + b"\x04\x01\x0b\x1a\x0b")]),
        "control: if (type [i32]->[i32]) without else")
    add("loop_br_params", "valid",
        module(types=[([], []), ([I32], [])], funcs=[0],
               codes=[code_entry(i32c(0) + b"\x03\x01" + i32c(1) + b"\x0d\x00\x1a\x0b\x0b")]),
        "control: br_if to a loop label carries the loop params")

    # ---------------------------------------------------------------- const exprs
    add("const_global_get_local_global", "invalid",
        module(globals_=[global_entry(I32, False, i32c(1) + b"\x0b"),
                         global_entry(I32, False, b"\x23\x00\x0b")]),
        "control: global.get of a module-defined global in a const expr")
    add("const_global_get_mut_import", "invalid",
        module(imports=[import_global("m", "g", I32, True)],
               globals_=[global_entry(I32, False, b"\x23\x00\x0b")]),
        "control: global.get of a mutable import")

    # ---------------------------------------------------------------- limits / structure controls
    add("two_memories", "invalid", module(mems=[limits(1), limits(1)]), "control")
    add("memory_too_big", "invalid", module(mems=[limits(65537)]), "control")
    add("table_min_gt_max", "invalid", module(tables=[table_type(FUNCREF, 2, 1)]), "control")
    add("data_count_mismatch", "invalid",
        module(mems=[limits(1)], datacount=2, data=[b"\x01" + vec([])]), "control")
    add("memory_init_without_datacount", "invalid",
        single_func(i32c(0) + i32c(0) + i32c(0) + b"\xfc\x08\x00\x00\x0b", mem=True,
                    data=[b"\x01" + vec([])]), "control")
    add("dup_export", "invalid",
        single_func(b"\x0b", exports=[export("a", 0, 0), export("a", 0, 0)]), "control")
    add("export_overlong_utf8", "invalid",
        single_func(b"\x0b", exports=[export(b"\xc0\x80", 0, 0)]), "control")
    add("export_surrogate_utf8", "invalid",
        single_func(b"\x0b", exports=[export(b"\xed\xa0\x80", 0, 0)]), "control")
    add("start_with_params", "invalid",
        module(types=[([I32], [])], funcs=[0], start=0, codes=[code_entry(b"\x0b")]), "control")
    add("shuffle_lane_32", "invalid",
        single_func(V + V + simd(13) + bytes([32] + [0] * 15) + b"\x1a\x0b"), "control")
    add("extract_lane_16", "invalid",
        single_func(V + simd(21) + b"\x10" + b"\x1a\x0b"), "control")
    add("load8_align_1", "invalid",
        single_func(i32c(0) + b"\x2c" + memarg(1) + b"\x1a\x0b", mem=True), "control")
    add("v128_load_align_5", "invalid",
        single_func(i32c(0) + simd(0) + memarg(5) + b"\x1a\x0b", mem=True), "control")
    add("func_code_count_mismatch", "invalid",
        module(types=[([], [])], funcs=[0, 0], codes=[code_entry(b"\x0b")]), "control")
    add("body_trailing_bytes", "invalid",
        module(types=[([], [])], funcs=[0], codes=[u32(3) + b"\x00\x0b\x01"]), "control")
    add("local_count_bomb", "invalid",
        module(types=[([], [])], funcs=[0], codes=[code_entry(b"\x0b", [(0xFFFFFFFF, I32)])]),
        "control: one local group with count 0xFFFFFFFF must fail fast, no allocation")

    # ---------------------------------------------------------------- integer-overflow length fields
    add("data_len_2gib", "invalid",
        module(mems=[limits(1)], data=[b"\x00" + i32c(0) + b"\x0b" + u32(0x7FFFFFFF)]),
        "data segment declares 2 GiB - 1 of payload in a ~40 B file")
    add("custom_name_len_2gib", "invalid",
        b"\x00asm\x01\x00\x00\x00" + b"\x00\x06" + u32(0x7FFFFFF0) + b"\x00",
        "custom section name length 2^31-16 inside a 6-byte section")
    add("export_name_len_2gib", "invalid",
        module(raw_sections=[(7, u32(1) + u32(0x7FFFFFF0) + b"\x00\x00")]),
        "export name length 2^31-16")
    add("import_name_len_2gib", "invalid",
        module(raw_sections=[(2, u32(1) + u32(0x7FFFFFF0) + b"\x00\x00")]),
        "import module-name length 2^31-16")
    add("passive_data_len_2gib", "invalid",
        b"\x00asm\x01\x00\x00\x00" + section(11, u32(2) + b"\x01" + u32(0x7FFFFFFF)),
        "2 passive data segments, first one 2^31-1 long (minimised from a fuzzer-found abort)")
    add("section_len_2gib", "invalid",
        b"\x00asm\x01\x00\x00\x00" + b"\x01" + u32(0x7FFFFFFF) + b"\x00",
        "type section declares 2 GiB in a 14-byte file")
    add("code_body_len_2gib", "invalid",
        module(types=[([], [])], funcs=[0], raw_sections=[(10, u32(1) + u32(0x7FFFFFF0) + b"\x00\x0b")]),
        "code body size 2^31-16")

    # ---------------------------------------------------------------- implementation limits (valid modules)
    deep = 5000
    add("nested_blocks_5000", "valid",
        single_func(b"\x02\x40" * deep + b"\x0b" * deep + b"\x0b"),
        "5,000 nested blocks: valid; wasmparser has no nesting limit")
    add("stack_height_70000", "valid",
        single_func(i32c(0) * 70000 + b"\x1a" * 70000 + b"\x0b"),
        "70,000 live operands then dropped: valid")
    add("instrs_1_2m", "valid",
        single_func(b"\x01" * 1_200_000 + b"\x0b"),
        "1.2 M `nop` (1.2 MB body, below wasmparser's 7,654,321 B function size limit)")
    add("locals_params_plus_locals_50005", "invalid",
        module(types=[([I32] * 10, [])], funcs=[0],
               codes=[code_entry(b"\x0b", [(49995, I32)])]),
        "10 params + 49,995 locals = 50,005 > 50,000 (wasmparser & V8 count params)")

    # ---------------------------------------------------------------- WAT printer stress (all valid)
    add("wat_export_names_escapes", "valid",
        single_func(b"\x0b", exports=[export(nm, 0, 0) for nm in
                                      ["q\"uote", "back\\slash", "nl\nx", "tab\tx", "\u00e9\u4e2d\U0001f600",
                                       "nul\u0000x", "del\u007f", "", " "]]),
        "export names with quote, backslash, control chars, NUL, DEL, empty, non-ASCII")
    add("wat_float_specials", "valid",
        single_func(b"".join(f32c(x) + b"\x1a" for x in
                             [0, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000, 0xFFC00000, 0x7F800001,
                              0x7FBFFFFF, 0x00000001, 0x807FFFFF, 0x7F7FFFFF, 0x3F800000]) +
                    b"".join(f64c(x) + b"\x1a" for x in
                             [0, 1 << 63, 0x7FF0000000000000, 0xFFF0000000000000, 0x7FF8000000000000,
                              0x7FF0000000000001, 0xFFFFFFFFFFFFFFFF, 1, 0x800FFFFFFFFFFFFF,
                              0x7FEFFFFFFFFFFFFF]) + b"\x0b"),
        "f32/f64 +-0, +-inf, canonical/arithmetic/signalling NaN payloads, subnormal, max")
    add("wat_int_extremes", "valid",
        single_func(i32c(-0x80000000) + b"\x1a" + i32c(0x7FFFFFFF) + b"\x1a" + i64c(-(1 << 63)) + b"\x1a" +
                    i64c((1 << 63) - 1) + b"\x1a\x0b"), "i32/i64 min and max")
    add("wat_data_all_bytes", "valid",
        module(mems=[limits(1)], data=[b"\x00" + i32c(0) + b"\x0b" + vec(bytes([x]) for x in range(256)),
                                       b"\x01" + vec([b"\x00"])]),
        "active data with every byte 0..255 plus a passive segment")
    add("wat_elem_forms", "valid",
        module(types=[([], [])], funcs=[0, 0],
               tables=[table_type(FUNCREF, 4), table_type(FUNCREF, 4), table_type(EXTERNREF, 1)],
               elems=[u32(0) + i32c(0) + b"\x0b" + vec([u32(0)]),
                      u32(1) + b"\x00" + vec([u32(1)]),
                      u32(2) + u32(1) + i32c(1) + b"\x0b" + b"\x00" + vec([u32(0), u32(1)]),
                      u32(3) + b"\x00" + vec([u32(0)]),
                      u32(4) + i32c(2) + b"\x0b" + vec([b"\xd2\x01\x0b", b"\xd0\x70\x0b"]),
                      u32(5) + bytes([EXTERNREF]) + vec([b"\xd0\x6f\x0b"]),
                      u32(6) + u32(2) + i32c(0) + b"\x0b" + bytes([EXTERNREF]) + vec([b"\xd0\x6f\x0b"]),
                      u32(7) + bytes([FUNCREF]) + vec([b"\xd2\x00\x0b"])],
               codes=[code_entry(b"\x0b"), code_entry(b"\x0b")]),
        "all eight element segment encodings (flags 0..7)")
    add("wat_imports_all_kinds", "valid",
        module(types=[([I32], [I64])],
               imports=[import_func("a b", "c\"d", 0), import_table("t", "", table_type(EXTERNREF, 0, 7)),
                        import_mem("m", "mem", limits(1, 3)), import_global("g", "v", V128, False),
                        import_global("g", "m", FUNCREF, True)]),
        "imports of every kind with odd names")
    add("wat_control_multivalue", "valid",
        module(types=[([], []), ([I32, I64], [I32, I64])], funcs=[0],
               tables=[table_type(FUNCREF, 1), table_type(FUNCREF, 1)],
               codes=[code_entry(i32c(1) + i64c(2) + b"\x02\x01\x1a\x1a" + i32c(4) + i64c(3) + b"\x0b\x1a\x1a" +
                                 b"\x02\x40\x02\x40" + i32c(1) + b"\x0e\x02\x00\x01\x00\x0b\x0b" +
                                 i32c(1) + i64c(2) + i32c(0) + b"\x04\x01\x05\x0b\x1a\x1a" +
                                 i32c(1) + i64c(2) + i32c(0) + b"\x11\x01\x01\x1a\x1a" +
                                 b"\xd0\x70\xd0\x70" + i32c(1) + b"\x1c\x01\x70\x1a\x0b")]),
        "multi-value block/if with type index, br_table, call_indirect on table 1, typed select")
    add("wat_simd_lane_align0", "valid",
        single_func(i32c(0) + V + simd(0x55) + memarg(0) + b"\x07\x1a" + i32c(0) + V + simd(0x56) + memarg(0) +
                    b"\x03\x1a" + i32c(0) + V + simd(0x5B) + memarg(1) + b"\x01\x0b", mem=True),
        "v128.load16_lane / load32_lane / store64_lane with alignment below natural")
    add("wat_memargs", "valid",
        single_func(i32c(0) + b"\x28" + memarg(0, 0xFFFFFFFF) + b"\x1a" + i32c(0) + b"\x29" + memarg(1, 7) +
                    b"\x1a" + i32c(0) + simd(0) + memarg(0, 16) + b"\x1a\x0b", mem=True),
        "memargs with max offset, under-alignment and an under-aligned v128.load")

    # ---------------------------------------------------------------- per-opcode SIMD sweep (0xFD 0x00..0xFF)
    from gen_fuzz import SIMD, SIMD_MEM_NAT, SIMD_LANE, SIMD_MEMLANE  # noqa: E402
    consts = {I32: i32c(0), I64: i64c(0), F32: f32c(0), F64: f64c(0), V128: V}
    for sub in range(256):
        if sub in SIMD:
            ps, rs = SIMD[sub]
            body = b"".join(consts[t] for t in ps) + simd(sub) + b"\x1a" * len(rs) + b"\x0b"
            add(f"simd_sweep_{sub:#04x}", "valid", single_func(body, mem=True),
                f"0xFD {sub:#x} with its spec signature")
        elif sub in SIMD_MEM_NAT:
            body = i32c(0) + (V if sub == 11 else b"") + simd(sub) + memarg(0) + (b"" if sub == 11 else b"\x1a") + b"\x0b"
            add(f"simd_sweep_{sub:#04x}", "valid", single_func(body, mem=True), "SIMD memory op")
        elif sub in SIMD_LANE:
            n, pin, pout = SIMD_LANE[sub]
            body = V + (consts[pin] if pin else b"") + simd(sub) + bytes([n - 1]) + b"\x1a\x0b"
            add(f"simd_sweep_{sub:#04x}", "valid", single_func(body, mem=True), "SIMD lane op")
        elif sub in SIMD_MEMLANE:
            nat, n = SIMD_MEMLANE[sub]
            body = i32c(0) + V + simd(sub) + memarg(nat) + bytes([n - 1]) + (b"" if sub >= 88 else b"\x1a") + b"\x0b"
            add(f"simd_sweep_{sub:#04x}", "valid", single_func(body, mem=True), "SIMD lane memory op")
        elif sub in (12, 13):
            continue
        else:
            add(f"simd_sweep_{sub:#04x}", "invalid", single_func(V + V + simd(sub) + b"\x1a\x0b", mem=True),
                "unassigned SIMD opcode")
    return out
