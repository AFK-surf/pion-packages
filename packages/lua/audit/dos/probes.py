#!/usr/bin/env python3
"""DoS / crash / limit-bypass probes for packages/lua, run in 4 modes (native dbg/rel, wasm32 dbg/rel).
usage: probes.py <bin_dir> <out_dir> [--only a,b] [--modes rel,dbg,wdbg,wrel] [--timeout 60]
Each probe runs under the *default* LuaLimits (fuel 5e7, depth 200, slots 16384, mem 32 MiB, out 1 MiB)
unless it names its own. A sandbox is expected to end every probe with `=> OK` or `=> ERR <LimitKind>`
in bounded time and bounded host memory; anything else (signal, wasm trap, timeout, multi-GB RSS,
wrong result) is a finding. Reports wall time and peak RSS (via /usr/bin/time -l)."""
import os, re, subprocess, sys, time, json

D = "lim 50000000 200 16384 33554432 1048576"  # == LuaLimits::default()
P = {}
def probe(name, src, lim=D, note=""):
    P[name] = (src, lim, note)

# --- arithmetic crash ---
probe("shl_minint", "print(pcall(function() return 1 << math.mininteger end))", note="lua_shl_i64(-b) overflow -> mutual recursion")
probe("shr_minint", "print(pcall(function() return 1 >> math.mininteger end))")
# --- metamethod / call recursion on host stack ---
probe("call_self_loop", "local t = setmetatable({}, {}); getmetatable(t).__call = t; print(pcall(t))", note="__call = t")
probe("call_chain_long", "local f = function() return 'end' end\nfor i = 1, 100000 do f = setmetatable({}, {__call = f}) end\nprint(pcall(f))")
probe("index_fn_recursion", "local t = setmetatable({}, {}); getmetatable(t).__index = function(s, k) return s[k] end\nprint(pcall(function() return t.x end))")
probe("tostring_recursion", "local t = setmetatable({}, {}); getmetatable(t).__tostring = function(s) return tostring(s) end\nprint(pcall(tostring, t))")
probe("eq_recursion", "local mt = {}; mt.__eq = function(a, b) return a == b end\nlocal a, b = setmetatable({}, mt), setmetatable({}, mt)\nprint(pcall(function() return a == b end))")
probe("lt_recursion", "local mt = {}; mt.__lt = function(a, b) return a < b end\nlocal a, b = setmetatable({}, mt), setmetatable({}, mt)\nprint(pcall(function() return a < b end))")
probe("concat_recursion", "local mt = {}; mt.__concat = function(a, b) return a .. b end\nlocal a = setmetatable({}, mt)\nprint(pcall(function() return a .. 'x' end))")
probe("pcall_nest_native", "local function f(n) if n == 0 then return 0 end return select(2, pcall(f, n - 1)) end\nprint(pcall(f, 100000))")
probe("sort_cmp_recursion", "local function cmp(a, b) table.sort({3, 2, 1}, cmp); return a < b end\nprint(pcall(table.sort, {3, 2, 1}, cmp))")
probe("gsub_fn_recursion", "local function r(m) return (string.gsub('a', 'a', r)) end\nprint(pcall(string.gsub, 'a', 'a', r))")
probe("deep_depth_10000_index_fn", "local t = setmetatable({}, {}); getmetatable(t).__index = function(s, k) if k == 0 then return 0 end return s[k - 1] end\nprint(pcall(function() return t[5000] end))", lim="lim 50000000 10000 1000000 33554432 1048576", note="host raised max_call_depth to 10000")
probe("deep_depth_100000_lua", "local function f(n) if n == 0 then return 0 end return 1 + f(n - 1) end\nprint(pcall(f, 90000))", lim="lim 500000000 100000 10000000 268435456 1048576", note="host raised max_call_depth to 1e5")
# --- parser / compiler nesting ---
for n in (200, 1000, 10000, 100000):
    probe("parse_parens_%d" % n, "return " + "(" * n + "1" + ")" * n)
for n in (300, 400):
    probe("parse_add_%d" % n, "return 1" + " + 1" * n, note="wasm32 host-stack threshold")
for n in (1000, 100000):
    probe("parse_tables_%d" % n, "return " + "{" * n + "}" * n)
    probe("parse_unary_%d" % n, "return " + "-" * n + "1")
    probe("parse_not_%d" % n, "return " + "not " * n + "1")
    probe("parse_concat_%d" % n, "local a = 'x' return a" + " .. a" * n)
    probe("parse_pow_%d" % n, "return 1" + " ^ 1" * n)
    probe("parse_add_%d" % n, "return 1" + " + 1" * n)
    probe("parse_dots_%d" % n, "local a = {} return a" + ".b" * n)
    probe("parse_calls_%d" % n, "local function f() return f end return f" + "()" * n)
    probe("parse_blocks_%d" % n, "do " * n + "end " * n)
    probe("parse_funcs_%d" % n, "return " + "function() return " * n + "1" + " end" * n)
    probe("parse_ifs_%d" % n, "if true then " * n + "end " * n)
# --- fuel bypass in native library loops ---
probe("const_pool_60k_compile_time", "local t = {" + ",".join("'x%d'" % i for i in range(1, 60001)) + "} print(#t)", note="O(n^2) constant dedupe; compile is not fuel-metered")
probe("long_string_key_hash", "local k = ('a'):rep(1000000) local t = {[k] = 1} local n = 0 for i = 1, 2000 do n = n + t[k] end print(n)", note="string key re-hashed (copied) per access")
probe("move_maxint", "print(pcall(table.move, {1}, 1, math.maxinteger, 2))", note="Lua: 'too many elements to move'")
probe("move_1e9", "print(pcall(table.move, {}, 1, 1e9, 2))", note="1e9 iterations under fuel=5e7")
probe("move_1e9_tight", "print(pcall(table.move, {}, 1, 1e9, 2))", lim="lim 100000 200 16384 33554432 1048576")
probe("unpack_1e8", "print(pcall(table.unpack, {}, 1, 1e8))")
probe("unpack_1e6", "print(pcall(table.unpack, {}, 1, 1e6))")
probe("concat_range_1e9", "print(pcall(table.concat, setmetatable({}, {__index = function() return 'x' end}), '', 1, 1e9))")
probe("insert_shift_big", "local t = {} for i = 1, 200000 do t[i] = i end\nfor i = 1, 200 do table.insert(t, 1, 0) end print(#t)", lim="lim 300000 200 16384 33554432 1048576", note="each insert shifts 2e5 slots")
probe("remove_shift_big", "local t = {} for i = 1, 200000 do t[i] = i end\nfor i = 1, 200 do table.remove(t, 1) end print(#t)", lim="lim 300000 200 16384 33554432 1048576")
probe("sort_big_default_cmp", "local t = {} for i = 1, 300000 do t[i] = (i * 7919) % 300007 end table.sort(t) print(t[1], t[#t])", lim="lim 1000000 200 16384 33554432 1048576", note="native sort under 1e6 fuel")
probe("sort_lua_cmp_fuel", "local t = {} for i = 1, 100000 do t[i] = (i * 7919) % 100003 end table.sort(t, function(a, b) return a < b end) print(t[1])", lim="lim 1000000 200 16384 33554432 1048576")
probe("rep_fuel", "local s = ('x'):rep(1000000) print(#s)", lim="lim 100000 200 16384 33554432 1048576")
probe("rep_concat_loop", "local s = 'x' for i = 1, 24 do s = s .. s end print(#s)")
probe("find_plain_long", "local s = ('a'):rep(2000000) local p = ('a'):rep(1000000) .. 'b' print(s:find(p, 1, true))", note="plain find O(n*m) without fuel?")
probe("find_backtrack", "print(pcall(string.find, ('a'):rep(5000), ('a*'):rep(10) .. 'b'))")
probe("gmatch_backtrack", "print(pcall(function() for x in (('a'):rep(3000)):gmatch(('a-'):rep(10) .. 'b') do end end))")
probe("balance_long", "print(pcall(string.find, ('('):rep(1000000), '%b()'))")
probe("byte_loop_quadratic", "local s = ('a'):rep(200000) local n = 0 for i = 1, #s do n = n + s:byte(i) end print(n)", note="string_to_bytes copies whole string per call?")
probe("sub_loop_quadratic", "local s = ('a'):rep(200000) local n = 0 for i = 1, #s do n = n + #s:sub(i, i) end print(n)")
probe("upper_loop", "local s = ('a'):rep(100000) for i = 1, 300 do s:upper() end print(1)")
probe("len_loop", "local s = ('a'):rep(1000000) local n = 0 for i = 1, 1000 do n = n + #s end print(n)")
probe("hash_int_collide", "local t = {} for i = 1, 200000 do t[i * 1048576] = i end local n = 0 for k in pairs(t) do n = n + 1 end print(n)")
probe("hash_float_collide", "local t = {} for i = 1, 200000 do t[i + 0.5] = i end print(t[100.5])")
probe("hash_str_collide", "local t = {} for i = 1, 200000 do t['k' .. i] = i end print(t.k777)")
probe("next_quadratic", "local t = {} for i = 1, 50000 do t['k' .. i] = i end local n = 0 for k, v in pairs(t) do n = n + 1 end print(n)")
probe("next_delete_quadratic", "local t = {} for i = 1, 50000 do t['k' .. i] = i end for k in pairs(t) do t[k] = nil end print(next(t))")
# --- memory budget bypass (32-bit Int overflow, check-after-build, no GC) ---
probe("rep_int32_trunc", "print(#('x'):rep(2^32 + 3))", note="count.to_int() truncates Int64 -> Int32")
probe("rep_total_overflow", "local s = ('a'):rep(1000000) print(pcall(function() return #s:rep(2148) end))", note="2148*1e6 > 2^31: charge_mem(negative) skipped")
probe("rep_total_overflow_wrap", "local s = ('a'):rep(1000000) print(pcall(function() return #s:rep(4295) end))", note="4295e6 mod 2^32 = 32704")
probe("rep_sep_overflow", "local s = ('a'):rep(1000000) print(pcall(function() return #('b'):rep(2148, s) end))")
probe("rep_mem_limit", "print(pcall(string.rep, 'x', 1e9))")
probe("concat_check_after_build", "local s = ('a'):rep(1000000) local t = {} for i = 1, 30 do t[i] = s end print(pcall(function() return #table.concat(t):rep(1) end)) local u = {} for i = 1, 2000 do u[i] = s end print(pcall(table.concat, u))", note="table.concat builds 2 GB before charge_mem")
probe("gsub_expand", "local s = ('a'):rep(20000) print(pcall(function() return #s:gsub('a', s) end))", note="4e8 byte result")
probe("format_width_huge", "print(pcall(string.format, '%099999999d', 1))")
probe("format_prec_huge", "print(pcall(string.format, '%.99999999f', 1))")
probe("format_many_width", "local t = {} for i = 1, 200 do t[i] = '%99s' end local f = table.concat(t) local args = {} for i = 1, 200 do args[i] = 'x' end for i = 1, 2000 do local s = string.format(f, table.unpack(args)) end print(1)")
probe("tables_no_gc", "for i = 1, 1000000 do local t = {} end print('ok')", note="1e6 short-lived tables, legit Lua")
probe("strings_no_gc", "local n = 0 for i = 1, 200000 do local s = 'abc' .. i .. 'def' n = n + #s end print(n)", note="legit workload: garbage strings")
probe("closures_no_gc", "local n = 0 for i = 1, 300000 do local f = function() return i end n = n + f() end print(n)")
probe("tables_no_gc_host_rss", "for i = 1, 400000 do local t = {} end print('ok')", lim="lim 5000000000 200 16384 2000000000 1048576", note="memory limit raised: does host RSS grow without bound?")
probe("table_grow_mem_charge", "local t = {} for i = 1, 3000000 do t[i] = i end print(#t)", note="3e6 ints (~48 MB) vs 32 MiB limit")
probe("table_hash_grow_mem_charge", "local t = {} for i = 1, 1000000 do t[-i] = i end print(1)")
probe("setlist_ctor_mem", "local t = {} for i = 1, 100000 do t[i] = {1, 2, 3, 4, 5, 6, 7, 8} end print(#t)")
probe("varargs_mem", "local function f(...) return select('#', ...) end local t = {} for i = 1, 10000 do t[i] = i end local n = 0 for i = 1, 2000 do n = n + f(table.unpack(t)) end print(n)")
probe("upvalue_arena_leak", "local n = 0 for i = 1, 2000000 do local x = i local f = function() return x end n = n + 1 end print(n)", lim="lim 100000000 200 16384 2000000000 1048576")
# --- output ---
probe("print_huge_line", "print(pcall(print, ('x'):rep(2000000)))")
probe("print_many_args", "local t = {} for i = 1, 10000 do t[i] = ('x'):rep(200) end print(pcall(print, table.unpack(t)))")
# --- pcall must not swallow limits ---
probe("pcall_swallow_fuel", "print(pcall(function() while true do end end)) print('after')", lim="lim 100000 200 16384 33554432 1048576")
probe("pcall_swallow_mem", "print(pcall(string.rep, 'x', 100000000)) print('after')")
probe("xpcall_swallow_stack", "local function f() return f() + 1 end print(xpcall(f, function(m) return 'handled' end)) print('after')")
probe("error_object_mem_limit", "print(pcall(error, ('x'):rep(30000000))) print('after')")
probe("xpcall_handler_loop", "print(xpcall(function() error('x') end, function(m) while true do end end))", lim="lim 100000 200 16384 33554432 1048576")
probe("sort_swallow_fuel", "local t = {} for i = 1, 1000 do t[i] = i end print(pcall(table.sort, t, function(a, b) while true do end end)) print('after')", lim="lim 100000 200 16384 33554432 1048576")
probe("gsub_cb_swallow_fuel", "print(pcall(string.gsub, 'aaa', 'a', function() while true do end end)) print('after')", lim="lim 100000 200 16384 33554432 1048576")

def main():
    a = sys.argv[1:]
    bin_dir, out_dir = a[0], a[1]
    only, modes, timeout = None, ["rel", "dbg", "wrel", "wdbg"], 60
    i = 2
    while i < len(a):
        if a[i] == "--only": only = set(a[i + 1].split(",")); i += 2
        elif a[i] == "--modes": modes = a[i + 1].split(","); i += 2
        elif a[i] == "--timeout": timeout = int(a[i + 1]); i += 2
        else: i += 1
    os.makedirs(out_dir, exist_ok=True)
    rt = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
    results = {}
    for name, (src, lim, note) in P.items():
        if only and name not in only: continue
        path = os.path.join(out_dir, name + ".lua")
        with open(path, "w") as f: f.write(src)
        lim_args = lim.split()
        row = {"note": note, "lim": lim}
        for m in modes:
            if m in ("rel", "dbg"):
                cmd = [os.path.join(bin_dir, "drv_" + m)] + lim_args + [path]
            else:
                cmd = ["node", "--stack-size=984", rt, os.path.join(bin_dir, "drv_%s.wasm" % m[1:])] + lim_args + [path]
            t0 = time.time()
            try:
                p = subprocess.run(["/usr/bin/time", "-l"] + cmd, capture_output=True, timeout=timeout)
                rc = p.returncode; out = p.stdout.decode("latin-1"); err = p.stderr.decode("latin-1")
                m_rss = re.search(r"(\d+)\s+maximum resident set size", err)
                rss = int(m_rss.group(1)) / 1048576 if m_rss else -1
                tail = [l for l in err.splitlines() if "maximum resident" not in l and l.strip() and not re.match(r"^\s+\d+\s+\w", l) and "real" not in l]
            except subprocess.TimeoutExpired:
                rc, out, rss, tail = "TIMEOUT", "", -1, []
            dt = time.time() - t0
            body = [l for l in out.splitlines() if not l.startswith("## ") and not l.startswith("#stats")]
            row[m] = {"rc": rc, "ms": round(dt * 1000), "rss_mb": round(rss, 1), "out": "\n".join(body)[-600:], "stderr": "\n".join(tail)[-300:]}
        results[name] = row
        summ = " | ".join("%s rc=%s %dms %.0fMB" % (m, row[m]["rc"], row[m]["ms"], row[m]["rss_mb"]) for m in modes)
        first = row[modes[0]]["out"].replace("\n", " ⏎ ")[:220]
        print("%-28s %s\n    %s" % (name, summ, first), flush=True)
    with open(os.path.join(out_dir, "probes.json"), "w") as f: json.dump(results, f, indent=1)

main()
