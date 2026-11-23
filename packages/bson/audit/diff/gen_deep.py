"""Write single-request oracle files for nesting-depth probes:
<out>/deep_bson_<n>.tsv (B: n-deep {"a":{"a":...}}) and <out>/deep_json_<n>.tsv (J: the same as Extended JSON).
usage: gen_deep.py <out_dir> <n>..."""
import struct
import sys

out = sys.argv[1]
for n in map(int, sys.argv[2:]):
    total = 5 + 8 * n
    b = bytearray(total)
    for i in range(n + 1):
        s = 7 * i
        b[s:s + 4] = struct.pack("<i", total - 8 * i)
        if i < n:
            b[s + 4:s + 7] = b"\x03a\x00"
    open("%s/deep_bson_%d.tsv" % (out, n), "w").write("B\t" + bytes(b).hex() + "\n")
    j = ('{"a":' * n + "{}" + "}" * n).encode()
    open("%s/deep_json_%d.tsv" % (out, n), "w").write("J\t" + j.hex() + "\n")
