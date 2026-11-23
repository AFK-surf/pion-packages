#!/bin/sh
# Copy h2 0.4.20's private HPACK module (decoder/encoder/table/huffman/header) + ext.rs into <dst>/src.
# usage: vendor_h2_hpack.sh <dst_project_dir>
set -eu
DST=$1
H2=$(ls -d "${CARGO_HOME:-$HOME/.cargo}"/registry/src/*/h2-0.4.20 2>/dev/null | head -1)
if [ -z "$H2" ]; then
  # fetch the crate source into the cargo registry (network), then retry
  T=$(mktemp -d); (cd "$T" && cargo init -q --name fetch_h2 && echo 'h2 = "=0.4.20"' >> Cargo.toml && cargo fetch -q); rm -rf "$T"
  H2=$(ls -d "${CARGO_HOME:-$HOME/.cargo}"/registry/src/*/h2-0.4.20 | head -1)
fi
rm -rf "$DST/src/hpack"
cp -R "$H2/src/hpack" "$DST/src/hpack"
rm -rf "$DST/src/hpack/test"
cp "$H2/src/ext.rs" "$DST/src/ext.rs"
# drop the only dependency on h2's frame module
python3 - "$DST/src/hpack/decoder.rs" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
s = s.replace("use crate::frame;\n", "")
s = re.sub(r"impl From<DecoderError> for frame::Error \{.*?\n\}\n", "", s, flags=re.S)
open(p, "w").write(s)
PY
echo "vendored h2 hpack from $H2"
