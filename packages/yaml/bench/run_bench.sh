#!/bin/sh
# Reproducible head-to-head benchmark runner:
# Pion Native (`packages/yaml`) vs Rust (`yaml-rust2`) vs Go (`gopkg.in/yaml.v3`).
# All build artifacts and generated corpora are kept in /tmp (zero worktree pollution).
set -eu

PKG_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT_DIR=$(CDPATH= cd -- "$PKG_DIR/../.." && pwd)
TMP_DIR="${TMPDIR:-/tmp}/pion-yaml-bench"
mkdir -p "$TMP_DIR/rust_src/src" "$TMP_DIR/go_src"

export PATH="${HOME}/.pion/bin:${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/go/bin:${PATH}"

echo "==> Building Pion native release benchmark"
pionc build --release -o "$TMP_DIR/bench_pion" "$PKG_DIR/bench/pion_bench"

echo "==> Building Rust yaml-rust2 release benchmark"
cp "$PKG_DIR/bench/rust_bench/Cargo.toml" "$TMP_DIR/rust_src/Cargo.toml"
cp "$PKG_DIR/bench/rust_bench/src/main.rs" "$TMP_DIR/rust_src/src/main.rs"
CARGO_TARGET_DIR="$TMP_DIR/rust_target" cargo build --release --manifest-path "$TMP_DIR/rust_src/Cargo.toml"
cp "$TMP_DIR/rust_target/release/rust_yaml_bench" "$TMP_DIR/bench_rust"

echo "==> Building Go gopkg.in/yaml.v3 benchmark"
cp "$PKG_DIR/bench/go_bench/go.mod" "$TMP_DIR/go_src/go.mod"
cp "$PKG_DIR/bench/go_bench/main.go" "$TMP_DIR/go_src/main.go"
(
  cd "$TMP_DIR/go_src"
  go mod tidy
  go build -o "$TMP_DIR/bench_go" .
)

echo "==> Generating mixed Kubernetes + GitHub Actions + OpenAPI YAML corpus (~3.0 MB)"
python3 - "$TMP_DIR/corpus_mixed.yaml" << 'PYEOF'
import sys

bundle = """apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway-shard-{i}
  namespace: production
  labels:
    app.kubernetes.io/name: api-gateway
    app.kubernetes.io/component: ingress
    app.kubernetes.io/instance: shard-{i}
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9090"
spec:
  replicas: 4
  revisionHistoryLimit: 10
  paused: false
  selector:
    matchLabels:
      app: api-gateway
      shard: "s{i}"
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: "25%"
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: api-gateway
        shard: "s{i}"
    spec:
      serviceAccountName: gateway-sa
      terminationGracePeriodSeconds: 30
      containers:
        - name: envoy
          image: envoyproxy/envoy:v1.31.2
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
            - name: admin
              containerPort: 9901
              protocol: TCP
          env:
            - name: ENVOY_UID
              value: "1000"
            - name: LOG_LEVEL
              value: "info"
            - name: CLUSTER_NAME
              value: "prod-ap-northeast-1"
            - name: RETRY_BUDGET
              value: "0.25"
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "1000m"
              memory: "1Gi"
          readinessProbe:
            httpGet:
              path: /ready
              port: 9901
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          volumeMounts:
            - name: config
              mountPath: /etc/envoy
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: envoy-config-{i}
---
name: CI Pipeline Shard {i}
on:
  push:
    branches: [main, release/*]
    paths-ignore: ["docs/**", "*.md"]
  pull_request:
    branches: [main]
concurrency:
  group: ci-shard-{i}
  cancel-in-progress: true
permissions:
  contents: read
  checks: write
jobs:
  build-and-test:
    runs-on: ubuntu-24.04
    timeout-minutes: 25
    strategy:
      fail-fast: false
      matrix:
        target: [arm64_apple, amd64_sysv, wasm32]
        profile: [debug, release]
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 1
      - name: Verify formatting and tests
        run: |
          export PATH="$HOME/.pion/bin:$PATH"
          pionc fmt --check packages/yaml
          pionc check --json packages/yaml
          pionc test --json packages/yaml
      - name: Summary note
        run: >-
          echo "Completed shard {i} verification
          across native and wasm32 targets"
---
openapi: "3.1.0"
info:
  title: Control Plane API Shard {i}
  version: "2.4.1"
  description: "Multi-region workload orchestration and telemetry ingestion API."
servers:
  - url: https://api-{i}.example.internal/v2
    description: Regional endpoint
paths:
  /v2/workloads:
    get:
      operationId: listWorkloads_{i}
      summary: List active workloads
      parameters:
        - name: namespace
          in: query
          required: false
          schema:
            type: string
        - name: limit
          in: query
          required: false
          schema:
            type: integer
            minimum: 1
            maximum: 500
            default: 50
      responses:
        "200":
          description: Successful response
          content:
            application/json:
              schema:
                type: object
                required: [items, total]
                properties:
                  total:
                    type: integer
                  ratio:
                    type: number
                    example: 0.995
                  items:
                    type: array
                    items:
                      type: object
                      properties:
                        id:
                          type: string
                        healthy:
                          type: boolean
                        replicas:
                          type: integer
                        tags:
                          type: array
                          items:
                            type: string
"""

target_bytes = 3_000_000
chunks = []
total = 0
idx = 0
while total < target_bytes:
    s = bundle.format(i=idx)
    if idx > 0:
        s = "---\n" + s
    chunks.append(s)
    total += len(s.encode("utf-8"))
    idx += 1

out_bytes = "".join(chunks).encode("utf-8")
open(sys.argv[1], "wb").write(out_bytes)
print(f"Generated {len(out_bytes)} bytes ({idx * 3} YAML documents)")
PYEOF

CORPUS_BYTES=$(wc -c < "$TMP_DIR/corpus_mixed.yaml" | tr -d ' ')
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "YAML 1.2 Parse + Canonical JSON (Mixed K8s + CI + OpenAPI, 3.0 MB)" \
  --impl "rust_yaml_rust2=$TMP_DIR/bench_rust $TMP_DIR/corpus_mixed.yaml" \
  --impl "go_yaml_v3=$TMP_DIR/bench_go $TMP_DIR/corpus_mixed.yaml" \
  --impl "pion_yaml=$TMP_DIR/bench_pion $TMP_DIR/corpus_mixed.yaml" \
  --baseline rust_yaml_rust2 \
  --warmup 1 --rounds 5 --bytes "$CORPUS_BYTES"
