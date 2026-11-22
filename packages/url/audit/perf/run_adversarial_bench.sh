#!/bin/sh
# Adversarial throughput head-to-head (Pion vs Rust url v2.5.9 --release) through the
# differential drivers, via the repository's scripts/bench_compare.py (SHA-256 gated).
# Usage: sh run_adversarial_bench.sh <bin_dir> <out_dir>
set -eu
PERF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PERF_DIR/../../../.." && pwd)
BIN=$1
OUT=$2
mkdir -p "$OUT/adv"
python3 "$PERF_DIR/gen_adversarial.py" "$OUT/adv" >/dev/null
: > "$OUT/adversarial_bench.md"
for w in adv_idn adv_ipv6 adv_ipv4 adv_pct adv_big_url adv_query_sort adv_setters adv_join; do
  for kind in "" ".noop"; do
    in="$OUT/adv/$w$kind.in"
    bytes=$(wc -c < "$in" | tr -d ' ')
    ops=$(wc -l < "$in" | tr -d ' ')
    python3 "$ROOT_DIR/scripts/bench_compare.py" \
      --title "url audit: $w$kind ($ops cases)" \
      --impl "pion=$BIN/pion_diff < $in" \
      --impl "rust_url=$BIN/rust_diff < $in" \
      --baseline rust_url --warmup 1 --rounds 5 --ops "$ops" --bytes "$bytes" \
      --md-out "$OUT/adv/$w$kind.md" --json-out "$OUT/adv/$w$kind.json" >/dev/null
    { echo "#### $w$kind ($ops cases, $bytes B)"; echo; sed -n '/^| Implementation/,$p' "$OUT/adv/$w$kind.md"; echo; } >> "$OUT/adversarial_bench.md"
  done
done
cat "$OUT/adversarial_bench.md"
python3 - "$OUT/adv" > "$OUT/adversarial_net.md" <<'PY'
import json, os, statistics, sys
d = sys.argv[1]
print("| workload | cases | pion median (ms) | rust median (ms) | driver no-op pion / rust (ms) | "
      "net pion (ms) | net rust (ms) | net pion/rust speed |")
print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
for w in ["adv_idn", "adv_ipv6", "adv_ipv4", "adv_pct", "adv_big_url", "adv_query_sort", "adv_setters", "adv_join"]:
    def med(name):
        j = json.load(open(os.path.join(d, name + ".json")))
        return {r["name"]: statistics.median(r["samples_ms"]) for r in j["results"]}, j["ops"]
    full, ops = med(w)
    noop, _ = med(w + ".noop")
    np_, nr = full["pion"] - noop["pion"], full["rust_url"] - noop["rust_url"]
    print("| %s | %d | %.1f | %.1f | %.1f / %.1f | %.1f | %.1f | **%.2fx** |" % (
        w, ops, full["pion"], full["rust_url"], noop["pion"], noop["rust_url"], np_, nr, nr / np_))
PY
echo; echo "Net of driver overhead (median - no-op median; >1x = Pion faster):"; cat "$OUT/adversarial_net.md"
