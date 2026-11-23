#!/bin/sh
# Head-to-head benchmark runner for packages/jq:
# Pion Native (--release) vs Go (`github.com/itchyny/gojq`).
# All build artifacts and generated datasets are isolated in /tmp/w12-jq-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/w12-jq-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_DIR="$OUT_DIR/data"
ROUNDS="${BENCH_ROUNDS:-5}"

mkdir -p "$BIN_DIR" "$DATA_DIR"

echo "==> Generating deterministic benchmark datasets in $DATA_DIR"
python3 - "$DATA_DIR" <<'PY'
import json, os, sys

data_dir = sys.argv[1]

# W1: 10,000 K8s/API events
namespaces = ["prod-api", "prod-worker", "staging-web", "dev-ml", "kube-system", "payments", "search", "auth"]
kinds = ["Pod", "Service", "Ingress", "Job", "Deployment"]
w1 = []
for i in range(10000):
    w1.append({
        "id": i,
        "ns": namespaces[(i * 7 + 3) % len(namespaces)],
        "kind": kinds[i % len(kinds)],
        "service": f"svc-{(i * 13) % 40}",
        "latency_ms": ((i * 37 + 11) % 250) + 1,
        "status": 200 if (i % 5) != 0 else 503,
        "ok": (i % 5) != 0,
    })
with open(os.path.join(data_dir, "w1.json"), "w", encoding="utf-8") as f:
    json.dump(w1, f, separators=(",", ":"))

# W2: Deeply nested JSON tree (~1,365 nodes across 5 levels)
def make_tree(depth, idx):
    node = {
        "id": f"n-{depth}-{idx}",
        "score": ((idx * 19 + depth * 7) % 100) + 1,
        "active": ((idx + depth) % 2) == 0,
        "meta": {"tag": f"t-{idx % 10}", "weight": (idx % 5) + 1},
    }
    if depth > 0:
        node["children"] = [make_tree(depth - 1, idx * 4 + c) for c in range(4)]
    return node

w2 = make_tree(4, 1)
with open(os.path.join(data_dir, "w2.json"), "w", encoding="utf-8") as f:
    json.dump(w2, f, separators=(",", ":"))

# W3: Structured e-commerce + nested tree document for Compile + Eval
skus = ["AB-101", "CD-202", "bad_sku", "EF-303", "GH-404", "X-9", "IJ-505", "KL-606"]
cats = ["books", "electronics,home", "toys", "music"]
w3 = {
    "items": [
        {
            "sku": skus[i % len(skus)],
            "category": cats[i % len(cats)],
            "price": ((i * 17) % 90) + 10,
            "qty": (i % 5) + 1,
        }
        for i in range(40)
    ],
    "nested": {
        "a": [1, 2, {"x": 3, "y": [4, 5, {"z": 6}]}],
        "b": {"m": [7, 8, 9], "n": {"p": 10, "q": [11, 12]}},
    },
}
with open(os.path.join(data_dir, "w3.json"), "w", encoding="utf-8") as f:
    json.dump(w3, f, separators=(",", ":"))
PY

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_jq_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Go (github.com/itchyny/gojq) benchmark (isolated in $OUT_DIR)"
rm -rf "$OUT_DIR/go-proj"
mkdir -p "$OUT_DIR/go-proj"
cp "$BENCH_DIR/go/go.mod" "$BENCH_DIR/go/go.sum" "$BENCH_DIR/go/main.go" "$OUT_DIR/go-proj/"
(cd "$OUT_DIR/go-proj" && go build -o "$BIN_DIR/go_jq_bench" .)

W1_BYTES=$(wc -c < "$DATA_DIR/w1.json" | tr -d ' ')
W2_BYTES=$(wc -c < "$DATA_DIR/w2.json" | tr -d ' ')

echo ""
echo "=== W1: 10,000 K8s/API Events Aggregation Pipeline (5 iters) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: 10k K8s/API Events Aggregation (select + group_by + map + sort_by, 5x)" \
  --impl "pion=$BIN_DIR/pion_jq_bench w1 $DATA_DIR/w1.json" \
  --impl "gojq=$BIN_DIR/go_jq_bench w1 $DATA_DIR/w1.json" \
  --baseline gojq \
  --warmup 1 --rounds "$ROUNDS" --bytes "$((W1_BYTES * 5))" \
  --md-out "$OUT_DIR/w1.md" --json-out "$OUT_DIR/w1.json"

echo ""
echo "=== W2: Deep Nested Tree Recursive Extract + |= Update (10 iters) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Deep Nested Tree Extract + |= Path Rewrite (10x)" \
  --impl "pion=$BIN_DIR/pion_jq_bench w2 $DATA_DIR/w2.json" \
  --impl "gojq=$BIN_DIR/go_jq_bench w2 $DATA_DIR/w2.json" \
  --baseline gojq \
  --warmup 1 --rounds "$ROUNDS" --bytes "$((W2_BYTES * 10))" \
  --md-out "$OUT_DIR/w2.md" --json-out "$OUT_DIR/w2.json"

echo ""
echo "=== W3: End-to-End Compile + Eval (200 rounds x 5 queries = 1,000 ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: End-to-End Compile + Eval (1,000 queries: reduce, def, interp, @csv, test)" \
  --impl "pion=$BIN_DIR/pion_jq_bench w3 $DATA_DIR/w3.json" \
  --impl "gojq=$BIN_DIR/go_jq_bench w3 $DATA_DIR/w3.json" \
  --baseline gojq \
  --warmup 1 --rounds "$ROUNDS" --ops 1000 \
  --md-out "$OUT_DIR/w3.md" --json-out "$OUT_DIR/w3.json"
