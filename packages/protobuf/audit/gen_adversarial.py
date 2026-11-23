#!/usr/bin/env python3
"""Adversarial inputs for packages/protobuf DoS / performance probes.

usage: gen_adversarial.py <outdir>

Every *.bin is a stream of records, each prefixed by a 4-byte little-endian length (the same
framing as packages/protobuf/bench/gen_corpus.py); every *.proto is the schema to decode it with.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pbvec import ld, tag, varint, vi  # noqa: E402

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)


def save(name, records):
    with open(os.path.join(OUT, name + ".bin"), "wb") as f:
        for r in records:
            f.write(struct.pack("<I", len(r)))
            f.write(r)


def proto(name, src):
    with open(os.path.join(OUT, name + ".proto"), "w") as f:
        f.write(src)


# 1. Repeated occurrences of one singular sub-message field are merged (spec).
#    Pion's merge copies every previous field + unknown field of the sub-message per occurrence.
proto("merge", 'syntax = "proto3";\nmessage Inner { int32 x = 1; }\nmessage Outer { Inner inner = 1; }\n')
for n in (5000, 10000, 20000, 40000):
    unit = ld(1, vi(99, 1))  # Outer.inner { unknown 99: 1 }
    save("merge_unknown_%d" % n, [unit * n])
    save("merge_known_%d" % n, [ld(1, vi(1, 7)) * n])  # control: no unknown fields

# 2. Wide message: field lookup by number is a linear scan over the descriptor.
for f in (2000, 8000, 16000):
    proto("wide_%d" % f, 'syntax = "proto3";\nmessage W {\n' +
          "".join("  int32 f%d = %d;\n" % (i, i) for i in range(1, f + 1)) + "}\n")
    save("wide_%d" % f, [b"".join(vi(i, 1) for i in range(1, f + 1))])

# 3. Large schema: every message-typed field occurrence re-runs schema-wide DFS searches
#    (first for an *enum* of that name, then for a message) instead of a resolved descriptor.
for t in (500, 2000, 4000):
    src = ['syntax = "proto3";\npackage big.v1;\n']
    for i in range(t):
        src.append("message Filler%d { enum K%d { Z%d = 0; } int32 a = 1; }\n" % (i, i, i))
    src.append("message Leaf { int32 v = 1; }\nmessage Root { repeated Leaf leaves = 1; }\n")
    proto("bigschema_%d" % t, "".join(src))
    save("bigschema_%d" % t, [ld(1, vi(1, 1)) * 20000])

# 4. Maps: 50,000 distinct entries (linear expected everywhere) and 50,000 duplicates of one key.
proto("map", 'syntax = "proto3";\nmessage M { map<string, int64> m = 1; }\n')
save("map_50000_distinct", [b"".join(ld(1, ld(1, "key-%06d" % i) + vi(2, i)) for i in range(50000))])
save("map_50000_dupkey", [ld(1, ld(1, "k") + vi(2, 1)) * 50000])

# 5. Many unknown fields at top level (linear expected).
proto("unknown", 'syntax = "proto3";\nmessage U { int32 a = 1; }\n')
save("unknown_100000", [b"".join(vi(2 + (i % 1000), i) for i in range(100000))])

# 6. Realistic head-to-head: the official OTel span corpus decoded *dynamically*.
proto("spans", """syntax = "proto3";
message KeyValue { string key = 1; string str_value = 2; int64 int_value = 3; }
message SpanEvent { uint64 time_unix_nano = 1; string name = 2; int32 dropped_attributes = 3; }
message Span {
  bytes trace_id = 1; bytes span_id = 2; string name = 3; int32 kind = 4;
  uint64 start_time_unix_nano = 5; uint64 end_time_unix_nano = 6;
  repeated KeyValue attributes = 7; repeated SpanEvent events = 8;
  int32 status_code = 9; string status_message = 10;
}
""")

# 7. Schema-parser stress: one message with N fields (duplicate-number check is O(N^2)).
for f in (10000, 18000):  # stays below the reserved 19000..19999 range
    with open(os.path.join(OUT, "schema_fields_%d.proto" % f), "w") as fh:
        fh.write('syntax = "proto3";\nmessage W {\n' + "".join("  int32 f%d = %d;\n" % (i, i) for i in range(1, f + 1)) + "}\n")

print("wrote adversarial corpus to", OUT)
