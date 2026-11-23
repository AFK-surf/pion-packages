#!/bin/sh
# Run the Pion differential driver in 4 build modes (native/wasm32 x debug/release) over one corpus and
# compare transcripts byte-for-byte (timing column dropped).
#   sh four_modes.sh <cases.jsonl> <out_dir>
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CASES=$1
OUT=$2
mkdir -p "$OUT"
ref=""
for m in debug release; do
  for t in native wasm32; do
    set --
    [ "$m" = release ] && set -- "$@" --release
    [ "$t" = wasm32 ] && set -- "$@" --target wasm32
    pionc run "$@" "$HERE/pion_driver" -- "$CASES" > "$OUT/mode_$m-$t.tsv" 2> "$OUT/mode_$m-$t.err"
    rc=$?
    h=$(cut -f1,2,3,5 "$OUT/mode_$m-$t.tsv" | shasum -a 256 | cut -c1-16)
    n=$(wc -l < "$OUT/mode_$m-$t.tsv" | tr -d ' ')
    [ -z "$ref" ] && ref=$h
    same=SAME; [ "$h" = "$ref" ] || same=DIFFERENT
    printf '  %-15s rc=%s lines=%s verdict-sha256=%s %s\n' "$m-$t" "$rc" "$n" "$h" "$same"
  done
done
